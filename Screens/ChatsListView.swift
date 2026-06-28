//
//  ChatsListView.swift
//  Screens
//
//  The home screen — every conversation, ordered by recent activity.
//  This is the real entry point of the app; ContentView will route
//  here once we replace the debug Conversation-direct wiring.
//
//  Quiet posture: no compose button (new conversations are discovered
//  via the Nearby screen — you can't text a stranger you've never met
//  in person), no avatar uploads, no online/offline status, no badge
//  counts on the app icon. Just a list of who you've met, and how near
//  they are right now.
//

import SwiftUI
import SwiftData

struct ChatsListView: View {

    /// All conversations, most recently active first. Live-updates as
    /// SwiftData inserts/updates land.
    @Query(sort: \Conversation.lastActivity, order: .reverse)
    private var conversations: [Conversation]

    /// Live mesh presence (identity-resolved), injected by the composition
    /// root. Drives each row's reachability chain.
    @Environment(MeshPresence.self) private var presence

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            if conversations.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .readableColumn()
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: Conversation.self) { conv in
            ConversationView(conversation: conv)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Chats")
                .font(.custom("Geist-Bold", size: 26))
                .foregroundStyle(Color.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(height: 1)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(conversations) { conv in
                    NavigationLink(value: conv) {
                        ChatRow(
                            conversation: conv,
                            presence: reachability(for: conv),
                            hasUnread: hasUnread(conv)
                        )
                    }
                    .buttonStyle(.plain)
                    // Inset hairline — aligned with the start of the name
                    // column, not the avatar, so the avatars feel grouped.
                    Rectangle()
                        .fill(Color.hairline)
                        .frame(height: 1)
                        .padding(.leading, 64)
                }
            }
        }
    }

    /// Reachability to a conversation's peer right now, resolved from live BLE
    /// presence (Phase 7a). Drives `.direct` vs `.outOfRange`; multi-hop arrives
    /// with the MessageRouter (7b). A conversation with no single peer (a mesh
    /// room) resolves to `.outOfRange`.
    private func reachability(for conversation: Conversation) -> PresenceChain.Reachability {
        guard let key = conversation.peer?.publicKeyData,
              presence.isReachable(key) else {
            return .outOfRange
        }
        return .direct
    }

    /// A conversation is "unread" when it holds any INBOUND message the
    /// user hasn't opened yet. Outbound messages never count.
    private func hasUnread(_ conversation: Conversation) -> Bool {
        conversation.messages.contains { !$0.isOutbound && !$0.isRead }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("no chats yet")
                .font(Typography.deliveryChip)
                .foregroundStyle(Color.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
