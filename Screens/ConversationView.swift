//
//  ConversationView.swift
//  Screens
//
//  The conversation transcript — the screen you see after opening a chat.
//
//  Three vertical regions, all built around the Calm + Alive + Private
//  posture:
//
//   1. HEADER — back chevron, tappable name (pushes Peer Settings),
//      PresenceChain + label underneath. The name and presence together
//      ARE the relationship; no avatar, no "online" status, no typing
//      indicator. The mesh's state IS the social state.
//
//   2. TRANSCRIPT — messages flow up from the bottom; newest at the
//      bottom. Each row composes MessageRow.
//
//   3. COMPOSER — quiet by default: a placeholder, no shouting. The
//      send button materializes only when there is text. Earns its
//      visibility.
//
//  This view receives a Conversation and renders it. Real send wiring
//  (security → router → transport) attaches at `sendDraft()` once the
//  BLE transport lands.
//

import SwiftUI

struct ConversationView: View {

    let conversation: Conversation

    @Environment(\.dismiss) private var dismiss

    @State private var draft: String = ""

    /// Presence with the peer. Stubbed to .outOfRange until the BLE
    /// transport exists and a real ReachabilityMonitor drives it.
    @State private var presence: PresenceChain.Reachability = .outOfRange

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            transcript
            composer
        }
        .background(Color.bgApp.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            backButton
            Spacer()
            peerCenter
            Spacer()
            // Symmetric placeholder for a future trailing action; keeps
            // the peer name visually centered without jumping later.
            Color.clear
                .frame(width: 32, height: 32)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var backButton: some View {
        Button(action: { dismiss() }) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.brand)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Back")
    }

    /// Centered peer block. Tap pushes the Peer Settings screen.
    private var peerCenter: some View {
        NavigationLink {
            PeerSettingsView(conversation: conversation)
        } label: {
            VStack(spacing: 4) {
                Text(peerNameDisplay)
                    .font(Typography.headerName)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                presenceRow
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens peer settings")
    }

    /// The reachability chain + label, under the peer name. This is the
    /// "alive" surface of the header — the line that breathes with the
    /// state of the radio (once BLE lands).
    private var presenceRow: some View {
        HStack(spacing: 6) {
            PresenceChain(reachability: presence)
            Text(presenceLabel)
                .font(Typography.headerPresence)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
    }

    private var peerNameDisplay: String {
        switch conversation.kind {
        case .direct:
            return conversation.peer?.displayLabel
                ?? conversation.title
                ?? ""
        case .meshRoom:
            return conversation.title ?? "Mesh room"
        }
    }

    private var presenceLabel: String {
        switch presence {
        case .direct:     return "In range · direct"
        case .oneHop:     return "Reachable · 1 hop"
        case .twoHops:    return "Reachable · 2 hops"
        case .outOfRange: return "Out of range · searching…"
        }
    }

    // MARK: - Hairline

    private var hairline: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(height: 1)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 9) {
                ForEach(orderedMessages) { message in
                    MessageRow(message: message)
                        .id(message.id)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
    }

    /// Messages in chronological order, oldest first. SwiftData doesn't
    /// guarantee an order on a relationship; sort defensively here so
    /// the row order is stable.
    private var orderedMessages: [Message] {
        conversation.messages.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 0) {
            hairline
            HStack(alignment: .bottom, spacing: 10) {
                TextField(text: $draft, axis: .vertical) {
                    Text("message…")
                        .foregroundStyle(Color.composerPlaceholder)
                }
                .textFieldStyle(.plain)
                .font(Typography.messageBody)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1...5)
                .padding(.horizontal, 15)
                .padding(.vertical, 9)

                if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                    sendButton
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .animation(.easeOut(duration: 0.18), value: draft.isEmpty)
        }
        .background(Color.bgApp)
    }

    private var sendButton: some View {
        Button(action: sendDraft) {
            Circle()
                .fill(Color.brand)
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                )
        }
        .accessibilityLabel("Send")
    }

    // MARK: - Actions

    /// Stub send path. The real implementation runs the draft through
    /// the security/session layer (libsignal seal) → MessageRouter → BLE
    /// transport. None of that exists yet from the UI's perspective;
    /// this stub clears the field so the composer behavior can be felt
    /// without claiming a message was sent.
    private func sendDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // TODO: hand `trimmed` to the security layer, persist as an
        // outbound Message bound to `conversation`, and pass the sealed
        // Envelope to MessageRouter.send. For now the composer just
        // clears, so we can feel the interaction.
        draft = ""
    }
}
