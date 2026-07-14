//
//  PTTCaptureEngine.swift
//  Core/Media
//
//  Step 3 of BLE-live push-to-talk: the AVAudioEngine capture tap. The single
//  capture client for the walkie globe — a DROP-IN for VoiceRecorder's public
//  contract (start/stop/cancel/permissionDenied/levels) so it swaps in at the
//  globe call sites without touching the composer's own VoiceRecorder.
//
//  One capture forks POST-CONVERSION so the note and the Opus stream are the
//  identical audio:
//    hardware format → AVAudioConverter → 48 kHz mono Float32, then
//      (a) .m4a note   — written straight to an AAC AVAudioFile (Float fits), and
//      (b) Opus stream — sliced to exact 960-sample frames across tap-buffer
//                        seams and encoded (this step counts/sizes them and
//                        discards — NO transport yet).
//
//  Session handling replicates VoiceRecorder EXACTLY (the music-resume
//  invariant): take over with `.playAndRecord`/`.defaultToSpeaker`, no
//  `.mixWithOthers`/`.duckOthers`, and hand back with
//  `.notifyOthersOnDeactivation` on every stop/cancel.
//

import Foundation
import AVFoundation
import Observation

// MARK: - Pure DSP (unit-tested, no hardware)

/// Accumulates Float32 samples and emits exact `frameSize`-sample frames,
/// carrying the remainder across buffer boundaries so no sample is dropped or
/// duplicated at a tap-buffer seam.
struct OpusFrameSlicer {
    let frameSize: Int
    private var buffer: [Float] = []

    init(frameSize: Int = OpusVoiceCodec.samplesPerFrame) { self.frameSize = frameSize }

    /// Append `samples`; return every complete frame now available.
    mutating func push(_ samples: [Float]) -> [[Float]] {
        buffer.append(contentsOf: samples)
        var out: [[Float]] = []
        while buffer.count >= frameSize {
            out.append(Array(buffer.prefix(frameSize)))
            buffer.removeFirst(frameSize)
        }
        return out
    }

    var remainderCount: Int { buffer.count }
}

enum PTTCaptureDSP {
    /// Float32 [-1, 1] → Int16 PCM (clamped) — the shape `OpusVoiceCodec.encode`
    /// expects. Overshoot is clamped, not wrapped.
    static func int16(_ f: Float) -> Int16 {
        Int16(max(-1, min(1, f)) * 32767)
    }
    static func int16Frame(_ f: [Float]) -> [Int16] { f.map(int16) }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var acc: Float = 0
        for s in samples { acc += s * s }
        return (acc / Float(samples.count)).squareRoot()
    }

    /// dBFS at which the meter reads silent — identical to VoiceRecorder.
    static let silenceFloor: Float = -50

    /// dBFS → 0…1, byte-for-byte the mapping `VoiceRecorder.normalized` uses so
    /// the sphere's outbound response is visually identical.
    static func normalized(_ db: Float) -> CGFloat {
        guard db.isFinite else { return 0 }
        let clamped = max(silenceFloor, min(0, db))
        return CGFloat((clamped - silenceFloor) / -silenceFloor)
    }

    /// Linear RMS → the same 0…1 meter the sphere binds today.
    static func meterLevel(rms: Float) -> CGFloat {
        normalized(rms > 0 ? 20 * log10(rms) : -.infinity)
    }
}

// MARK: - Audio-thread pipeline (runs on the render thread, off the main actor)

/// Convert → fork(note + Opus) → meter, driven by the tap on the audio thread.
/// `@unchecked Sendable`: its mutable state is only ever touched from that one
/// tap thread; the only cross-thread hop is the `onLevel` callback.
final class PTTCapturePipeline: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    private let hwSampleRate: Double
    /// Optional so `finalize()` can nil the sole reference and close the file.
    private var file: AVAudioFile?
    private let codec: OpusVoiceCodec.Encoder
    private var slicer = OpusFrameSlicer()
    private let onLevel: (CGFloat) -> Void
    /// Live-session seal seam (PTT Part B). BOTH nil on the note-only path,
    /// which then behaves exactly as before (encode + discard). The sealer is
    /// render-thread-confined after the coordinator's one-shot handoff (I2);
    /// this thread is serial, so its counter needs no lock (I3). `send` is the
    /// fire-and-forget transport closure (I1 — never blocks this thread).
    private let sealer: PTTFrameSealer?
    private let send: (@Sendable (Data) -> Void)?

    init(hwFormat: AVAudioFormat, targetFormat: AVAudioFormat, fileURL: URL,
         onLevel: @escaping (CGFloat) -> Void,
         sealer: PTTFrameSealer? = nil,
         send: (@Sendable (Data) -> Void)? = nil) throws {
        guard let conv = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw PTTCaptureError.converterUnavailable
        }
        self.converter = conv
        self.targetFormat = targetFormat
        self.hwSampleRate = hwFormat.sampleRate
        self.file = try AVAudioFile(forWriting: fileURL,
                                    settings: [AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                                               AVSampleRateKey: 48_000.0,
                                               AVNumberOfChannelsKey: 1],
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
        self.codec = try OpusVoiceCodec.Encoder()
        self.onLevel = onLevel
        self.sealer = sealer
        self.send = send
    }

    func process(_ hwBuffer: AVAudioPCMBuffer) {
        // hardware → 48 kHz mono Float32 (rate conversion — the input-block API).
        let ratio = targetFormat.sampleRate / hwSampleRate
        let capacity = AVAudioFrameCount(Double(hwBuffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return hwBuffer
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))

        // (a) .m4a note — the same converted audio.
        try? file?.write(from: out)

        // (b) Opus — exact 960-sample frames across seams. With a live session,
        // seal + pack + send ON THIS RENDER THREAD (I1: fire-and-forget, no
        // await, no actor hop, no per-frame Task). Without one (note-only),
        // encoded frames are not sent — today's behavior, unchanged.
        for frame in slicer.push(samples) {
            guard let opus = try? codec.encode(PTTCaptureDSP.int16Frame(frame)) else { continue }
            if let sealer, let send {                                   // live session present
                // Peek-then-seal, NEVER split: `nextCounter` is the counter this
                // seal consumes (serial render thread — I3), so the AAD seq and
                // the packed seq are identical bytes. Splitting the idiom makes
                // every frame fail authentication on the far side.
                let seq = sealer.nextCounter                            // peek; == returned counter
                if let s = try? sealer.seal(opus, aad: PTTAudioWire.aad(forSeq: seq)) {
                    send(PTTAudioWire.pack(seq: s.counter, ciphertext: s.ciphertext, tag: s.tag))
                }
            }
            // sealer == nil → note-only path; encoded frame not sent (fallback unchanged)
        }

        // meter — same dB→0…1 mapping the sphere binds.
        onLevel(PTTCaptureDSP.meterLevel(rms: PTTCaptureDSP.rms(samples)))
    }

    /// Flush + close the .m4a. Nil-ing the SOLE `AVAudioFile` reference runs its
    /// deinit synchronously, writing the AAC moov/trailer and closing the file
    /// before this returns. Must be called AFTER the tap is removed (no more
    /// `process()` can run), so a late buffer can't be dropped.
    func finalize() { file = nil }
}

enum PTTCaptureError: Error { case converterUnavailable, targetFormatUnavailable }

// MARK: - The capture client (drop-in for VoiceRecorder's contract)

@MainActor
@Observable
final class PTTCaptureEngine {

    private(set) var isRecording = false
    /// Set when mic access is denied — same surface the globe's mic-denied cover
    /// reads, so that path keeps working unchanged.
    private(set) var permissionDenied = false
    /// Rolling 0…1 meter, same name/type/mapping VoiceRecorder exposes so the
    /// sphere binds it as a drop-in.
    private(set) var levels: [CGFloat] = []
    private static let maxLevels = 48

    private let engine = AVAudioEngine()
    private var pipeline: PTTCapturePipeline?
    private var fileURL: URL?

    // MARK: Lifecycle

    /// `live` (PTT Part B): the coordinator's one-shot sealer + send handoff for
    /// a live walkie session. Defaults nil — note-only callers pass nothing and
    /// get today's behavior exactly (encode + discard, .m4a note unchanged).
    func start(live: PTTLiveSend? = nil) async {
        guard !isRecording else { return }
        guard await ensurePermission() else { permissionDenied = true; return }
        permissionDenied = false

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)

            let input = engine.inputNode
            let hwFormat = input.inputFormat(forBus: 0)     // real route format — may be 44.1 kHz
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 48_000, channels: 1,
                                             interleaved: false) else {
                throw PTTCaptureError.targetFormatUnavailable
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ptt-\(UUID().uuidString).m4a")
            let pipe = try PTTCapturePipeline(hwFormat: hwFormat, targetFormat: target,
                                              fileURL: url,
                                              onLevel: { [weak self] level in
                                                  Task { @MainActor in self?.appendLevel(level) }
                                              },
                                              sealer: live?.sealer,
                                              send: live?.send)
            // The tap runs `pipe.process` on the render thread; its buffer size is
            // a hint iOS overrides — the slicer's ring buffer absorbs that.
            input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [pipe] buffer, _ in
                pipe.process(buffer)
            }
            engine.prepare()
            try engine.start()

            pipeline = pipe
            fileURL = url
            levels = []
            isRecording = true
        } catch {
            RedactLog.event("[PTTCaptureEngine] start failed", "\(type(of: error))")
            teardownEngine()
            deactivateSession()
            reset()
        }
    }

    /// Stop and return the `.m4a` bytes (nil if nothing usable) — same contract
    /// as `VoiceRecorder.stop()`.
    func stop() -> Data? {
        guard isRecording, let url = fileURL else { finish(); return nil }
        teardownEngine()                        // tap removed → no more process() calls
        pipeline?.finalize()                    // close the AVAudioFile: moov written BEFORE we read
        pipeline = nil                          // now release the pipeline object
        isRecording = false
        let data = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        deactivateSession()
        reset()
        return data
    }

    func cancel() {
        guard isRecording else { return }
        teardownEngine()
        pipeline = nil
        isRecording = false
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        deactivateSession()
        reset()
    }

    // MARK: Internals

    private func appendLevel(_ l: CGFloat) {
        levels.append(l)
        if levels.count > Self.maxLevels { levels.removeFirst(levels.count - Self.maxLevels) }
    }

    private func teardownEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func reset() { pipeline = nil; fileURL = nil }

    private func finish() {
        teardownEngine()
        pipeline = nil
        isRecording = false
        deactivateSession()
        reset()
    }

    private func ensurePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { c in
                AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
            }
        @unknown default: return false
        }
    }
}
