//
//  ChatRow.swift
//  Screens
//
//  One row in the Chats list — a single Conversation summarized.
//
//  Reads quietly: deterministic-hue avatar (derived from the peer's
//  public key), peer's petname or fingerprint, the PresenceChain
//  underneath, last activity time on the right, and a small brand-teal
//  dot when there are unread messages.
//
//  No content preview — by design, message text doesn't surface here;
//  you open the chat to see it. (Private posture: the radio knows the
//  shape of your conversations, not their contents.)
//

import SwiftUI

struct ChatRow: View {

    let conversation: Conversation

    /// Presence to the peer right now. Stubbed at .outOfRange until the
    /// BLE layer drives this; rows will animate when real reachability
    /// arrives.
    let presence: PresenceChain.Reachability

    /// Whether this conversation has unread inbound messages. Stubbed at
    /// false until Message gains an `isRead` field; the dot is wired and
    /// ready to render the moment that lands.
    let hasUnread: Bool

    private static let avatarSize: CGFloat = 38
    private static let dotSize: CGFloat = 8
    private static let avatarGap: CGFloat = 12

    var body: some View {
        HStack(spacing: Self.avatarGap) {
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
        .contentShape(Rectangle())
    }

    // MARK: - Avatar

    /// The deterministic-hue identity disc — same hue every time for the
    /// same peer, derived from their public key.
    private var avatar: some View {
        Circle()
            .fill(LinearGradient.avatarBrand)
            .hueRotation(.degrees(hueDegrees))
            .frame(width: Self.avatarSize, height: Self.avatarSize)
    }

    private var hueDegrees: Double {
        guard let peer = conversation.peer else { return 0 }
        return peer.avatarHue * 360
    }

    // MARK: - Name

    private var nameText: some View {
        Text(displayName)
            .font(Typography.headerName)
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
    }

    private var displayName: String {
        switch conversation.kind {
        case .direct:
            return conversation.peer?.displayLabel
                ?? conversation.title
                ?? ""
        case .meshRoom:
            return conversation.title ?? "Mesh room"
        }
    }

    // MARK: - Presence row

    private var presenceRow: some View {
        HStack(spacing: 6) {
            PresenceChain(reachability: presence)
            Text(presenceLabel)
                .font(Typography.headerPresence)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
    }

    private var presenceLabel: String {
        switch presence {
        case .direct:     return "Direct"
        case .oneHop:     return "1 hop"
        case .twoHops:    return "2 hops"
        case .outOfRange: return "Out of range"
        }
    }

    // MARK: - Trailing

    /// Time on top, unread dot below. The dot's slot is always reserved
    /// (with a clear placeholder when there's no unread) so rows don't
    /// jump horizontally as unread state flips.
    private var trailing: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(timeText)
                .font(Typography.deliveryChip)
                .foregroundStyle(Color.textTertiary)

            Circle()
                .fill(hasUnread ? Color.brand : Color.clear)
                .frame(width: Self.dotSize, height: Self.dotSize)
        }
    }

    private var timeText: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(
            for: conversation.lastActivity,
            relativeTo: Date()
        )
    }
}
