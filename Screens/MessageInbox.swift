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

    /// STEP 7f (STRICT-VERIFIED) backstop: answers whether a raw 32-byte peer key is
    /// VERIFIED. Injected as a closure (it reads PairingService/EnrollmentService) so
    /// the inbox stays decoupled from the enrollment stack. The composer is the
    /// PRIMARY gate — an unverified thread shows no composer — and this is the belt-
    /// and-suspenders that refuses to transmit even if a send path is somehow reached
    /// (e.g. a stale auto-retry). `@ObservationIgnored`: not view state.
    @ObservationIgnored private let isVerified: (Data) -> Bool

    /// N2 — the local-notification façade (owned by BeaconApp, threaded in by
    /// ReadyView). Fired ONLY from the two inbound persist seams below, which
    /// sit downstream of decryption AND the `alreadyStored(wireID)` dedup, so a
    /// BLE message later re-fetched from a relay can never double-fire. Optional
    /// + `@ObservationIgnored`: not view state, absent in tests/previews.
    @ObservationIgnored private let notifier: LocalNotifier?

    init(modelContext: ModelContext,
         coordinator: FirstContactCoordinator,
         router: MessageRouter,
         isVerified: @escaping (Data) -> Bool,
         notifier: LocalNotifier? = nil) {
        self.modelContext = modelContext
        self.coordinator = coordinator
        self.router = router
        self.isVerified = isVerified
        self.notifier = notifier
    }

    // MARK: - Inbound event loop

    /// FaceTime v1 (P3): the call layer's tap on the events stream. Set by
    /// the composition root; nil (frames silently ignored) until calls wire.
    var onCallSignal: ((CallSignal, _ peerKey: Data) -> Void)?

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
            case .receivedMedia(let key, let data, let mime, let wireID, let sentAt, let isStory, let isPushToTalk):
                handleReceivedMedia(peerKey: key, data: data, mime: mime, wireID: wireID,
                                    sentAt: sentAt, isStory: isStory, isPushToTalk: isPushToTalk)
            case .learnedNostrIdentity(let key, let nostrPubkey):
                handleLearnedNostrIdentity(peerKey: key, nostrPubkey: nostrPubkey)
            case .reconnected(let key):
                await handleReconnected(peerKey: key)
            case .callSignal(let key, let signal):
                // FaceTime v1 (P3): forwarded to the call layer, never
                // persisted. The inbox stays the events stream's SINGLE
                // consumer; CallEngine hangs off this hook.
                onCallSignal?(signal, key)
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
        notifyMessageArrived(peerKey: peerKey, conversationKey: conversation.id,
                             isStory: false)   // N2 — genuinely-new row only (dedup above)
    }

    /// A complete media transfer was reassembled + verified: persist it as an
    /// inbound media Message (blob in the row, protected at rest by Phase 5b).
    /// Deduped on the mediaID-derived wireID, so a re-sent transfer is ignored.
    private func handleReceivedMedia(peerKey: Data, data: Data,
                                     mime: MediaMimeType, wireID: MessageID,
                                     sentAt: Date?, isStory: Bool, isPushToTalk: Bool) {
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
                              mediaMimeRaw: mime.rawValue,
                              isStory: isStory,
                              isPushToTalk: isPushToTalk)
        // CLAMP (SEC-6 stories): the manifest's `sentAt` is the SENDER's clock —
        // attacker-controlled. Unclamped, a future-dated stamp makes a story
        // that NEVER expires (now − future < window, forever). Take the earlier
        // of their stamp and our arrival time; a story manifest missing the
        // stamp entirely anchors on arrival. Non-story rows keep sentAt nil.
        if isStory {
            message.sentAt = min(sentAt ?? message.timestamp, message.timestamp)
        }
        modelContext.insert(message)
        message.conversation = conversation
        conversation.lastActivity = .now
        save()
        notifyMessageArrived(peerKey: peerKey, conversationKey: conversation.id,
                             isStory: isStory)   // N2 — genuinely-new row only (dedup above)
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

        // 7f backstop: never transmit to an unverified contact. The UI removes the
        // composer for unverified threads (primary gate); this refuses even if a send
        // is somehow driven here. Persist-then-mark keeps the optimistic row so
        // nothing typed is lost — it flushes once the contact verifies + is reachable.
        guard isVerified(rawKey) else {
            message.deliveryState = .notDelivered
            save()
            print("inbox: BLOCKED send to unverified peer")
            return
        }

        do {
            let wireID = try await coordinator.send(trimmed, toRawKey: rawKey,
                                                    nostrRecipient: nostrRecipient)
            message.wireIDData = Data(wireID.bytes)
            // Read back the transport the router committed this id to, race-free:
            // .sent (BLE radio handoff) or .cast (handed to a Nostr relay — no ack
            // deadline, "in the current, will surface"). Falls back to the current
            // optimistic .sent if the outbox entry has already resolved/cleared.
            if let committed = await router.state(of: wireID) {
                message.deliveryState = committed
            }
            save()
        } catch {
            message.deliveryState = .notDelivered
            save()
            RedactLog.event("inbox: send failed, kept as .notDelivered", "\(type(of: error))")
        }
    }

    /// Persist `data` as an outbound media Message IMMEDIATELY (optimistic, like
    /// text), then chunk + seal + send. On any failure the row is kept and
    /// marked `.notDelivered`; the transcript shows the media the instant this
    /// is called, not after the radio finishes the burst.
    ///
    /// STORIES: pass `isStory: true` to send a photo story. The row is stamped
    /// `sentAt` = its own `timestamp` (the ONE first-send instant), and both
    /// fields ride the manifest so the receiver expires on the same anchor.
    func sendMedia(_ data: Data, mime: MediaMimeType, in conversation: Conversation,
                   isStory: Bool = false, isPushToTalk: Bool = false) async {
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
                              mediaMimeRaw: mime.rawValue,
                              isStory: isStory,
                              isPushToTalk: isPushToTalk)
        // One instant is the expiry anchor everywhere: row insert time.
        if isStory { message.sentAt = message.timestamp }
        modelContext.insert(message)
        message.conversation = conversation
        conversation.lastActivity = .now
        save()

        // 7f backstop: never transmit media to an unverified contact (see `send`).
        guard isVerified(rawKey) else {
            message.deliveryState = .notDelivered
            save()
            print("inbox: BLOCKED media send to unverified peer")
            return
        }

        do {
            let wireID = try await coordinator.sendMedia(data, mime: mime, toRawKey: rawKey,
                                                         nostrRecipient: nostrRecipient,
                                                         sentAt: message.sentAt,
                                                         isStory: isStory,
                                                         isPushToTalk: isPushToTalk)
            message.wireIDData = Data(wireID.bytes)
            // .sent over BLE (90s timer armed), or .cast over Nostr (no timer —
            // the transfer will surface when the peer reconnects).
            if let committed = await router.state(of: wireID) {
                message.deliveryState = committed
            }
            save()
        } catch {
            message.deliveryState = .notDelivered
            save()
            RedactLog.event("inbox: media send failed, kept as .notDelivered", "\(type(of: error))")
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
        // STORIES (SEC-6 reversal safety): an EXPIRED story's blob was reaped
        // but the row survives as a tombstone. `isMedia` is blob-presence, so
        // without this guard a reaped story still at `.notDelivered` would fall
        // into the TEXT branch below on the next return-to-range auto-flush and
        // transmit an EMPTY message. A media row is recognizable after the wipe
        // by its surviving mime stamp: mime set + blob gone → skip, forever.
        if message.mediaMimeRaw != nil, message.mediaData == nil {
            print("inbox: skip resend — media tombstone (expired story)")
            return
        }
        guard let peer = message.conversation?.peer else {
            print("inbox: cannot resend — message has no peer")
            return
        }
        let rawKey = peer.publicKeyData
        let nostrRecipient = peer.nostrPubkey   // Tier-2 fallback target (nil until bootstrapped)

        // 7f backstop: never re-transmit to an unverified contact. Placed BEFORE the
        // `.sent` flip below, so a blocked resend stays `.notDelivered` rather than
        // sticking at `.sent`. (An unverified peer is never in a reachable set, so a
        // flush wouldn't pick this up anyway — this is defense in depth.)
        guard isVerified(rawKey) else {
            print("inbox: BLOCKED resend to unverified peer")
            return
        }

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
                                                         reuseID: reuse,
                                                         sentAt: message.sentAt,
                                                         isStory: message.isStory,
                                                         isPushToTalk: message.isPushToTalk)
            } else {
                wireID = try await coordinator.send(message.content, toRawKey: rawKey,
                                                    nostrRecipient: nostrRecipient,
                                                    reuseID: reuse)
            }
            message.wireIDData = Data(wireID.bytes)
            // Reflect the transport actually used: a resend while the peer is out
            // of BLE range commits over Nostr → .cast ("will surface"), NOT the
            // false "tap to resend" loop. In BLE range → .sent as before.
            if let committed = await router.state(of: wireID) {
                message.deliveryState = committed
            }
            message.conversation?.lastActivity = .now
            save()
            RedactLog.event("inbox: resend OK", "→ \(wireID)")
        } catch {
            message.deliveryState = .notDelivered
            save()
            RedactLog.event("inbox: resend failed, kept .notDelivered", "\(type(of: error))")
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

    // MARK: - Media re-drive on mid-burst BLE drop (ISSUE-3b)

    /// A media transfer that COMMITTED to BLE (the peer was verified-reachable when
    /// the composer fired → `sendMedia` chose the 4096 BLE burst) then lost the link
    /// mid-burst cannot finish over BLE: the chunks already handed to CoreBluetooth
    /// at teardown returned `.sent` and are gone, the coordinator's linear loop has
    /// moved past them, and the router's `rerouteToNostr` skips media (its outbox
    /// entry has no backing envelope). Crucially the row still reads `.sent` (the
    /// coordinator never threw — a broadcast-flood chunk "succeeds" even into the
    /// void), so `flushUndelivered` (which fetches `.notDelivered`) never sees it.
    ///
    /// So when a peer DEPARTS the reachable set, re-drive its still-in-flight media
    /// rows WHOLE over Nostr. This is the media analogue of the router's text
    /// `rerouteToNostr`, but inbox-driven because only the persisted row owns the
    /// full media blob. `sendMedia(redrive: true)` re-chunks at the ORIGINAL 4096
    /// BLE bucket and REUSES the mediaID (via `reuseID:`), so every re-driven chunk
    /// is byte-identical to the partial the receiver already buffered — and to any
    /// straggler a flapping BLE link later delivers. They dedup by (mediaID, index)
    /// into exactly ONE transfer that completes once and persists once.
    ///
    /// Called from the composition root when the reachable set LOSES a peer (the
    /// same diff that feeds `flushUndelivered` on a gain). A no-op when nothing
    /// departed. Terminal rows (delivered / relayed / notDelivered) and rows for a
    /// peer with no learned Nostr address are skipped — the latter simply wait for
    /// the peer to return to BLE range (or for the stuck-send timeout to fail them,
    /// after which the ordinary Tier-3 flush applies).
    func redriveInFlightMedia(toDepartedKeys departed: Set<Data>) async {
        guard !departed.isEmpty else { return }

        // Coarse fetch (mirrors `inFlightWireIDs`): outbound rows that already hold
        // a wireID, filtered in Swift — `#Predicate` can't traverse the peer
        // relationship, read the computed `deliveryState`, or test media-ness.
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.isOutbound && $0.wireIDData != nil }
        )
        guard let rows = try? modelContext.fetch(descriptor), !rows.isEmpty else { return }

        for message in rows {
            guard message.isMedia,
                  !message.deliveryState.isTerminal,            // still in flight (unacked)
                  !message.nostrRedriveDone,                    // PERSISTED cap-of-1: re-drive over Nostr at most once, ever (survives relaunch)
                  let peer = message.conversation?.peer,
                  departed.contains(peer.publicKeyData),
                  let nostrRecipient = peer.nostrPubkey,         // must have an internet address
                  let data = message.mediaData,
                  let mime = message.mediaMime,
                  let reuse = message.wireID                     // the mediaID to preserve
            else { continue }

            let rawKey = peer.publicKeyData
            // 7f backstop: never transmit to an unverified contact (belt-and-
            // suspenders; an unverified peer is never in a reachable set to depart
            // from, but the re-drive path is defended like every other send path).
            guard isVerified(rawKey) else { continue }

            // Durable cap-of-1 reservation (ISSUE-3b): persist the flag BEFORE the
            // await, so (a) a force-quit mid-re-drive or (b) a re-drive that fails and
            // marks the row `.notDelivered` can't loop back into the rate-limited relays
            // on the next launch. On @MainActor this also serialises a near-simultaneous
            // second call: it re-fetches, sees the saved flag, and skips — no double
            // publish. Set once and never cleared: one Nostr re-drive per row, for real.
            message.nostrRedriveDone = true
            save()

            do {
                let wireID = try await coordinator.sendMedia(data, mime: mime, toRawKey: rawKey,
                                                             nostrRecipient: nostrRecipient,
                                                             reuseID: reuse, redrive: true,
                                                             sentAt: message.sentAt,
                                                             isStory: message.isStory,
                                                             isPushToTalk: message.isPushToTalk)
                // Same mediaID (reuse), so the row's wireID is unchanged; re-stamp
                // it anyway for parity with the other send paths. A re-drive always
                // commits over Nostr, so the router reports `.cast` — reflect that
                // ("in the current, will surface"), not the optimistic `.sent`. The
                // ack path flips it terminal, after which a repeat departure won't
                // re-drive it.
                message.wireIDData = Data(wireID.bytes)
                if let committed = await router.state(of: wireID) {
                    message.deliveryState = committed
                }
                message.conversation?.lastActivity = .now
                save()
                RedactLog.event("inbox: media re-driven over Nostr", "→ \(wireID)")
            } catch {
                // Nostr re-drive itself failed (e.g. every relay down): mark
                // `.notDelivered` so the ordinary return-to-range flush retries it.
                message.deliveryState = .notDelivered
                save()
                RedactLog.event("inbox: media re-drive failed, marked .notDelivered", "\(type(of: error))")
            }
        }
    }

    // MARK: - Ephemeral media reaper (SEC-6 / P3)

    /// Wipe the blobs of media past their ephemerality window
    /// (`MediaEphemeralityPolicy`): inbound photos AND v1 videos `photoWindow`
    /// after receipt, inbound voice notes `voiceListenWindow` after they were
    /// listened to, and STORIES `storyWindow` after they were sent — BOTH
    /// directions, sender included (the stories-only SEC-6 reversal). The render-time
    /// wipes only run when a row is actually on screen — a never-opened
    /// conversation would otherwise hold the bytes forever (the SEC-6 defect:
    /// forensically recoverable after first unlock). Called at boot (ReadyView's
    /// setup task) and on every return to the foreground. Idempotent — a second
    /// run finds nothing to wipe.
    ///
    /// TOMBSTONE, NOT DELETE: only `mediaData` is nilled, mirroring the view
    /// layer's `wipeMedia`. The row MUST survive — its `wireIDData` is the dedup
    /// record (`alreadyStored`) that stops a late relay replay of the same
    /// transfer from re-materializing a self-destructed photo. Outbound
    /// NON-STORY rows are excluded in the store predicate itself: a resend
    /// still needs their blob. An outbound STORY is admitted and reaped like
    /// any other; the tombstone guard in `resend` keeps the blob-less row out
    /// of every send path afterwards.
    func reapExpiredMedia() {
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate {
                $0.mediaData != nil && ($0.isOutbound == false || $0.isStory)
            }
        )
        guard let rows = try? modelContext.fetch(descriptor), !rows.isEmpty else { return }

        let now = Date.now
        var reaped = 0
        for message in rows {
            guard MediaEphemeralityPolicy.isExpired(isStory: message.isStory,
                                                    mime: message.mediaMime,
                                                    timestamp: message.timestamp,
                                                    sentAt: message.sentAt,
                                                    listenedAt: message.listenedAt,
                                                    now: now) else { continue }
            message.mediaData = nil
            reaped += 1
        }
        if reaped > 0 {
            save()
            print("inbox: reaped \(reaped) expired media blob(s)")
        }
    }

    // MARK: - Boot reconcile (Phase 2 / P4)

    /// Reclassify outbound rows a relaunch stranded NON-TERMINAL. The router's
    /// outbox and timers are in-memory, so after a restart nothing can ever
    /// resolve a row left at `.sent` / `.waitingForRange` / `.findingPath` —
    /// `flushUndelivered` fetches only `.notDelivered`, and the ack that might
    /// have settled it can no longer match (the outbox entry is gone). Stamp
    /// them `.notDelivered`, the one state the recovery machinery (and the
    /// user's resend affordance) can see. Honest-but-pessimistic is safe here:
    /// the B2 reuseID dedup means a later resend lands ZERO duplicates even if
    /// the orphan was actually delivered before the relaunch.
    ///
    /// `.cast` rows are deliberately LEFT ALONE: `.cast` is only ever stamped
    /// from `router.state(of:)` after a real relay commit, so a persisted
    /// `.cast` is a wrap waiting at a relay — "will surface" stays true across
    /// a relaunch, and demoting it would recreate the P0 false-failure.
    ///
    /// CLASSIFY-ONLY, NO SENDS: this runs from ReadyView's boot task,
    /// concurrent with transport startup — a send here could race
    /// `mesh.start()` and throw `TransportError.notStarted`. Rows are written
    /// directly (not via a `DeliveryUpdate` through `apply`), so nothing
    /// downstream can trigger off the transition. Synchronous on the main
    /// actor, so the flush that follows in the same task sees the fresh states.
    func reconcileBootOrphans() {
        // The full set of non-terminal raws EXCEPT "cast" (see above). A future
        // non-terminal state must be enumerated here too — noted at the
        // `deliveryState` bridge in PersistentModels.
        let sent = "sent"
        let waiting = "waitingForRange"
        let finding = "findingPath"
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate {
                $0.isOutbound == true &&
                ($0.deliveryStateRaw == sent
                 || $0.deliveryStateRaw == waiting
                 || $0.deliveryStateRaw == finding)
            }
        )
        guard let orphans = try? modelContext.fetch(descriptor), !orphans.isEmpty else { return }
        for message in orphans {
            message.deliveryState = .notDelivered
        }
        save()
        print("inbox: boot reconcile — \(orphans.count) orphaned outbound row(s) → .notDelivered")
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
    /// `deliveryState`. The set is small (only unconfirmed sends). `.cast` rows are
    /// excluded: a relay commit carries no timer to extend (none may ever be armed
    /// for it), so offering its id to `extendTimeout` on reconnect would re-arm a
    /// stuck-send timer that later demotes a message sitting safely at a relay.
    private func inFlightWireIDs(forPeerKey peerKey: Data) -> [MessageID] {
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.isOutbound && $0.wireIDData != nil }
        )
        guard let rows = try? modelContext.fetch(descriptor) else { return [] }
        return rows.compactMap { row in
            guard row.conversation?.peer?.publicKeyData == peerKey,
                  !row.deliveryState.isTerminal,
                  row.deliveryState != .cast,
                  let wire = row.wireID else { return nil }
            return wire
        }
    }

    // MARK: - Local notification (N2)

    /// Fire the banner + badge for a genuinely-new inbound row. Called ONLY from
    /// the two persist seams above, after their `alreadyStored(wireID)` dedup and
    /// after the row is saved — so the unread count below already includes it,
    /// and a relay replay of a BLE-delivered message never reaches here. The
    /// thread key is the peer's raw 32-byte identity key (`Peer.publicKeyData`),
    /// the same `Data` form every key crossing this boundary uses. Suppression
    /// for the on-screen conversation lives in the notifier
    /// (`activeConversationID`, set/cleared by StreamView).
    private func notifyMessageArrived(peerKey: Data, conversationKey: UUID, isStory: Bool) {
        guard let notifier else { return }
        let unread = unreadInboundTotal()
        Task { await notifier.messageArrived(conversationID: peerKey,
                                             threadKey: conversationKey,
                                             unreadTotal: unread,
                                             isStory: isStory) }
    }

    /// FaceTime v1 (P3): the missed-call transcript row. LOCAL-ONLY — nothing
    /// rides the wire (both ends run their own ring clock and write their
    /// own row, per the committed no-server design). Rendered as an ordinary
    /// inbound text line; unread, so the chat surfaces it.
    func recordMissedCall(peerKey: Data) {
        let peer = peer(forRawKey: peerKey)
        let conversation = conversation(for: peer)
        let message = Message(content: "missed call",
                              isOutbound: false,
                              deliveryState: .delivered,
                              isRead: false)
        modelContext.insert(message)
        message.conversation = conversation
        conversation.lastActivity = .now
        save()
    }

    /// FaceTime v1 (P3): the peer's Nostr key for internet-relayed signaling
    /// (the same Tier-2 fallback target every send path reads).
    func nostrKey(forRawKey rawKey: Data) -> Data? {
        peer(forRawKey: rawKey).nostrPubkey
    }

    /// Re-sync the app-icon badge to the store's true unread total. Called by
    /// StreamView after `markInboundRead` saves, so READING a chat pulls the
    /// badge back down — without this the badge stamped on arrival sticks at
    /// its old count until the next message lands. Idempotent (it's a count,
    /// not a delta) and a no-op when no notifier is wired.
    func syncBadgeToUnreadTotal() {
        notifier?.syncBadge(unreadInboundTotal())
    }

    /// The store's TRUE app-wide unread total — a count, not a blind increment,
    /// so the badge self-heals across replays, relaunches, and reads. Same
    /// `!isOutbound && !isRead` definition as the Home unread stone
    /// (HomeView.unreadCount) and the chats-list dot (ChatsListView.hasUnread).
    private func unreadInboundTotal() -> Int {
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { !$0.isOutbound && !$0.isRead }
        )
        return (try? modelContext.fetchCount(descriptor)) ?? 0
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
        catch { RedactLog.event("inbox: save failed", "\(type(of: error))") }
    }
}
