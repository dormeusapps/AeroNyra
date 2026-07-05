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

    /// ACCEPTANCE LEDGER (observability ONLY — behavior unchanged). `publish`
    /// resumes once the frame is handed to >= 1 live socket, but a relay's real
    /// verdict is its later async `OK <eventID> <accepted>` — a rate-limit
    /// rejection (`accepted=false`) or a half-open socket that never answers is
    /// today invisible except as one uncorrelated log line. This registry keys
    /// each published event's id to its envelope and counts the per-relay
    /// verdicts, then logs ONE summary — loudly (`error`) when NO relay accepted,
    /// which is exactly the silent-strand signature the stranded-run log hunt
    /// needs (P0/P1). It does NOT gate `publish`, `.cast`, or the re-drive cap —
    /// that (the acceptance-blocking half) is deliberately deferred pending that
    /// log. Queue-confined like all mutable state here; entries self-expire at
    /// `acceptanceSummaryDeadline`, so the map is bounded by publish rate.
    private var pendingAcceptance: [String: PendingAcceptance] = [:]

    private struct PendingAcceptance {
        let envelopeID: MessageID
        let relayCount: Int          // live relays the frame was handed to
        var accepted = 0
        var rejected = 0
    }

    /// How long after a publish we wait for relay OKs before summarizing. OKs
    /// normally land well under a second; anything still silent by now is
    /// counted as such in the summary. Long enough to never truncate a slow
    /// relay's honest verdict, short enough to bound the registry.
    private static let acceptanceSummaryDeadline: Double = 10
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
        init(url: URL) {
            self.url = url
            self.subID = "aeronyra-\(UUID().uuidString.prefix(8))"
        }
    }

    // MARK: Constants
    /// Synthetic source link for inbound envelopes (Nostr has no real link, and
    /// nothing relays them onward). Process-stable; never used for split-horizon.
    private static let nostrSourceLink = UUID()
    private static let baseReconnectDelay: Double = 1     // seconds
    private static let maxReconnectDelay: Double = 30     // capped backoff ceiling

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
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.started = false
            for conn in self.conns {
                conn.task?.cancel(with: .goingAway, reason: nil)
                conn.task = nil
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
                            self?.log.error("nostr: publish to \(conn.url.host ?? "relay", privacy: .public) failed: \(error.localizedDescription)")
                        }
                    }
                }
                self.log.info("nostr: published gift wrap id=\(envID) → \(live.count) relay(s)")
                // Acceptance ledger: watch this event's OKs and summarize once
                // (observability only — the resume below is unchanged).
                self.recordPublishLocked(eventID: event.id, envelopeID: envID,
                                         relayCount: live.count)
                cont.resume()
            }
        }
    }

    // MARK: - Connection (queue-confined, per relay)

    private func connectLocked(_ conn: RelayConn) {
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: conn.url)
        conn.session = session
        conn.task = task
        task.resume()
        log.info("nostr: connecting → \(conn.url.absoluteString, privacy: .public)")
        sendSubscriptionLocked(conn)
        receiveNext(conn)
    }

    private func sendSubscriptionLocked(_ conn: RelayConn) {
        let frame = Self.subscriptionFrame(subscriptionID: conn.subID,
                                            recipientPubkeyHex: ourPubkeyHex)
        guard let text = String(data: frame, encoding: .utf8) else { return }
        conn.task?.send(.string(text)) { [weak self] error in
            if let error {
                self?.log.error("nostr: REQ to \(conn.url.host ?? "relay", privacy: .public) failed: \(error.localizedDescription)")
            }
        }
    }

    private func receiveNext(_ conn: RelayConn) {
        conn.task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success(let message):
                    conn.reconnectAttempts = 0
                    let data: Data
                    switch message {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d):   data = d
                    @unknown default:    data = Data()
                    }
                    self.handleFrameLocked(data, from: conn)
                    if self.started, conn.task != nil { self.receiveNext(conn) }   // keep reading
                case .failure(let error):
                    self.log.error("nostr: receive from \(conn.url.host ?? "relay", privacy: .public) failed: \(error.localizedDescription)")
                    if self.started { self.scheduleReconnectLocked(conn) }
                }
            }
        }
    }

    private func scheduleReconnectLocked(_ conn: RelayConn) {
        conn.task = nil
        conn.session = nil
        guard started else { return }
        conn.reconnectAttempts += 1
        let delay = min(Self.maxReconnectDelay,
                        Self.baseReconnectDelay * pow(2, Double(conn.reconnectAttempts - 1)))
        log.info("nostr: reconnect \(conn.url.host ?? "relay", privacy: .public) #\(conn.reconnectAttempts) in \(delay)s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.started else { return }
            self.connectLocked(conn)
        }
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
            log.info("nostr: CLOSED \(sub, privacy: .public) \(msg, privacy: .public) @ \(host, privacy: .public)")
        case .unknown:
            break
        }
    }

    private func handleInboundEventLocked(_ event: NostrEvent, from conn: RelayConn) {
        let host = conn.url.host ?? "relay"
        guard event.kind == NostrGiftWrap.wrapKind else { return }   // only 1059s
        // ISSUE-5: skip a wrap whose OUTER id we've already processed — a relay
        // replay of a stored event, or the same wrap fanned in from several
        // relays. Recorded on FIRST sight (the id is a content hash, so
        // re-processing can only repeat the same outcome), BEFORE the expensive
        // isValid() + unwrap. Quiet .debug so it doesn't re-introduce the noise
        // this guard exists to remove.
        if processedLedger.containsOrInsert(event.id) {
            log.debug("nostr: skip already-processed 1059 \(String(event.id.prefix(12)), privacy: .public) @ \(host, privacy: .public)")
            return
        }
        scheduleLedgerSaveLocked()   // a new id was recorded — persist (debounced)
        guard event.isValid() else {
            log.error("nostr: inbound 1059 failed event validation @ \(host, privacy: .public)")
            return
        }
        do {
            let (envelope, _) = try NostrGiftWrap.unwrap(giftWrap: event,
                                                         mySecret: ourSecretKey)
            inboundCont.yield((link: Self.nostrSourceLink, envelope: envelope))
            log.info("nostr: unwrapped inbound envelope id=\(envelope.id) @ \(host, privacy: .public) → incoming")
        } catch {
            log.error("nostr: unwrap failed @ \(host, privacy: .public): \(error.localizedDescription)")
        }
    }

    // MARK: - Acceptance ledger (queue-confined; observability only)

    /// Register a just-published event for OK-tracking and schedule its one-time
    /// summary. The deadline closure runs on `queue` (same confinement as every
    /// mutation here); a finalize triggered earlier by all relays answering
    /// removes the entry, making the deadline pass a silent no-op.
    private func recordPublishLocked(eventID: String, envelopeID: MessageID, relayCount: Int) {
        pendingAcceptance[eventID] = PendingAcceptance(envelopeID: envelopeID,
                                                       relayCount: relayCount)
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

    /// Emit the one-time acceptance summary and drop the entry. ZERO accepts is
    /// the silent-strand signature (a wrap `publish` reported as handed off that
    /// no relay actually took) — logged at `error` so it stands out in the
    /// stranded-run log this exists to feed. Idempotent: the entry is removed
    /// first, so the deadline and the all-answered path can't both fire.
    private func finalizeAcceptanceLocked(eventID: String, trigger: String) {
        guard let pending = pendingAcceptance.removeValue(forKey: eventID) else { return }
        let silent = max(0, pending.relayCount - pending.accepted - pending.rejected)
        let idPrefix = String(eventID.prefix(12))
        if pending.accepted == 0 {
            log.error("nostr: NO relay accepted event \(idPrefix, privacy: .public) (envelope \(pending.envelopeID)) — rejected=\(pending.rejected) silent=\(silent) of \(pending.relayCount) [\(trigger, privacy: .public)]")
        } else {
            log.info("nostr: acceptance \(idPrefix, privacy: .public) (envelope \(pending.envelopeID)) — accepted=\(pending.accepted) rejected=\(pending.rejected) silent=\(silent) of \(pending.relayCount) [\(trigger, privacy: .public)]")
        }
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
