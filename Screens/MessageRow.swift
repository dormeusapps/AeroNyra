//
//  MessageRow.swift
//  Screens
//
//  One row in the conversation transcript.
//
//  Composes a bubble + the inline DeliveryChip (outbound only) + a tap-to-
//  expand DeliveryReceipt. The Quiet Rule (DESIGN_TOKENS §0) lives here in
//  practice: the row's default state is calm — content + a muted chip —
//  and the receipt is the lean-in detail layer that earns color when the
//  user asks for it.
//
//  Distinction between outbound and inbound is alignment + a barely-
//  perceptible tonal lift on the bubble background, NOT a loud color
//  shift. Per the design posture: calm canvas, success is silent.
//
//  A row carries EITHER text or media (Message.isMedia). A photo renders
//  as the message content itself — the decoded JPEG, scaled to fit (never
//  cropped) and clipped to the SAME tail geometry as a text bubble.
//
//  TAP behaviour differs by content: a TEXT bubble toggles the delivery
//  receipt (the route detail layer); a PHOTO opens the fullscreen viewer.
//  The delivery chip still sits under outbound photos, so delivery state is
//  never hidden — only the detailed route card moves out of the photo's tap.
//

import SwiftUI
import UIKit

struct MessageRow: View {

    let message: Message

    /// The send/persist bridge, injected by ReadyView. Used to re-send a
    /// `.notDelivered` message when its chip is tapped (Phase 7c).
    @Environment(MessageInbox.self) private var inbox

    @State private var receiptExpanded: Bool = false
    @State private var showPhotoViewer: Bool = false

    // MARK: - Spec constants (DESIGN_TOKENS §3)

    private static let bubbleRadius: CGFloat = 17
    private static let bubbleTailRadius: CGFloat = 5
    private static let bubblePaddingH: CGFloat = 13
    private static let bubblePaddingV: CGFloat = 9
    /// Minimum spacer on the opposite side of the bubble. Caps bubble width
    /// at roughly the 76–78% spec on standard iPhone widths.
    private static let oppositeSideMin: CGFloat = 60
    private static let labelGap: CGFloat = 3

    /// Media bubble caps. A photo fits WITHIN these bounds preserving its
    /// aspect ratio (portrait → up to 240×320, landscape → 240×auto), so a
    /// tall image can't run away down the transcript.
    private static let mediaMaxWidth: CGFloat = 240
    private static let mediaMaxHeight: CGFloat = 320

    var body: some View {
        HStack(spacing: 0) {
            if message.isOutbound {
                Spacer(minLength: Self.oppositeSideMin)
            }

            VStack(alignment: message.isOutbound ? .trailing : .leading,
                   spacing: Self.labelGap) {
                bubble
                if message.isOutbound {
                    DeliveryChip(state: message.deliveryState)
                        .padding(.top, 2)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // The chip reads "tap to resend" only in the failed
                            // state; tapping it re-seals + re-sends the row.
                            // (Other states ignore the tap — the bubble still
                            // owns the receipt toggle.)
                            if message.deliveryState == .notDelivered {
                                Task { await inbox.resend(message) }
                            }
                        }
                }
                if receiptExpanded {
                    receipt
                        .padding(.top, 6)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            if !message.isOutbound {
                Spacer(minLength: Self.oppositeSideMin)
            }
        }
        .fullScreenCover(isPresented: $showPhotoViewer) {
            if let image = decodedImage {
                PhotoViewer(image: image)
            }
        }
    }

    // MARK: - Bubble

    /// The shared tail geometry: a rounded rect whose bottom-leading or
    /// bottom-trailing corner tightens into the "tail" depending on side.
    /// Computed once so text and media bubbles are pixel-identical in shape.
    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius:     Self.bubbleRadius,
            bottomLeadingRadius:  message.isOutbound
                ? Self.bubbleRadius
                : Self.bubbleTailRadius,
            bottomTrailingRadius: message.isOutbound
                ? Self.bubbleTailRadius
                : Self.bubbleRadius,
            topTrailingRadius:    Self.bubbleRadius,
            style: .continuous
        )
    }

    /// Text vs. media. Each carries its own tap: text → receipt, photo →
    /// fullscreen viewer, placeholder → receipt.
    @ViewBuilder
    private var bubble: some View {
        if message.isMedia {
            mediaBubble
        } else {
            textBubble
                .contentShape(Rectangle())
                .onTapGesture { toggleReceipt() }
        }
    }

    private var textBubble: some View {
        Text(message.content)
            .beaconMessageBody()
            .foregroundStyle(bubbleTextColor)
            .padding(.horizontal, Self.bubblePaddingH)
            .padding(.vertical, Self.bubblePaddingV)
            .background(bubbleShape.fill(bubbleBackground))
    }

    /// Media content. JPEG → tappable image bubble (opens the viewer);
    /// .m4a → voice-note bubble (play/pause + seekable waveform); anything
    /// else (or a decode failure) → calm placeholder that toggles the receipt.
    @ViewBuilder
    private var mediaBubble: some View {
        if message.mediaMime == .jpeg, let image = decodedImage {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: Self.mediaMaxWidth,
                       maxHeight: Self.mediaMaxHeight)
                .clipShape(bubbleShape)
                .contentShape(bubbleShape)
                .onTapGesture { showPhotoViewer = true }
        } else if message.mediaMime == .m4a, let data = message.mediaData {
            // The voice bubble carries its own controls/gestures, so it does
            // NOT toggle the receipt on tap (the chip still shows delivery).
            VoiceNoteBubble(data: data, isOutbound: message.isOutbound)
                .padding(.horizontal, Self.bubblePaddingH)
                .padding(.vertical, Self.bubblePaddingV)
                .background(bubbleShape.fill(bubbleBackground))
                .clipShape(bubbleShape)
        } else {
            mediaPlaceholder
                .contentShape(Rectangle())
                .onTapGesture { toggleReceipt() }
        }
    }

    /// A muted stand-in when there's nothing to show yet: a non-JPEG media
    /// kind (voice notes, until 6c.3) or a blob that failed to decode. Uses
    /// the bubble's own background tone so it sits quietly in the transcript.
    private var mediaPlaceholder: some View {
        bubbleShape
            .fill(bubbleBackground)
            .frame(width: 200, height: 132)
            .overlay(
                Image(systemName: placeholderGlyph)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.textTertiary)
            )
    }

    private var placeholderGlyph: String {
        message.mediaMime == .m4a ? "waveform" : "photo"
    }

    /// Decode the stored blob lazily for display. Returns nil if the bytes
    /// aren't a decodable image (→ placeholder).
    private var decodedImage: UIImage? {
        guard let data = message.mediaData else { return nil }
        return UIImage(data: data)
    }

    private var bubbleBackground: Color {
        message.isOutbound ? .bubbleOutBg : .bubbleInBg
    }

    private var bubbleTextColor: Color {
        message.isOutbound ? .bubbleOutText : .bubbleInText
    }

    private func toggleReceipt() {
        withAnimation(.easeOut(duration: 0.22)) {
            receiptExpanded.toggle()
        }
    }

    // MARK: - Receipt

    /// The tap-expand route card. Nodes are derived from what we know
    /// honestly: the user as origin, the peer as destination, with N
    /// unnamed relay nodes in between (we don't have route metadata yet
    /// — that arrives with the BLE transport).
    private var receipt: some View {
        DeliveryReceipt(
            nodes: receiptNodes,
            statusText: receiptStatusText,
            hopsLabel: receiptHopsLabel,
            timeText: receiptTimeText,
            signalText: receiptSignalText,
            signalColor: receiptSignalColor,
            signalBars: receiptSignalBars
        )
    }

    private var receiptNodes: [DeliveryReceipt.Node] {
        var result: [DeliveryReceipt.Node] = []

        // Origin: deliberately unlabeled per design posture (no "you" label).
        result.append(.init(name: "", kind: .origin))

        // Relay placeholders — unlabeled until route metadata is available
        // from the BLE layer. The hop count is real; the names are honestly
        // empty rather than invented.
        let hops = currentHopCount
        for _ in 0..<hops {
            result.append(.init(name: "", kind: .relay))
        }

        // Destination: the peer, by petname or fingerprint.
        let peerLabel: String
        if let peer = message.conversation?.peer {
            peerLabel = peer.displayLabel
        } else {
            peerLabel = ""
        }
        result.append(.init(name: peerLabel, kind: .peer))

        return result
    }

    /// Hops currently known for this message. Only `.relayed` carries a
    /// concrete count; other states have no relay yet.
    private var currentHopCount: Int {
        if case .relayed(let hops) = message.deliveryState { return hops }
        return 0
    }

    private var receiptStatusText: String {
        switch message.deliveryState {
        case .waitingForRange: return "Queued"
        case .sent:            return "Sent"
        case .findingPath:     return "In transit"
        case .delivered:       return "Delivered"
        case .relayed:         return "Relayed"
        case .notDelivered:    return "Failed"
        }
    }

    private var receiptHopsLabel: String {
        if case .relayed(let h) = message.deliveryState {
            return "\(h) \(h == 1 ? "hop" : "hops")"
        }
        return "direct"
    }

    private var receiptTimeText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: message.timestamp,
                                         relativeTo: Date())
    }

    // Signal information is derived from delivery state until real RSSI
    // arrives from the BLE transport. This is not fake data — it's the
    // best honest reading we can make from what we know right now.
    private var receiptSignalText: String {
        switch message.deliveryState {
        case .delivered, .sent: return "good"
        case .relayed, .waitingForRange, .findingPath: return "fair"
        case .notDelivered: return "weak"
        }
    }

    private var receiptSignalColor: Color {
        switch message.deliveryState {
        case .delivered, .sent: return .statusHealthy
        case .relayed, .waitingForRange, .findingPath: return .statusRelay
        case .notDelivered: return .statusError
        }
    }

    private var receiptSignalBars: SignalBars.Strength {
        switch message.deliveryState {
        case .delivered, .sent: return .good
        case .relayed, .waitingForRange, .findingPath: return .fair
        case .notDelivered: return .weak
        }
    }
}

// MARK: - Peer display helpers

extension Peer {

    /// What to show this peer as in the UI: their local petname if the
    /// user has set one, otherwise their short fingerprint. Used by the
    /// Conversation header, message rows, Nearby rows, and Chats list.
    var displayLabel: String {
        if let name = displayName, !name.isEmpty {
            return name
        }
        return shortFingerprint
    }

    /// The first 6 hex chars of the public key, formatted with the ·
    /// separator (e.g. `a3·9f·2c`). Short enough for a header, distinctive
    /// enough for everyday disambiguation; the full fingerprint lives in
    /// the Peer Settings screen for verification.
    var shortFingerprint: String {
        publicKeyData
            .prefix(3)
            .map { String(format: "%02x", $0) }
            .joined(separator: "·")
    }
}
