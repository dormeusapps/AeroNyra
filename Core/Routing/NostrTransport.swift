//
//  NostrTransport.swift
//  Core/Routing
//
//  PILLAR 2 — the internet transport (Phase 8d). A second `MeshTransport`
//  conformer that carries the SAME opaque `Envelope` the BLE mesh carries, but
//  over Nostr relays instead of the radio. Inbound gift wraps are unwrapped
//  back into byte-identical Envelopes and surfaced on `incoming`, exactly like
//  BLE — so everything above transport (router → coordinator → SwiftData) is
//  reused unchanged.
//
//  *** LOCKED: NOSTR IS NOT A FLOOD MESH. *** The relays ARE the infrastructure.
//  None of the router's relay()/forwarded()/split-horizon/TTL logic applies
//  here. This transport BYPASSES all of it:
//    • `relay(_:excludingLinks:)` is a deliberate NO-OP.
//    • inbound envelopes carry a synthetic source link (`nostrSourceLink`) only
//      to satisfy the stream's shape; nothing forwards them onward.
//
//  *** ADDRESSED, NOT BROADCAST. *** A Nostr gift wrap is built FOR a specific
//  recipient pubkey (NIP-59: tagged `["p", peerHex]`, encrypted to the peer).
//  The protocol's recipient-blind `send(_:)` therefore cannot build one and
//  THROWS — the router calls the addressed `publish(_:to:)` instead, because the
//  router is the layer that actually knows the conversation's recipient. This is
//  the seam decision (Option B): conform to `MeshTransport` so the router can
//  start/stop us and drain `incoming` polymorphically, but route real DMs
//  through the addressed face.
//
//  *** MULTI-RELAY (availability). *** The transport holds a SET of relays, each
//  its own websocket with its own receive loop and independent reconnect/backoff.
//  A single relay having a bad day (e.g. a 503, as damus did) must NOT kill the
//  internet pillar — that is the whole point of a relay-backed transport.
//    • `publish` FANS OUT to every currently-connected relay; it succeeds if the
//      wrap was handed to AT LEAST ONE live relay, and throws `.notConnected`
//      only when EVERY relay is down. Real acceptance is each relay's async `OK`;
//      end-to-end delivery is the app-level ACK, with the router's stuck-send
//      timeout as the safety net if nothing lands.
//    • Every relay's inbound feeds the SAME `incoming` stream. The router already
//      dedups by envelope id, so the same gift wrap arriving from several relays
//      collapses to a single delivery for free — no extra dedup here.
//  A future user-configurable relay list is a drop-in: swap the injected array.
//
//  CONCURRENCY: not an actor. ALL mutable state (including every per-relay
//  `RelayConn`) is confined to `queue`; the URLSession callbacks hop onto `queue`
//  before touching anything. That is what makes `@unchecked Sendable` honest
//  (same stance as BLEMeshTransport).
//

import Foundation
import Network
import os

// MARK: - Errors

public enum NostrTransportError: Error, Equatable {
    /// The recipient-blind `send(_:)` was called. A gift wrap must be addressed;
    /// callers use `publish(_:to:)` with a resolved peer pubkey instead.
    case sendRequiresRecipient
    /// `publish` was called with no live websocket on ANY relay.
    case notConnected
    /// Wrapping the envelope or serializing the event frame failed.
    case publishFailed
}

// MARK: - NostrTransport

public final class NostrTransport: MeshTransport, AddressedTransport, @unchecked Sendable {

    // MARK: Protocol: identity
    public let kind: TransportKind = .internet

    // MARK: Protocol: inbound envelope stream
    /// Inbound, unwrapped gift wraps from ALL relays, merged. The `link` is a
    /// synthetic constant (`nostrSourceLink`): Nostr has no per-link source and
    /// bypasses relay, so it exists only to match the BLE stream's shape. The
    /// same wrap arriving from multiple relays yields the same envelope id and
    /// collapses in the router's dedup.
    public let incoming: AsyncStream<(link: UUID, envelope: Envelope)>
    private let inboundCont: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation

    // MARK: Injected identity + relays
    private let relayURLs: [URL]
    private let ourSecretKey: Data        // signs wraps; opens inbound (NIP-44)
    private let ourPubkeyHex: String      // for the #p subscription filter

    // MARK: Queue-confined connection state
    private let queue = DispatchQueue(label: "com.aeronyra.nostr.transport")
    /// One connection per relay. Built in `start`, torn down in `stop`. Touched
    /// ONLY on `queue`.
    private var conns: [RelayConn] = []
    private var started = false

    /// ISSUE-5 backlog-replay guard: OUTER 1059 event ids already processed, so a
    /// relay replay (or the same wrap fanned in from several relays) is skipped
    /// BEFORE the schnorr verify + unwrap — killing the `open failed: openFailed`
    /// storm on subscribe. Queue-confined like all mutable state here. SEEDED at
    /// init from the sealed store (survives relaunch) and PERSISTED via
    /// `persistLedger` on a debounce, so a burst coalesces into one sealed write.
    private var processedLedger: ProcessedEventLedger

    /// Persist hook for the ledger (injected; nil = in-memory only, e.g. tests).
    /// Called with a value-type snapshot, DISPATCHED OFF `queue` onto a utility
    /// queue so the sealed file write never blocks the inbound receive loop.
    private let persistLedger: (@Sendable (ProcessedEventLedger) -> Void)?

    /// F2: wraps that failed validation/unwrap this session. RAM-only by design
    /// — see `noteFailedWrapLocked`. Queue-confined.
    private var failedWrapsThisSession: Set<String> = []
    private static let failedWrapsCap = 1024

    /// ACCEPTANCE LEDGER (F1: now ACTING, not just observing). `publish` still
    /// resumes once the frame is handed to >= 1 live socket, but a relay's real
    /// verdict is its later async `OK <eventID> <accepted>`. This registry keys
    /// each published event's id to its envelope + retained frame and counts the
    /// per-relay verdicts. At the deadline (or when all relays answered):
    ///   • >= 1 accept → settled, one info summary (unchanged).
    ///   • ZERO accepts → the silent-strand signature ("the publish lie": a
    ///     half-open socket swallowed the frame, or every relay rejected it).
    ///     The frame is RE-PUBLISHED to the then-live sockets — riding the
    ///     liveness watchdogs' rebuild — up to `maxPublishAttempts`, then the
    ///     failure is surfaced via `onPublishFailed` so a tracked row demotes
    ///     from `.cast` to `.notDelivered` (the sanctioned "real failure ack";
    ///     the .cast no-timer invariant is untouched). Re-publishing the SAME
    ///     frame is safe: the event id is a content hash, so a relay that DID
    ///     take an earlier attempt dedups it.
    /// Queue-confined like all mutable state here; entries self-expire at
    /// `acceptanceSummaryDeadline`, so the map is bounded by publish rate.
    private var pendingAcceptance: [String: PendingAcceptance] = [:]

    private struct PendingAcceptance {
        let eventID: String
        let envelopeID: MessageID
        let frame: String            // retained for the zero-accept re-publish
        let relayCount: Int          // live relays the frame was handed to
        let attempt: Int             // 1-based publish attempt this entry tracks
        var accepted = 0
        var rejected = 0
    }

    /// F1 upward failure signal — fired on `queue` when a publish exhausted its
    /// attempts with ZERO relay accepts. The composition root points this at
    /// `MessageRouter.confirmFailure(of:)`. Untracked envelopes (acks,
    /// announces, echoes) have no outbox row, so for them the bounded
    /// re-publish above is the whole recovery and this fires into a no-op.
    private var onPublishFailed: (@Sendable (MessageID) -> Void)?

    /// F1: wire the zero-accept failure handler. Called once by the composition
    /// root; hops onto `queue` so the property stays queue-confined.
    public func setPublishFailureHandler(_ handler: @escaping @Sendable (MessageID) -> Void) {
        queue.async { [weak self] in self?.onPublishFailed = handler }
    }

    /// How long after a publish we wait for relay OKs before summarizing. OKs
    /// normally land well under a second; anything still silent by now is
    /// counted as such in the summary. Long enough to never truncate a slow
    /// relay's honest verdict, short enough to bound the registry.
    private static let acceptanceSummaryDeadline: Double = 10
    /// F1: total publish attempts (initial + re-publishes) before a zero-accept
    /// publish is surfaced as a real failure. Three attempts spaced
    /// `republishDelay` apart spans ~40s — enough for the ping watchdog
    /// (pong timeout ≈ interval 25-30s + deadline 10s) to have rebuilt a dead
    /// socket under the retry.
    private static let maxPublishAttempts = 3
    private static let republishDelay: Double = 15
    /// Debounce bookkeeping (queue-confined). `dirty` = new ids since last save;
    /// `saveScheduled` = a coalescing save is already pending.
    private var ledgerDirty = false
    private var ledgerSaveScheduled = false
    /// Coalescing window: a storm of first-sight inserts becomes ONE sealed write
    /// this many seconds after the first. A crash inside the window re-processes
    /// at most that window's ids once (bounded, self-healing). Tune vs. traffic.
    private static let ledgerSaveDebounce: Double = 3

    /// Per-relay connection state. A reference type so a socket callback can hold
    /// the exact relay it fired for. `@unchecked Sendable` on the same terms as
    /// the transport: every field is read/written ONLY on `queue`.
    private final class RelayConn: @unchecked Sendable {
        let url: URL
        let subID: String
        var session: URLSession?
        var task: URLSessionWebSocketTask?
        var reconnectAttempts = 0
        /// LIVENESS (FIX 2): bumped on EVERY socket teardown. Async callbacks
        /// (receive loop, ping chain, pong watchdog, delegate events, pending
        /// reconnect timers, REQ retries) capture the generation they were
        /// armed under and no-op if it has moved on — so a stale socket's
        /// callbacks can never kill or double-drive its replacement. Queue-
        /// confined like every field here.
        var generation = 0
        /// Instrumentation + staleness inputs (FIX 2): any parsed frame stamps
        /// `lastInboundAt`; a pong stamps `lastPongAt`. `connectedAt` guards
        /// the scene-active refresh from recycling a socket that simply hasn't
        /// had time to receive anything yet.
        var lastInboundAt = Date.distantPast
        var lastPongAt = Date.distantPast
        var lastPingAt = Date.distantPast
        var connectedAt = Date.distantPast
        /// REQ re-send attempts on THIS socket (reset per connect).
        var reqRetries = 0
        init(url: URL) {
            self.url = url
            self.subID = "aeronyra-\(UUID().uuidString.prefix(8))"
        }
    }

    /// URLSessionWebSocketDelegate bridge (FIX 2): one per socket, retained by
    /// its URLSession until `invalidateAndCancel`. Both callbacks hop onto the
    /// transport's `queue` and are generation-guarded there — the delegate
    /// itself holds no mutable state.
    private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        private weak var transport: NostrTransport?
        private let conn: RelayConn
        private let generation: Int
        init(transport: NostrTransport, conn: RelayConn, generation: Int) {
            self.transport = transport
            self.conn = conn
            self.generation = generation
        }
        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                        didOpenWithProtocol protocol: String?) {
            transport?.socketDidOpen(conn, generation: generation)
        }
        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                        reason: Data?) {
            transport?.socketDidClose(conn, generation: generation,
                                      code: closeCode, reason: reason)
        }
    }

    /// FIX 2: network-path change trigger. TRIGGER ONLY, never liveness proof —
    /// a satisfied path says nothing about individual sockets; it just tells us
    /// a transition happened that idle sockets won't notice on their own.
    private var pathMonitor: NWPathMonitor?
    /// Last seen path signature (status + interface classes), to detect real
    /// transitions (wifi↔cell, regain-after-loss) vs. repeated identical ticks.
    private var lastPathSignature: String?

    // MARK: Constants
    /// Synthetic source link for inbound envelopes (Nostr has no real link, and
    /// nothing relays them onward). Process-stable; never used for split-horizon.
    private static let nostrSourceLink = UUID()
    private static let baseReconnectDelay: Double = 1     // seconds
    private static let maxReconnectDelay: Double = 30     // capped backoff ceiling
    /// FIX 2 ping watchdog. Interval keeps cellular NAT mappings warm (carrier
    /// idle timeouts commonly start ~30s); the jitter de-synchronizes the three
    /// relays' pings. A ping whose pong hasn't landed inside `pongDeadline` is
    /// the half-open-socket signature — reads dead, writes "fine" — and forces
    /// an immediate rebuild. Pings fire only while the process runs; iOS
    /// suspension pauses them, and the scene-active refresh covers the resume.
    private static let pingInterval: Double = 25
    private static let pingJitter: Double = 5
    private static let pongDeadline: Double = 10
    /// Scene-active refresh: a socket with no inbound frame AND no pong in this
    /// long is treated stale and rebuilt; younger-than-10s sockets are left
    /// alone (they haven't had time to prove anything).
    private static let staleAfter: Double = 45
    private static let minSocketAgeForRefresh: Double = 10
    /// FIX 2 REQ retry: a failed subscription send retries this many times per
    /// socket, spaced `reqRetryDelay` apart, instead of log-and-abandon. The
    /// socket-level watchdogs own the truly-dead case.
    private static let maxREQRetries = 5
    private static let reqRetryDelay: Double = 2

    private let log = Logger(subsystem: "com.aeronyra.app", category: "Nostr")

    // MARK: - Init

    /// - Parameters:
    ///   - relayURLs: one or more relay websocket URLs (e.g. `wss://nos.lol`).
    ///     Every relay is connected independently; publish fans out to all and
    ///     inbound from all is merged. A future settings screen swaps this array.
    ///   - ourSecretKey: our 32-byte Nostr secret (signs gift wraps, opens
    ///     inbound NIP-44). From `NostrIdentity.secretKeyBytes`.
    ///   - ourPublicKey: our 32-byte x-only pubkey, used to build the inbound
    ///     subscription filter. From `NostrIdentity.publicKeyBytes`.
    ///   - initialLedger: the ISSUE-5 replay guard seeded from the sealed store at
    ///     launch (empty on first run / a corrupt-load degrade). Defaults empty so
    ///     single-relay callers and tests need not supply it.
    ///   - persistLedger: sealed-store save hook, called with a value snapshot off
    ///     `queue`. nil (default) = in-memory only.
    public init(relayURLs: [URL],
                ourSecretKey: Data,
                ourPublicKey: Data,
                initialLedger: ProcessedEventLedger = ProcessedEventLedger(),
                persistLedger: (@Sendable (ProcessedEventLedger) -> Void)? = nil) {
        self.relayURLs = relayURLs
        self.ourSecretKey = ourSecretKey
        self.ourPubkeyHex = ourPublicKey.map { String(format: "%02x", $0) }.joined()
        self.processedLedger = initialLedger
        self.persistLedger = persistLedger

        var cont: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation!
        self.incoming = AsyncStream<(link: UUID, envelope: Envelope)> { cont = $0 }
        self.inboundCont = cont
    }

    /// Convenience: a single-relay transport. Preserved so existing single-URL
    /// callers (and `NostrRelayRoundTripTests`) compile unchanged.
    public convenience init(relayURL: URL, ourSecretKey: Data, ourPublicKey: Data) {
        self.init(relayURLs: [relayURL], ourSecretKey: ourSecretKey, ourPublicKey: ourPublicKey)
    }

    // MARK: - Protocol: lifecycle

    public func start() async throws {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.conns = self.relayURLs.map { RelayConn(url: $0) }
            for conn in self.conns { self.connectLocked(conn) }
            // FIX 2: path-change trigger. Started on `queue`, so the handler is
            // already inside the confinement — no extra hop.
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                self?.handlePathUpdateLocked(path)
            }
            monitor.start(queue: self.queue)
            self.pathMonitor = monitor
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.started = false
            self.pathMonitor?.cancel()
            self.pathMonitor = nil
            self.lastPathSignature = nil
            for conn in self.conns {
                conn.generation += 1                       // kill every pending callback
                conn.task?.cancel(with: .goingAway, reason: nil)
                conn.task = nil
                conn.session?.invalidateAndCancel()        // releases the socket delegate
                conn.session = nil
            }
            self.conns.removeAll()
            self.pendingAcceptance.removeAll()   // summaries are meaningless across a stop
            // Flush any pending ledger changes so a clean stop doesn't drop up to
            // the debounce window of processed ids.
            if self.ledgerDirty, let persist = self.persistLedger {
                self.ledgerDirty = false
                let snapshot = self.processedLedger
                DispatchQueue.global(qos: .utility).async { persist(snapshot) }
            }
            self.log.info("nostr: stopped (\(self.relayURLs.count) relay(s))")
        }
    }

    // MARK: - Protocol: send / relay

    /// UNSUPPORTED BY DESIGN. A gift wrap is addressed to a specific peer pubkey;
    /// a recipient-blind broadcast cannot build one. Callers use `publish(_:to:)`.
    public func send(_ envelope: Envelope) async throws {
        throw NostrTransportError.sendRequiresRecipient
    }

    /// NO-OP BY DESIGN. Nostr is not a flood mesh — the relays are the
    /// infrastructure. TTL / split-horizon / forwarding live only on the BLE path.
    public func relay(_ envelope: Envelope, excludingLinks: Set<UUID>) async {
        // intentionally empty
    }

    // MARK: - Addressed publish (NOT part of MeshTransport)

    /// Wrap `envelope` as a NIP-59 gift wrap addressed to `peerPubkey` and publish
    /// it to EVERY currently-connected relay (`["EVENT", <event>]`). This is the
    /// real DM send path; the router calls it with the recipient it resolved from
    /// the conversation (the peer's bootstrapped `nostrPubkey`).
    ///
    /// Succeeds (resumes) once the frame has been handed to at least one live
    /// relay; throws `.notConnected` only when no relay is connected, or
    /// `.publishFailed` if the wrap/serialization fails before fan-out. Each
    /// relay's send is best-effort with error logging (mirroring the subscription
    /// send) — the relay's async `OK` is the acceptance signal, and the app-level
    /// ACK (plus the router's stuck-send timeout) is the delivery guarantee.
    public func publish(_ envelope: Envelope, to peerPubkey: Data) async throws {
        let event: NostrEvent
        do {
            event = try NostrGiftWrap.wrap(envelope: envelope,
                                           senderSecret: ourSecretKey,
                                           peerPublicKey: peerPubkey)
        } catch {
            throw NostrTransportError.publishFailed
        }
        guard let frame = Self.publishFrame(event: event),
              let text = String(data: frame, encoding: .utf8) else {
            throw NostrTransportError.publishFailed
        }
        let envID = envelope.id

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: NostrTransportError.notConnected)
                    return
                }
                let live = self.conns.filter { $0.task != nil }
                guard !live.isEmpty else {
                    cont.resume(throwing: NostrTransportError.notConnected)
                    return
                }
                for conn in live {
                    conn.task?.send(.string(text)) { [weak self] error in
                        if let error {
                            // FIX 2 instrumentation: domain+code (non-secret;
                            // localizedDescription redacts to <private>).
                            let ns = error as NSError
                            self?.log.error("nostr: publish to \(conn.url.host ?? "relay", privacy: .public) failed: domain=\(ns.domain, privacy: .public) code=\(ns.code)")
                        }
                    }
                }
                self.log.info("nostr: published gift wrap id=\(envID) → \(live.count) relay(s)")
                // Acceptance ledger (F1): watch this event's OKs; a zero-accept
                // round re-publishes (bounded) and finally fails upward. The
                // resume below is unchanged — acceptance gating is async.
                self.recordPublishLocked(eventID: event.id, envelopeID: envID,
                                         frame: text, relayCount: live.count,
                                         attempt: 1)
                cont.resume()
            }
        }
    }

    // MARK: - Connection (queue-confined, per relay)

    /// Build a FRESH socket for `conn` under its CURRENT generation: new
    /// delegate-backed session, new task, re-send the subscription (the
    /// no-`since` REQ replays the relay's stored backlog — the heal), restart
    /// the read loop, and arm the ping watchdog. Callers that replace a live
    /// socket bump `conn.generation` FIRST so the old socket's callbacks die.
    private func connectLocked(_ conn: RelayConn) {
        let generation = conn.generation
        conn.reqRetries = 0
        conn.connectedAt = Date()
        let delegate = SocketDelegate(transport: self, conn: conn, generation: generation)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: conn.url)
        conn.session = session
        conn.task = task
        task.resume()
        log.info("nostr: connecting → \(conn.url.absoluteString, privacy: .public) gen=\(generation)")
        sendSubscriptionLocked(conn)
        receiveNext(conn, generation: generation)
        schedulePingLocked(conn, generation: generation)
    }

    private func sendSubscriptionLocked(_ conn: RelayConn) {
        let generation = conn.generation
        let frame = Self.subscriptionFrame(subscriptionID: conn.subID,
                                            recipientPubkeyHex: ourPubkeyHex)
        guard let text = String(data: frame, encoding: .utf8) else { return }
        conn.task?.send(.string(text)) { [weak self] error in
            guard let self, let error else { return }
            let ns = error as NSError
            self.queue.async {
                guard self.started, conn.generation == generation else { return }
                self.log.error("nostr: REQ to \(conn.url.host ?? "relay", privacy: .public) failed: domain=\(ns.domain, privacy: .public) code=\(ns.code) attempt=\(conn.reqRetries + 1)")
                // FIX 2: retry, don't abandon — a lost REQ is silent inbound
                // death on an otherwise healthy socket. Bounded per socket; a
                // truly dead socket is the watchdogs' job, and every reconnect
                // path re-sends the REQ anyway.
                guard conn.reqRetries < Self.maxREQRetries else { return }
                conn.reqRetries += 1
                self.queue.asyncAfter(deadline: .now() + Self.reqRetryDelay) { [weak self] in
                    guard let self, self.started, conn.generation == generation else { return }
                    self.sendSubscriptionLocked(conn)
                }
            }
        }
    }

    private func receiveNext(_ conn: RelayConn, generation: Int) {
        conn.task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                // A stale socket's pending receive (cancelled or replaced) must
                // neither tear down nor double-read the replacement.
                guard conn.generation == generation else { return }
                switch result {
                case .success(let message):
                    conn.reconnectAttempts = 0
                    conn.lastInboundAt = Date()
                    let data: Data
                    switch message {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d):   data = d
                    @unknown default:    data = Data()
                    }
                    self.handleFrameLocked(data, from: conn)
                    if self.started, conn.task != nil {
                        self.receiveNext(conn, generation: generation)   // keep reading
                    }
                case .failure(let error):
                    let ns = error as NSError
                    self.log.error("nostr: receive from \(conn.url.host ?? "relay", privacy: .public) failed: domain=\(ns.domain, privacy: .public) code=\(ns.code) — \(self.livenessSummaryLocked(conn), privacy: .public)")
                    if self.started { self.scheduleReconnectLocked(conn) }
                }
            }
        }
    }

    /// Tear the socket down and reconnect after the capped backoff. Bumps the
    /// generation FIRST, so every callback armed under the old socket —
    /// receive, ping chain, pong watchdog, delegate events, an earlier pending
    /// reconnect timer — dies on its generation guard.
    private func scheduleReconnectLocked(_ conn: RelayConn) {
        conn.generation += 1
        conn.task?.cancel(with: .goingAway, reason: nil)
        conn.task = nil
        conn.session?.invalidateAndCancel()        // releases the socket delegate
        conn.session = nil
        guard started else { return }
        conn.reconnectAttempts += 1
        let generation = conn.generation
        let delay = min(Self.maxReconnectDelay,
                        Self.baseReconnectDelay * pow(2, Double(conn.reconnectAttempts - 1)))
        log.info("nostr: reconnect \(conn.url.host ?? "relay", privacy: .public) #\(conn.reconnectAttempts) in \(delay)s gen=\(generation)")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.started, conn.generation == generation else { return }
            self.connectLocked(conn)
        }
    }

    /// FIX 2: immediate rebuild — new socket + new REQ NOW, no backoff. Used by
    /// the watchdogs (pong timeout, path change, scene-active refresh) where
    /// the trigger itself is the evidence the old socket is dead or doomed.
    private func reconnectNowLocked(_ conn: RelayConn, reason: String) {
        guard started else { return }
        log.info("nostr: reconnect NOW \(conn.url.host ?? "relay", privacy: .public) — \(reason, privacy: .public) — \(self.livenessSummaryLocked(conn), privacy: .public)")
        conn.generation += 1
        conn.task?.cancel(with: .goingAway, reason: nil)
        conn.task = nil
        conn.session?.invalidateAndCancel()
        conn.session = nil
        conn.reconnectAttempts = 0
        connectLocked(conn)
    }

    // MARK: - Liveness watchdogs (FIX 2; queue-confined)

    /// Arm the next ping for this socket generation. The chain re-arms itself
    /// after every ping and dies with the generation.
    private func schedulePingLocked(_ conn: RelayConn, generation: Int) {
        let delay = Self.pingInterval + Double.random(in: 0...Self.pingJitter)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.sendPingLocked(conn, generation: generation)
        }
    }

    private func sendPingLocked(_ conn: RelayConn, generation: Int) {
        guard started, conn.generation == generation, let task = conn.task else { return }
        conn.lastPingAt = Date()
        let pingAt = conn.lastPingAt
        task.sendPing { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard conn.generation == generation else { return }
                if let error {
                    let ns = error as NSError
                    self.log.error("nostr: ping \(conn.url.host ?? "relay", privacy: .public) failed: domain=\(ns.domain, privacy: .public) code=\(ns.code)")
                    self.reconnectNowLocked(conn, reason: "ping send failed")
                } else {
                    conn.lastPongAt = Date()
                    self.log.debug("nostr: pong @ \(conn.url.host ?? "relay", privacy: .public)")
                }
            }
        }
        // The half-open signature: sendPing's handler may simply NEVER fire on
        // a NAT-dropped socket (no error, no pong). This deadline is the
        // detector — no pong recorded since this ping ⇒ reads are dead even if
        // writes still "succeed" ⇒ rebuild now.
        queue.asyncAfter(deadline: .now() + Self.pongDeadline) { [weak self] in
            guard let self, self.started, conn.generation == generation else { return }
            if conn.lastPongAt < pingAt {
                self.reconnectNowLocked(conn, reason: "pong timeout >\(Int(Self.pongDeadline))s")
            }
        }
        schedulePingLocked(conn, generation: generation)
    }

    /// FIX 2: scene-active refresh hook, called by the app layer when the scene
    /// becomes active. Rebuilds any relay whose socket is missing or shows no
    /// life (no inbound frame, no pong) for `staleAfter` — the post-suspension
    /// state pings couldn't observe. Fresh sockets are left alone.
    public func refreshConnections() {
        queue.async { [weak self] in
            guard let self, self.started else { return }
            let now = Date()
            for conn in self.conns {
                let lastLife = max(conn.lastInboundAt, conn.lastPongAt)
                let stale = now.timeIntervalSince(lastLife) > Self.staleAfter
                let youngSocket = now.timeIntervalSince(conn.connectedAt) < Self.minSocketAgeForRefresh
                if conn.task == nil || (stale && !youngSocket) {
                    self.reconnectNowLocked(conn, reason: "scene-active refresh")
                }
            }
        }
    }

    /// FIX 2: socket delegate events (hopped to `queue`, generation-guarded).
    private func socketDidOpen(_ conn: RelayConn, generation: Int) {
        queue.async { [weak self] in
            guard let self, conn.generation == generation else { return }
            self.log.info("nostr: socket OPEN @ \(conn.url.host ?? "relay", privacy: .public) gen=\(generation)")
        }
    }

    private func socketDidClose(_ conn: RelayConn, generation: Int,
                                code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { [weak self] in
            guard let self, conn.generation == generation else { return }
            let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            self.log.error("nostr: socket CLOSED @ \(conn.url.host ?? "relay", privacy: .public) code=\(code.rawValue) reason=\(reasonText, privacy: .public) — \(self.livenessSummaryLocked(conn), privacy: .public)")
            if self.started { self.scheduleReconnectLocked(conn) }
        }
    }

    /// FIX 2: network-path transitions. Trigger only — on a REAL change of a
    /// satisfied path (regain after loss, wifi↔cell), rebuild every relay;
    /// idle sockets never notice these on their own. The first callback (no
    /// prior signature) is startup noise, not a transition.
    private func handlePathUpdateLocked(_ path: NWPath) {
        var classes: [String] = []
        if path.usesInterfaceType(.wifi) { classes.append("wifi") }
        if path.usesInterfaceType(.cellular) { classes.append("cell") }
        if path.usesInterfaceType(.wiredEthernet) { classes.append("wired") }
        let signature = "\(String(describing: path.status))|\(classes.joined(separator: "+"))"
        let prior = lastPathSignature
        lastPathSignature = signature
        guard started, let prior, prior != signature, path.status == .satisfied else { return }
        log.info("nostr: network path changed \(prior, privacy: .public) → \(signature, privacy: .public) — reconnecting all relays")
        for conn in conns { reconnectNowLocked(conn, reason: "path change") }
    }

    /// One-line per-relay liveness snapshot for the instrumentation lines:
    /// seconds since the last inbound frame and the last pong (or "never").
    private func livenessSummaryLocked(_ conn: RelayConn) -> String {
        func age(_ date: Date) -> String {
            date == .distantPast ? "never" : "\(Int(Date().timeIntervalSince(date)))s"
        }
        return "lastInbound=\(age(conn.lastInboundAt)) lastPong=\(age(conn.lastPongAt))"
    }

    // MARK: - Inbound handling (queue-confined)

    private func handleFrameLocked(_ data: Data, from conn: RelayConn) {
        guard let message = Self.parseRelayFrame(data) else { return }
        let host = conn.url.host ?? "relay"
        switch message {
        case .event(_, let event):
            handleInboundEventLocked(event, from: conn)
        case .endOfStoredEvents(let sub):
            log.info("nostr: EOSE \(sub, privacy: .public) @ \(host, privacy: .public)")
        case .ok(let id, let accepted, let msg):
            log.info("nostr: OK \(id, privacy: .public) accepted=\(accepted) \(msg, privacy: .public) @ \(host, privacy: .public)")
            noteAcceptanceLocked(eventID: id, accepted: accepted)
        case .notice(let msg):
            log.info("nostr: NOTICE \(msg, privacy: .public) @ \(host, privacy: .public)")
        case .closed(let sub, let msg):
            // FIX 2: a relay killing OUR subscription used to be log-only —
            // publish kept working while inbound went permanently silent on
            // that relay. NIP-01 machine-readable refusals that retrying can't
            // cure get a distinct log and NO retry (a tight loop against
            // auth-required/blocked invites a ban); anything else (idle sweep,
            // restart, rate limit) is transient → rebuild socket + REQ through
            // the normal backoff. A CLOSED for a sub id that isn't ours is
            // logged and ignored, as before.
            let permanentPrefixes = ["auth-required:", "restricted:", "blocked:",
                                     "invalid:", "unsupported:"]
            if sub == conn.subID, permanentPrefixes.contains(where: { msg.hasPrefix($0) }) {
                log.error("nostr: subscription REFUSED \(sub, privacy: .public) \(msg, privacy: .public) @ \(host, privacy: .public) — permanent, not retrying")
            } else if sub == conn.subID, started {
                log.error("nostr: subscription CLOSED \(sub, privacy: .public) \(msg, privacy: .public) @ \(host, privacy: .public) — transient, reconnect+resubscribe")
                scheduleReconnectLocked(conn)
            } else {
                log.info("nostr: CLOSED \(sub, privacy: .public) \(msg, privacy: .public) @ \(host, privacy: .public)")
            }
        case .unknown:
            break
        }
    }

    private func handleInboundEventLocked(_ event: NostrEvent, from conn: RelayConn) {
        let host = conn.url.host ?? "relay"
        guard event.kind == NostrGiftWrap.wrapKind else { return }   // only 1059s
        // ISSUE-5 replay guard, F2-REVISED: the PERSISTED ledger records an id
        // only after a SUCCESSFUL unwrap + yield. Recording on first sight
        // permanently consumed wraps that a later state fix would have made
        // processable — the v55 invite echo unwrapped fine, failed at the
        // Security open on overwritten prekeys, and after the prekey fix the
        // relay's replays were ledger-skipped forever (minter blank for good).
        // A wrap that fails validation/unwrap instead goes into a RAM-only set:
        // the open-fail replay storm stays dead within a session, and the next
        // launch gets exactly one fresh try. KNOWN LIMIT, deliberate: a wrap
        // that unwraps but is dropped DOWNSTREAM (Security open) is still
        // recorded — the recovery for that class is sender-side (the F1
        // zero-accept demotion + resend re-seals a FRESH wrap with a new id)
        // and, for the one-shot invite echo, the re-echo heal (F3).
        if processedLedger.contains(event.id) {
            log.debug("nostr: skip already-processed 1059 \(String(event.id.prefix(12)), privacy: .public) @ \(host, privacy: .public)")
            return
        }
        if failedWrapsThisSession.contains(event.id) { return }   // logged at first failure
        guard event.isValid() else {
            noteFailedWrapLocked(event.id)
            log.error("nostr: inbound 1059 failed event validation @ \(host, privacy: .public)")
            return
        }
        do {
            let (envelope, _) = try NostrGiftWrap.unwrap(giftWrap: event,
                                                         mySecret: ourSecretKey)
            processedLedger.containsOrInsert(event.id)
            scheduleLedgerSaveLocked()   // a new id was recorded — persist (debounced)
            inboundCont.yield((link: Self.nostrSourceLink, envelope: envelope))
            log.info("nostr: unwrapped inbound envelope id=\(envelope.id) @ \(host, privacy: .public) → incoming")
        } catch {
            noteFailedWrapLocked(event.id)
            log.error("nostr: unwrap failed @ \(host, privacy: .public): \(error.localizedDescription)")
        }
    }

    /// F2: wraps that failed validation/unwrap THIS SESSION (RAM only) — a
    /// replay is skipped without re-paying schnorr/ECDH, but the id is eligible
    /// again next launch (unlike the persisted ledger, which now records only
    /// successes). Crudely bounded: a flood past the cap clears the set — worst
    /// case one extra re-verification pass, keeping this both un-poisonable and
    /// un-growable. Queue-confined like all mutable state here.
    private func noteFailedWrapLocked(_ id: String) {
        if failedWrapsThisSession.count >= Self.failedWrapsCap {
            failedWrapsThisSession.removeAll()
        }
        failedWrapsThisSession.insert(id)
    }

    // MARK: - Acceptance ledger (queue-confined; observability only)

    /// Register a just-published event for OK-tracking and schedule its one-time
    /// summary. The deadline closure runs on `queue` (same confinement as every
    /// mutation here); a finalize triggered earlier by all relays answering
    /// removes the entry, making the deadline pass a silent no-op.
    private func recordPublishLocked(eventID: String, envelopeID: MessageID,
                                     frame: String, relayCount: Int, attempt: Int) {
        pendingAcceptance[eventID] = PendingAcceptance(eventID: eventID,
                                                       envelopeID: envelopeID,
                                                       frame: frame,
                                                       relayCount: relayCount,
                                                       attempt: attempt)
        queue.asyncAfter(deadline: .now() + Self.acceptanceSummaryDeadline) { [weak self] in
            self?.finalizeAcceptanceLocked(eventID: eventID, trigger: "deadline")
        }
    }

    /// Fold one relay's OK verdict into the pending entry. An id we aren't
    /// tracking (already summarized, or not our publish) is ignored. Once every
    /// live relay has answered, summarize early rather than waiting out the
    /// deadline.
    private func noteAcceptanceLocked(eventID: String, accepted: Bool) {
        guard var pending = pendingAcceptance[eventID] else { return }
        if accepted { pending.accepted += 1 } else { pending.rejected += 1 }
        pendingAcceptance[eventID] = pending
        if pending.accepted + pending.rejected >= pending.relayCount {
            finalizeAcceptanceLocked(eventID: eventID, trigger: "all answered")
        }
    }

    /// F1 decision core, pure so a unit test can pin the retry ladder without
    /// sockets: a round with >= 1 accept is settled; zero accepts retries until
    /// the attempt cap, then gives up (surfaces the failure upward).
    enum AcceptanceOutcome: Equatable { case settled, retry, giveUp }
    static func acceptanceOutcome(accepted: Int, attempt: Int, maxAttempts: Int) -> AcceptanceOutcome {
        if accepted > 0 { return .settled }
        return attempt < maxAttempts ? .retry : .giveUp
    }

    /// Emit the one-time acceptance summary, then ACT on it (F1). ZERO accepts
    /// is the silent-strand signature (a wrap `publish` reported as handed off
    /// that no relay actually took): re-publish the retained frame after
    /// `republishDelay` — by then the liveness watchdogs have had a chance to
    /// rebuild a dead socket — or, past the attempt cap, fire `onPublishFailed`
    /// so a tracked row demotes off `.cast`. Idempotent: the entry is removed
    /// first, so the deadline and the all-answered path can't both fire.
    private func finalizeAcceptanceLocked(eventID: String, trigger: String) {
        guard let pending = pendingAcceptance.removeValue(forKey: eventID) else { return }
        let silent = max(0, pending.relayCount - pending.accepted - pending.rejected)
        let idPrefix = String(eventID.prefix(12))
        switch Self.acceptanceOutcome(accepted: pending.accepted,
                                      attempt: pending.attempt,
                                      maxAttempts: Self.maxPublishAttempts) {
        case .settled:
            log.info("nostr: acceptance \(idPrefix, privacy: .public) (envelope \(pending.envelopeID)) — accepted=\(pending.accepted) rejected=\(pending.rejected) silent=\(silent) of \(pending.relayCount) [\(trigger, privacy: .public)]")
        case .retry:
            log.error("nostr: NO relay accepted event \(idPrefix, privacy: .public) (envelope \(pending.envelopeID)) — rejected=\(pending.rejected) silent=\(silent) of \(pending.relayCount) [\(trigger, privacy: .public)] — retry \(pending.attempt + 1)/\(Self.maxPublishAttempts) in \(Int(Self.republishDelay))s")
            queue.asyncAfter(deadline: .now() + Self.republishDelay) { [weak self] in
                self?.republishLocked(pending)
            }
        case .giveUp:
            log.error("nostr: NO relay accepted event \(idPrefix, privacy: .public) (envelope \(pending.envelopeID)) after \(pending.attempt) attempt(s) — giving up [\(trigger, privacy: .public)]")
            onPublishFailed?(pending.envelopeID)
        }
    }

    /// F1: re-fan-out a zero-accept publish to the currently-live sockets and
    /// re-enter the acceptance cycle with attempt+1. Zero live sockets is fine:
    /// the fresh entry's deadline fires with zero accepts and the ladder
    /// continues (retry or give up) — no rung is ever silently skipped. A late
    /// OK from an EARLIER attempt's socket still counts for the new entry (the
    /// event id is identical), which is exactly the honest outcome.
    private func republishLocked(_ pending: PendingAcceptance) {
        guard started else { return }
        let live = conns.filter { $0.task != nil }
        for conn in live {
            conn.task?.send(.string(pending.frame)) { [weak self] error in
                if let error {
                    let ns = error as NSError
                    self?.log.error("nostr: re-publish to \(conn.url.host ?? "relay", privacy: .public) failed: domain=\(ns.domain, privacy: .public) code=\(ns.code)")
                }
            }
        }
        log.info("nostr: re-published \(String(pending.eventID.prefix(12)), privacy: .public) (envelope \(pending.envelopeID)) attempt \(pending.attempt + 1)/\(Self.maxPublishAttempts) → \(live.count) relay(s)")
        recordPublishLocked(eventID: pending.eventID, envelopeID: pending.envelopeID,
                            frame: pending.frame, relayCount: live.count,
                            attempt: pending.attempt + 1)
    }

    /// Coalesce a ledger save (queue-confined). Marks the ledger dirty and, if no
    /// save is already pending, schedules one `ledgerSaveDebounce` seconds out. The
    /// scheduled block snapshots the value-type ledger ON `queue`, then dispatches
    /// the injected `persistLedger` OFF `queue` (utility) so the sealed write never
    /// stalls the receive loop. A no-op when no persist hook is wired.
    private func scheduleLedgerSaveLocked() {
        guard persistLedger != nil else { return }
        ledgerDirty = true
        guard !ledgerSaveScheduled else { return }
        ledgerSaveScheduled = true
        queue.asyncAfter(deadline: .now() + Self.ledgerSaveDebounce) { [weak self] in
            guard let self else { return }
            self.ledgerSaveScheduled = false
            guard self.ledgerDirty else { return }
            self.ledgerDirty = false
            let snapshot = self.processedLedger
            let persist = self.persistLedger
            DispatchQueue.global(qos: .utility).async { persist?(snapshot) }
        }
    }

    // MARK: - NIP-01 wire framing (PURE + testable; no I/O)

    /// Relay → client messages we care about. Pure value type so the parser is
    /// unit-testable without a socket. Internal (not public): its `.event` case
    /// carries `NostrEvent`, an app-internal type — and a public case can't
    /// expose an internal type. Tests reach it via `@testable import Beacon`.
    enum RelayMessage: Equatable {
        case event(subscriptionID: String, event: NostrEvent)
        case endOfStoredEvents(subscriptionID: String)
        case ok(eventID: String, accepted: Bool, message: String)
        case notice(String)
        case closed(subscriptionID: String, message: String)
        case unknown
    }

    /// Build a NIP-01 subscription: `["REQ", <subid>, {"kinds":[1059],"#p":[hex]}]`.
    /// We only ever want gift wraps (kind 1059) tagged to us.
    static func subscriptionFrame(subscriptionID: String, recipientPubkeyHex: String) -> Data {
        let filter: [String: Any] = [
            "kinds": [NostrGiftWrap.wrapKind],
            "#p": [recipientPubkeyHex]
        ]
        let req: [Any] = ["REQ", subscriptionID, filter]
        return (try? JSONSerialization.data(withJSONObject: req)) ?? Data()
    }

    /// Build a NIP-01 publish: `["EVENT", <event-json-object>]`. Returns nil if
    /// the event can't be serialized.
    static func publishFrame(event: NostrEvent) -> Data? {
        guard let eventData = event.jsonData(),
              let eventObj = try? JSONSerialization.jsonObject(with: eventData) else {
            return nil
        }
        let msg: [Any] = ["EVENT", eventObj]
        return try? JSONSerialization.data(withJSONObject: msg)
    }

    /// Parse a relay frame into a `RelayMessage`. Returns nil only for input that
    /// isn't a JSON array with a leading string tag; recognized-but-malformed
    /// frames map to `.unknown` so the receive loop never wedges on junk.
    static func parseRelayFrame(_ data: Data) -> RelayMessage? {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [Any],
              let tag = top.first as? String else {
            return nil
        }
        switch tag {
        case "EVENT":
            guard top.count >= 3,
                  let subID = top[1] as? String,
                  let eventObj = top[2] as? [String: Any],
                  let eventData = try? JSONSerialization.data(withJSONObject: eventObj),
                  let event = NostrEvent(jsonData: eventData) else {
                return .unknown
            }
            return .event(subscriptionID: subID, event: event)
        case "EOSE":
            guard top.count >= 2, let subID = top[1] as? String else { return .unknown }
            return .endOfStoredEvents(subscriptionID: subID)
        case "OK":
            guard top.count >= 3, let eid = top[1] as? String, let ok = top[2] as? Bool else {
                return .unknown
            }
            let msg = (top.count >= 4 ? top[3] as? String : "") ?? ""
            return .ok(eventID: eid, accepted: ok, message: msg)
        case "NOTICE":
            return .notice((top.count >= 2 ? top[1] as? String : "") ?? "")
        case "CLOSED":
            let subID = (top.count >= 2 ? top[1] as? String : "") ?? ""
            let msg = (top.count >= 3 ? top[2] as? String : "") ?? ""
            return .closed(subscriptionID: subID, message: msg)
        default:
            return .unknown
        }
    }
}
