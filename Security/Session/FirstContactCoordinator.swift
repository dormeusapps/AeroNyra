//
//  FirstContactCoordinator.swift
//  Security/Session
//
//  Marries the BLE transport to the secure-session store to perform CARRIER-
//  NEUTRAL first contact.
//
//  On a new link both peers exchange prekey bundles. A deterministic tie-break
//  (the higher identity key initiates) picks exactly ONE initiator, so the two
//  sides don't both start a session at once (simultaneous initiation can cross
//  the ratchets). The initiator establishes a session from the peer's bundle;
//  the responder's session forms when it opens the first (prekey) message the
//  initiator sends, which self-identifies the sender.
//
//  CARRIER-NEUTRAL BY DESIGN: although wired to BLE here, a bundle pasted from a
//  QR code or arriving over a future internet transport enters the SAME
//  `onBundle` path. Nothing here assumes proximity, and nothing assumes a peer
//  count — sessions scale to as many peers as you meet.
//
//  THIS IS THE ACTOR↔SwiftData BOUNDARY (STEP 4). The coordinator is an `actor`
//  and NEVER touches SwiftData. Instead it EMITS `SessionEvent`s on `events`;
//  a main-actor consumer (MessageInbox) turns those into Peer / Conversation /
//  Message rows. The 33-byte libsignal identity rep stays sealed inside the
//  session store — every key that crosses this boundary is the RAW 32-byte
//  `Peer.publicKeyData` form (via store.rawPublicKey / store.peerIdentity).
//
//  ROUTING (Phase 7b.1 / 7b.1a). The coordinator no longer touches the transport
//  for ENVELOPES — that path now runs through `MessageRouter`, which dedups +
//  relays (multi-hop, max 7 hops). This actor is the router's `EnvelopeReceiver`:
//  inbound survivors arrive at `receive(_:)`, which opens them and emits events;
//  and `relayExclusions(forSourceLink:)` tells the router which links NOT to
//  forward back out (split-horizon — never echo a message to the peer it came
//  from, across EITHER of that peer's two GATT-role link ids). Outbound seals go
//  out via `router.send`, so our own ids are marked seen and flooding echoes
//  don't loop back to us. BUNDLES stay link-local and direct (`sendBundle`).
//
//  DELIVERY ACKS (Phase 7b.2b/c). When we open a data message we seal a tiny
//  delivery receipt back to the sender — the acked message's wire id plus the
//  hop count it travelled (maxHops − arrival ttl). For TEXT the acked id is the
//  envelope id; for MEDIA it is the mediaID-derived message id, stamped once the
//  transfer reassembles whole. The receipt rides the same sealed Envelope path,
//  UNTRACKED (no receipt-of-receipt, no tracking on the ack itself). On the
//  sending side, opening an `.ack` calls `router.confirmDelivery`, which turns
//  the chip into Delivered / Relayed and cancels that message's timeout. Media
//  is registered for tracking around its burst (`beginTracking` before,
//  `startDeliveryTimeout` after) so its message-level id can be confirmed.
//
//  PRESENCE-BY-IDENTITY (Phase 7a). The coordinator is ALSO the only place that
//  knows which ephemeral BLE link maps to which crypto identity (`linkPeers`,
//  learned from each peer's bundle). It therefore publishes a second stream —
//  `reachablePeers` — carrying the set of RAW 32-byte peer keys currently
//  reachable, computed as (live links ∩ identified links). This collapses the
//  per-role presence double-count for free: one physical peer linked over BOTH
//  GATT directions surfaces as two ephemeral ids but ONE identity, hence one
//  key. A main-actor consumer mirrors this into MeshPresence so per-conversation
//  reachability ("Direct" vs "Out of range") is finally real. Like `events`, the
//  stream is `nonisolated` + unbounded-buffered, so emissions made before the
//  consumer starts are held, not dropped.
//
//  An `actor` so its mutable link/peer state is race-free; the composition root
//  feeds it the transport's streams and consumes `events` + `reachablePeers`.
//

import Foundation

/// What the coordinator tells the (main-actor) persistence layer happened.
///
/// Payload keys are RAW 32-byte X25519 public keys — exactly what
/// `Peer.publicKeyData` stores. No libsignal type leaks here, so this is freely
/// `Sendable` and safe to hand across the actor → main-actor boundary.
enum SessionEvent: Sendable {

    /// We were the initiator and a session is now established with this peer.
    /// The persistence layer should create-or-fetch the Peer + a direct
    /// Conversation so it becomes a named, tappable row — even before any
    /// message is typed. (No message is attached; this is "you've met them".)
    case established(peerKey: Data)

    /// A sealed message was opened from this peer. The persistence layer should
    /// create-or-fetch the Peer + Conversation and persist an inbound Message.
    /// `wireID` is the envelope id, for dedup against relayed duplicates.
    case received(peerKey: Data, plaintext: Data, wireID: MessageID)

    /// A complete media transfer (photo / voice note) was reassembled and
    /// integrity-verified from this peer. `data` is the whole blob; `wireID` is
    /// derived from the 16-byte mediaID (stable across the transfer) so dedup
    /// works the same as for text. Partial transfers never surface here.
    case receivedMedia(peerKey: Data, data: Data, mime: MediaMimeType, wireID: MessageID)
}

actor FirstContactCoordinator: EnvelopeReceiver {

    private let store: SignalSessionStore
    private let transport: BLEMeshTransport

    /// The mesh router (Phase 7b.1): owns Envelope I/O — dedup, relay, and the
    /// transport-facing send. Injected after construction by the composition
    /// root (`setRouter`), which also registers this actor as the router's
    /// `EnvelopeReceiver`. Held strongly; the router holds us weakly, so there
    /// is no retain cycle. Outbound envelopes go through it; bundles do not.
    private var router: MessageRouter?

    /// Media chunking config. A chunk fills `mediaBucket` exactly once its
    /// 1-byte payload tag (`mediaReserved`) is accounted for — no wasted
    /// padding tier (see MediaChunker / MessagePayload).
    private static let mediaBucket = 4096
    private static let mediaReserved = 1

    /// Collects inbound media chunks until a transfer is whole + verified.
    /// Actor-isolated, so its buffers are race-free. Initialized in `init`
    /// (4096/1 are known-valid, so the chunker can't fail — validated constant).
    private var reassembler: MediaReassembler

    /// Links we've already greeted with our bundle (don't re-send each tick).
    private var greetedLinks: Set<UUID> = []
    /// Peer identity learned per link from their bundle.
    ///
    /// STICKY: not pruned in the reachability hot path. Presence is computed by
    /// intersecting with the LIVE link set (`reachableLinks`), so a link that
    /// goes away simply stops contributing — no need to forget its identity, and
    /// keeping it avoids a presence flicker on a transient link blip. Bounded by
    /// the number of distinct links seen this session; UUIDs are never reused
    /// for a different peer.
    private var linkPeers: [UUID: PublicIdentity] = [:]

    /// The most recent set of reachable BLE links (ephemeral CoreBluetooth ids)
    /// from the transport. Remembered between ticks so `onBundle` can recompute
    /// presence when a link becomes identified, and so `emitReachablePeers`
    /// always intersects against the current live set.
    private var reachableLinks: Set<UUID> = []

    /// Events for the main-actor persistence layer (MessageInbox). `nonisolated`
    /// so the consumer can `for await` it without hopping into actor isolation;
    /// `AsyncStream` is `Sendable` and `SessionEvent` carries no actor state.
    /// Default (unbounded) buffering means events emitted before the consumer
    /// starts are held, not dropped.
    nonisolated let events: AsyncStream<SessionEvent>
    private let eventsContinuation: AsyncStream<SessionEvent>.Continuation

    /// Presence resolved to identity (Phase 7a): the set of RAW 32-byte peer
    /// keys currently reachable over BLE. A main-actor consumer mirrors this
    /// into MeshPresence so per-conversation reachability is real. `nonisolated`
    /// + unbounded-buffered for the same reasons as `events`.
    nonisolated let reachablePeers: AsyncStream<Set<Data>>
    private let reachablePeersContinuation: AsyncStream<Set<Data>>.Continuation

    init(store: SignalSessionStore, transport: BLEMeshTransport) {
        self.store = store
        self.transport = transport
        self.reassembler = MediaReassembler(
            chunker: try! MediaChunker(targetBucket: Self.mediaBucket,
                                       reservedBytes: Self.mediaReserved))
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream()
        self.events = stream
        self.eventsContinuation = continuation

        let (rStream, rContinuation) = AsyncStream<Set<Data>>.makeStream()
        self.reachablePeers = rStream
        self.reachablePeersContinuation = rContinuation
    }

    /// Wire the mesh router in (Phase 7b.1). Called once by the composition root
    /// right after it registers this actor as the router's `EnvelopeReceiver`.
    func setRouter(_ router: MessageRouter) {
        self.router = router
    }

    // MARK: Reachability → send our bundle to new links + publish presence

    func onReachable(_ ids: [UUID]) async {
        let current = Set(ids)
        reachableLinks = current
        greetedLinks.formIntersection(current)   // drop links that went away
        for link in current where !greetedLinks.contains(link) {
            greetedLinks.insert(link)
            await sendOurBundle(to: link)
        }
        emitReachablePeers()
    }

    private func sendOurBundle(to link: UUID) async {
        do {
            let bundle = try store.localPrekeyBundle()
            try await transport.sendBundle(bundle.data, toLink: link)
            print("first-contact: sent our bundle → link \(link)")
        } catch {
            greetedLinks.remove(link)   // allow a retry on the next tick
            print("first-contact: bundle send to \(link) failed: \(error)")
        }
    }

    /// Publish the set of RAW 32-byte keys currently reachable: every live link
    /// that we've resolved to an identity, mapped to its raw key and de-duped by
    /// the `Set`. The de-dup is what collapses the per-role double-count — both
    /// GATT directions of one peer map to the same identity, hence one key.
    private func emitReachablePeers() {
        var keys = Set<Data>()
        for link in reachableLinks {
            if let peer = linkPeers[link] {
                keys.insert(store.rawPublicKey(of: peer))
            }
        }
        reachablePeersContinuation.yield(keys)
        print("first-contact: presence → \(keys.count) reachable peer(s)")
    }

    // MARK: Inbound bundle → maybe initiate

    func onBundle(link: UUID, data: Data) async {
        let bundle = PrekeyBundle(data: data)
        guard let peer = try? store.peerIdentity(from: bundle) else {
            print("first-contact: malformed bundle on link \(link)")
            return
        }
        linkPeers[link] = peer
        // A link just became identified — if it's currently reachable, this is
        // the moment its peer's presence flips on. Recompute + publish.
        emitReachablePeers()

        // Deterministic initiator: the higher identity key initiates. Both
        // sides compute the same comparison, so exactly one initiates.
        let mine = Array(store.localIdentity.agreementKey)
        let theirs = Array(peer.agreementKey)
        let iInitiate = theirs.lexicographicallyPrecedes(mine)

        if iInitiate {
            await initiate(with: bundle, peer: peer)
        } else {
            print("first-contact: responder role for \(peer.userIDHex.prefix(16))… — session forms on first message")
        }
    }

    private func initiate(with bundle: PrekeyBundle, peer: PublicIdentity) async {
        do {
            // Establish the outgoing session from the peer's bundle. We do NOT
            // auto-send anything here any more — the composer drives the first
            // real message (step 4). Establishing makes the peer real on OUR
            // side now; the responder's side becomes real when our first typed
            // message reaches them.
            _ = try store.establishSession(from: bundle)
            let rawKey = store.rawPublicKey(of: peer)
            eventsContinuation.yield(.established(peerKey: rawKey))
            print("first-contact: INITIATED session with \(peer.userIDHex.prefix(16))…")
        } catch {
            print("first-contact: initiate failed: \(error)")
        }
    }

    // MARK: Outbound send (composer-driven)

    /// Hand a sealed envelope to the mesh router and translate the immediate
    /// routing outcome into this layer's throw contract: a clean `.sent`
    /// succeeds; anything else (no reachable peer, or a transport rejection)
    /// throws, so the caller (MessageInbox) keeps its optimistically-persisted
    /// row and marks it `.notDelivered` — exactly as before the router existed.
    ///
    /// `tracked` (default true) is forwarded to the router: a real text message
    /// is tracked (delivery state + stuck-send timeout), while a media
    /// manifest/chunk goes untracked (still flooded + seen-marked, but not
    /// individually delivery-tracked — media's message-level tracking is
    /// registered around the burst in `sendMedia`).
    private func routeOut(_ envelope: Envelope, tracked: Bool = true) async throws {
        guard let router else { throw TransportError.notStarted }
        let state = await router.send(envelope, tracked: tracked)
        guard state == .sent else { throw TransportError.sendFailed }
    }

    /// Seal `text` to an already-established peer (looked up by its RAW 32-byte
    /// key) and hand the resulting Envelope to the router. Returns the wire
    /// `MessageID` so the caller can persist it on the outbound Message (for
    /// delivery-receipt matching and dedup).
    ///
    /// Throws if no session exists yet, sealing fails, or the router could not
    /// hand the envelope to the radio. The caller (MessageInbox) has already
    /// optimistically persisted the row, so on a throw it simply marks that
    /// message `.notDelivered` — nothing the user typed is ever lost.
    func send(_ text: String, toRawKey rawKey: Data) async throws -> MessageID {
        let peer = store.peerIdentity(fromRawKey: rawKey)
        let session = try store.session(with: peer)
        // Tag the plaintext as text so the receiver can tell it apart from a
        // media manifest/chunk (which now share this same sealed path).
        let sealed = try session.seal(MessagePayload.text(Data(text.utf8)).encoded())
        let envelope = Envelope(ciphertext: sealed)
        try await routeOut(envelope)   // tracked: a real message earns a receipt
        return envelope.id
    }

    /// Seal + send a media blob as a manifest followed by N chunks, each its own
    /// framed, sealed Envelope. Returns a `MessageID` derived from the 16-byte
    /// mediaID, stable for the whole transfer (the caller persists it for dedup
    /// + delivery matching).
    ///
    /// The manifest is sent first so the receiver knows the size/count before
    /// chunks pile up; the reassembler tolerates any order regardless. Chunks go
    /// out sequentially — the transport's notify path is strict-FIFO
    /// (Phase 6b.2a), so this ordered burst reassembles cleanly on the peer.
    ///
    /// DELIVERY TRACKING (7b.2c): the manifest + chunks are UNTRACKED control
    /// envelopes, but the TRANSFER is tracked by its message-level id. We
    /// `beginTracking` that id BEFORE the burst (so a fast media ack still finds
    /// an entry to confirm) and `startDeliveryTimeout` AFTER the whole burst is
    /// on the radio (so the timeout doesn't count our own send time). If the
    /// burst fails mid-way we mark the transfer failed and rethrow, so the
    /// inbox's optimistic row becomes `.notDelivered` — nothing the user picked
    /// is lost.
    func sendMedia(_ blob: Data, mime: MediaMimeType, toRawKey rawKey: Data) async throws -> MessageID {
        let peer = store.peerIdentity(fromRawKey: rawKey)
        let session = try store.session(with: peer)

        let chunker = try MediaChunker(targetBucket: Self.mediaBucket,
                                       reservedBytes: Self.mediaReserved)
        // Use a CSPRNG 16-byte id (a MessageID's bytes) as the mediaID, so the
        // same value is both the transfer key and the dedup / tracking MessageID.
        let idBytes = MessageID.random().bytes
        let mediaWireID = MessageID(bytes: idBytes)!
        let (manifest, chunks) = try chunker.split(blob, mime: mime, mediaID: idBytes)

        // Register the transfer for delivery tracking up front, so an ack that
        // races back before the burst finishes still matches.
        await router?.beginTracking(of: mediaWireID)

        // Manifest + chunks are UNTRACKED: flooded + seen-marked, but not
        // individually delivery-tracked (no per-chunk timeout, no outbox bloat).
        func emit(_ payload: MessagePayload) async throws {
            let sealed = try session.seal(payload.encoded())
            try await routeOut(Envelope(ciphertext: sealed), tracked: false)
        }

        do {
            let manifestJSON = try JSONEncoder().encode(manifest)
            try await emit(.mediaManifest(manifestJSON))
            for chunk in chunks {
                try await emit(.mediaChunk(chunk))
            }
        } catch {
            // The burst broke before completing; fail the tracked transfer so
            // the router cancels any state and the inbox marks the row failed.
            await router?.confirmFailure(of: mediaWireID)
            throw error
        }

        // Whole burst is on the radio — now start the (longer) media timeout.
        await router?.startDeliveryTimeout(for: mediaWireID,
                                           after: MessageRouter.mediaDeliveryTimeout)
        print("first-contact: SENT media \(blob.count)B as \(chunks.count) chunks → \(peer.userIDHex.prefix(16))…")
        return mediaWireID
    }

    /// Seal a delivery receipt back to `peer` for a message we just opened,
    /// stamped with the hop count it travelled. The receipt rides the same
    /// sealed Envelope path but is sent UNTRACKED — it is itself never acked (no
    /// receipt loop) and earns no delivery state. Best-effort: a failed ack just
    /// means the sender keeps showing "Sent" until its timeout, and it never
    /// blocks or fails inbound handling. `wireID` is the acked message's id —
    /// the envelope id for text, or the mediaID-derived id for a media transfer.
    private func sendDeliveryAck(wireID: MessageID, hops: UInt8, to peer: PublicIdentity) async {
        do {
            let session = try store.session(with: peer)
            let payload = MessagePayload.deliveryAck(wireID: wireID, hops: hops)
            let sealed = try session.seal(payload.encoded())
            await router?.send(Envelope(ciphertext: sealed), tracked: false)
        } catch {
            print("first-contact: delivery-ack seal/send failed: \(error)")
        }
    }

    /// Hop count an envelope travelled, read from its arrival ttl: 0 for a
    /// direct delivery, ≥1 if it was relayed (maxHops − ttl, floored at 0).
    private func hops(of envelope: Envelope) -> UInt8 {
        UInt8(max(0, Int(Envelope.maxHops) - Int(envelope.ttl)))
    }

    // MARK: Relay split-horizon + inbound open  (EnvelopeReceiver)

    /// The router asks, for each inbound envelope, which links a relay must NOT
    /// go back out — so a forwarded message never echoes to the peer it came
    /// from. We answer with EVERY link currently mapped to the source link's
    /// peer: a peer is reachable over up to two ephemeral ids (its peripheral id
    /// and its central id), and both must be excluded or the message storms back
    /// over the other GATT role. If we can't resolve the source link to a known
    /// peer yet, we still exclude the source link itself.
    func relayExclusions(forSourceLink link: UUID) -> Set<UUID> {
        guard let peer = linkPeers[link] else { return [link] }
        let peerKey = store.rawPublicKey(of: peer)
        var exclusions: Set<UUID> = [link]
        for (otherLink, otherPeer) in linkPeers
        where store.rawPublicKey(of: otherPeer) == peerKey {
            exclusions.insert(otherLink)
        }
        return exclusions
    }

    /// The router's `EnvelopeReceiver` entry point: an inbound envelope that
    /// survived dedup (and was relayed onward if it had hop budget) is handed
    /// here to be opened. Only this layer holds the keys.
    func receive(_ envelope: Envelope) async {
        do {
            let (peer, plaintext) = try store.openInbound(envelope.ciphertext)
            let rawKey = store.rawPublicKey(of: peer)

            guard let payload = MessagePayload.decode(plaintext) else {
                print("first-contact: opened but undecodable payload from \(peer.userIDHex.prefix(16))…")
                return
            }

            switch payload {
            case .text(let body):
                eventsContinuation.yield(
                    .received(peerKey: rawKey, plaintext: body, wireID: envelope.id)
                )
                print("first-contact: OPENED text from \(peer.userIDHex.prefix(16))…")
                // Acknowledge the text message by its envelope id, with hops.
                await sendDeliveryAck(wireID: envelope.id, hops: hops(of: envelope), to: peer)

            case .mediaManifest(let json):
                guard let manifest = try? JSONDecoder().decode(MediaManifest.self, from: json) else {
                    print("first-contact: bad media manifest from \(peer.userIDHex.prefix(16))…")
                    return
                }
                if let done = reassembler.ingest(manifest: manifest),
                   let wireID = emitMedia(done, rawKey: rawKey) {
                    // The transfer completed on the manifest — ack the whole
                    // media by its message-level id, stamped with this leg's hops.
                    await sendDeliveryAck(wireID: wireID, hops: hops(of: envelope), to: peer)
                }

            case .mediaChunk(let chunk):
                if let done = reassembler.ingest(chunk: chunk),
                   let wireID = emitMedia(done, rawKey: rawKey) {
                    // The transfer completed on this chunk — ack the whole media
                    // by its message-level id, stamped with this leg's hops.
                    await sendDeliveryAck(wireID: wireID, hops: hops(of: envelope), to: peer)
                }

            case .ack(let body):
                // A delivery receipt for one of OUR sent messages. Match it to
                // the router's outbox (text envelope id, or a media transfer's
                // message-level id) and advance the sender-side chip to
                // Delivered / Relayed, cancelling that message's timeout. We
                // never ack an ack, so this terminates the receipt exchange.
                guard let (wireID, hops) = MessagePayload.parseDeliveryAck(body) else {
                    print("first-contact: malformed delivery ack from \(peer.userIDHex.prefix(16))…")
                    return
                }
                await router?.confirmDelivery(of: wireID, hops: Int(hops))
                print("first-contact: ACK \(wireID) (\(hops) hop(s)) from \(peer.userIDHex.prefix(16))…")
            }
        } catch {
            print("first-contact: open failed: \(error)")
        }
    }

    /// Emit a completed media transfer to the persistence layer and return the
    /// message-level `MessageID` (derived from the 16-byte mediaID hex) so the
    /// caller can ack the transfer by that id. Returns nil only if the mediaID
    /// is malformed (in which case nothing is emitted and no ack is sent).
    @discardableResult
    private func emitMedia(_ done: MediaReassembler.Completed, rawKey: Data) -> MessageID? {
        guard let idBytes = Self.hexToBytes(done.mediaID),
              let wireID = MessageID(bytes: idBytes) else { return nil }
        eventsContinuation.yield(
            .receivedMedia(peerKey: rawKey, data: done.data, mime: done.mime, wireID: wireID)
        )
        print("first-contact: MEDIA complete \(done.data.count)B (\(done.mime.rawValue))")
        return wireID
    }

    /// Decode a lowercase-hex string to bytes. nil on odd length or non-hex.
    private static func hexToBytes(_ hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }
}
