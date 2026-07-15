//
//  VoiceRecorder.swift
//  Screens
//
//  The composer's voice-note recorder — an @Observable driver around
//  AVAudioRecorder that the ConversationView composer binds to.
//
//  Records mono AAC to a temp .m4a (small, mesh-friendly), exposes a live
//  metered level buffer for the recording waveform, and hands back the
//  encoded bytes on stop so the inbox can chunk + seal + send them like any
//  other media. Metering runs on a Swift-6-clean async loop (no Timer, no
//  Sendable-closure escape), so the whole type stays main-actor isolated.
//
//  REQUIRES NSMicrophoneUsageDescription in the app's Info settings — iOS
//  hard-crashes a record-permission request without it.
//

import Foundation
import AVFoundation
import Observation

@MainActor
@Observable
final class VoiceRecorder {

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    /// Rolling buffer of recent normalized levels (0...1) for the live meter.
    private(set) var levels: [CGFloat] = []
    /// Set when the user has denied mic access; the composer surfaces an alert.
    private(set) var permissionDenied = false

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var startDate: Date?
    private var meterTask: Task<Void, Never>?

    /// Most-recent N bars kept on screen during recording.
    private static let maxLevels = 48
    /// dBFS at which a bar reads as silent.
    private static let silenceFloor: Float = -50

    // MARK: - Lifecycle

    func start() async {
        guard !isRecording else { return }
        guard await ensurePermission() else {
            permissionDenied = true
            return
        }
        permissionDenied = false

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.defaultToSpeaker])
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("voicenote-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 24_000.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ]
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = true
            rec.record()

            recorder = rec
            fileURL = url
            startDate = Date()
            elapsed = 0
            levels = []
            isRecording = true
            startMeterLoop()
        } catch {
            RedactLog.event("[VoiceRecorder] start failed", "\(type(of: error))")
            deactivateSession()
            reset()
        }
    }

    /// Stop recording and return the .m4a bytes (nil if nothing usable).
    /// Caller is responsible for sending them.
    func stop() -> Data? {
        guard isRecording, let rec = recorder, let url = fileURL else {
            finish()
            return nil
        }
        rec.stop()
        finishMetering()
        isRecording = false

        let data = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        deactivateSession()
        reset()
        return data
    }

    /// Discard the in-progress recording entirely.
    func cancel() {
        guard isRecording else { return }
        recorder?.stop()
        finishMetering()
        isRecording = false
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        deactivateSession()
        reset()
    }

    // MARK: - Metering

    private func startMeterLoop() {
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.isRecording else { break }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let rec = recorder else { return }
        rec.updateMeters()
        let level = Self.normalized(rec.averagePower(forChannel: 0))
        levels.append(level)
        if levels.count > Self.maxLevels {
            levels.removeFirst(levels.count - Self.maxLevels)
        }
        if let startDate { elapsed = Date().timeIntervalSince(startDate) }
    }

    /// Map dBFS to a 0...1 bar height. silenceFloor → 0, 0 dB → 1, clamped,
    /// with non-finite readings treated as silence.
    private static func normalized(_ db: Float) -> CGFloat {
        guard db.isFinite else { return 0 }
        let clamped = max(silenceFloor, min(0, db))
        return CGFloat((clamped - silenceFloor) / -silenceFloor)
    }

    private func finishMetering() {
        meterTask?.cancel()
        meterTask = nil
    }

    // MARK: - Permission

    private func ensurePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    // MARK: - Teardown

    private func deactivateSession() {
        guard !PTTSessionOwner.isLive else { return }
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func reset() {
        recorder = nil
        fileURL = nil
        startDate = nil
    }

    /// Full stop used when there's nothing usable to return.
    private func finish() {
        finishMetering()
        isRecording = false
        deactivateSession()
        reset()
    }
}
