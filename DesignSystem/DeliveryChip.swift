//
//  DeliveryChip.swift
//  DesignSystem
//
//  Mono telemetry indicator shown under each outbound message — the
//  visible read-out of the six delivery states (DESIGN_TOKENS §4).
//
//  Per the Quiet Rule (DESIGN_TOKENS §0), success states render in muted
//  neutral. Color is earned only by states needing attention: amber for
//  queue/relay (the mesh is doing or needing work), red for failure.
//
//  This is the inline indicator; the DeliveryReceipt card is the tap-to-
//  expand "lean-in" detail layer that sits on top of it.
//

import SwiftUI

struct DeliveryChip: View {

    let state: MessageDeliveryState

    private static let iconSize: CGFloat = 10
    private static let spacing: CGFloat = 4

    var body: some View {
        HStack(spacing: Self.spacing) {
            icon
            Text(label)
                .font(Typography.deliveryChip)
                .foregroundStyle(textColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Icon

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .waitingForRange:
            Image(systemName: "clock")
                .font(.system(size: Self.iconSize, weight: .medium))
                .foregroundStyle(Color.statusRelay)

        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: Self.iconSize, weight: .medium))
                .foregroundStyle(Color.statusNeutral)

        case .cast:
            Image(systemName: "arrow.up.forward")
                .font(.system(size: Self.iconSize, weight: .medium))
                .foregroundStyle(Color.statusNeutral)

        case .findingPath:
            PulsingChipDot()

        case .delivered:
            doubleCheck(color: .statusNeutral)

        case .relayed:
            doubleCheck(color: .statusRelay)

        case .notDelivered:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: Self.iconSize, weight: .medium))
                .foregroundStyle(Color.statusError)
        }
    }

    /// Two slightly-overlapped checkmarks. SF Symbols lacks a double-check
    /// glyph; the negative spacing pulls them into one read.
    private func doubleCheck(color: Color) -> some View {
        HStack(spacing: -2) {
            Image(systemName: "checkmark")
            Image(systemName: "checkmark")
        }
        .font(.system(size: 8, weight: .medium))
        .foregroundStyle(color)
    }

    // MARK: - Label (DESIGN_TOKENS §4 — spec labels verbatim)

    private var label: String {
        switch state {
        case .waitingForRange:
            return "queued"
        case .sent:
            return "handed to radio"
        case .cast:
            return "in the current"
        case .findingPath:
            return "in transit"
        case .delivered:
            return "confirmed"
        case .relayed(let hops):
            return "via mesh · \(hops) \(hops == 1 ? "hop" : "hops")"
        case .notDelivered:
            return "tap to resend"
        }
    }

    private var textColor: Color {
        switch state {
        case .waitingForRange, .relayed:
            return .statusRelay
        case .sent, .cast, .findingPath, .delivered:
            return .textTertiary
        case .notDelivered:
            return .statusError
        }
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        switch state {
        case .waitingForRange:
            return "Queued, waiting for range"
        case .sent:
            return "Sent, handed to radio"
        case .cast:
            return "Cast over relay, will surface when they reconnect"
        case .findingPath:
            return "In transit, finding a path"
        case .delivered:
            return "Delivered, confirmed"
        case .relayed(let hops):
            return "Relayed via mesh, \(hops) \(hops == 1 ? "hop" : "hops")"
        case .notDelivered:
            return "Not delivered, tap to resend"
        }
    }
}

// MARK: - Animations

/// Small pulsing dot for the "in transit" state — same find rhythm used by
/// LiveTransit's header, so the two read as one heartbeat across the screen.
private struct PulsingChipDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Color.statusNeutral)
            .frame(width: 5, height: 5)
            .opacity(on ? 1.0 : 0.28)
            .scaleEffect(on ? 1.0 : 0.82)
            .animation(
                .easeInOut(duration: 1.3).repeatForever(autoreverses: true),
                value: on
            )
            .onAppear { on = true }
    }
}
