//
//  VideoBubble.swift
//  Screens
//
//  The interactive content of a v1 video-message bubble: an inline AVKit
//  player over the persisted mp4 blob. Like VoiceNoteBubble, the row owns the
//  bubble's shape; this view renders only the media inside it.
//
//  DISK NOTE (deliberate v1 trade): AVPlayer cannot play from memory, so the
//  blob is written to a TEMP file to play. The copy is written with
//  completeFileProtection, lives in temporaryDirectory, and is deleted on
//  disappear — a bounded, encrypted-at-rest window, not a second durable copy.
//  The durable blob stays in the SwiftData row (Phase 5b protection) and is
//  reaped by the SEC-6 machinery like any photo (photoWindow from arrival).
//

import SwiftUI
import AVKit
import UIKit

struct VideoBubble: View {

    let data: Data
    let isOutbound: Bool

    @State private var player: AVPlayer?
    @State private var tempURL: URL?
    @State private var showFullscreen = false
    /// Fitted to the clip's real aspect once its track loads — the bubble hugs
    /// the video exactly, so there is never a letterbox "box" around it.
    @State private var displaySize = CGSize(width: 220, height: 160)

    private static let maxWidth: CGFloat = 230
    private static let maxHeight: CGFloat = 300
    private static let cornerRadius: CGFloat = 14

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .frame(width: displaySize.width, height: displaySize.height)
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                    .overlay(alignment: .topTrailing) { expandButton }
                    .fullScreenCover(isPresented: $showFullscreen) { fullscreenPlayer }
            } else {
                // Blob not staged yet (or gone): a still, dark pane. A reaped
                // row never reaches here — the caller renders the tombstone.
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(Color.black.opacity(0.35))
                    .frame(width: displaySize.width, height: displaySize.height)
                    .overlay(
                        Image(systemName: "play.circle")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Stillwater.Palette.mist)
                    )
            }
        }
        .task { stage() }
        .onDisappear { teardown() }
    }

    /// Small expand affordance — the player's own controls swallow bare taps,
    /// so enlargement gets an explicit corner button.
    private var expandButton: some View {
        Button { showFullscreen = true } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Stillwater.Palette.foam)
                .padding(6)
                .background(.black.opacity(0.45), in: Circle())
                .padding(6)
        }
        .buttonStyle(.plain)
    }

    /// The enlarged view: same AVPlayer (position carries over), but a BARE
    /// player layer — no system chrome, no volume slider (hardware buttons
    /// own volume). Tap toggles play/pause; ✕ returns.
    private var fullscreenPlayer: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player {
                PlayerLayerView(player: player)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { togglePlayback() }
                    .onAppear { player.play() }
            }
            Button { showFullscreen = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Stillwater.Palette.foam)
                    .padding(10)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .padding(.trailing, 16)
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    /// Write the blob to a protected temp file and point a player at it, then
    /// fit the bubble to the clip's oriented natural size (no letterbox).
    private func stage() {
        guard player == nil, !data.isEmpty else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        do {
            try data.write(to: url, options: [.completeFileProtection])
            tempURL = url
            player = AVPlayer(url: url)
        } catch {
            RedactLog.event("video-bubble: temp stage failed", "\(type(of: error))")
            return
        }
        Task {
            guard let track = try? await AVURLAsset(url: url)
                .loadTracks(withMediaType: .video).first,
                  let (natural, transform) = try? await track
                .load(.naturalSize, .preferredTransform) else { return }
            // Apply the rotation transform so portrait clips size as portrait.
            let rect = CGRect(origin: .zero, size: natural).applying(transform)
            let w = abs(rect.width), h = abs(rect.height)
            guard w > 0, h > 0 else { return }
            let scale = min(Self.maxWidth / w, Self.maxHeight / h)
            displaySize = CGSize(width: w * scale, height: h * scale)
        }
    }

    /// Stop playback and remove the temp copy — the bounded window closes.
    private func teardown() {
        player?.pause()
        player = nil
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        tempURL = nil
    }
}

// MARK: - PlayerLayerView

/// A bare AVPlayerLayer with zero system chrome, for the fullscreen cover —
/// playback control is a tap, volume is the hardware buttons.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerContainerView, context: Context) {
        view.playerLayer.player = player
    }
}

/// UIView whose backing layer IS the player layer, so it resizes for free.
private final class PlayerContainerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
