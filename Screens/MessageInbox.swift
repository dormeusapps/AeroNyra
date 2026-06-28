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
            case .receivedMedia(let key, let data, let mime, let wireID):
                handleReceivedMedia(peerKey: key, data: data, mime: mime, wireID: wireID)
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

    /// A complete media transfer was reassembled + verified: persist it as an
    /// inbound media Message (blob in the row, protected at rest by Phase 5b).
    /// Deduped on the mediaID-derived wireID, so a re-sent transfer is ignored.
    private func handleReceivedMedia(peerKey: Data, data: Data,
                                     mime: MediaMimeType, wireID: MessageID) {
        guard !alreadyStored(wireID) else { return }

        let peer = peer(forRawKey: peerKey)
        peer.lastSeen = .now
        let conversation = conversation(for: peer)

        let message = Message(content: "",
                              isOutbound: false,
                              deliveryState: .delivered,
                              isRead: false,
                              wireID: wireID,
                              mediaData: data,
                              mediaMimeRaw: mime.rawValue)
        modelContext.insert(message)
        message.conversation = conversation
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

    /// Persist `data` as an outbound media Message IMMEDIATELY (optimistic, like
    /// text), then chunk + seal + send. On any failure the row is kept and
    /// marked `.notDelivered`; the transcript shows the media the instant this
    /// is called, not after the radio finishes the burst.
    func sendMedia(_ data: Data, mime: MediaMimeType, in conversation: Conversation) async {
        guard let peer = conversation.peer else {
            print("inbox: cannot send media — conversation has no peer")
            return
        }
        let rawKey = peer.publicKeyData

        let message = Message(content: "",
                              isOutbound: true,
                              deliveryState: .sent,
                              mediaData: data,
                              mediaMimeRaw: mime.rawValue)
        modelContext.insert(message)
        message.conversation = conversation
        conversation.lastActivity = .now
        save()

        do {
            let wireID = try await coordinator.sendMedia(data, mime: mime, toRawKey: rawKey)
            message.wireIDData = Data(wireID.bytes)
            save()
        } catch {
            message.deliveryState = .notDelivered
            save()
            print("inbox: media send failed, kept as .notDelivered: \(error)")
        }
    }

    // MARK: - Resend (manual tap + auto-retry on return-to-range)  Phase 7c

    /// Re-attempt delivery of a single `.notDelivered` outbound message by
    /// RE-SEALING it from the persisted row (OPEN-4: reuse the row, fresh
    /// wireID). The row holds the plaintext (`content`) and any media blob
    /// (`mediaData` + `mediaMime`), so the natural retry is to call the same
    /// coordinator path again — which advances the ratchet and mints a NEW
    /// envelope id. This is the only retry that survives a relaunch: the
    /// router's in-memory outbox is gone after a restart, but the row is not.
    ///
    /// Only acts on an outbound row that is currently `.notDelivered`, and flips
    /// it to `.sent` up front, so a double-tap or an overlapping auto-flush
    /// can't put the same row in flight twice. On success the row keeps `.sent`
    /// and stores the fresh wireID; on failure it reverts to `.notDelivered`.
    func resend(_ message: Message) async {
        guard message.isOutbound, message.deliveryState == .notDelivered else { return }
        guard let rawKey = message.conversation?.peer?.publicKeyData else {
            print("inbox: cannot resend — message has no peer")
            return
        }

        // Flip to .sent up front: the chip stops saying "tap to resend" and a
        // concurrent flush won't re-pick this row (the fetch is .notDelivered
        // only). Reverts on failure below.
        message.deliveryState = .sent
        save()

        do {
            let wireID: MessageID
            if message.isMedia, let data = message.mediaData, let mime = message.mediaMime {
                wireID = try await coordinator.sendMedia(data, mime: mime, toRawKey: rawKey)
            } else {
                wireID = try await coordinator.send(message.content, toRawKey: rawKey)
            }
            message.wireIDData = Data(wireID.bytes)
            message.conversation?.lastActivity = .now
            save()
            print("inbox: resend OK → \(wireID)")
        } catch {
            message.deliveryState = .notDelivered
            save()
            print("inbox: resend failed, kept .notDelivered: \(error)")
        }
    }

    /// Auto-retry (Tier 3): flush every `.notDelivered` outbound message whose
    /// peer is now reachable. Called from the composition root when presence
    /// gains a peer. Each row re-seals via `resend` (so the same guard +
    /// fresh-wireID semantics apply). A no-op when no one is reachable.
    func flushUndelivered(toReachableKeys reachableKeys: Set<Data>) async {
        guard !reachableKeys.isEmpty else { return }

        // `deliveryStateRaw` is the queryable form of the state enum.
        let raw = "notDelivered"
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.isOutbound && $0.deliveryStateRaw == raw }
        )
        guard let stuck = try? modelContext.fetch(descriptor), !stuck.isEmpty else { return }

        for message in stuck {
            guard let key = message.conversation?.peer?.publicKeyData,
                  reachableKeys.contains(key) else { continue }
            await resend(message)
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
