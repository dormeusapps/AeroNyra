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
    public init(relayURLs: [URL], ourSecretKey: Data, ourPublicKey: Data) {
        self.relayURLs = relayURLs
        self.ourSecretKey = ourSecretKey
        self.ourPubkeyHex = ourPublicKey.map { String(format: "%02x", $0) }.joined()

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
