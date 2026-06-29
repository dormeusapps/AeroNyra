//
//  NostrTransport.swift
//  Core/Routing
//
//  PILLAR 2 — the internet transport (Phase 8d). A second `MeshTransport`
//  conformer that carries the SAME opaque `Envelope` the BLE mesh carries, but
//  over a Nostr relay instead of the radio. Inbound gift wraps are unwrapped
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
//  SCOPE (8d-1): a single-relay websocket client — connect, subscribe for our
//  inbound 1059s, unwrap them onto `incoming`, and publish addressed wraps.
//  Multi-relay redundancy, the 3-tier BLE→Nostr→queue routing policy, and
//  wiring `incoming` into the router's receiver are LATER substeps (8d-2/8d-3).
//
//  CONCURRENCY: not an actor. ALL mutable state is confined to `queue`; the
//  URLSession receive callback hops onto `queue` before touching anything. That
//  is what makes `@unchecked Sendable` honest (same stance as BLEMeshTransport).
//

import Foundation
import os

// MARK: - Errors

public enum NostrTransportError: Error, Equatable {
    /// The recipient-blind `send(_:)` was called. A gift wrap must be addressed;
    /// callers use `publish(_:to:)` with a resolved peer pubkey instead.
    case sendRequiresRecipient
    /// `publish` was called with no live websocket task.
    case notConnected
    /// Wrapping the envelope or serializing the event frame failed.
    case publishFailed
}

// MARK: - NostrTransport

public final class NostrTransport: MeshTransport, AddressedTransport, @unchecked Sendable {

    // MARK: Protocol: identity
    public let kind: TransportKind = .internet

    // MARK: Protocol: inbound envelope stream
    /// Inbound, unwrapped gift wraps. The `link` is a synthetic constant
    /// (`nostrSourceLink`): Nostr has no per-link source and bypasses relay, so
    /// it exists only to match the BLE stream's shape.
    public let incoming: AsyncStream<(link: UUID, envelope: Envelope)>
    private let inboundCont: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation

    // MARK: Injected identity + relay
    private let relayURL: URL
    private let ourSecretKey: Data        // signs wraps; opens inbound (NIP-44)
    private let ourPubkeyHex: String      // for the #p subscription filter
    private let subID: String

    // MARK: Queue-confined connection state
    private let queue = DispatchQueue(label: "com.aeronyra.nostr.transport")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var started = false
    private var reconnectAttempts = 0

    // MARK: Constants
    /// Synthetic source link for inbound envelopes (Nostr has no real link, and
    /// nothing relays them onward). Process-stable; never used for split-horizon.
    private static let nostrSourceLink = UUID()
    private static let baseReconnectDelay: Double = 1     // seconds
    private static let maxReconnectDelay: Double = 30     // capped backoff ceiling

    private let log = Logger(subsystem: "com.aeronyra.app", category: "Nostr")

    // MARK: - Init

    /// - Parameters:
    ///   - relayURL: a single relay websocket URL (e.g. `wss://relay.damus.io`).
    ///     Multi-relay is a later substep; the seam takes one for now.
    ///   - ourSecretKey: our 32-byte Nostr secret (signs gift wraps, opens
    ///     inbound NIP-44). From `NostrIdentity.secretKeyBytes`.
    ///   - ourPublicKey: our 32-byte x-only pubkey, used to build the inbound
    ///     subscription filter. From `NostrIdentity.publicKeyBytes`.
    public init(relayURL: URL, ourSecretKey: Data, ourPublicKey: Data) {
        self.relayURL = relayURL
        self.ourSecretKey = ourSecretKey
        self.ourPubkeyHex = ourPublicKey.map { String(format: "%02x", $0) }.joined()
        self.subID = "aeronyra-\(UUID().uuidString.prefix(8))"

        var cont: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation!
        self.incoming = AsyncStream<(link: UUID, envelope: Envelope)> { cont = $0 }
        self.inboundCont = cont
    }

    // MARK: - Protocol: lifecycle

    public func start() async throws {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.reconnectAttempts = 0
            self.connectLocked()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.started = false
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.session = nil
            self.log.info("nostr: stopped")
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

    /// Wrap `envelope` as a NIP-59 gift wrap addressed to `peerPubkey` and
    /// publish it to the relay (`["EVENT", <event>]`). This is the real DM send
    /// path; the router calls it with the recipient it resolved from the
    /// conversation (the peer's bootstrapped `nostrPubkey`).
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

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self, let task = self.task else {
                    cont.resume(throwing: NostrTransportError.notConnected)
                    return
                }
                task.send(.string(text)) { error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume() }
                }
            }
        }
        log.info("nostr: published gift wrap for envelope id=\(envelope.id)")
    }

    // MARK: - Connection (queue-confined)

    private func connectLocked() {
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: relayURL)
        self.session = session
        self.task = task
        task.resume()
        log.info("nostr: connecting → \(self.relayURL.absoluteString, privacy: .public)")
        sendSubscriptionLocked()
        receiveNext()
    }

    private func sendSubscriptionLocked() {
        let frame = Self.subscriptionFrame(subscriptionID: subID,
                                            recipientPubkeyHex: ourPubkeyHex)
        guard let text = String(data: frame, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] error in
            if let error {
                self?.log.error("nostr: REQ send failed: \(error.localizedDescription)")
            }
        }
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success(let message):
                    self.reconnectAttempts = 0
                    let data: Data
                    switch message {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d):   data = d
                    @unknown default:    data = Data()
                    }
                    self.handleFrameLocked(data)
                    if self.started { self.receiveNext() }   // keep reading
                case .failure(let error):
                    self.log.error("nostr: receive failed: \(error.localizedDescription)")
                    if self.started { self.scheduleReconnectLocked() }
                }
            }
        }
    }

    private func scheduleReconnectLocked() {
        task = nil
        session = nil
        guard started else { return }
        reconnectAttempts += 1
        let delay = min(Self.maxReconnectDelay,
                        Self.baseReconnectDelay * pow(2, Double(reconnectAttempts - 1)))
        log.info("nostr: reconnect #\(self.reconnectAttempts) in \(delay)s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.started else { return }
            self.connectLocked()
        }
    }

    // MARK: - Inbound handling (queue-confined)

    private func handleFrameLocked(_ data: Data) {
        guard let message = Self.parseRelayFrame(data) else { return }
        switch message {
        case .event(_, let event):
            handleInboundEventLocked(event)
        case .endOfStoredEvents(let sub):
            log.info("nostr: EOSE \(sub, privacy: .public)")
        case .ok(let id, let accepted, let msg):
            log.info("nostr: OK \(id, privacy: .public) accepted=\(accepted) \(msg, privacy: .public)")
        case .notice(let msg):
            log.info("nostr: NOTICE \(msg, privacy: .public)")
        case .closed(let sub, let msg):
            log.info("nostr: CLOSED \(sub, privacy: .public) \(msg, privacy: .public)")
        case .unknown:
            break
        }
    }

    private func handleInboundEventLocked(_ event: NostrEvent) {
        guard event.kind == NostrGiftWrap.wrapKind else { return }   // only 1059s
        guard event.isValid() else {
            log.error("nostr: inbound 1059 failed event validation")
            return
        }
        do {
            let (envelope, _) = try NostrGiftWrap.unwrap(giftWrap: event,
                                                         mySecret: ourSecretKey)
            inboundCont.yield((link: Self.nostrSourceLink, envelope: envelope))
            log.info("nostr: unwrapped inbound envelope id=\(envelope.id) → incoming")
        } catch {
            log.error("nostr: unwrap failed: \(error.localizedDescription)")
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
