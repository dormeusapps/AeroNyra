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
//  An `actor` so its mutable link/peer state is race-free; the composition root
//  feeds it the transport's streams and consumes `events`.
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

actor FirstContactCoordinator {

    private let store: SignalSessionStore
    private let transport: BLEMeshTransport

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
    private var linkPeers: [UUID: PublicIdentity] = [:]

    /// Events for the main-actor persistence layer (MessageInbox). `nonisolated`
    /// so the consumer can `for await` it without hopping into actor isolation;
    /// `AsyncStream` is `Sendable` and `SessionEvent` carries no actor state.
    /// Default (unbounded) buffering means events emitted before the consumer
    /// starts are held, not dropped.
    nonisolated let events: AsyncStream<SessionEvent>
    private let eventsContinuation: AsyncStream<SessionEvent>.Continuation

    init(store: SignalSessionStore, transport: BLEMeshTransport) {
        self.store = store
        self.transport = transport
        self.reassembler = MediaReassembler(
            chunker: try! MediaChunker(targetBucket: Self.mediaBucket,
                                       reservedBytes: Self.mediaReserved))
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream()
        self.events = stream
        self.eventsContinuation = continuation
    }

    // MARK: Reachability → send our bundle to new links

    func onReachable(_ ids: [UUID]) async {
        let current = Set(ids)
        greetedLinks.formIntersection(current)   // drop links that went away
        for link in current where !greetedLinks.contains(link) {
            greetedLinks.insert(link)
            await sendOurBundle(to: link)
        }
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

    // MARK: Inbound bundle → maybe initiate

    func onBundle(link: UUID, data: Data) async {
        let bundle = PrekeyBundle(data: data)
        guard let peer = try? store.peerIdentity(from: bundle) else {
            print("first-contact: malformed bundle on link \(link)")
            return
        }
        linkPeers[link] = peer

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

    /// Seal `text` to an already-established peer (looked up by its RAW 32-byte
    /// key) and hand the resulting Envelope to the transport. Returns the wire
    /// `MessageID` so the caller can persist it on the outbound Message (for
    /// delivery-receipt matching and dedup).
    ///
    /// Throws if no session exists yet, sealing fails, or the transport send
    /// fails. The caller (MessageInbox) has already optimistically persisted
    /// the row, so on a throw it simply marks that message `.notDelivered` —
    /// nothing the user typed is ever lost.
    func send(_ text: String, toRawKey rawKey: Data) async throws -> MessageID {
        let peer = store.peerIdentity(fromRawKey: rawKey)
        let session = try store.session(with: peer)
        // Tag the plaintext as text so the receiver can tell it apart from a
        // media manifest/chunk (which now share this same sealed path).
        let sealed = try session.seal(MessagePayload.text(Data(text.utf8)).encoded())
        let envelope = Envelope(ciphertext: sealed)
        try await transport.send(envelope)
        return envelope.id
    }

    /// Seal + send a media blob as a manifest followed by N chunks, each its own
    /// framed, sealed Envelope. Returns a `MessageID` derived from the 16-byte
    /// mediaID, stable for the whole transfer (the caller persists it for dedup
    /// + delivery matching).
    ///
    /// The manifest is sent first so the receiver knows the size/count before
    /// chunks pile up; the reassembler tolerates any order regardless. Chunks go
    /// out sequentially — the transport's notify path is now strict-FIFO
    /// (Phase 6b.2a), so this ordered burst reassembles cleanly on the peer.
    ///
    /// Throws if no session exists, sealing fails, or a send fails. The caller
    /// (MessageInbox) has optimistically persisted the row, so on a throw it
    /// marks that message `.notDelivered` — nothing the user picked is lost.
    func sendMedia(_ blob: Data, mime: MediaMimeType, toRawKey rawKey: Data) async throws -> MessageID {
        let peer = store.peerIdentity(fromRawKey: rawKey)
        let session = try store.session(with: peer)

        let chunker = try MediaChunker(targetBucket: Self.mediaBucket,
                                       reservedBytes: Self.mediaReserved)
        // Use a CSPRNG 16-byte id (a MessageID's bytes) as the mediaID, so the
        // same value is both the transfer key and the dedup MessageID.
        let idBytes = MessageID.random().bytes
        let (manifest, chunks) = try chunker.split(blob, mime: mime, mediaID: idBytes)

        func emit(_ payload: MessagePayload) async throws {
            let sealed = try session.seal(payload.encoded())
            try await transport.send(Envelope(ciphertext: sealed))
        }

        let manifestJSON = try JSONEncoder().encode(manifest)
        try await emit(.mediaManifest(manifestJSON))
        for chunk in chunks {
            try await emit(.mediaChunk(chunk))
        }
        print("first-contact: SENT media \(blob.count)B as \(chunks.count) chunks → \(peer.userIDHex.prefix(16))…")
        return MessageID(bytes: idBytes)!
    }

    // MARK: Inbound envelope → open + emit

    func onEnvelope(_ envelope: Envelope) async {
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

            case .mediaManifest(let json):
                guard let manifest = try? JSONDecoder().decode(MediaManifest.self, from: json) else {
                    print("first-contact: bad media manifest from \(peer.userIDHex.prefix(16))…")
                    return
                }
                if let done = reassembler.ingest(manifest: manifest) {
                    emitMedia(done, rawKey: rawKey)
                }

            case .mediaChunk(let chunk):
                if let done = reassembler.ingest(chunk: chunk) {
                    emitMedia(done, rawKey: rawKey)
                }
            }
        } catch {
            print("first-contact: open failed: \(error)")
        }
    }

    /// Emit a completed media transfer to the persistence layer. The mediaID hex
    /// (16 bytes) becomes the dedup `MessageID`.
    private func emitMedia(_ done: MediaReassembler.Completed, rawKey: Data) {
        guard let idBytes = Self.hexToBytes(done.mediaID),
              let wireID = MessageID(bytes: idBytes) else { return }
        eventsContinuation.yield(
            .receivedMedia(peerKey: rawKey, data: done.data, mime: done.mime, wireID: wireID)
        )
        print("first-contact: MEDIA complete \(done.data.count)B (\(done.mime.rawValue))")
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
