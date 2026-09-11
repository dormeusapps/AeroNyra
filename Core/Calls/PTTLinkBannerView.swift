// PTTLinkBannerView.swift
// Core/Calls
//
// The RESPONDER's honest surface for an auto-answered walkie link (live
// PTT-over-IP, step 5). Under the no-mutual-cover ruling a verified contact
// can open a link to us while we are anywhere in the app, and
// `WebRTCCallMedia.makeAnswer` activates the audio session then — our mic
// HARDWARE is on (iOS shows the indicator) and their voice plays on the
// loudspeaker, though nothing is TRANSMITTED until we hold to talk. This
// banner is the ruling's only safeguard: it states both facts, separately,
// because both are true and only one is alarming — and it offers one tap to
// close. Hiding either fact would defeat the ruling.
//
// Renders only for a link in the RESPONDER role (the initiator has the
// walkie cover). TAP THE CARD to talk back (Rubins' ruling 2026-09-11 — the
// banner must not instruct the user to hold a button that is not on screen):
// it posts a walkie request to `NavigationIntent`; the chats root routes to
// that peer's conversation and the cover ADOPTS the already-open link — no
// request, no reconnect. The ✕ is a separate control and it CLOSES the link
// (hangs up on the initiator, who learns of it by ICE decay).
//
// A visible close reason from the responder side is shown briefly, then the
// banner clears; the engine is left in `.closed` (the controller treats
// that as free for the next inbound request, and the cover resets on open).
//

import SwiftUI
import SwiftData

struct PTTLinkBannerView: View {
    let engine: PTTLinkEngine
    let intent: NavigationIntent
    @Environment(\.modelContext) private var modelContext

    /// The last responder-side peer + reason, so an ended link can say so
    /// for a moment instead of vanishing silently.
    @State private var endedNotice: (peerKey: Data, reason: PTTLinkController.CloseReason)?
    @State private var endedToken = 0
    @State private var lastResponderPeer: Data?

    var body: some View {
        Group {
            switch engine.state {
            case .opening(_, let peerKey, .responder, _):
                liveBanner(peerKey: peerKey, connected: false)
            case .open(_, let peerKey, .responder):
                liveBanner(peerKey: peerKey, connected: true)
            case .closed(let reason):
                if let notice = endedNotice, notice.reason == reason {
                    endedBanner(peerKey: notice.peerKey, reason: reason)
                }
            case .idle, .opening, .open:
                EmptyView()
            }
        }
        .onChange(of: engine.state) { _, newState in
            switch newState {
            case .opening(_, let peerKey, .responder, _), .open(_, let peerKey, .responder):
                lastResponderPeer = peerKey
            case .closed(let reason):
                if let peerKey = lastResponderPeer, reason.isUserVisible {
                    endedNotice = (peerKey, reason)
                    endedToken += 1
                }
                lastResponderPeer = nil
            case .idle, .opening, .open:
                endedNotice = nil
                lastResponderPeer = nil
            }
        }
        .task(id: endedToken) {
            guard endedToken > 0 else { return }
            do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
            endedNotice = nil
        }
    }

    // MARK: Live

    private func liveBanner(peerKey: Data, connected: Bool) -> some View {
        VStack {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("walkie · \(name(peerKey))")
                        .stillwaterSerif(18, color: Stillwater.Palette.foam)
                    Text("\(name(peerKey)) opened a walkie with you")
                        .stillwaterMono(8.5, trackingEm: 0.2, color: Stillwater.Palette.mistDim)
                    Text(connected
                         ? "tap to talk back · your mic is on · nothing sends unless you hold"
                         : "tap to talk back · your mic is on · connecting…")
                        .stillwaterMono(8.5, trackingEm: 0.2, color: Stillwater.Palette.biolume)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button { engine.close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Stillwater.Palette.mistDim)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close walkie")
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(Stillwater.Palette.abyss.opacity(0.96))
                    .overlay(RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(Stillwater.Palette.biolume.opacity(0.35)))
            )
            // The whole card is the deep link; the ✕ Button above wins the
            // hit test over this gesture, so close stays close.
            .contentShape(RoundedRectangle(cornerRadius: 22))
            .onTapGesture { intent.openWalkie(with: peerKey) }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Open walkie with \(name(peerKey))")
            .padding(.horizontal, 26)
            .padding(.top, 14)
            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: Ended

    private func endedBanner(peerKey: Data, reason: PTTLinkController.CloseReason) -> some View {
        VStack {
            Text(Self.endCopy(reason, name: name(peerKey)))
                .stillwaterMono(8.5, trackingEm: 0.2, color: Stillwater.Palette.mistDim)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Stillwater.Palette.abyss.opacity(0.96))
                        .overlay(RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Stillwater.Palette.biolume.opacity(0.2)))
                )
                .padding(.top, 14)
            Spacer()
        }
        .transition(.opacity)
    }

    /// Responder-side outcome copy. Only user-visible reasons reach here.
    static func endCopy(_ reason: PTTLinkController.CloseReason, name: String) -> String {
        switch reason {
        case .remoteEnded:    return "walkie with \(name) ended"
        case .interrupted:    return "walkie with \(name) paused"
        case .connectFailed:  return "couldn't connect to \(name)"
        case .failed:         return "walkie with \(name) couldn't start"
        case .unreachable:    return "couldn't reach \(name)"
        case .remoteDeclined: return "\(name) isn't accepting walkies right now"
        case .localClosed, .preempted:
            return ""
        }
    }

    // MARK: Peer naming (same lookup as CallOverlayView)

    private func name(_ peerKey: Data) -> String {
        var descriptor = FetchDescriptor<Peer>(
            predicate: #Predicate { $0.publicKeyData == peerKey })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor).first?.displayName ?? nil) ?? "them"
    }
}
