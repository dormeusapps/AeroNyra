//
//  TransportStopCoverageTests.swift
//  BeaconTests
//
//  COVERAGE BEFORE CALL — the erase fix (Option R) will call
//  `MessageRouter.stop()` → `NostrTransport.stop()` / `BLEMeshTransport.stop()`,
//  code that has never run in production and ran only in the skipped
//  live-relay test. These pin that a STOPPED transport refuses to reach a
//  relay again through every path that could reconnect or send:
//
//    1. publish                       → throws, no EVENT
//    2. a subscription change         → no REQ
//    3. the foreground refresh        → no connection
//    4. a reconnect timer that fires after stop → no connection
//    5. the ping chain                → no ping
//    6. the epoch-rollover timer      → no REQ
//    7. MessageRouter.stop() with the REAL BLEMeshTransport → send reaches
//       neither rail
//
//  Every negative is paired with a CONTROL on a running transport that must
//  produce the traffic, so no test passes vacuously. What reaches a "relay"
//  is observed at a local loopback WebSocket server (Network.framework), not
//  inferred from the transport's own bookkeeping.
//
//  Test 5 waits ~31 s: the ping interval is a fixed 25 s + up to 5 s jitter
//  (NostrTransport.pingInterval / pingJitter) and is not injectable.
//

import XCTest
import CryptoKit
import Network
import os
@testable import Beacon

final class TransportStopCoverageTests: XCTestCase {

    // MARK: Fixtures

    private let ourSecret = Data((1...32).map { UInt8($0) })          // valid scalar
    private let identity = Data(repeating: 0xBB, count: 32)
    private let pairSecret = Data((0...31).map { UInt8($0) })
    /// A REAL x-only key (the wrap derives a NIP-44 key from it).
    private let recipientNpub = Secp256k1.xOnlyPublicKey(
        fromSecretKey: Data([0x10] + Array(repeating: 0x00, count: 30) + [0x01]))!

    private func makeRelay() async throws -> LocalRelay {
        let relay = try LocalRelay()
        try await relay.start()
        addTeardownBlock { relay.stop() }
        return relay
    }

    /// A transport pointed at `relay`, with a decoy secret (so a REQ is
    /// planned) and a table row for `recipientNpub` (so publish can tag).
    private func makeTransport(to relay: LocalRelay,
                               now: @escaping @Sendable () -> UInt64 = { 1_789_344_000 }) -> NostrTransport {
        let pub = Secp256k1.xOnlyPublicKey(fromSecretKey: ourSecret)!
        let transport = NostrTransport(relayURLs: [relay.url], ourSecretKey: ourSecret,
                                       ourPublicKey: pub, now: now)
        transport.setDecoySecret(NostrInboxDecoy.secret(fromAgreementPrivate: Curve25519.KeyAgreement.PrivateKey()))
        transport.setTagTable(NostrInboxTagTable(ourIdentity: identity,
                                                 rows: [.init(identity: identity, secret: pairSecret,
                                                              nostrPubkey: recipientNpub)]))
        addTeardownBlock { transport.stop() }
        return transport
    }

    /// Start `transport` and wait until `relay` has a connection and a REQ.
    private func startLive(_ transport: NostrTransport, _ relay: LocalRelay,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        try await transport.start()
        let live = await waitUntil(timeout: 5) { relay.connections >= 1 && relay.reqCount >= 1 }
        XCTAssertTrue(live, "transport never reached the local relay (connection + REQ)", file: file, line: line)
    }

    /// Stop and let the stop block (and the socket close) land.
    private func stopAndSettle(_ transport: NostrTransport) async {
        transport.stop()
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func waitUntil(timeout: Double, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: 1. publish

    func testStoppedTransportPublishThrowsAndSendsNoEvent() async throws {
        let relay = try await makeRelay()
        let transport = makeTransport(to: relay)
        try await startLive(transport, relay)

        // Control: a running transport's publish reaches the relay.
        try await transport.publish(Envelope(ciphertext: Data([1, 2, 3])), to: recipientNpub)
        let controlSaw = await waitUntil(timeout: 3) { relay.eventCount == 1 }
        XCTAssertTrue(controlSaw, "control: a running publish must reach the relay")

        await stopAndSettle(transport)
        let connectionsAtStop = relay.connections

        do {
            try await transport.publish(Envelope(ciphertext: Data([4, 5, 6])), to: recipientNpub)
            XCTFail("a stopped transport must refuse to publish")
        } catch let error as NostrTransportError {
            XCTAssertEqual(error, .notConnected)
        }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(relay.eventCount, 1, "no EVENT after stop")
        XCTAssertEqual(relay.connections, connectionsAtStop, "publish must not reconnect")
    }

    // MARK: 2. a subscription change

    func testStoppedTransportSubscriptionChangeSendsNoReq() async throws {
        let relay = try await makeRelay()
        let transport = makeTransport(to: relay)
        try await startLive(transport, relay)

        // Control: a running transport sends a new REQ for a new invite echo.
        let reqBefore = relay.reqCount
        transport.addInviteEchoSubscription(inviteID: Data(repeating: 0x01, count: 16),
                                            expiresAtMillis: 1_789_344_000_000 + 600_000)
        let controlSaw = await waitUntil(timeout: 3) { relay.reqCount > reqBefore }
        XCTAssertTrue(controlSaw, "control: a running subscription change must send a REQ")

        await stopAndSettle(transport)
        let reqAtStop = relay.reqCount
        let connectionsAtStop = relay.connections

        transport.addInviteEchoSubscription(inviteID: Data(repeating: 0x02, count: 16),
                                            expiresAtMillis: 1_789_344_000_000 + 600_000)
        transport.setTagTable(NostrInboxTagTable(ourIdentity: identity, rows: []))
        transport.setDecoySecret(NostrInboxDecoy.secret(fromAgreementPrivate: Curve25519.KeyAgreement.PrivateKey()))
        try await Task.sleep(for: .seconds(1))

        XCTAssertEqual(relay.reqCount, reqAtStop, "no REQ after stop")
        XCTAssertEqual(relay.connections, connectionsAtStop, "a subscription change must not reconnect")
    }

    // MARK: 3. the foreground refresh

    func testStoppedTransportForegroundRefreshDoesNotReconnect() async throws {
        let relay = try await makeRelay()
        let transport = makeTransport(to: relay)
        let events = RelayEventLog()
        transport.setRelayEventObserver { events.append($0) }
        try await startLive(transport, relay)

        // Control: kill the socket; once the transport has scheduled its 1 s
        // backoff reconnect, a refresh reconnects NOW — well inside that 1 s.
        relay.closeAll()
        let scheduled = await waitUntil(timeout: 3) { events.contains("reconnect #1") }
        XCTAssertTrue(scheduled, "control setup: the dead socket must schedule a reconnect")
        let before = relay.connections
        transport.refreshConnections()
        let controlSaw = await waitUntil(timeout: 0.6) { relay.connections > before }
        XCTAssertTrue(controlSaw, "control: a running refresh must reconnect a dead socket at once")

        await stopAndSettle(transport)
        let connectionsAtStop = relay.connections
        transport.refreshConnections()
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(relay.connections, connectionsAtStop, "refresh after stop must not reconnect")
    }

    // MARK: 4. a reconnect timer that fires after stop

    func testReconnectTimerFiringAfterStopDoesNotReconnect() async throws {
        let controlRelay = try await makeRelay()
        let stoppedRelay = try await makeRelay()
        let control = makeTransport(to: controlRelay)
        let stopped = makeTransport(to: stoppedRelay)
        let controlEvents = RelayEventLog()
        let stoppedEvents = RelayEventLog()
        control.setRelayEventObserver { controlEvents.append($0) }
        stopped.setRelayEventObserver { stoppedEvents.append($0) }
        try await startLive(control, controlRelay)
        try await startLive(stopped, stoppedRelay)

        // Kill both sockets; wait until BOTH have a 1 s reconnect pending.
        controlRelay.closeAll()
        stoppedRelay.closeAll()
        let pending = await waitUntil(timeout: 3) {
            controlEvents.contains("reconnect #1") && stoppedEvents.contains("reconnect #1")
        }
        XCTAssertTrue(pending, "setup: both transports must have a reconnect timer pending")

        let controlBefore = controlRelay.connections
        stopped.stop()                                 // the timer is still armed
        let stoppedAtStop = stoppedRelay.connections
        try await Task.sleep(for: .seconds(2.5))

        XCTAssertGreaterThan(controlRelay.connections, controlBefore,
                             "control: the pending timer must reconnect a running transport")
        XCTAssertEqual(stoppedRelay.connections, stoppedAtStop,
                       "a reconnect timer firing after stop must not reconnect")
    }

    // MARK: 5. the ping chain (~31 s)

    func testPingChainAfterStopSendsNoPing() async throws {
        let controlRelay = try await makeRelay()
        let stoppedRelay = try await makeRelay()
        let control = makeTransport(to: controlRelay)
        let stopped = makeTransport(to: stoppedRelay)
        try await startLive(control, controlRelay)
        try await startLive(stopped, stoppedRelay)

        await stopAndSettle(stopped)                   // its first ping is armed, not yet sent
        let stoppedConnections = stoppedRelay.connections

        let controlPinged = await waitUntil(timeout: 33) { controlRelay.pings >= 1 }
        XCTAssertTrue(controlPinged, "control: a running transport must ping within interval + jitter")
        XCTAssertEqual(stoppedRelay.pings, 0, "no ping after stop")
        XCTAssertEqual(stoppedRelay.connections, stoppedConnections, "the ping chain must not reconnect")
    }

    // MARK: 6. the epoch-rollover timer

    func testRolloverTimerAfterStopSendsNoReq() async throws {
        // A clock 2 s before an epoch boundary, advancing in real time: the
        // rollover fires at ~5 s (2 s + 3 s grace) and moves the page window.
        let length = NostrInboxTag.epochLength
        let base = (1_789_344_000 / length + 1) * length - 2
        let t0 = Date()
        let clock: @Sendable () -> UInt64 = { base + UInt64(Date().timeIntervalSince(t0)) }

        let controlRelay = try await makeRelay()
        let stoppedRelay = try await makeRelay()
        let control = makeTransport(to: controlRelay, now: clock)
        let stopped = makeTransport(to: stoppedRelay, now: clock)
        try await startLive(control, controlRelay)
        try await startLive(stopped, stoppedRelay)

        let controlBefore = controlRelay.reqCount
        await stopAndSettle(stopped)
        let stoppedAtStop = stoppedRelay.reqCount
        try await Task.sleep(for: .seconds(7))

        XCTAssertGreaterThan(controlRelay.reqCount, controlBefore,
                             "control: the rollover must re-REQ on a running transport")
        XCTAssertEqual(stoppedRelay.reqCount, stoppedAtStop, "no rollover REQ after stop")
    }

    // MARK: 7. MessageRouter.stop() with the real BLE transport

    func testRouterStopSilencesBothRails() async throws {
        let relay = try await makeRelay()
        let nostr = makeTransport(to: relay)
        let ble = BLEMeshTransport()                   // the real type; no peers in the simulator
        let router = MessageRouter(transports: [ble, nostr])
        try await router.start()
        let live = await waitUntil(timeout: 5) { relay.connections >= 1 && relay.reqCount >= 1 }
        XCTAssertTrue(live, "setup: the router's Nostr rail must reach the local relay")

        // Control: BLE has no peer → Tier-2 → the relay gets the EVENT.
        let controlState = await router.send(Envelope(ciphertext: Data([7])), tracked: false,
                                             nostrRecipient: recipientNpub)
        XCTAssertEqual(controlState, .cast, "control: a running router casts to the relay")
        let controlSaw = await waitUntil(timeout: 3) { relay.eventCount == 1 }
        XCTAssertTrue(controlSaw)

        await router.stop()
        try await Task.sleep(for: .milliseconds(300))
        let connectionsAtStop = relay.connections

        let state = await router.send(Envelope(ciphertext: Data([8])), tracked: false,
                                      nostrRecipient: recipientNpub)
        XCTAssertNotEqual(state, .sent, "BLE must not accept after stop")
        XCTAssertNotEqual(state, .cast, "the relay must not accept after stop")
        let direct = await router.publishOverNostr(Envelope(ciphertext: Data([9])), to: recipientNpub)
        XCTAssertNotEqual(direct, .cast)
        do {
            try await ble.sendReconnect(Data([0x00]), toLink: UUID())
            XCTFail("a stopped BLE transport must refuse link-local sends")
        } catch let error as TransportError {
            XCTAssertEqual(error, .notStarted)
        }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(relay.eventCount, 1, "no EVENT after router.stop()")
        XCTAssertEqual(relay.connections, connectionsAtStop, "router.stop() must not reconnect")
    }
}

// MARK: - Test doubles

/// Lines from the transport's DEBUG relay-event observer.
private final class RelayEventLog: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [String]())
    func append(_ line: String) { lock.withLock { $0.append(line) } }
    func contains(_ fragment: String) -> Bool { lock.withLock { $0.contains { $0.contains(fragment) } } }
}

/// A loopback WebSocket "relay": counts connections, REQ / EVENT text frames
/// and pings (answering each ping with a pong), and can drop every connection.
private final class LocalRelay: @unchecked Sendable {
    private struct Counts {
        var connections = 0
        var req = 0
        var event = 0
        var pings = 0
        var live: [NWConnection] = []
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.local-relay")
    private let counts = OSAllocatedUnfairLock(uncheckedState: Counts())
    private(set) var url = URL(string: "ws://127.0.0.1:1")!

    var connections: Int { counts.withLock { $0.connections } }
    var reqCount: Int { counts.withLock { $0.req } }
    var eventCount: Int { counts.withLock { $0.event } }
    var pings: Int { counts.withLock { $0.pings } }

    init() throws {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = false
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.counts.withLock { $0.connections += 1; $0.live.append(conn) }
            conn.start(queue: self.queue)
            self.receive(on: conn)
        }
        let ready: Bool = await withCheckedContinuation { cont in
            let once = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.withLock({ let was = $0; $0 = true; return !was }) { cont.resume(returning: true) }
                case .failed, .cancelled:
                    if once.withLock({ let was = $0; $0 = true; return !was }) { cont.resume(returning: false) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        guard ready, let port = listener.port else { throw URLError(.cannotConnectToHost) }
        url = URL(string: "ws://127.0.0.1:\(port.rawValue)")!
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata {
                switch meta.opcode {
                case .text:
                    let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    self.counts.withLock {
                        if text.hasPrefix("[\"REQ\"") { $0.req += 1 }
                        if text.hasPrefix("[\"EVENT\"") { $0.event += 1 }
                    }
                case .ping:
                    self.counts.withLock { $0.pings += 1 }
                    let pong = NWProtocolWebSocket.Metadata(opcode: .pong)
                    let ctx = NWConnection.ContentContext(identifier: "pong", metadata: [pong])
                    conn.send(content: data ?? Data(), contentContext: ctx, isComplete: true,
                              completion: .contentProcessed { _ in })
                case .close:
                    return
                default:
                    break
                }
            }
            self.receive(on: conn)
        }
    }

    /// Drop every connection without a WebSocket close — the client's receive fails.
    func closeAll() {
        let live = counts.withLock { c -> [NWConnection] in
            let l = c.live
            c.live = []
            return l
        }
        for conn in live { conn.cancel() }
    }

    func stop() {
        listener.cancel()
        closeAll()
    }
}
