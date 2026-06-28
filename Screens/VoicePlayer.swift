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

    private var player: AVAudioPlayer?
    private var tickTask: Task<Void, Never>?

    init(data: Data) {
        if let player = try? AVAudioPlayer(data: data) {
            player.prepareToPlay()
            duration = player.duration
            self.player = player
        }
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        configureSession()
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
        stopTicking()
    }

    /// Seek to a fraction (0...1) of the clip.
    func seek(to fraction: Double) {
        guard let player else { return }
        let clamped = min(max(fraction, 0), 1)
        player.currentTime = clamped * player.duration
        progress = clamped
    }

    // MARK: - Internals

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
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
            stopTicking()
            return
        }
        if player.duration > 0 {
            progress = player.currentTime / player.duration
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}
