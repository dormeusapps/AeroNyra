//
//  ChatsListView.swift
//  Screens
//
//  The home screen — every conversation, ordered by recent activity.
//  This is the app's ROOT: ContentView lands here directly (no tab bar;
//  the Nearby/radar screen was removed with the closed-contact pivot).
//
//  Quiet posture: new contacts are added deliberately (pair by QR in person,
//  or by invite + 4-word confirm) — you can't text a stranger who merely has
//  the app. No online/offline status, no badge counts on the app icon. The
//  top bar carries two deliberate actions: add a contact, and open settings.
//  Just a list of who you've paired with, and how near they are right now.
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
        HStack(spacing: 14) {
            Text("Chats")
                .font(.custom("Geist-Bold", size: 26))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            addContactButton
            settingsButton
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    /// Add a contact — the entry to the (deliberate) pairing flow: show/scan a
    /// QR in person, or generate/redeem an invite. The pairing surface itself
    /// lands with enrollment (7c) + the pairing UI (7d); this is its placed,
    /// consistent home in the top bar. Muted per the Calm posture.
    private var addContactButton: some View {
        Button {
            // Wired to the pairing flow in 7d. Placed now so the root's shape
            // is final and nothing shifts when pairing lands.
        } label: {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Color.textSecondary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Add contact")
    }

    /// Open settings — profile, your own identity/QR, and (later) the emergency
    /// wipe. Muted; opens the settings surface (built in the UI phase).
    private var settingsButton: some View {
        Button {
            // Wired to the settings surface in the UI phase.
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Color.textSecondary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Settings")
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
