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

    /// The mesh router — held so a reconnect can EXTEND this peer's live stuck-send
    /// timers (STEP 0b / A). `@ObservationIgnored`: it is not view state.
    @ObservationIgnored private let router: MessageRouter

    /// Per-peer reconnect grace deadlines (STEP 0b / A). While a peer sits in this
    /// map with a future deadline, its auto-retry (`flushUndelivered`) is held so a
    /// delivery ack delayed by link churn can land before we'd needlessly resend —
    /// which matters most for a slow media re-transfer the receiver would just dedup
    /// away. PER-PEER: a grace for one peer never stalls another's flush.
    /// `@ObservationIgnored`: internal scheduling state, not view state.
    @ObservationIgnored private var reconnectGraceUntil: [Data: Date] = [:]

    /// How long a peer's auto-retry is held after it reconnects, and how far its
    /// live delivery timers are pushed out. Sized to cover a text/voice ack landing
    /// post-reconnect (text <1s, voice ack ~12s in hardware tests) without stalling
    /// a genuinely-failed message's resend for long. Tune against real traffic.
    private static let reconnectGraceSeconds: TimeInterval = 10

    init(modelContext: ModelContext,
         coordinator: FirstContactCoordinator,
         router: MessageRouter) {
        self.modelContext = modelContext
        self.coordinator = coordinator
        self.router = router
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
            case .learnedNostrIdentity(let key, let nostrPubkey):
                handleLearnedNostrIdentity(peerKey: key, nostrPubkey: nostrPubkey)
            case .reconnected(let key):
                await handleReconnected(peerKey: key)
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

    /// A peer announced their Nostr public key over the established sealed
    /// channel (Phase 8d npub-bootstrap). Create-or-fetch the peer by its raw
    /// 32-byte key and store the announced key on the row, so the router can
    /// later address a Nostr gift wrap to this peer. This is identity metadata,
    /// not a message — no Message row, no unread dot, no conversation forced.
    ///
    /// Last-announcement-wins, and a re-announcement of the SAME key is a pure
    /// no-op (no redundant SwiftData write, mirroring the delivery-update path).
    /// Overwrite is safe: the channel carrying the announcement is already
    /// sealed and authenticated to this exact peer.
    private func handleLearnedNostrIdentity(peerKey: Data, nostrPubkey: Data) {
        let peer = peer(forRawKey: peerKey)
        guard peer.nostrPubkey != nostrPubkey else { return }
        peer.nostrPubkey = nostrPubkey
        peer.lastSeen = .now
        save()
    }

    /// Consume the router's `deliveryUpdates` for the app's lifetime, applying
    /// each one to the matching outbound row. Started once from the composition
    /// root (a `.task`, right next to `run()`), fed `router.deliveryUpdates`.
    ///
    /// `deliveryUpdates` is single-consumer: this method must be the ONLY reader
    /// of that stream. It is the rail the ack path (7b.2b) rides. Today the
    /// router emits `.sent` for rows that already hold a wireID (a no-op here)
    /// and, on a SYNCHRONOUS failure, `.waitingForRange` / `.notDelivered` for
    /// an id whose row has not been stamped with a wireID yet (so those match
    /// nothing) — so this loop is effectively idempotent until acks + a timeout
    /// begin producing real `.delivered` / `.relayed` / timed-out `.notDelivered`
    /// transitions.
    func runDeliveryUpdates(_ updates: AsyncStream<DeliveryUpdate>) async {
        for await update in updates {
            apply(update)
        }
    }

    /// Match a `DeliveryUpdate` (keyed by wire `MessageID`) to its outbound row
    /// and advance the row's `deliveryState`. Conservative on purpose:
    ///   • a TERMINAL row (delivered / relayed / notDelivered) is never pulled
    ///     back to a non-terminal state by a late or stale update, so the
    ///     inbox's optimistic `.notDelivered` and any settled ack hold; and
    ///   • an update that wouldn't change the row is dropped, so there's no
    ///     redundant SwiftData write on the common echo of `.sent`.
    private func apply(_ update: DeliveryUpdate) {
        let wire: Data? = Data(update.id.bytes)
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.isOutbound && $0.wireIDData == wire }
        )
        guard let row = try? modelContext.fetch(descriptor).first else { return }

        if row.deliveryState.isTerminal && !update.state.isTerminal { return }
        guard row.deliveryState != update.state else { return }

        row.deliveryState = update.state
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
        let nostrRecipient = peer.nostrPubkey   // Tier-2 fallback target (nil until bootstrapped)

        let message = Message(content: trimmed, isOutbound: true, deliveryState: .sent)
        modelContext.insert(message)
        message.conversation = conversation
        conversation.lastActivity = .now
        save()

        do {
            let wireID = try await coordinator.send(trimmed, toRawKey: rawKey,
                                                    nostrRecipient: nostrRecipient)
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
        let nostrRecipient = peer.nostrPubkey   // Tier-2 fallback target (nil until bootstrapped)

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
            let wireID = try await coordinator.sendMedia(data, mime: mime, toRawKey: rawKey,
                                                         nostrRecipient: nostrRecipient)
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
    /// RE-SEALING it from the persisted row (OPEN-4: reuse the row). The row
    /// holds the plaintext (`content`) and any media blob (`mediaData` +
    /// `mediaMime`), so the natural retry is to call the same coordinator path
    /// again — which advances the ratchet (a FRESH ciphertext).
    ///
    /// B2 (idempotency backstop): the retry REUSES the wireID this row was
    /// already sent under, so the re-sealed envelope carries the SAME cleartext
    /// id even though the ciphertext is new. That is what lets the receiver's
    /// `alreadyStored(envelope.id)` dedup recognize the retry and drop it — a
    /// redelivery lands ZERO duplicates instead of one. (Reuse is safe from the
    /// ratchet's replay rejection: a fresh seal is a new `.whisper`, never an
    /// identical ciphertext.) This is the only retry that survives a relaunch:
    /// the router's in-memory outbox is gone after a restart, but the row is not.
    ///
    /// Only acts on an outbound row that is currently `.notDelivered`, and flips
    /// it to `.sent` up front, so a double-tap or an overlapping auto-flush
    /// can't put the same row in flight twice. On success the row keeps `.sent`
    /// and stores the fresh wireID; on failure it reverts to `.notDelivered`.
    func resend(_ message: Message) async {
        guard message.isOutbound, message.deliveryState == .notDelivered else { return }
        guard let peer = message.conversation?.peer else {
            print("inbox: cannot resend — message has no peer")
            return
        }
        let rawKey = peer.publicKeyData
        let nostrRecipient = peer.nostrPubkey   // Tier-2 fallback target (nil until bootstrapped)

        // Flip to .sent up front: the chip stops saying "tap to resend" and a
        // concurrent flush won't re-pick this row (the fetch is .notDelivered
        // only). Reverts on failure below.
        message.deliveryState = .sent
        save()

        // B2: reuse the wireID this row was already sent under so the receiver's
        // dedup catches the retry. Nil only for a NEVER-SEALED row (one that hit
        // .notDelivered before ever getting a wireID) — in that case the
        // coordinator mints a fresh id and returns it, and the write below records
        // it, exactly as before.
        let reuse = message.wireID
        do {
            let wireID: MessageID
            if message.isMedia, let data = message.mediaData, let mime = message.mediaMime {
                wireID = try await coordinator.sendMedia(data, mime: mime, toRawKey: rawKey,
                                                         nostrRecipient: nostrRecipient,
                                                         reuseID: reuse)
            } else {
                wireID = try await coordinator.send(message.content, toRawKey: rawKey,
                                                    nostrRecipient: nostrRecipient,
                                                    reuseID: reuse)
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
    /// reused-wireID semantics apply). A no-op when no one is reachable.
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
            // Per-peer reconnect grace (STEP 0b / A): if this peer just reconnected,
            // hold its auto-retry until the grace elapses so an in-flight ack can
            // land first — the deferred flush scheduled in `handleReconnected` picks
            // this row up afterward. Every other peer flushes normally.
            if isInReconnectGrace(key) { continue }
            await resend(message)
        }
    }

    // MARK: - Reconnect grace (STEP 0b / A)

    /// A peer completed the closed-contact reconnect handshake. Open (or extend) a
    /// per-peer grace window: defer that peer's auto-retry so a delivery ack delayed
    /// by link churn can land before we'd resend, and push out its live stuck-send
    /// timers so the sender's chip doesn't falsely flip to `.notDelivered`. Strictly
    /// per-peer — no other peer's retries or timers are touched.
    private func handleReconnected(peerKey: Data) async {
        reconnectGraceUntil[peerKey] =
            Date.now.addingTimeInterval(Self.reconnectGraceSeconds)

        // Extend live delivery timers for THIS peer's still-in-flight messages.
        // No-op after a relaunch (the router's in-memory outbox is gone) — the
        // deferred flush below still applies to the persisted `.notDelivered` rows.
        for id in inFlightWireIDs(forPeerKey: peerKey) {
            await router.extendTimeout(for: id, by: .seconds(Self.reconnectGraceSeconds))
        }

        scheduleGraceFlush(forPeerKey: peerKey)
    }

    /// True while `peerKey` sits in an unexpired reconnect grace. Clears the entry
    /// lazily once it has elapsed so the map doesn't accrete stale peers.
    private func isInReconnectGrace(_ peerKey: Data) -> Bool {
        guard let until = reconnectGraceUntil[peerKey] else { return false }
        if Date.now < until { return true }
        reconnectGraceUntil[peerKey] = nil
        return false
    }

    /// After the grace elapses, flush just this peer's held `.notDelivered` rows.
    /// Re-reads the deadline each wake so a fresh reconnect that EXTENDS the grace
    /// defers the flush further; the first waking task to see the grace expired
    /// clears it and flushes, and any superseded sibling task then no-ops.
    private func scheduleGraceFlush(forPeerKey peerKey: Data) {
        Task { @MainActor [weak self] in
            while let until = self?.reconnectGraceUntil[peerKey], Date.now < until {
                try? await Task.sleep(for: .seconds(max(0.05, until.timeIntervalSinceNow)))
            }
            guard let self, self.reconnectGraceUntil[peerKey] != nil else { return }
            self.reconnectGraceUntil[peerKey] = nil
            // resend is idempotent (B2), so this is safe even if the peer drifted
            // back out of range; a truly failed retry simply re-queues .notDelivered.
            await self.flushUndelivered(toReachableKeys: [peerKey])
        }
    }

    /// The wire ids of this peer's still-in-flight outbound messages (non-terminal,
    /// already sealed). A coarse fetch (outbound + has a wireID) filtered in Swift,
    /// since `#Predicate` can't traverse the peer relationship or read the computed
    /// `deliveryState`. The set is small (only unconfirmed sends).
    private func inFlightWireIDs(forPeerKey peerKey: Data) -> [MessageID] {
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.isOutbound && $0.wireIDData != nil }
        )
        guard let rows = try? modelContext.fetch(descriptor) else { return [] }
        return rows.compactMap { row in
            guard row.conversation?.peer?.publicKeyData == peerKey,
                  !row.deliveryState.isTerminal,
                  let wire = row.wireID else { return nil }
            return wire
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
