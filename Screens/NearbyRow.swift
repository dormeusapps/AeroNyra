//
//  NearbyRow.swift
//  Screens
//
//  One peer row in the Nearby list — "who is here right now."
//
//  Composes avatar + name + PresenceChain + label + optional SignalBars
//  + last-seen time. Used by both sections of NearbyView:
//
//   • "Reachable now" — full color, current presence, signal bars visible.
//   • "Recently seen" — dimmed to 50% opacity, presence is .outOfRange
//      (dashed), no signal bars; the time-since-last-seen takes over.
//
//  That dimming IS the Quiet Rule applied here: peers we've lost contact
//  with fade until they come back into range.
//

import SwiftUI

struct NearbyRow: View {

    let peer: Peer

    /// Current reachability to this peer. Stubbed at .outOfRange until
    /// the BLE layer drives it.
    let reachability: PresenceChain.Reachability

    /// Signal strength. Pass nil to omit the bars entirely (e.g. the
    /// "Recently seen" section, where there is no current signal).
    let signalStrength: SignalBars.Strength?

    /// The color the signal bars take when shown.
    let signalColor: Color

    /// Whether to render in the recently-seen muted variant.
    let isRecentlySeen: Bool

    /// Optional relay petname for the presence label ("1 hop · via Theo").
    /// nil until route metadata is available from BLE.
    let relayName: String?

    private static let avatarSize: CGFloat = 38

    var body: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                nameText
                presenceRow
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .opacity(isRecentlySeen ? 0.5 : 1.0)
        .contentShape(Rectangle())
    }

    // MARK: - Avatar

    private var avatar: some View {
        Circle()
            .fill(LinearGradient.avatarBrand)
            .hueRotation(.degrees(peer.avatarHue * 360))
            .frame(width: Self.avatarSize, height: Self.avatarSize)
    }

    // MARK: - Name

    private var nameText: some View {
        Text(peer.displayLabel)
            .font(Typography.headerName)
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
    }

    // MARK: - Presence row

    private var presenceRow: some View {
        HStack(spacing: 6) {
            PresenceChain(reachability: reachability)
            Text(presenceLabel)
                .font(Typography.headerPresence)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
    }

    private var presenceLabel: String {
        switch reachability {
        case .direct:
            return "Direct"
        case .oneHop:
            if let relay = relayName { return "1 hop · via \(relay)" }
            return "1 hop"
        case .twoHops:
            return "2 hops · via mesh"
        case .outOfRange:
            return "Out of range"
        }
    }

    // MARK: - Trailing

    private var trailing: some View {
        HStack(spacing: 10) {
            if let strength = signalStrength {
                SignalBars(strength: strength, color: signalColor)
            }
            if isRecentlySeen {
                Text(lastSeenText)
                    .font(Typography.deliveryChip)
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }

    private var lastSeenText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: peer.lastSeen, relativeTo: Date())
    }
}
