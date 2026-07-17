// CallOverlayView.swift
// Core/Calls
//
// STILLWATER · the call surface (P4). App-wide overlay driven entirely by
// CallEngine.state — a ring reaches the user on ANY screen. Renders:
//   • incoming ring banner (decline / voice / video),
//   • outgoing ring + connecting full-screens (cancel / hang up),
//   • the active call: remote video full-bleed, local PIP while the camera
//     is on, mute + camera + hang-up controls (in-band only — the wire never
//     learns; kinds 8-10 untouched),
//   • the outcome screen, whose copy keeps the committed NAT honesty
//     ("couldn't connect — try joining the same WiFi").
//
// No WebRTC import here: the video surfaces cross as plain UIViews via
// CallEngine's accessors.
//

import SwiftUI
import UIKit
import SwiftData

struct CallOverlayView: View {

    let engine: CallEngine
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        switch engine.state {
        case .idle:
            EmptyView()
        case .incomingRinging(_, let peerKey, _):
            ringBanner(peerKey)
        case .outgoingRinging(_, let peerKey):
            waitingScreen(title: "calling \(name(peerKey))…", cancelLabel: "cancel") {
                Task { await engine.cancelOutgoing() }
            }
        case .connecting:
            waitingScreen(title: "connecting…", cancelLabel: "hang up") {
                engine.hangUp()
            }
        case .active(_, let peerKey):
            activeScreen(peerKey)
        case .ended(let reason):
            endedScreen(reason)
        }
    }

    // MARK: Incoming ring

    private func ringBanner(_ peerKey: Data) -> some View {
        VStack {
            VStack(spacing: 14) {
                Text(name(peerKey))
                    .stillwaterSerif(22, color: Stillwater.Palette.foam)
                Text("wants to talk")
                    .stillwaterMono(9, trackingEm: 0.24, color: Stillwater.Palette.mistDim)
                HStack(spacing: 26) {
                    ringButton("decline", system: "phone.down.fill",
                               tint: Stillwater.Palette.mistDim) {
                        Task { await engine.decline() }
                    }
                    ringButton("voice", system: "phone.fill",
                               tint: Stillwater.Palette.biolume) {
                        Task { await engine.accept(withCamera: false) }
                    }
                    ringButton("video", system: "video.fill",
                               tint: Stillwater.Palette.biolume) {
                        Task { await engine.accept(withCamera: true) }
                    }
                }
            }
            .padding(22)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(Stillwater.Palette.abyss.opacity(0.96))
                    .overlay(RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(Stillwater.Palette.biolume.opacity(0.35)))
            )
            .padding(.horizontal, 26)
            .padding(.top, 14)
            Spacer()
        }
    }

    private func ringButton(_ label: String, system: String, tint: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: system)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(tint.opacity(0.12)))
                Text(label)
                    .stillwaterMono(7.5, trackingEm: 0.2, color: Stillwater.Palette.mistDim)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Waiting (outgoing ring / connecting)

    private func waitingScreen(title: String, cancelLabel: String,
                               onCancel: @escaping () -> Void) -> some View {
        ZStack {
            Stillwater.Palette.abyss.ignoresSafeArea()
            VStack(spacing: 26) {
                Spacer()
                Text(title)
                    .stillwaterSerif(24, color: Stillwater.Palette.foam)
                Spacer()
                Button(action: onCancel) {
                    Text(cancelLabel)
                        .stillwaterMono(9, trackingEm: 0.24, color: Stillwater.Palette.mistDim)
                        .padding(.bottom, 44)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Active call

    private func activeScreen(_ peerKey: Data) -> some View {
        ZStack {
            Stillwater.Palette.abyss.ignoresSafeArea()

            if let remote = engine.remoteVideoSurface, engine.remoteVideoActive {
                CallVideoSurface(view: remote)
                    .ignoresSafeArea()
            } else if engine.remoteVideoWasEverActive {
                // Fix 2: their frames stopped (camera off — or a stall; the
                // staleness signal can't tell, so the copy stays honest).
                // Beats the frozen last frame this used to show.
                VStack(spacing: 12) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Stillwater.Palette.mistDim)
                    Text("video paused")
                        .stillwaterMono(9, trackingEm: 0.24, color: Stillwater.Palette.mistDim)
                }
            }

            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name(peerKey))
                            .stillwaterSerif(20, color: Stillwater.Palette.foam)
                        Text("connected · sealed")
                            .stillwaterMono(8, trackingEm: 0.22, color: Stillwater.Palette.mistDim)
                    }
                    .padding(18)
                    Spacer()
                    if engine.cameraOn, let local = engine.localVideoSurface {
                        CallVideoSurface(view: local)
                            .frame(width: 104, height: 148)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Stillwater.Palette.biolume.opacity(0.35)))
                            .padding(18)
                    }
                }
                Spacer()
                HStack(spacing: 26) {
                    controlButton(engine.micMuted ? "mic.slash.fill" : "mic.fill",
                                  active: engine.micMuted) {
                        engine.setMicMuted(!engine.micMuted)
                    }
                    controlButton(engine.speakerEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                  active: engine.speakerEnabled) {
                        engine.setSpeakerEnabled(!engine.speakerEnabled)
                    }
                    .accessibilityLabel("Speaker")
                    controlButton("phone.down.fill", active: false,
                                  tint: Stillwater.Palette.mistDim) {
                        engine.hangUp()
                    }
                    controlButton(engine.cameraOn ? "video.fill" : "video.slash.fill",
                                  active: engine.cameraOn) {
                        engine.setCameraEnabled(!engine.cameraOn)
                    }
                    if engine.cameraOn {
                        controlButton("arrow.triangle.2.circlepath.camera",
                                      active: false) {
                            engine.flipCamera()
                        }
                    }
                }
                .padding(.bottom, 44)
            }
        }
    }

    private func controlButton(_ system: String, active: Bool,
                               tint: Color = Stillwater.Palette.biolume,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(active ? Stillwater.Palette.abyss : tint)
                .frame(width: 56, height: 56)
                .background(Circle().fill(active ? tint : tint.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Ended

    private func endedScreen(_ reason: CallController.EndReason) -> some View {
        ZStack {
            Stillwater.Palette.abyss.ignoresSafeArea()
            VStack(spacing: 26) {
                Spacer()
                Text(endCopy(reason))
                    .stillwaterSerif(20, color: Stillwater.Palette.foam)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()
                Button { engine.reset() } label: {
                    Text("done")
                        .stillwaterMono(9, trackingEm: 0.24, color: Stillwater.Palette.biolume)
                        .padding(.bottom, 44)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Outcome copy — `connectFailed` keeps the committed NAT-honesty line.
    private func endCopy(_ reason: CallController.EndReason) -> String {
        switch reason {
        case .declined:       return "call declined"
        case .remoteDeclined: return "they can't talk right now"
        case .timedOut:       return "no answer"
        case .connectFailed:  return "couldn't connect —\ntry joining the same WiFi"
        case .hungUp:         return "call ended"
        case .failed:         return "the call couldn't start"
        }
    }

    // MARK: Peer naming

    private func name(_ peerKey: Data) -> String {
        var descriptor = FetchDescriptor<Peer>(
            predicate: #Predicate { $0.publicKeyData == peerKey })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor).first?.displayName ?? nil) ?? "them"
    }
}

// MARK: - Video surface bridge

/// Hosts a video view WebRTCCallMedia owns (crosses as a plain UIView, so
/// the UI layer never imports WebRTC). Aspect-fill: RTCMTLVideoView maps
/// UIKit `contentMode` onto its video gravity.
private struct CallVideoSurface: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView {
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
