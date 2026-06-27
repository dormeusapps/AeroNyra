//
//  MessageInbox.swift
//
//  The main-actor bridge between FirstContactCoordinator (an `actor` that
//  speaks crypto + radio and NEVER touches SwiftData) and the SwiftData store.
//
//  WHY THIS EXISTS: ModelContext is main-actor-bound; the coordinator is an
//  actor. Writing SwiftData from inside the coordinator would cross that
//  boundary unsafely. So the coordinator EMITS `SessionEvent`s and this type —
//  pinned to the main actor — is the only thing that turns them into Peer /
//  Conversation / Message rows. It also owns the composer's send path, so every
//  persistence write in the messaging flow lives here, in one main-actor place.
//
//  IDENTITY: every key crossing the boundary is the RAW 32-byte
//  Peer.publicKeyData form. The 33-byte libsignal rep never reaches this file
//  (the SignalSessionStore bridges it, in one place).
//
//  SEND POLICY: OPTIMISTIC. An outbound message is persisted IMMEDIATELY so it
//  is never lost — even if the radio is down — and only marked `.notDelivered`
//  if sealing/transport throws. (Internet fallback, when it lands, slots in as
//  a second send attempt before that mark — additive, no model change.)
//

import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class MessageInbox {

    private let modelContext: ModelContext
    private let coordinator: FirstContactCoordinator

    init(modelContext: ModelContext, coordinator: FirstContactCoordinator) {
        self.modelContext = modelContext
        self.coordinator = coordinator
    }

    // MARK: - Inbound event loop

    /// Consume coordinator events for the app's lifetime, writing SwiftData on
    /// the main actor. Started once from the composition root (a `.task`).
    /// `events` is unbounded-buffered, so anything emitted before this starts
    /// is delivered, not dropped.
    func run() async {
        for await event in coordinator.events {
            switch event {
            case .established(let key):
                handleEstablished(peerKey: key)
            case .received(let key, let plaintext, let wireID):
                handleReceived(peerKey: key, plaintext: plaintext, wireID: wireID)
            }
        }
    }

    /// We were the initiator: make the peer real now (named, tappable row in
    /// Chats) so the composer has somewhere to live, before any message is sent.
    private func handleEstablished(peerKey: Data) {
        let peer = peer(forRawKey: peerKey)
        peer.lastSeen = .now
        let conversation = conversation(for: peer)
        conversation.lastActivity = .now
        save()
    }

    /// A sealed message was opened: create-or-fetch the peer + conversation and
    /// persist the inbound Message (which lights the unread dot).
    private func handleReceived(peerKey: Data, plaintext: Data, wireID: MessageID) {
        // Dedup: a relayed duplicate of a message we already stored is ignored.
        guard !alreadyStored(wireID) else { return }

        let peer = peer(forRawKey: peerKey)
        peer.lastSeen = .now
        let conversation = conversation(for: peer)

        let text = String(data: plaintext, encoding: .utf8) ?? ""
        let message = Message(content: text,
                              isOutbound: false,
                              deliveryState: .delivered,
                              isRead: false,
                              wireID: wireID)
        modelContext.insert(message)
        message.conversation = conversation   // sets the inverse → appears in transcript
        conversation.lastActivity = .now
        save()
    }

    // MARK: - Outbound (composer-driven, optimistic)

    /// Persist `text` as an outbound Message IMMEDIATELY (so it is never lost),
    /// then seal + send. On any failure the row is kept and marked
    /// `.notDelivered`; the transcript updates the instant this is called —
    /// no waiting on the radio.
    func send(_ text: String, in conversation: Conversation) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let peer = conversation.peer else {
            print("inbox: cannot send — conversation has no peer")
            return
        }
        let rawKey = peer.publicKeyData

        let message = Message(content: trimmed, isOutbound: true, deliveryState: .sent)
        modelContext.insert(message)
        message.conversation = conversation
        conversation.lastActivity = .now
        save()

        do {
            let wireID = try await coordinator.send(trimmed, toRawKey: rawKey)
            message.wireIDData = Data(wireID.bytes)
            save()
        } catch {
            message.deliveryState = .notDelivered
            save()
            print("inbox: send failed, kept as .notDelivered: \(error)")
        }
    }

    // MARK: - Fetch-or-create

    private func peer(forRawKey key: Data) -> Peer {
        let descriptor = FetchDescriptor<Peer>(
            predicate: #Predicate { $0.publicKeyData == key }
        )
        if let existing = try? modelContext.fetch(descriptor).first {
            return existing
        }
        let peer = Peer(publicKeyData: key)
        modelContext.insert(peer)
        return peer
    }

    private func conversation(for peer: Peer) -> Conversation {
        if let existing = peer.conversations.first(where: { $0.kind == .direct }) {
            return existing
        }
        let conversation = Conversation(kind: .direct, peer: peer)
        modelContext.insert(conversation)
        return conversation
    }

    private func alreadyStored(_ wireID: MessageID) -> Bool {
        let data: Data? = Data(wireID.bytes)
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.wireIDData == data }
        )
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    private func save() {
        do { try modelContext.save() }
        catch { print("inbox: save failed: \(error)") }
    }
}
