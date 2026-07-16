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

    /// Frames sealed AND handed to the transport this hold — the note-gate's
    /// evidence that the far side actually received audio to hear. Render-
    /// thread confined like the sealer (I3): incremented only on the tap
    /// thread's serial `process()`, no lock. Read from the main actor ONLY
    /// after the tap is removed (`stop()` calls `teardownEngine()` first, so
    /// no `process()` can still be running). Note-only holds never touch it.
    private var sentFrames = 0
    var sentFrameCount: Int { sentFrames }

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
                    sentFrames += 1
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

enum PTTCaptureError: Error {
    case converterUnavailable, targetFormatUnavailable
    /// The input node read 0 Hz / 0 ch twice — dead I/O unit even after an
    /// engine rebuild (mediaserverd itself is wedged). Distinct from
    /// `converterUnavailable`, which means converter creation genuinely failed
    /// between two VALID formats.
    case inputUnavailable
}

// MARK: - The capture client (drop-in for VoiceRecorder's contract)

@MainActor
@Observable
final class PTTCaptureEngine {

    /// Capture lifecycle (Commit 2). `.starting` spans the whole start() window
    /// (500–900 ms healthy; 1175 ms+ under the field's wedged-daemon permission
    /// stall), so "not recording" no longer conflates idle with start-in-flight
    /// — the confusion that let a release land mid-start and leave the mic
    /// running with no hold to end it (field-confirmed: RACE CONFIRMED, then
    /// AUTH-FAILED on the far side as the stale sealer outlived its session).
    enum CaptureState { case idle, starting, recording }
    private var state: CaptureState = .idle
    /// Drop-in for VoiceRecorder's contract — computed, so it can never
    /// disagree with `state`.
    var isRecording: Bool { state == .recording }
    /// Set ONLY by stop()/cancel() landing while `.starting` (release raced
    /// ahead of an in-flight start). The setter does NOTHING else — no
    /// teardown, no session deactivation (an unguarded setActive(false) can
    /// kill a live listen under PTTSessionOwner). start() consumes the flag at
    /// its two abort checkpoints and owns the teardown.
    private var abortRequested = false
    /// True while the CURRENT hold runs with a live session (a sealer + send
    /// were handed to the pipeline). Set alongside `.recording`, consumed by
    /// stop()'s note-gate, cleared in `reset()`. INERT today: shipped callers
    /// pass `live: nil`, so this never goes true until the trigger lands.
    private var liveHold = false
    /// The view-layer hold token that OWNS the current `.starting`/`.recording`
    /// run — recorded at `start(live:holdToken:)`, checked by
    /// `stop(holdToken:)`. A stale caller (a hold whose token the view has
    /// already superseded) reaching stop() with the engine mid-hold for a
    /// LATER press would abort (`.starting` → abortRequested) or kill
    /// (`.recording` → full teardown) that hold. The caller cannot reconstruct
    /// ownership once its token is stale — only the engine can name its owner.
    private var currentHoldToken = 0
    /// Set when mic access is denied — same surface the globe's mic-denied cover
    /// reads, so that path keeps working unchanged.
    private(set) var permissionDenied = false
    /// Rolling 0…1 meter, same name/type/mapping VoiceRecorder exposes so the
    /// sphere binds it as a drop-in.
    private(set) var levels: [CGFloat] = []
    private static let maxLevels = 48

    /// `var`, not `let`: when mediaserverd reconfigures, a persistent engine's
    /// I/O unit can die and its input node reads 0 Hz / 0 ch against a healthy
    /// session — the only recovery is replacing the instance (see
    /// `rebuildEngine()`). Private and never escapes the class, so replacement
    /// is invisible to every caller.
    private var engine = AVAudioEngine()
    private var pipeline: PTTCapturePipeline?
    private var fileURL: URL?

    // MARK: Lifecycle

    /// `live` (PTT Part B): the coordinator's one-shot sealer + send handoff for
    /// a live walkie session. Defaults nil — note-only callers pass nothing and
    /// get today's behavior exactly (encode + discard, .m4a note unchanged).
    func start(live: PTTLiveSend? = nil, holdToken: Int) async {
        guard state == .idle else {
            return }
        state = .starting
        currentHoldToken = holdToken
        guard await ensurePermission() else {
            permissionDenied = true
            abortRequested = false      // a flag set during the perm suspension dies with the hold
            state = .idle
            return
        }
        permissionDenied = false
        // Abort checkpoint 1: the permission await is start()'s ONLY suspension
        // point, so this is where a release can land mid-start (field-proven:
        // the 1175 ms undetermined-despite-grant stall). Bail before touching
        // the session — nothing to tear down yet.
        if abortRequested {
            abortRequested = false
            state = .idle
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)

            var input = engine.inputNode
            var hwFormat = input.inputFormat(forBus: 0)     // real route format — may be 44.1 kHz

            // A 0 Hz / 0 ch input read is a dead I/O unit, not a bad route: the
            // session is live (we just activated it) but the engine's AURemoteIO
            // died under a mediaserverd reconfigure. Rebuild the engine ONCE and
            // re-read; the old `input` node belongs to the dead instance, so it
            // must be re-fetched. Nonzero sampleRate/channelCount is Apple's
            // documented signal that input is enabled — checked here so a dead
            // engine can never masquerade as `converterUnavailable` downstream.
            if hwFormat.sampleRate == 0 || hwFormat.channelCount == 0 {
                rebuildEngine()
                input = engine.inputNode
                hwFormat = input.inputFormat(forBus: 0)
            }
            guard hwFormat.sampleRate != 0, hwFormat.channelCount != 0 else {
                throw PTTCaptureError.inputUnavailable
            }
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

            // Abort checkpoint 2: last gate before frames flow. On the granted
            // path there is no suspension inside this do-block, so a flag set
            // during the perm await was already consumed at checkpoint 1 —
            // this is belt for any future suspension added upstream of here.
            if abortRequested {
                abortRequested = false
                teardownEngine()
                try? FileManager.default.removeItem(at: url)
                deactivateSession()
                reset()
                state = .idle
                return
            }
            pipeline = pipe
            fileURL = url
            levels = []
            liveHold = live != nil
            state = .recording
        } catch {
            RedactLog.event("[PTTCaptureEngine] start failed", "\(type(of: error))")
            teardownEngine()
            deactivateSession()
            reset()
            state = .idle
        }
    }

    /// Stop and return the `.m4a` bytes (nil if nothing usable) — same contract
    /// as `VoiceRecorder.stop()`.
    func stop(holdToken: Int) -> Data? {
        // OWNERSHIP: only the hold that started the engine may stop it. A
        // stale caller reaching this with the engine mid-hold for a LATER
        // press has already proven it is not the owner (its view token went
        // stale) — it must not touch state it cannot name. Required, not
        // defaulted: an "unowned" stop must be impossible to write by
        // accident; the first legitimate teardown caller gets an explicit
        // `cancelUnowned()` instead.
        guard holdToken == currentHoldToken else { return nil }
        switch state {
        case .idle:
            // Pure no-op: nothing armed, nothing to tear down — and critically
            // no deactivateSession(). The old finish() here fired an unguarded
            // setActive(false) with nothing to clean up.
            return nil
        case .starting:
            // Release raced ahead of an in-flight start(): request the abort
            // and do NOTHING else — start() owns the teardown at its
            // checkpoints, under whatever state it actually built.
            abortRequested = true
            return nil
        case .recording:
            break
        }
        guard let url = fileURL else { finish(); return nil }   // unreachable: .recording implies fileURL set
        teardownEngine()                        // tap removed → no more process() calls
        let sentFrames = pipeline?.sentFrameCount ?? 0   // read AFTER tap removal — no process() can race this
        pipeline?.finalize()                    // close the AVAudioFile: moov written BEFORE we read
        pipeline = nil                          // now release the pipeline object
        state = .idle
        // NOTE-GATE: a live hold that actually shipped audio leaves no note —
        // they heard it, and the ~90 KB fallback would queue .pttOpen/.pttClose
        // behind it on the reliable rail (the field-proven clog). A live hold
        // that shipped nothing still returns the note: it is the only copy of
        // the utterance anywhere. INERT until the committed trigger lands —
        // shipped callers pass live: nil, so liveHold is never true.
        let data = Self.shouldSuppressNote(liveHold: liveHold, sentFrames: sentFrames)
            ? nil : (try? Data(contentsOf: url))
        try? FileManager.default.removeItem(at: url)
        deactivateSession()
        reset()
        return data
    }

    /// The note-gate decision, pure so it is unit-testable: suppress the
    /// fallback `.m4a` only when the hold ran live AND at least
    /// `noteSuppressionMinFrames` sealed frames were handed to the transport.
    /// The frame floor is load-bearing — a live session that opened but moved
    /// no audio (link died at open) must still leave the note.
    nonisolated static func shouldSuppressNote(liveHold: Bool, sentFrames: Int) -> Bool {
        liveHold && sentFrames >= noteSuppressionMinFrames
    }
    /// 25 frames × 20 ms = 500 ms of audio confirmed onto the wire — enough
    /// that the far side plausibly heard the utterance open, not just a click.
    nonisolated static let noteSuppressionMinFrames = 25

    /// PRIVATE by design: `cancelUnowned()` is its only caller, so the
    /// ownership bypass is structural, not nominal — no future call site can
    /// reach tokenless cancel semantics except through the one documented
    /// sanction. (A future OWNED cancel would take a holdToken like stop().)
    private func cancel() {
        switch state {
        case .idle: return                                  // same no-op contract as stop()
        case .starting: abortRequested = true; return       // start() owns the teardown
        case .recording: break
        }
        teardownEngine()
        pipeline = nil
        state = .idle
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        deactivateSession()
        reset()
    }

    /// Teardown-only: kill WHATEVER hold owns the engine, regardless of token.
    /// The ONE sanctioned ownership bypass, for surfaces that are going away
    /// (walkie cover dismissed mid-hold, screen popped mid-hold) where no
    /// release can ever arrive AND the owner token may be unreachable — the
    /// cover-dismiss wedge: a reopened cover mints newer tokens, so no
    /// `stop(holdToken:)` can ever match the wedged owner again, and without
    /// this the engine keeps SEALING AND TRANSMITTING frames to the stale
    /// session's link indefinitely (a hot transmitter, not just a hot mic).
    /// CANCEL semantics only — the temp file is deleted and no data is ever
    /// returned: a caller with no hold has no claim to the recording. In
    /// `.starting` it defers to the owner's own abort checkpoints, exactly
    /// like an owned cancel.
    func cancelUnowned() {
        cancel()
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

    /// Replace a dead engine (0 Hz / 0 ch input read). Engine ONLY — this NEVER
    /// touches AVAudioSession: it runs after `setActive(true)`, under a live
    /// session, possibly with a live listen session under `PTTSessionOwner`;
    /// a deactivation here would kill that session out from under its owner.
    /// Releasing the old instance releases its dead AURemoteIO.
    private func rebuildEngine() {
        RedactLog.event("[PTTCaptureEngine] engine rebuilt", "dead input read under live session")
        teardownEngine()
        engine = AVAudioEngine()
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func reset() { pipeline = nil; fileURL = nil; liveHold = false }

    private func finish() {
        teardownEngine()
        pipeline = nil
        state = .idle
        deactivateSession()
        reset()
    }

    #if DEBUG
    // MARK: Test-only seams (hold-ownership pins)
    /// Force the state machine into a mid-hold state: the REAL path to
    /// `.starting`/`.recording` needs mic permission and a live audio session,
    /// which unit tests don't have. DEBUG-only — the Release product must not
    /// contain these symbols (nm-verified before commit).
    func _testForceState(_ forced: CaptureState, ownerToken: Int) {
        state = forced
        currentHoldToken = ownerToken
    }
    /// Read-only observability for the `.starting` no-op pin.
    var _testAbortRequested: Bool { abortRequested }
    #endif

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
