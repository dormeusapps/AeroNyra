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
//   3. COMPOSER — quiet by default: a placeholder, no shouting. A muted
//      photo affordance lives on the left (always present, earns no color
//      until tapped). The send button materializes only when there is
//      text. Both earn their visibility.
//
//  This view receives a Conversation and renders it. The composer's text
//  send is wired through `MessageInbox` (read from the environment): the
//  draft is persisted optimistically, then sealed and handed to the BLE
//  transport. The photo affordance picks an image, normalizes it to a
//  mesh-sized JPEG, and hands it to `inbox.sendMedia` — same optimistic
//  path, but the payload is chunked + sealed per-chunk by the coordinator.
//

import SwiftUI
import PhotosUI
import UIKit

struct ConversationView: View {

    let conversation: Conversation

    @Environment(\.dismiss) private var dismiss

    /// The main-actor persistence/send bridge, injected by ReadyView.
    @Environment(MessageInbox.self) private var inbox

    @State private var draft: String = ""

    /// The photo currently chosen in the system picker. Cleared back to nil
    /// after each send so the same image can be picked again immediately.
    @State private var pickedItem: PhotosPickerItem?

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
                photoButton

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

    /// The photo affordance — always present, leading the composer. Muted
    /// per the Calm posture (no brand color; it doesn't shout). Opens the
    /// system photo picker; selection is handled in `onChange`.
    private var photoButton: some View {
        PhotosPicker(selection: $pickedItem,
                     matching: .images,
                     photoLibrary: .shared()) {
            Image(systemName: "photo")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Color.textSecondary)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Attach photo")
        .onChange(of: pickedItem) { _, newItem in
            guard let newItem else { return }
            // Inherits the main actor; loads + normalizes off the actor in
            // the async helper, then hands the JPEG to the inbox.
            Task { await sendPickedPhoto(newItem) }
        }
    }

    private var sendButton: some View {
        Button {
            sendDraft()
        } label: {
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

    /// Hand the draft to the MessageInbox: it persists an outbound Message
    /// immediately (optimistic — the row appears at once and is never lost),
    /// then seals it and hands the Envelope to the BLE transport. We clear the
    /// field right away so the composer feels instant; the inbox owns the rest.
    @MainActor
    private func sendDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draft = ""
        // `Task` inherits the main actor here, so passing `conversation`
        // (a non-Sendable @Model) to the @MainActor inbox stays on-actor.
        Task { await inbox.send(trimmed, in: conversation) }
    }

    /// Load the picked image, normalize it to a mesh-sized JPEG, and hand it
    /// to the inbox's optimistic media path. The blob is deliberately small:
    /// a full-resolution photo would chunk into thousands of sealed envelopes
    /// and never finish over BLE. 1280px long-edge @ 0.7 quality lands around
    /// the "~40-chunk photo" the size model already assumes.
    @MainActor
    private func sendPickedPhoto(_ item: PhotosPickerItem) async {
        // Always release the selection so the same image can be re-picked.
        defer { pickedItem = nil }

        guard let raw = try? await item.loadTransferable(type: Data.self),
              let jpeg = Self.meshSizedJPEG(from: raw)
        else { return }

        await inbox.sendMedia(jpeg, mime: .jpeg, in: conversation)
    }

    /// Decode arbitrary picked image data (HEIC/PNG/JPEG/…), correct for
    /// orientation, downscale the long edge to `maxDimension`, and re-encode
    /// as JPEG. Returns nil if the data isn't a decodable image.
    private static func meshSizedJPEG(from data: Data,
                                      maxDimension: CGFloat = 1280,
                                      quality: CGFloat = 0.7) -> Data? {
        guard let image = UIImage(data: data) else { return nil }

        let longEdge = max(image.size.width, image.size.height)
        let scale = longEdge > maxDimension ? maxDimension / longEdge : 1
        let target = CGSize(width: image.size.width * scale,
                            height: image.size.height * scale)

        // UIGraphicsImageRenderer.draw bakes in the orientation, so the
        // re-encoded JPEG is upright with no EXIF orientation dependency.
        let renderer = UIGraphicsImageRenderer(size: target)
        let normalized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return normalized.jpegData(compressionQuality: quality)
    }
}
