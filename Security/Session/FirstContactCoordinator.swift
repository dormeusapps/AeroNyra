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
import CryptoKit

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
    case receivedMedia(peerKey: Data, data: Data, mime: MediaMimeType, wireID: MessageID,
                       sentAt: Date?, isStory: Bool, isPushToTalk: Bool)
    /// A sealed, VERIFIED-contact call-signaling frame (FaceTime v1). Routed
    /// to the call layer, never persisted as a Message.
    case callSignal(peerKey: Data, signal: CallSignal)
    
    /// This peer announced their raw 32-byte x-only secp256k1 Nostr public key
    /// over the established sealed channel (Phase 8d npub-bootstrap — never from
    /// the PrekeyBundle). The persistence layer should create-or-fetch the Peer
    /// and store `nostrPubkey` on the row, so the router can later address a
    /// Nostr gift wrap to this peer when BLE is out of range. Identity metadata,
    /// not a message: no Message row, no unread dot.
    case learnedNostrIdentity(peerKey: Data, nostrPubkey: Data)
    
    /// This peer completed the closed-contact reconnect handshake (5d admission).
    /// NOT a message — no Peer / Conversation / Message write is required — but the
    /// persistence layer uses it to open a PER-PEER reconnect GRACE (STEP 0b / A):
    /// briefly defer this peer's auto-retry so a delivery ack delayed by link churn
    /// can land before we'd resend, and extend this peer's live stuck-send timeouts
    /// so the sender's chip doesn't falsely flip to `.notDelivered` mid-reconnect.
    /// Per-peer by construction, so no other peer's timeouts or retries are touched.
    case reconnected(peerKey: Data)
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
    
    /// OUR raw 32-byte x-only secp256k1 Nostr public key, injected post-
    /// construction by the composition root (`setNostrPublicKey`, mirroring
    /// `setRouter`). Held so we can announce it to peers we converse with (the
    /// npub-bootstrap). Optional: nil if the device has no Nostr identity yet, in
    /// which case the announce path is a silent no-op and the BLE pillar is
    /// unaffected.
    private var ourNostrPublicKey: Data?
    
    /// The invite-echo redeemer (STEP 7c-2). Injected post-construction by the
    /// composition root (`setInviteRedeemer`, mirroring `setRouter`). Held WEAKLY
    /// so it does not retain the service, which retains us via ReconnectEnrolling.
    private weak var inviteRedeemer: (any InviteRedeeming)?
    
    /// Media chunking config. A chunk fills `mediaBucket` exactly once its
    /// 1-byte payload tag (`mediaReserved`) is accounted for — no wasted
    /// padding tier (see MediaChunker / MessagePayload).
    private static let mediaBucket = 4096
    private static let mediaReserved = 1
    /// Media chunk bucket for the Nostr (out-of-BLE-range) path. The LARGEST
    /// PayloadBucket tier: ~4x fewer gift wraps than the 4096 BLE bucket (a
    /// 460 KB photo goes 114 -> 29), which both dodges relay rate-limiting on a
    /// burst and shrinks the same-#p wrap cluster a relay observer sees
    /// (THREAT_MODEL §7). Still Nostr-safe: a 16384-byte chunk wraps to ~22 KB
    /// base64, well under NIP-44's 65535-byte plaintext limit across seal + wrap.
    /// The receiver reassembles from the manifest's chunkCount, so a different
    /// bucket than its own local chunker is fine (MediaReassembler is bucket-
    /// agnostic on the receive side).
    private static let mediaBucketNostr = 16384
    /// Open-loop pacing between successive gift-wrap publishes on the Nostr media
    /// path. `NostrTransport.publish` is fire-and-forget (the relay's OK is async
    /// and only logged), so this can't close the loop on acceptance — it just
    /// spaces the burst so a relay's rate limiter (damus rejected a 100+ wrap
    /// unpaced burst) isn't tripped. ~120 ms ≈ 8 wraps/s → a 29-wrap photo ≈ 3.5 s.
    /// Tune against real relays.
    private static let nostrMediaPacingMillis = 120
    
    /// Collects inbound media chunks until a transfer is whole + verified.
    /// Actor-isolated, so its buffers are race-free. Initialized in `init`
    /// (4096/1 are known-valid, so the chunker can't fail — validated constant).
    private var reassembler: MediaReassembler
    
    /// Links we've already greeted with our bundle (don't re-send each tick).
    private var greetedLinks: Set<UUID> = []
    
    /// Peers (by RAW 32-byte key) we've already sent our Nostr-identity
    /// announcement to this session — so the npub-bootstrap fires at most once
    /// per peer. RAM-only by design: a relaunch clears it, so we re-announce on
    /// the next conversation, which the receiver harmlessly no-ops (last-write-
    /// wins). That re-announce is the self-healing path if a prior one was lost.
    private var announcedNostrTo: Set<Data> = []
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

    /// The last set of reachable VERIFIED peer keys we emitted. Diffed on each
    /// BLE reachability change (`onReachable`) to detect peers that just DROPPED,
    /// so their in-flight sends can be handed to Nostr immediately (the BLE→
    /// internet handoff). Updated by `emitReachablePeers`.
    private var lastReachableKeys: Set<Data> = []
    
    // MARK: Reconnect (Closed-Contact 5d) — injected, no-op until enabled
    //
    // The reconnection auth handshake (RECONNECT_AUTH_WIRING_5d.md). Disabled by
    // default: every reconnect path below early-returns until `enableReconnect`
    // injects our agreement key + the paired identities, so a build that never
    // calls it behaves exactly as the pre-5d coordinator (coexistence-safe).
    
    /// 15-minute epoch buckets; ±1 skew (BeaconRecognizer default) tolerates up
    /// to ~30 min of inter-device clock drift. Bumping this is a wire change.
    private static let reconnectEpochLength: UInt64 = 900
    /// Inner discriminators carried in the 0x03 reconnect frame's first byte
    /// (knob A — kept ABOVE the transport so it stays a dumb Ethertype).
    private static let reconnectBeaconSet: UInt8 = 0x00
    private static let reconnectItsMe: UInt8 = 0x01
    
    private var reconnectEnabled = false
    /// Our X25519 identity-agreement private key (drives every S_AC). The store
    /// holds only the bridged libsignal identity, not this raw scalar, so it is
    /// injected. nil until `enableReconnect`.
    private var reconnectAgreementPrivate: Curve25519.KeyAgreement.PrivateKey?
    /// The paired raw 32-byte identities (`ContactAllowlist.identities`). Re-inject
    /// via `enableReconnect` if the allowlist changes (step-7 enrollment concern).
    private var reconnectAllowlistIdentities: [Data] = []
    /// STEP 7f (STRICT-VERIFIED) — the subset of paired identities that are also
    /// VERIFIED (the 4-word SAS confirmed, or a QR pair). This — NOT the enrolled
    /// set above — is what the ADMISSION + PRESENCE gates test: an enrolled-but-
    /// unverified contact is dropped from presence (`emitReachablePeers`), reconnect
    /// admission (`onReconnectItsMe`), and inbound user content (`receive`) until
    /// BOTH sides finish the SAS. Seeded at startup — before transports start — by
    /// `enableReconnect`, and kept live by `addVerifiedContact`/`removeVerifiedContact`.
    ///
    /// A `Set` (not the `[Data]` the enrolled side uses) for O(1) `contains` on the
    /// inbound hot path. The RECOGNIZER / BEACON math deliberately STAYS on the
    /// enrolled set (`reconnectAllowlistIdentities`): flipping it would change wire
    /// emission/recognition and break the reconnect KAT. An unverified peer's it's-me
    /// is instead dropped at the `onReconnectItsMe` gate, so recognizing them costs
    /// nothing and needs no KAT change.
    private var verifiedIdentities: Set<Data> = []
    /// Injectable clock (seconds since Unix epoch) — wall-time in production, a
    /// fixed value in tests so epoch bucketing is deterministic.
    private var reconnectNow: @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970) }
    /// Cached recognizer contacts (identity + S_AC). Epoch-INDEPENDENT — the
    /// epoch is applied at `recognize` time — so this is rebuilt only when the
    /// allowlist changes (or each emission, cheaply), not per epoch.
    private var reconnectRecognizerContacts: [BeaconRecognizer.Contact] = []
    
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
    
    /// Wire the invite-echo redeemer in (STEP 7c-2). Called once by the
    /// composition root alongside `setRouter`. Weak — no retain cycle.
    func setInviteRedeemer(_ redeemer: InviteRedeeming) {
        self.inviteRedeemer = redeemer
    }
    
    /// Inject our Nostr public key (Phase 8d npub-bootstrap). Called once by the
    /// composition root after it load-or-creates the device's NostrIdentity,
    /// alongside `setRouter`. A nil key (no Nostr identity) leaves the announce
    /// path a silent no-op.
    func setNostrPublicKey(_ key: Data?) {
        self.ourNostrPublicKey = key
    }
    
    /// Enable the closed-contact reconnection handshake (5d). Called once by the
    /// composition root at startup, AFTER `store.warmInboundSessions(for:)` has
    /// warmed the trial-decrypt cache from the same allowlist (Invariant #1), so
    /// an inbound it's-me can open. Injects our agreement private key, the paired
    /// identities, and a clock. Eagerly builds the recognizer cache so a beacon
    /// that arrives before our first `onReachable` emission can still be matched.
    ///
    /// STEP 7f (STRICT-VERIFIED): `verifiedIdentities` is the VERIFIED subset of
    /// `allowlistIdentities` and MUST be seeded here — before transports start —
    /// exactly like the enrolled set, or verified contacts are dropped from the
    /// admission/presence gates on relaunch and the mesh darkens. No default: the
    /// composition root is required to supply it, so an empty seed can't slip in
    /// silently.
    func enableReconnect(agreementPrivate: Curve25519.KeyAgreement.PrivateKey,
                         allowlistIdentities: [Data],
                         verifiedIdentities: [Data],
                         now: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970) }) {
        self.reconnectAgreementPrivate = agreementPrivate
        self.reconnectAllowlistIdentities = allowlistIdentities
        self.verifiedIdentities = Set(verifiedIdentities)
        self.reconnectNow = now
        self.reconnectEnabled = true
        refreshRecognizerCache()
    }
    
    // MARK: Reachability → send reconnect beacons to new links + publish presence

    func onReachable(_ ids: [UUID]) async {
        let current = Set(ids)
        reachableLinks = current
        greetedLinks.formIntersection(current)   // drop links that went away
        for link in current where !greetedLinks.contains(link) {
            greetedLinks.insert(link)
            // Reconnect beacons only. The over-RF prekey-bundle greet is GONE
            // (identity-off-RF invariant): enrolled contacts bootstrap a session
            // via the QR/invite payload or a self-identifying prekey message, and
            // maintain it via warmInboundSessions + the 0x03 it's-me handshake — so
            // nothing enrolled needs a bundle over BLE. Greeting every connector
            // leaked our long-term identity key to any unauthenticated peer that
            // linked (and handed strangers the bundle to forge a prekey message).
            await sendReconnectBeacons(to: link)
        }
        // BLE→internet handoff. Capture who was reachable BEFORE we recompute, so
        // a peer that just dropped out of range (or whose Bluetooth went off — the
        // BLE transport tears the dead link down on a failed write) can have its
        // in-flight text handed to Nostr IMMEDIATELY, not after a 45s timeout.
        let before = lastReachableKeys
        let now = emitReachablePeers()
        let departed = before.subtracting(now)
        if !departed.isEmpty, let router {
            let n = await router.rerouteToNostr(departed: departed)
            if n > 0 {
                print("first-contact: BLE dropped — rerouted \(n) in-flight msg(s) → Nostr")
            }
        }
    }
    
    /// Publish the set of RAW 32-byte keys currently reachable: every live link
    /// that we've resolved to an identity, mapped to its raw key and de-duped by
    /// the `Set`. The de-dup is what collapses the per-role double-count — both
    /// GATT directions of one peer map to the same identity, hence one key.
    @discardableResult
    private func emitReachablePeers() -> Set<Data> {
        var keys = Set<Data>()
        for link in reachableLinks {
            if let peer = linkPeers[link] {
                let raw = store.rawPublicKey(of: peer)
                // STEP 7f (STRICT-VERIFIED) — only VERIFIED contacts surface as
                // "near". Enrolled-but-unverified is hidden from presence until BOTH
                // sides finish the 4-word SAS (was `reconnectAllowlistIdentities` at
                // 7e; tightened to the verified subset here).
                if verifiedIdentities.contains(raw) {
                    keys.insert(raw)
                }
            }
        }
        lastReachableKeys = keys
        reachablePeersContinuation.yield(keys)
        print("first-contact: presence → \(keys.count) reachable peer(s)")
        return keys
    }
    
    // MARK: Inbound bundle → maybe initiate

    /// Outcome of processing one inbound bundle. Pairing call sites BRANCH on
    /// this — a dropped or failed bundle must roll back its enrollment — while
    /// the BLE feed discards it. `.responder` is a SUCCESS, not a failure: the
    /// tie-break gave the peer the initiator role and our session forms on
    /// their first message.
    enum BundleOutcome: Sendable {
        case initiated           // we held the higher key; session established now
        case responder           // peer initiates; session forms on their first message
        case malformed           // bundle didn't parse
        case droppedUnenrolled   // the 7e closed-contact gate refused it
        case initiateFailed      // establishSession threw
    }

    @discardableResult
    func onBundle(link: UUID, data: Data) async -> BundleOutcome {
        let bundle = PrekeyBundle(data: data)
        guard let peer = try? store.peerIdentity(from: bundle) else {
            print("first-contact: malformed bundle on link \(link)")
            return .malformed
        }
        // STEP 7e/7f — CLOSED-CONTACT GATE. This gate DELIBERATELY stays on the
        // ENROLLED set (not the verified subset). A bundle from anyone we have not
        // deliberately paired with is dropped before any session work or presence:
        // strangers never get in over RF. (QR/invite enroll BEFORE this, so a
        // freshly-paired contact is already in the live enrolled set.)
        //
        // 7f FLIP POINT: keeping #1 on ENROLLED is what keeps `linkPeers[link]` warm
        // for an enrolled-but-unverified peer, so the moment they finish the SAS,
        // `addVerifiedContact → emitReachablePeers` flips their presence LIVE. No
        // leak: presence is verified-gated in `emitReachablePeers`, reconnect
        // admission in `onReconnectItsMe`, inbound user content in `receive`, and
        // outbound at the composer + inbox backstop. To make strict mode drop the
        // bundle too (at the cost of a deferred presence flip on verify), change
        // `reconnectAllowlistIdentities` → `verifiedIdentities` on the guard below.
        let rawKey = store.rawPublicKey(of: peer)
        guard reconnectAllowlistIdentities.contains(rawKey) else {
            RedactLog.event("first-contact: DROP unenrolled bundle", "from \(peer.userIDHex.prefix(16))…")
            return .droppedUnenrolled
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
            return await initiate(with: bundle, peer: peer) ? .initiated : .initiateFailed
        } else {
            RedactLog.event("first-contact: responder role — session forms on first message", "\(peer.userIDHex.prefix(16))…")
            return .responder
        }
    }

    /// Returns whether the session was established.
    private func initiate(with bundle: PrekeyBundle, peer: PublicIdentity) async -> Bool {
        do {
            // Establish the outgoing session from the peer's bundle. We do NOT
            // auto-send anything here any more — the composer drives the first
            // real message (step 4). Establishing makes the peer real on OUR
            // side now; the responder's side becomes real when our first typed
            // message reaches them.
            _ = try store.establishSession(from: bundle)
            let rawKey = store.rawPublicKey(of: peer)
            eventsContinuation.yield(.established(peerKey: rawKey))
            RedactLog.event("first-contact: INITIATED session", "with \(peer.userIDHex.prefix(16))…")
            return true
        } catch {
            RedactLog.event("first-contact: initiate failed", "\(type(of: error))")
            return false
        }
    }

    // MARK: Remote invite redeem (STEP 7d-3)

    /// Redeem a REMOTE invite: establish a session from the initiator's bundle and
    /// seal the invite-echo back, so THEY burn the single-use id and enroll us.
    ///
    /// Unlike `onBundle` there is NO higher-key tie-break — the initiator is
    /// remote/offline, so we are always the X3DH initiator, and the sealed echo
    /// doubles as the first message that forms the initiator\'s responder session.
    /// The echo carries `nostrRecipient` so it reaches a far initiator over Nostr
    /// (BLE won\'t reach). The initiator\'s existing `.inviteEcho` receive path
    /// (see `receive`) then consumes the id via `inviteRedeemer.redeemEcho` and
    /// enrolls us. Emits `.established`; returns the peer\'s raw key so the caller
    /// enrolls them UNVERIFIED (the 4-word SAS is the MITM defense, not this).
    func redeemInvite(bundle: PrekeyBundle,
                      inviteID: Data,
                      nostrRecipient: Data?) async throws -> Data {
        let peer = try store.peerIdentity(from: bundle)
        let rawKey = store.rawPublicKey(of: peer)

        // Always establish (no tie-break) — we hold their bundle from the invite.
        let session = try store.establishSession(from: bundle)
        // NOTE: we do NOT add to the reconnect/gate set here — the caller
        // (PairingService.redeemInvite) enrolls right after, which calls
        // addReconnectContact. That keeps enrollment the single source of truth
        // for the 7e gate. Presence for this peer surfaces once enrolled.
        emitReachablePeers()

        // Seal the echo and route it (Nostr-capable) back to the initiator.
        // V2 when we have a Nostr identity: the echo carries OUR npub so the
        // MINTER learns our relay address at echo-receipt — a pure-Nostr pair
        // has no BLE rail for the lazy announce, so without this the minter
        // could never send to us over the relay. V1 (id-only) when we have
        // none; the minter's V1 path then behaves exactly as before.
        let payload: MessagePayload
        if let ourNpub = ourNostrPublicKey, ourNpub.count == 32 {
            payload = MessagePayload.inviteEchoV2(inviteID: inviteID,
                                                  redeemerNostrPubkey: ourNpub)
        } else {
            payload = MessagePayload.inviteEchoV1(inviteID: inviteID)
        }
        let sealed = try session.seal(payload.sealedPlaintext())
        try await routeOut(Envelope(ciphertext: sealed),
                           tracked: false,
                           nostrRecipient: nostrRecipient)

        eventsContinuation.yield(.established(peerKey: rawKey))
        // Persist the MINTER's npub from the invite payload (threaded in as
        // `nostrRecipient`) so this peer is Nostr-addressable from the FIRST
        // send — same event the announce path uses, and the inbox handler's
        // same-key no-op / last-wins semantics make a re-redeem converge.
        if let nostrRecipient, nostrRecipient.count == 32 {
            eventsContinuation.yield(
                .learnedNostrIdentity(peerKey: rawKey, nostrPubkey: nostrRecipient))
        }
        RedactLog.event("first-contact: REDEEMED invite → echo sent", "to \(peer.userIDHex.prefix(16))…")
        return rawKey
    }

    /// QR npub parity (CONTACT_MODEL §6): persist a proximity-authenticated
    /// npub carried by a scanned PairingPayload — the SAME event the invite
    /// redeem above yields, so MessageInbox lands it on the Peer row and the
    /// contact is Nostr-addressable from the first send. Strict 32-byte gate
    /// mirrors that path; anything else is dropped, not an error.
    func learnNostrIdentity(peerKey: Data, nostrPubkey: Data) {
        guard nostrPubkey.count == 32 else { return }
        eventsContinuation.yield(
            .learnedNostrIdentity(peerKey: peerKey, nostrPubkey: nostrPubkey))
    }

    /// Shared V1/V2 invite-echo handling on the MINTER (see `receive`): burn the
    /// id, then — gated — surface the redeemer as a contact. `redeemerNostrPubkey`
    /// is non-nil only for a V2 echo, already strict-length-validated by
    /// `parseInviteEchoV2`.
    private func redeemInviteEcho(inviteID: Data, redeemerNostrPubkey: Data?,
                                  peer: PublicIdentity, rawKey: Data) async {
        do {
            let redeemed = try await inviteRedeemer?.redeemEcho(
                inviteID: inviteID, redeemerIdentity: rawKey) ?? false
            RedactLog.event("first-contact: invite-echo \(redeemed ? "REDEEMED" : "ignored")", "from \(peer.userIDHex.prefix(16))…")
            // MINTER-SIDE COMPLETION: make the redeemer a Peer/Conversation
            // row, exactly as the redeemer's own `redeemInvite` does for us
            // (same `.established` event → MessageInbox.handleEstablished,
            // whose fetch-or-create converges a re-fired echo to ONE row).
            // GATED, unlike the redeemer side: invite ids are attacker-
            // choosable bytes and this arm is deliberately outside the 7f
            // verified gate, so an unconditional yield would let any
            // session-holder conjure a contact row with a garbage echo.
            // Admit only a fresh burn (redeemed) OR an identity already in
            // the enrolled set — the legitimate-echo-replayed case (the id
            // is burned, single-use, but the contact is real), which is
            // what makes reprocessing idempotent. Do NOT "repair" by
            // re-running enroll here: outside the burn gate a re-enroll
            // would DOWNGRADE an SAS-verified contact to unverified
            // (ContactAllowlist.enroll replaces the record).
            if redeemed || reconnectAllowlistIdentities.contains(rawKey) {
                eventsContinuation.yield(.established(peerKey: rawKey))
                // V2: persist the REDEEMER's npub under the SAME gate — echo
                // bytes are attacker-choosable, so nothing persists for a
                // garbage echo. This is the minter's half of the pure-Nostr
                // npub-bootstrap; the redeemer's half rides `redeemInvite`.
                if let redeemerNostrPubkey {
                    eventsContinuation.yield(
                        .learnedNostrIdentity(peerKey: rawKey,
                                              nostrPubkey: redeemerNostrPubkey))
                }
            }
        } catch {
            RedactLog.event("first-contact: invite-echo redeem failed", "\(type(of: error))")
        }
    }
    
    // MARK: Reconnect handshake (Closed-Contact)

    /// PUBLIC enrollment entry (STEP 7c-1). The EnrollmentService calls this after
    /// a successful enroll + persist so a newly-paired contact reconnects — and is
    /// ADMITTED by the 7e gate — immediately, without waiting for a relaunch.
    func addReconnectContact(rawIdentity: Data) {
        guard reconnectEnabled, rawIdentity.count == 32 else { return }
        guard !reconnectAllowlistIdentities.contains(rawIdentity) else { return }
        reconnectAllowlistIdentities.append(rawIdentity)
        refreshRecognizerCache()
        print("first-contact: reconnect contact added via enrollment (\(reconnectAllowlistIdentities.count) total)")
    }

    /// PUBLIC revoke entry (STEP 7e). EnrollmentService.revoke calls this after it
    /// persists the removal, so a revoked contact is dropped from the LIVE gate
    /// immediately — no longer admitted, no longer present — rather than only
    /// after a relaunch. Symmetric to `addReconnectContact`.
    func removeReconnectContact(rawIdentity: Data) {
        let before = reconnectAllowlistIdentities.count
        reconnectAllowlistIdentities.removeAll { $0 == rawIdentity }
        guard reconnectAllowlistIdentities.count != before else { return }
        // Drop any live presence for the now-revoked identity, then republish.
        for (link, peer) in linkPeers where store.rawPublicKey(of: peer) == rawIdentity {
            linkPeers[link] = nil
        }
        refreshRecognizerCache()
        emitReachablePeers()
        print("first-contact: reconnect contact revoked (\(reconnectAllowlistIdentities.count) total)")
    }

    /// PUBLIC verified-promotion entry (STEP 7f). `EnrollmentService.markVerified`
    /// calls this after it persists + adopts the verified flag, so a just-verified
    /// pair can message + appear present IMMEDIATELY, without a relaunch. Mirrors
    /// `addReconnectContact`. Re-emits presence: because gate #1 (`onBundle`) stays
    /// on the enrolled set, an enrolled-but-unverified peer is already mapped in
    /// `linkPeers`, so promoting them here flips their presence on the spot.
    func addVerifiedContact(rawIdentity: Data) {
        guard reconnectEnabled, rawIdentity.count == 32 else { return }
        guard !verifiedIdentities.contains(rawIdentity) else { return }
        verifiedIdentities.insert(rawIdentity)
        emitReachablePeers()
        print("first-contact: verified contact added via enrollment (\(verifiedIdentities.count) verified)")
    }

    /// PUBLIC verified-revoke entry (STEP 7f). `EnrollmentService.revoke` calls this
    /// alongside `removeReconnectContact`, so a revoked contact drops from the
    /// admission/presence gates immediately. Symmetric to `addVerifiedContact`;
    /// `removeReconnectContact` already tore down this identity's `linkPeers` +
    /// presence, so here we only forget the verified flag and republish defensively.
    func removeVerifiedContact(rawIdentity: Data) {
        guard verifiedIdentities.remove(rawIdentity) != nil else { return }
        emitReachablePeers()
        print("first-contact: verified contact revoked (\(verifiedIdentities.count) verified)")
    }

    /// Current epoch from the injected clock.
    private func currentEpoch() -> UInt64 {
        ReconnectBeacon.epoch(at: reconnectNow(), epochLength: Self.reconnectEpochLength)
    }
    
    /// Rebuild the cached recognizer contacts (identity + S_AC) from the paired
    /// identities. Epoch-independent; a throwaway emission set is discarded. Best
    /// effort — a malformed contact key throws inside the builder and leaves the
    /// cache empty rather than crashing the actor.
    private func refreshRecognizerCache() {
        guard reconnectEnabled, let priv = reconnectAgreementPrivate else {
            reconnectRecognizerContacts = []
            return
        }
        var rng = SystemRandomNumberGenerator()
        let ourIdentity = store.rawPublicKey(of: store.localIdentity)
        if let plan = try? ReconnectEpochBuilder.plan(
            ourAgreementPrivate: priv, ourIdentity: ourIdentity,
            contacts: reconnectAllowlistIdentities, epoch: currentEpoch(), using: &rng) {
            reconnectRecognizerContacts = plan.recognizerContacts
        }
    }
    
    /// Phase 1: blast our decoy-padded emission set to a new link (0x00 frame).
    /// Reuses the `greetedLinks` once-per-link gate via `onReachable`. Also
    /// refreshes the recognizer cache for the current epoch.
    private func sendReconnectBeacons(to link: UUID) async {
        guard reconnectEnabled, let priv = reconnectAgreementPrivate else { return }
        let ourIdentity = store.rawPublicKey(of: store.localIdentity)
        do {
            var rng = SystemRandomNumberGenerator()
            let plan = try ReconnectEpochBuilder.plan(
                ourAgreementPrivate: priv, ourIdentity: ourIdentity,
                contacts: reconnectAllowlistIdentities, epoch: currentEpoch(), using: &rng)
            reconnectRecognizerContacts = plan.recognizerContacts   // refresh (epoch-independent)
            let frame = Self.reconnectFrame(Self.reconnectBeaconSet,
                                            Self.encodeEmissionSet(plan.emissionSet))
            try await transport.sendReconnect(frame, toLink: link)
            print("first-contact: sent reconnect beacons (\(plan.emissionSet.count)) → link \(link)")
        } catch {
            print("first-contact: reconnect beacon send to \(link) failed: \(type(of: error))")
        }
    }
    
    /// The single 0x03-frame entry point the composition root feeds from
    /// `transport.reconnects`. Owns the 1-byte inner discriminator (knob A): the
    /// transport stays a dumb Ethertype; beacon-vs-auth is resolved here.
    func onReconnectFrame(link: UUID, data: Data) async {
        guard reconnectEnabled else { return }
        guard let discriminator = data.first else { return }
        let payload = Data(data.dropFirst())
        switch discriminator {
        case Self.reconnectBeaconSet:
            await onReconnectBeacon(link: link, emissionSetData: payload)
        case Self.reconnectItsMe:
            await onReconnectItsMe(link: link, ciphertext: payload)
        default:
            print("first-contact: unknown reconnect discriminator \(discriminator) on link \(link)")
        }
    }
    
    /// Phase 2 (recognize): which paired contact, if any, is in the observed set.
    /// A match is a HINT ONLY (Invariant #2) — we answer with a sealed it's-me
    /// but admit NOTHING here. Admission happens when the PEER opens our it's-me;
    /// our own presence flips only when WE open theirs (`onReconnectItsMe`).
    private func onReconnectBeacon(link: UUID, emissionSetData: Data) async {
        guard let set = Self.decodeEmissionSet(emissionSetData) else {
            print("first-contact: malformed reconnect emission set on link \(link)")
            return
        }
        let present = BeaconRecognizer.recognize(
            emissionSet: set, contacts: reconnectRecognizerContacts,
            epoch: currentEpoch(), skew: 1)
        for identity in present {
            await sendItsMe(toContact: identity, link: link)
        }
    }
    
    /// Seal a `reconnectHello` under the recognized contact's existing session
    /// and send it link-local (0x01 frame). 9b pads it to the 256 bucket, so it
    /// is byte-indistinguishable from any short `.whisper`.
    private func sendItsMe(toContact identity: Data, link: UUID) async {
        do {
            let peer = store.peerIdentity(fromRawKey: identity)
            let session = try store.session(with: peer)
            let sealed = try session.seal(MessagePayload.reconnectHelloV1().sealedPlaintext())
            let frame = Self.reconnectFrame(Self.reconnectItsMe, sealed)
            try await transport.sendReconnect(frame, toLink: link)
            RedactLog.event("first-contact: sent reconnect it's-me", "link \(link) · \(peer.userIDHex.prefix(16))…")
        } catch {
            RedactLog.event("first-contact: it's-me seal/send failed", "link \(link) · \(type(of: error))")
        }
    }
    
    /// Phase 2 (authenticate): open the peer's sealed it's-me. This is the ONLY
    /// place a reconnect flips presence (Invariant #2). `openInbound` trial-opens
    /// against the warmed session cache (Invariant #1); a stranger holds no
    /// session and a replay's message key is already spent, so both throw out
    /// here and admit nothing.
    private func onReconnectItsMe(link: UUID, ciphertext: Data) async {
        do {
            let (peer, plaintext) = try store.openInbound(ciphertext)
            // STEP 7f (STRICT-VERIFIED) — admission gate. openInbound already trial-
            // opens only the warmed (enrolled) session cache, so a stranger throws
            // out above; here we further require the peer be VERIFIED, so an
            // enrolled-but-unverified reconnect flips NO presence and is not admitted
            // until the SAS is done (was `reconnectAllowlistIdentities` at 7e).
            guard verifiedIdentities.contains(store.rawPublicKey(of: peer)) else {
                RedactLog.event("first-contact: DROP reconnect from unverified", "\(peer.userIDHex.prefix(16))…")
                return
            }
            guard let payload = MessagePayload.decodeSealed(plaintext),
                  case .reconnectHello = payload else {
                print("first-contact: reconnect it's-me opened but not a hello on link \(link)")
                return
            }
            // AUTHENTICATED admission — set presence here and nowhere else on the
            // reconnect path. The peer is already known from pairing, so we do not
            // re-emit `.established`; we only flip reachability (§2.4).
            linkPeers[link] = peer
            emitReachablePeers()
            // A reconnect is exactly where an in-flight message's delivery ack is
            // most likely delayed by link churn. Tell the persistence layer this
            // peer just reconnected so it can hold that peer's auto-retry briefly
            // and extend its live delivery timeouts (A / STEP 0b) — per-peer.
            eventsContinuation.yield(.reconnected(peerKey: store.rawPublicKey(of: peer)))
            RedactLog.event("first-contact: reconnect ADMITTED", "link \(link) · \(peer.userIDHex.prefix(16))…")
        } catch {
            // Stranger / replay / undecodable: admit nothing. Quiet by design.
            RedactLog.event("first-contact: reconnect it's-me did not open", "link \(link) · \(type(of: error))")
        }
    }
    
    // MARK: Reconnect wire framing (coordinator-owned; transport carries opaque bytes)
    
    /// `[discriminator] ‖ payload` — the inner framing inside the 0x03 frame.
    private static func reconnectFrame(_ discriminator: UInt8, _ payload: Data) -> Data {
        var d = Data([discriminator])
        d.append(payload)
        return d
    }
    
    /// Concatenate the fixed-size emission set (64 × 16-byte tokens) into the
    /// beacon-set payload. No length prefixes: every token is exactly
    /// `ReconnectBeacon.tokenLength`, so the receiver splits on that boundary.
    private static func encodeEmissionSet(_ set: [Data]) -> Data {
        var d = Data(capacity: set.count * ReconnectBeacon.tokenLength)
        for token in set { d.append(token) }
        return d
    }
    
    /// Inverse of `encodeEmissionSet`: split into `tokenLength`-byte tokens.
    /// Returns nil if the payload is not a whole multiple of the token length
    /// (malformed) — the caller ignores it. Empty in → empty set (matches nothing).
    private static func decodeEmissionSet(_ data: Data) -> [Data]? {
        let n = ReconnectBeacon.tokenLength
        guard data.count % n == 0 else { return nil }
        var out: [Data] = []
        out.reserveCapacity(data.count / n)
        var i = data.startIndex
        while i < data.endIndex {
            let j = data.index(i, offsetBy: n)
            out.append(Data(data[i..<j]))
            i = j
        }
        return out
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
    private func routeOut(_ envelope: Envelope,
                          tracked: Bool = true,
                          peerKey: Data? = nil,
                          nostrRecipient: Data? = nil) async throws {
        guard let router else { throw TransportError.notStarted }
        let state = await router.send(envelope, tracked: tracked,
                                      peerKey: peerKey, nostrRecipient: nostrRecipient)
        // Both .sent (BLE radio handoff) and .cast (committed to a Nostr relay)
        // are successful commits to a transport. Only .waitingForRange /
        // .notDelivered mean nothing got out — those throw so the caller's
        // optimistic row is marked .notDelivered.
        guard state == .sent || state == .cast else { throw TransportError.sendFailed }
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
    func send(_ text: String, toRawKey rawKey: Data, nostrRecipient: Data? = nil,
              reuseID: MessageID? = nil) async throws -> MessageID {
        let peer = store.peerIdentity(fromRawKey: rawKey)
        let session = try store.session(with: peer)
        // npub-bootstrap: ensure this peer learns our Nostr id once we converse
        // (once-per-peer, best-effort, before the message itself).
        await announceNostrIdentity(to: peer, rawKey: rawKey)
        // Tag the plaintext as text so the receiver can tell it apart from a
        // media manifest/chunk (which now share this same sealed path). 9b:
        // sealedPlaintext() pads text to a fixed bucket so length doesn't leak.
        let sealed = try session.seal(MessagePayload.text(Data(text.utf8)).sealedPlaintext())
        // B2 (idempotency backstop): on a RESEND the caller passes the wireID this
        // row was already sent under, so the re-sealed envelope carries the SAME
        // cleartext id and the receiver's dedup drops it. On a first send reuseID
        // is nil → a fresh random id, exactly as before.
        let envelope = Envelope(id: reuseID ?? .random(), ciphertext: sealed)
        // tracked: a real message earns a receipt. nostrRecipient enables the
        // router's Tier-2 fallback (BLE → Nostr) when BLE is out of range;
        // peerKey lets a BLE-drop reroute find this message and hand it to Nostr
        // instantly (rather than after the stuck-send timeout).
        try await routeOut(envelope, peerKey: rawKey, nostrRecipient: nostrRecipient)
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
    ///
    /// RE-DRIVE (ISSUE-3b): pass `redrive: true` to re-send a transfer that
    /// STARTED on BLE (peer was verified-reachable at first send → committed to
    /// the 4096 BLE burst) but lost the link mid-burst. A re-drive (a) FORCES the
    /// internet path — BLE already failed us, so we don't retry it — and (b) keeps
    /// the ORIGINAL 4096 BLE chunking rather than the 16384 Nostr cold-send bucket.
    /// (b) is the correctness crux: the receiver already holds a PARTIAL 4096
    /// buffer for this mediaID (manifest + the chunks that landed before teardown),
    /// and the flapping link may yet deliver more 4096 chunks. Re-chunking the same
    /// mediaID at 16384 would mix chunk sizes under one manifest → wrong-length
    /// reassembly → SHA-256 fail → a transfer that never completes. Re-driving at
    /// the SAME 4096 bucket makes every re-driven chunk BYTE-IDENTICAL to the
    /// partial (and to any late BLE flap chunk), so they all dedup by
    /// (mediaID, index) into exactly ONE transfer that completes once and persists
    /// once (handleReceivedMedia dedups on the mediaID-derived wireID). Pair with
    /// `reuseID:` = the row's existing wireID so the mediaID is preserved.
    ///
    /// STORIES: `sentAt`/`isStory` are stamped verbatim into the manifest
    /// (MediaChunker.split). The caller (MessageInbox) passes the row's
    /// ORIGINAL first-send instant on a resend/re-drive, so a retry re-stamps
    /// the same expiry anchor — the 8h window can never be extended by
    /// retrying. Both default off: every non-story call site is unchanged.
    func sendMedia(_ blob: Data, mime: MediaMimeType, toRawKey rawKey: Data,
                   nostrRecipient: Data? = nil,
                   reuseID: MessageID? = nil,
                   redrive: Bool = false,
                   sentAt: Date? = nil,
                   isStory: Bool = false,
                   isPushToTalk: Bool = false) async throws -> MessageID {
        let peer = store.peerIdentity(fromRawKey: rawKey)
        let session = try store.session(with: peer)
        // npub-bootstrap: ensure this peer learns our Nostr id once we converse
        // (once-per-peer, best-effort, before the transfer burst).
        await announceNostrIdentity(to: peer, rawKey: rawKey)
        
        // TRANSPORT COMMIT (ISSUE-3): pick ONE transport for the WHOLE transfer up
        // front, rather than relying on the per-envelope BLE-first fallback. Two
        // reasons this must be a per-transfer commit keyed on THIS peer:
        //   • BLE is broadcast-flood, so "BLE has someone in range" is NOT "this
        //     peer is in range". If the intended peer is absent but another contact
        //     is nearby, a per-chunk BLE send SUCCEEDS (floods to the other contact,
        //     who can't open it) and never falls back to Nostr — the transfer
        //     strands. Committing on this peer's verified-reachable state avoids it.
        //   • A transfer that straddles BLE→Nostr per chunk loses the chunks already
        //     handed to CoreBluetooth when a link tears down mid-burst (they return
        //     .sent, the loop moves on), leaving an unfillable index gap. One
        //     transport for the whole burst can't straddle.
        // `lastReachableKeys` is the VERIFIED reachable set (7f) — the same signal
        // the drop-reroute trusts; sendMedia is only reached for a verified peer.
        // (Read, not recompute: emitReachablePeers() would also yield a presence
        // tick as a side effect.)
        //
        // ISSUE-3b: a re-drive ALWAYS goes over the internet (BLE just failed the
        // transfer), so it never takes the BLE branch regardless of live presence.
        let goingOverBLE = redrive ? false : lastReachableKeys.contains(rawKey)

        // Bucket choice:
        //   • BLE branch  → 4096 (its notify path is tuned there; larger GATT
        //                   notifies stress the queue).
        //   • Nostr COLD send → 16384 (largest tier: ~4x fewer, larger wraps).
        //   • Nostr RE-DRIVE  → 4096, to MATCH the BLE-started transfer's chunking
        //                   so the receiver's partial buffer dedups by index (see
        //                   the redrive note above). NOT 16384 — that would mix
        //                   chunk sizes under one mediaID and never reassemble.
        let bucket = (goingOverBLE || redrive) ? Self.mediaBucket : Self.mediaBucketNostr
        let chunker = try MediaChunker(targetBucket: bucket,
                                       reservedBytes: Self.mediaReserved)
        // Use a CSPRNG 16-byte id (a MessageID's bytes) as the mediaID, so the
        // same value is both the transfer key and the dedup / tracking MessageID.
        // B2 (idempotency backstop): on a RESEND the caller passes the wireID this
        // row was already sent under, so the whole re-sent transfer is dedup-
        // identical to the first. On a first send reuseID is nil → fresh random.
        let idBytes = (reuseID ?? .random()).bytes
        let mediaWireID = MessageID(bytes: idBytes)!
        let (manifest, chunks) = try chunker.split(blob, mime: mime, mediaID: idBytes,
                                                   sentAt: sentAt, isStory: isStory,
                                                   isPushToTalk: isPushToTalk)
        
        // Register the transfer for delivery tracking up front, so an ack that
        // races back before the burst finishes still matches.
        await router?.beginTracking(of: mediaWireID)
        
        // BLE branch: today's path — flood each sealed manifest/chunk over the
        // mesh, still carrying nostrRecipient so the router's per-envelope fallback
        // can catch a single chunk that finds no write target. UNTRACKED (the
        // transfer's message-level id is tracked separately, above/below).
        func emitOverBLE(_ payload: MessagePayload) async throws {
            // 9b: media kinds are returned unpadded by sealedPlaintext() (already
            // bucket-shaped by MediaChunker), so this is byte-identical to
            // encoded() for manifests/chunks — routed through the same method so
            // every seal site shares one rule.
            let sealed = try session.seal(payload.sealedPlaintext())
            try await routeOut(Envelope(ciphertext: sealed), tracked: false,
                               nostrRecipient: nostrRecipient)
        }
        
        // Nostr branch: publish each sealed manifest/chunk DIRECTLY over the relay,
        // bypassing the BLE-first path (no straddle, no flood-to-wrong-peer), PACED
        // so the burst doesn't trip a relay's rate limiter. `recipient` is the
        // committed non-nil nostrRecipient. UNTRACKED, same as the BLE branch.
        func emitOverNostr(_ payload: MessagePayload, to recipient: Data) async throws {
            let sealed = try session.seal(payload.sealedPlaintext())
            let state = await router?.publishOverNostr(Envelope(ciphertext: sealed),
                                                       to: recipient)
            // .cast = the wrap was handed to >= 1 live relay (a chunk success),
            // same success meaning as .sent here; only .waitingForRange/nil means
            // no relay took it.
            guard state == .sent || state == .cast else { throw TransportError.sendFailed }
            try? await Task.sleep(for: .milliseconds(Self.nostrMediaPacingMillis))
        }
        
        do {
            let manifestJSON = try JSONEncoder().encode(manifest)
            if goingOverBLE {
                try await emitOverBLE(.mediaManifest(manifestJSON))
                for chunk in chunks {
                    try await emitOverBLE(.mediaChunk(chunk))
                }
            } else if let recipient = nostrRecipient {
                try await emitOverNostr(.mediaManifest(manifestJSON), to: recipient)
                for chunk in chunks {
                    try await emitOverNostr(.mediaChunk(chunk), to: recipient)
                }
            } else {
                // Peer unreachable over BLE and no Nostr address bootstrapped for
                // them — nothing can carry this transfer. Fail it so the inbox marks
                // the row .notDelivered; it flushes once the peer is reachable again
                // or a nostr identity is learned.
                throw TransportError.noReachablePeers
            }
        } catch {
            // The burst broke before completing; fail the tracked transfer so
            // the router cancels any state and the inbox marks the row failed.
            await router?.confirmFailure(of: mediaWireID)
            throw error
        }
        
        // Whole burst is on the radio (BLE) or handed to the relays (Nostr).
        // BLE: arm the (longer) media stuck-send timeout, since a BLE ack should
        // return promptly. Nostr: the peer is out of range and may be offline for
        // hours — there is no bounded ack window, so DON'T arm a timer (it would
        // falsely demote to .notDelivered). Commit the transfer .cast instead; a
        // real ack later surfaces it to .delivered.
        if goingOverBLE {
            await router?.startDeliveryTimeout(for: mediaWireID,
                                               after: MessageRouter.mediaDeliveryTimeout)
        } else {
            await router?.commitToRelay(mediaWireID)
        }
        let via = goingOverBLE ? "BLE" : (redrive ? "Nostr (re-drive)" : "Nostr")
        RedactLog.event("first-contact: SENT media over \(via)", "\(chunks.count) chunks · \(blob.count)B → \(peer.userIDHex.prefix(16))…")
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
            let sealed = try session.seal(payload.sealedPlaintext())
            await router?.send(Envelope(ciphertext: sealed), tracked: false)
        } catch {
            RedactLog.event("first-contact: delivery-ack seal/send failed", "\(type(of: error))")
        }
    }

    /// Seal + route one call-signaling frame to a verified peer (FaceTime v1).
    /// UNTRACKED, like a delivery ack: signaling earns no delivery state and
    /// is never acked — ring timeouts belong to CallController, not the
    /// outbox. Rides the same addressed rail as text (BLE if reachable,
    /// Nostr Tier-2 fallback via `nostrRecipient`); throws if no transport
    /// takes it, so the call layer can end the attempt immediately.
    func sendCallSignal(_ signal: CallSignal, toRawKey rawKey: Data,
                        nostrRecipient: Data? = nil) async throws {
        let peer = store.peerIdentity(fromRawKey: rawKey)
        let session = try store.session(with: peer)
        let sealed = try session.seal(MessagePayload.callSignal(signal).sealedPlaintext())
        try await routeOut(Envelope(ciphertext: sealed), tracked: false,
                           peerKey: rawKey, nostrRecipient: nostrRecipient)
    }

    /// Announce OUR Nostr public key to an established peer over the sealed
    /// channel (Phase 8d npub-bootstrap). Sent UNTRACKED + best-effort, exactly
    /// like a delivery ack: never acked, no delivery state, and a failure simply
    /// means we re-announce on the next conversation/relaunch (the receiver
    /// no-ops a repeat). At most once per peer per session (`announcedNostrTo`),
    /// and a silent no-op if we have no Nostr identity. Fired lazily on the first
    /// REAL message in either direction — never on a bare handshake — so a stable
    /// internet identifier is shared only with peers actually conversed with.
    private func announceNostrIdentity(to peer: PublicIdentity, rawKey: Data) async {
        guard let ourNostrPublicKey else { return }              // no Nostr identity
        guard !announcedNostrTo.contains(rawKey) else { return }  // already told them
        do {
            let session = try store.session(with: peer)
            let payload = MessagePayload.nostrIdentityAnnounce(pubkey: ourNostrPublicKey)
            let sealed = try session.seal(payload.sealedPlaintext())
            await router?.send(Envelope(ciphertext: sealed), tracked: false)
            announcedNostrTo.insert(rawKey)
            RedactLog.event("first-contact: announced our Nostr id", "→ \(peer.userIDHex.prefix(16))…")
        } catch {
            RedactLog.event("first-contact: nostr-id announce failed", "to \(peer.userIDHex.prefix(16))… — \(error)")
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
            
            // npub-bootstrap (responder side): opening this proves our session
            // with the peer is live, so make sure they've learned our Nostr id
            // even if we haven't sent them anything yet. Once-per-peer + best-
            // effort; a no-op for a peer we already announced to (e.g. as the
            // initiator via `send`). Never blocks inbound handling.
            await announceNostrIdentity(to: peer, rawKey: rawKey)
            
            guard let payload = MessagePayload.decodeSealed(plaintext) else {
                RedactLog.event("first-contact: opened but undecodable payload", "from \(peer.userIDHex.prefix(16))…")
                return
            }
            
            switch payload {
            case .text(let body):
                // STEP 7f (STRICT-VERIFIED) — reject inbound USER CONTENT from an
                // unverified contact ("reject at openInbound"). A compliant peer never
                // sends here (their composer is gated + inbox backstop refuses), but a
                // NON-compliant one holds the session from pairing and could seal text
                // to us; drop it, and send NO ack. Housekeeping payloads below
                // (.ack/.nostrIdentity/.inviteEcho/.reconnectHello) are intentionally
                // NOT gated — .inviteEcho in particular MUST stay open, since at
                // echo-open time the redeemer is not yet enrolled (redeemEcho enrolls
                // them). Only .text/.mediaManifest/.mediaChunk are gated.
                guard verifiedIdentities.contains(rawKey) else {
                    RedactLog.event("first-contact: DROP text from unverified", "\(peer.userIDHex.prefix(16))…")
                    return
                }
                eventsContinuation.yield(
                    .received(peerKey: rawKey, plaintext: body, wireID: envelope.id)
                )
                RedactLog.event("first-contact: OPENED text", "from \(peer.userIDHex.prefix(16))…")
                // Acknowledge the text message by its envelope id, with hops.
                await sendDeliveryAck(wireID: envelope.id, hops: hops(of: envelope), to: peer)
                
            case .mediaManifest(let json):
                // 7f: strict-verified inbound gate (see .text). Drop before reassembly.
                guard verifiedIdentities.contains(rawKey) else {
                    RedactLog.event("first-contact: DROP media manifest from unverified", "\(peer.userIDHex.prefix(16))…")
                    return
                }
                guard let manifest = try? JSONDecoder().decode(MediaManifest.self, from: json) else {
                    RedactLog.event("first-contact: bad media manifest", "from \(peer.userIDHex.prefix(16))…")
                    return
                }
                if let done = reassembler.ingest(manifest: manifest),
                   let wireID = emitMedia(done, rawKey: rawKey) {
                    // The transfer completed on the manifest — ack the whole
                    // media by its message-level id, stamped with this leg's hops.
                    await sendDeliveryAck(wireID: wireID, hops: hops(of: envelope), to: peer)
                }
                
            case .mediaChunk(let chunk):
                // 7f: strict-verified inbound gate (see .text). Drop before reassembly.
                guard verifiedIdentities.contains(rawKey) else {
                    RedactLog.event("first-contact: DROP media chunk from unverified", "\(peer.userIDHex.prefix(16))…")
                    return
                }
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
                    RedactLog.event("first-contact: malformed delivery ack", "from \(peer.userIDHex.prefix(16))…")
                    return
                }
                await router?.confirmDelivery(of: wireID, hops: Int(hops))
                RedactLog.event("first-contact: ACK (\(hops) hop(s))", "\(wireID) from \(peer.userIDHex.prefix(16))…")
                
            case .nostrIdentity(let body):
                // A peer announced their raw 32-byte x-only secp256k1 pubkey over
                // the established sealed channel (the npub-bootstrap, LOCKED:
                // never embedded in the PrekeyBundle). Validate strictly on this
                // untrusted path; a malformed body is ignored. We then emit it
                // across the actor→SwiftData boundary like every other write:
                // the main-actor MessageInbox persists it onto the matching Peer
                // row (keyed by `rawKey`), so the router can later address a Nostr
                // gift wrap to this peer when BLE is out of range.
                guard let nostrKey = MessagePayload.parseNostrIdentity(body) else {
                    RedactLog.event("first-contact: malformed nostr-identity", "from \(peer.userIDHex.prefix(16))…")
                    return
                }
                eventsContinuation.yield(
                    .learnedNostrIdentity(peerKey: rawKey, nostrPubkey: nostrKey)
                )
                RedactLog.event("first-contact: NOSTR identity \(nostrKey.count)B", "from \(peer.userIDHex.prefix(16))…")
                
            case .reconnectHello:
                // A reconnect it's-me must NEVER arrive on the envelope /
                // MessageRouter path. It is link-local (the 0x03 reconnect frame)
                // and is opened ONLY by the dedicated onReconnectItsMe handler
                // (RECONNECT_AUTH_WIRING_5d.md §2.1), where admission happens and
                // ONLY there (Invariant #2 — never admit on this relayable path).
                // Reaching here means a misroute or an adversary stuffing a
                // reconnect kind into a 0x01 envelope: ignore it, admit nothing.
                RedactLog.event("first-contact: ignoring reconnectHello on the envelope path (link-local only)", "from \(peer.userIDHex.prefix(16))…")
            case .inviteEcho(let body):
                guard let inviteID = MessagePayload.parseInviteEcho(body) else {
                    RedactLog.event("first-contact: malformed invite-echo", "from \(peer.userIDHex.prefix(16))…")
                    return
                }
                // V1 (id-only): a redeemer with no Nostr identity. Full handling
                // lives in redeemInviteEcho, shared with V2.
                await redeemInviteEcho(inviteID: inviteID, redeemerNostrPubkey: nil,
                                       peer: peer, rawKey: rawKey)

            case .inviteEchoV2(let body):
                guard let parsed = MessagePayload.parseInviteEchoV2(body) else {
                    RedactLog.event("first-contact: malformed invite-echo-v2", "from \(peer.userIDHex.prefix(16))…")
                    return
                }
                // V2: id ‖ redeemer npub — the pure-Nostr npub-bootstrap. The
                // npub persists only behind the same gate as the contact row.
                await redeemInviteEcho(inviteID: parsed.inviteID,
                                       redeemerNostrPubkey: parsed.redeemerNostrPubkey,
                                       peer: peer, rawKey: rawKey)

            case .callRequest(let body):
                // F1 (7f STRICT-VERIFIED): call signaling is user-reaching
                // content — an unverified session-holder must not be able to
                // ring us. Gated exactly like .text; drop silently, no reply.
                guard verifiedIdentities.contains(rawKey) else {
                    RedactLog.event("first-contact: DROP call-request from unverified", "\(peer.userIDHex.prefix(16))…")
                    return
                }
                guard let signal = CallSignal.parseRequestBody(body) else {
                    RedactLog.event("first-contact: malformed call-request", "from \(peer.userIDHex.prefix(16))…")
                    return
                }
                eventsContinuation.yield(.callSignal(peerKey: rawKey, signal: signal))

            case .callAnswer(let body):
                // F1 (7f STRICT-VERIFIED): gated exactly like .callRequest —
                // an answer from an unverified holder is dropped, no reply.
                guard verifiedIdentities.contains(rawKey) else {
                    RedactLog.event("first-contact: DROP call-answer from unverified", "\(peer.userIDHex.prefix(16))…")
                    return
                }
                guard let signal = CallSignal.parseAnswerBody(body) else {
                    RedactLog.event("first-contact: malformed call-answer", "from \(peer.userIDHex.prefix(16))…")
                    return
                }
                eventsContinuation.yield(.callSignal(peerKey: rawKey, signal: signal))

            case .callDecline(let body):
                // F1 (7f STRICT-VERIFIED): gated exactly like .callRequest —
                // a decline from an unverified holder is dropped, no reply.
                guard verifiedIdentities.contains(rawKey) else {
                    RedactLog.event("first-contact: DROP call-decline from unverified", "\(peer.userIDHex.prefix(16))…")
                    return
                }
                guard let signal = CallSignal.parseDeclineBody(body) else {
                    RedactLog.event("first-contact: malformed call-decline", "from \(peer.userIDHex.prefix(16))…")
                    return
                }
                eventsContinuation.yield(.callSignal(peerKey: rawKey, signal: signal))
            }
        } catch {
            RedactLog.event("first-contact: open failed", "\(type(of: error))")
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
            .receivedMedia(peerKey: rawKey, data: done.data, mime: done.mime, wireID: wireID,
                           sentAt: done.sentAt, isStory: done.isStory,
                           isPushToTalk: done.isPushToTalk)
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

// STEP 7c-1 — conformance so EnrollmentService depends on the narrow
// ReconnectEnrolling contract, not the concrete coordinator.
extension FirstContactCoordinator: ReconnectEnrolling {}
