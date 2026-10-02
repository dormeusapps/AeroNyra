//
//  InviteEchoFallbackTests.swift
//  BeaconTests
//
//  Option A, Part 2 — the REDEEMER sends the invite echo over BLE, waits for
//  the minter's BLE ack, and publishes the SAME echo to the relay only if no
//  ack arrives in time.
//
//    P1  a REAL minter coordinator, joined by an in-process BLE pipe, acks the
//        echo (Part 1) → the wait resolves `.acked`, nothing touches the relay.
//    P2  no ack → exactly one fallback, the SAME envelope, inside one
//        register → publish → unregister bracket.
//    P3  an ack for the echo's id from ANOTHER identity is ignored → the
//        fallback still fires (forged-ack suppression).
//    P4  a genuine ack arriving AFTER the fallback is a no-op: no second publish.
//    P5  less than the full wait left in the invite window → no wait, the
//        fallback publishes at once.
//    P6  echo-tag hook not wired → no publish at all (never a pair-tag publish).
//    P7  cancelled (erase) → nothing published, no registration.
//
//  Real stores, real coordinators, a real MessageRouter; only the radio and the
//  relay are recording doubles. Waits are injected so the suite stays fast.
//

import XCTest
import CryptoKit
import os
@testable import Beacon

@MainActor
final class InviteEchoFallbackTests: XCTestCase {

    // MARK: Fixtures

    private let minterNpub = Data(repeating: 7, count: 32)

    private struct Redeemer {
        let pairing: PairingService
        let coordinator: FirstContactCoordinator
        let store: SignalSessionStore
        let log: EchoEventLog
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-fallback.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A redeemer façade over `ble` plus a logging relay rail. `wireHooks: false`
    /// leaves the echo-tag hooks nil (P6).
    private func makeRedeemer(ble: MeshTransport, wait: Duration,
                              wireHooks: Bool = true) async throws -> Redeemer {
        let dir = try makeTempDirectory()
        let store = SignalSessionStore()
        let coordinator = FirstContactCoordinator(store: store, transport: BLEMeshTransport())
        await coordinator.enableReconnect(
            agreementPrivate: Curve25519.KeyAgreement.PrivateKey(),
            allowlistIdentities: [],
            verifiedIdentities: [])
        let log = EchoEventLog()
        await coordinator.setRouter(MessageRouter(transports: [ble, LoggingRelayTransport(log: log)]))
        let enrollment = EnrollmentService(
            store: try ContactAllowlistStore(
                directory: dir, dek: SymmetricKey(size: .bits256),
                keychainService: "test.echo-fallback.\(UUID().uuidString)"),
            pendingStore: try PendingInvitesStore(
                directory: dir, dek: SymmetricKey(size: .bits256),
                keychainService: "test.echo-fallback.pending.\(UUID().uuidString)"),
            coordinator: coordinator)
        let pairing = PairingService(sessionStore: store,
                                     coordinator: coordinator,
                                     enrollment: enrollment,
                                     ourNostrPublicKey: nil,
                                     inviteEchoAckTimeout: wait)
        if wireHooks {
            pairing.registerInviteEchoTag = { npub, id in log.append(.register(npub: npub, inviteID: id)) }
            pairing.unregisterInviteEchoTag = { npub in log.append(.unregister(npub: npub)) }
        }
        return Redeemer(pairing: pairing, coordinator: coordinator, store: store, log: log)
    }

    /// A live invite from `minter`, carrying the minter npub. `nowMillis`
    /// overrides the mint time (P5).
    private func makeInvite(from minter: SignalSessionStore,
                            nowMillis: Int64? = nil) throws -> (string: String, invite: Invite) {
        let payload = PairingPayload(bundle: try minter.localPrekeyBundle(), nostrPublicKey: minterNpub)
        let invite = Invite.mint(payload: payload,
                                 now: nowMillis ?? Int64(Date().timeIntervalSince1970 * 1000))
        return (PairingService.encodeInvite(invite), invite)
    }

    /// Require exactly register(inviteID) → publish(same echo) → unregister.
    private func assertOneBracketedFallback(_ events: [EchoEventLog.Event], inviteID: Data,
                                            echoID: MessageID?,
                                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(events, [.register(npub: minterNpub, inviteID: inviteID),
                                .publish(npub: minterNpub, envelopeID: echoID ?? MessageID.random()),
                                .unregister(npub: minterNpub)],
                       "exactly one bracketed fallback of the SAME envelope", file: file, line: line)
    }

    // MARK: P1 — a real minter acks over the BLE pipe: no relay

    func testRealMinterAckResolvesTheWaitAndNothingTouchesTheRelay() async throws {
        let toMinter = PipeBLETransport()
        let r = try await makeRedeemer(ble: toMinter, wait: .seconds(2))

        let minterStore = SignalSessionStore()
        let minter = FirstContactCoordinator(store: minterStore, transport: BLEMeshTransport())
        let toRedeemer = PipeBLETransport()
        await minter.setRouter(MessageRouter(transports: [toRedeemer]))
        toMinter.connect(to: minter)
        toRedeemer.connect(to: r.coordinator)

        let (string, _) = try makeInvite(from: minterStore)
        guard case .redeemed = try await r.pairing.redeemInvite(string) else {
            return XCTFail("expected .redeemed")
        }
        let delivery = await r.pairing.lastInviteEchoDelivery?.value

        XCTAssertEqual(delivery, .acked, "the minter's BLE ack must resolve the wait")
        XCTAssertEqual(toMinter.sent.count, 1, "the echo, once, over BLE")
        XCTAssertEqual(toRedeemer.sent.count, 1, "the minter's ack, once, over BLE")
        XCTAssertTrue(r.log.events.isEmpty, "no registration, no relay publish: \(r.log.events)")
    }

    // MARK: P2 — no ack: one bracketed fallback of the same envelope

    func testNoAckFallsBackOnceWithTheSameEnvelope() async throws {
        let ble = PipeBLETransport()                       // never connected: accepts, delivers nowhere
        let r = try await makeRedeemer(ble: ble, wait: .milliseconds(50))
        let (string, invite) = try makeInvite(from: SignalSessionStore())

        _ = try await r.pairing.redeemInvite(string)
        let delivery = await r.pairing.lastInviteEchoDelivery?.value

        XCTAssertEqual(delivery, .relayFallbackSent)
        XCTAssertEqual(ble.sent.count, 1)
        assertOneBracketedFallback(r.log.events, inviteID: invite.id, echoID: ble.sent.first?.id)
    }

    // MARK: P3 — an ack from another identity is ignored

    func testAckFromAnotherIdentityIsIgnoredAndTheFallbackStillFires() async throws {
        let ble = PipeBLETransport()
        let r = try await makeRedeemer(ble: ble, wait: .milliseconds(500))
        let (string, invite) = try makeInvite(from: SignalSessionStore())

        _ = try await r.pairing.redeemInvite(string)
        let echoID = try XCTUnwrap(ble.sent.first?.id)

        // A different identity holding a session with the redeemer seals an ack
        // naming the echo's (cleartext-visible) envelope id.
        let stranger = SignalSessionStore()
        let forged = try stranger.establishSession(from: try r.store.localPrekeyBundle())
            .seal(MessagePayload.deliveryAck(wireID: echoID, hops: 0).sealedPlaintext())
        await r.coordinator.receive(Envelope(ciphertext: forged))

        let delivery = await r.pairing.lastInviteEchoDelivery?.value
        XCTAssertEqual(delivery, .relayFallbackSent, "a wrong-sender ack must not suppress the fallback")
        assertOneBracketedFallback(r.log.events, inviteID: invite.id, echoID: echoID)
    }

    // MARK: P4 — a genuine ack after the fallback is a no-op

    func testGenuineAckAfterTheFallbackIsANoOp() async throws {
        let ble = PipeBLETransport()
        let r = try await makeRedeemer(ble: ble, wait: .milliseconds(50))
        let minterStore = SignalSessionStore()
        let (string, invite) = try makeInvite(from: minterStore)

        _ = try await r.pairing.redeemInvite(string)
        let delivery = await r.pairing.lastInviteEchoDelivery?.value
        XCTAssertEqual(delivery, .relayFallbackSent)
        let echo = try XCTUnwrap(ble.sent.first)

        // The minter opens the echo late and acks it after the fallback fired.
        let (redeemerAtMinter, _) = try minterStore.openInbound(echo.ciphertext)
        let lateAck = try minterStore.session(with: redeemerAtMinter)
            .seal(MessagePayload.deliveryAck(wireID: echo.id, hops: 0).sealedPlaintext())
        await r.coordinator.receive(Envelope(ciphertext: lateAck))

        assertOneBracketedFallback(r.log.events, inviteID: invite.id, echoID: echo.id)
    }

    // MARK: P5 — the invite window is nearly closed: no wait

    func testClosingInviteWindowSkipsTheWait() async throws {
        let ble = PipeBLETransport()
        let r = try await makeRedeemer(ble: ble, wait: .seconds(30))
        // Minted so expiry + skew lands 10 s from now: live, but under the 30 s wait.
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let (string, invite) = try makeInvite(
            from: SignalSessionStore(),
            nowMillis: now - Invite.defaultTTLMillis - Invite.defaultSkewMillis + 10_000)

        let start = ContinuousClock.now
        _ = try await r.pairing.redeemInvite(string)
        let delivery = await r.pairing.lastInviteEchoDelivery?.value
        let elapsed = ContinuousClock.now - start

        XCTAssertEqual(delivery, .relayFallbackSent)
        XCTAssertLessThan(elapsed, .seconds(5), "must not have waited the 30 s")
        assertOneBracketedFallback(r.log.events, inviteID: invite.id, echoID: ble.sent.first?.id)
    }

    // MARK: P6 — echo-tag hook not wired: no publish

    func testUnwiredEchoTagHookSkipsTheFallback() async throws {
        let ble = PipeBLETransport()
        let r = try await makeRedeemer(ble: ble, wait: .milliseconds(50), wireHooks: false)
        let (string, _) = try makeInvite(from: SignalSessionStore())

        _ = try await r.pairing.redeemInvite(string)
        let delivery = await r.pairing.lastInviteEchoDelivery?.value

        XCTAssertEqual(delivery, .skippedNoHook)
        XCTAssertTrue(r.log.events.isEmpty, "never a pair-tag publish: \(r.log.events)")
    }

    // MARK: P7 — cancelled (erase): nothing published

    func testCancelledDeliveryPublishesNothing() async throws {
        let ble = PipeBLETransport()
        let r = try await makeRedeemer(ble: ble, wait: .milliseconds(300))
        let (string, _) = try makeInvite(from: SignalSessionStore())

        _ = try await r.pairing.redeemInvite(string)
        r.pairing.cancelInviteEchoDeliveries()
        let delivery = await r.pairing.lastInviteEchoDelivery?.value

        XCTAssertEqual(delivery, .cancelled)
        XCTAssertTrue(r.log.events.isEmpty, "no registration, no publish: \(r.log.events)")
    }
}

// MARK: - Test doubles

/// One ordered log shared by the echo-tag hooks and the relay rail.
private final class EchoEventLog: @unchecked Sendable {
    enum Event: Equatable {
        case register(npub: Data, inviteID: Data)
        case publish(npub: Data, envelopeID: MessageID)
        case unregister(npub: Data)
    }
    private let lock = OSAllocatedUnfairLock(initialState: [Event]())
    var events: [Event] { lock.withLock { $0 } }
    func append(_ e: Event) { lock.withLock { $0.append(e) } }
}

/// A BLE rail that ACCEPTS every send (a radio handoff) and records it; once
/// connected, it also delivers each envelope to the target coordinator's
/// `receive` asynchronously — an in-process radio between two coordinators.
private final class PipeBLETransport: MeshTransport, @unchecked Sendable {
    let kind: TransportKind = .ble
    let incoming: AsyncStream<(link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)>
    private let cont: AsyncStream<(link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)>.Continuation
    private let state = OSAllocatedUnfairLock<(target: FirstContactCoordinator?, sent: [Envelope])>(
        initialState: (target: nil, sent: []))
    var sent: [Envelope] { state.withLock { $0.sent } }

    init() {
        var c: AsyncStream<(link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)>.Continuation!
        self.incoming = AsyncStream { c = $0 }
        self.cont = c
    }

    func connect(to target: FirstContactCoordinator) { state.withLock { $0.target = target } }

    func start() async throws {}
    func stop() { cont.finish() }
    func send(_ envelope: Envelope) async throws {
        let target = state.withLock { s -> FirstContactCoordinator? in
            s.sent.append(envelope)
            return s.target
        }
        if let target { Task { await target.receive(envelope) } }
    }
    func relay(_ envelope: Envelope, excludingLinks: Set<UUID>) async {}
}

/// A relay rail that logs each publish (recipient + envelope id) into the
/// shared ordered log and accepts it.
private final class LoggingRelayTransport: MeshTransport, AddressedTransport, @unchecked Sendable {
    let kind: TransportKind = .internet
    let incoming: AsyncStream<(link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)>
    private let cont: AsyncStream<(link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)>.Continuation
    private let log: EchoEventLog

    init(log: EchoEventLog) {
        self.log = log
        var c: AsyncStream<(link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)>.Continuation!
        self.incoming = AsyncStream { c = $0 }
        self.cont = c
    }

    func start() async throws {}
    func stop() { cont.finish() }
    func send(_ envelope: Envelope) async throws { throw NostrTransportError.sendRequiresRecipient }
    func relay(_ envelope: Envelope, excludingLinks: Set<UUID>) async {}
    func publish(_ envelope: Envelope, to recipient: Data) async throws {
        log.append(.publish(npub: recipient, envelopeID: envelope.id))
    }
}
