//
//  VoicePlayer.swift
//  Screens
//
//  Playback driver for a voice-note bubble — an @Observable wrapper around
//  AVAudioPlayer that VoiceNoteBubble binds to.
//
//  Plays directly from the in-memory .m4a bytes (no temp file), exposes
//  isPlaying / progress (0...1) / duration, and supports tap-to-seek. End of
//  playback is detected by polling AVAudioPlayer.isPlaying in the progress
//  loop, so there's no NSObject delegate and the type stays a clean
//  main-actor @Observable.
//

import Foundation
import AVFoundation
import Observation

@MainActor
@Observable
final class VoicePlayer {

    private(set) var isPlaying = false
    private(set) var progress: Double = 0      // 0...1
    private(set) var duration: TimeInterval = 0
    /// Live playback level (0...1), published from the existing tick while
    /// playing so a visualizer can react to the clip. Metering only — playback
    /// behavior is unchanged. 0 whenever not playing.
    private(set) var level: CGFloat = 0

    private var player: AVAudioPlayer?
    private var tickTask: Task<Void, Never>?

    /// dBFS at which playback reads as silent (mirrors `VoiceRecorder`).
    private static let silenceFloor: Float = -50

    init(data: Data) {
        if let player = try? AVAudioPlayer(data: data) {
            player.prepareToPlay()
            player.isMeteringEnabled = true
            duration = player.duration
            self.player = player
        }
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        activateSession()
        if progress >= 1 || player.currentTime >= player.duration {
            player.currentTime = 0
            progress = 0
        }
        player.play()
        isPlaying = true
        startTicking()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        level = 0
        stopTicking()
        // Hand the audio session back so any music we took over resumes. The
        // note re-takes it on the next play().
        deactivateSession()
    }

    /// Seek to a fraction (0...1) of the clip.
    func seek(to fraction: Double) {
        guard let player else { return }
        let clamped = min(max(fraction, 0), 1)
        player.currentTime = clamped * player.duration
        progress = clamped
    }

    // MARK: - Internals

    /// Take over audio output for the note. `.playback` (no `.mixWithOthers`)
    /// is deliberate: a voice note is meant to be heard, so it pauses the user's
    /// music — the "take over" behaviour. It's handed back in `deactivateSession`
    /// the moment the note ends or is paused, which is what lets the music resume.
    /// Called ONLY from `play()`, never at construction, so merely opening a
    /// conversation full of voice notes never touches the session.
    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    /// Release the audio session and, crucially, notify other apps so their audio
    /// resumes. `.notifyOthersOnDeactivation` is the signal Music/Spotify use to
    /// pick their playback back up after we took over for the note.
    private func deactivateSession() {
        guard !PTTSessionOwner.isLive else { return }
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func startTicking() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard let self, self.isPlaying else { break }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let player else { return }
        // AVAudioPlayer flips isPlaying false when the clip ends.
        if !player.isPlaying {
            isPlaying = false
            progress = 1
            level = 0
            stopTicking()
            // Clip finished — release the session so the user's music resumes.
            deactivateSession()
            return
        }
        if player.duration > 0 {
            progress = player.currentTime / player.duration
        }
        player.updateMeters()
        level = Self.normalized(player.averagePower(forChannel: 0))
    }

    /// Map dBFS to a 0...1 level; silenceFloor → 0, 0 dB → 1, non-finite → 0.
    private static func normalized(_ db: Float) -> CGFloat {
        guard db.isFinite else { return 0 }
        let clamped = max(silenceFloor, min(0, db))
        return CGFloat((clamped - silenceFloor) / -silenceFloor)
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}
