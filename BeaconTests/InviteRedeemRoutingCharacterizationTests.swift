//
//  InviteRedeemRoutingCharacterizationTests.swift
//  BeaconTests
//
//  CHARACTERIZATION — pins TODAY's redeem routing on the paths Option A Part 2
//  must NOT change, so a regression there is caught by a test that predates
//  the change. Written against HEAD e324362 and green there. The Part 2 commit
//  must not modify this file; if it has to, that is a regression signal.
//
//    T1  remote redeem (no BLE link): BLE attempted once, then EXACTLY
//        register(npub, inviteID) → publish(npub, echo) → unregister(npub);
//        .redeemed, minter enrolled unverified, session established.
//    T2  no BLE link AND the relay fails: throws, minter NOT enrolled, and the
//        same register → publish → unregister sequence (clearance still runs).
//    T3  no npub in the invite and no BLE link: throws, zero registrations,
//        zero publishes.
//    T4  the coordinator's `.ack` arm still confirms a real delivery: a sealed
//        `.ack` for a tracked id, received through `receive`, yields `.delivered`.
//
//  The already-paired branch is pinned separately (PairingServiceAlreadyPairedTests).
//  The BLE-accepted redeem is deliberately NOT pinned here: Part 2 changes it.
//

import XCTest
import CryptoKit
import os
@testable import Beacon

@MainActor
final class InviteRedeemRoutingCharacterizationTests: XCTestCase {

    // MARK: Fixtures

    private struct Harness {
        let pairing: PairingService
        let enrollment: EnrollmentService
        let sessionStore: SignalSessionStore
        let ble: FailingBLETransport
        let log: RoutingEventLog
    }

    private let minterNpub = Data(repeating: 7, count: 32)

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redeem-routing.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A redeemer façade whose BLE rail has NO link (always `noReachablePeers`)
    /// and whose relay rail records into `log` — failing if `relayFails`.
    private func makeHarness(relayFails: Bool = false) async throws -> Harness {
        let dir = try makeTempDirectory()
        let sessionStore = SignalSessionStore()
        let coordinator = FirstContactCoordinator(store: sessionStore, transport: BLEMeshTransport())
        await coordinator.enableReconnect(
            agreementPrivate: Curve25519.KeyAgreement.PrivateKey(),
            allowlistIdentities: [],
            verifiedIdentities: [])
        let log = RoutingEventLog()
        let ble = FailingBLETransport()
        let relay = LoggingAddressedTransport(log: log, fails: relayFails)
        await coordinator.setRouter(MessageRouter(transports: [ble, relay]))

        let enrollment = EnrollmentService(
            store: try ContactAllowlistStore(
                directory: dir, dek: SymmetricKey(size: .bits256),
                keychainService: "test.redeem-routing.\(UUID().uuidString)"),
            pendingStore: try PendingInvitesStore(
                directory: dir, dek: SymmetricKey(size: .bits256),
                keychainService: "test.redeem-routing.pending.\(UUID().uuidString)"),
            coordinator: coordinator)
        let pairing = PairingService(sessionStore: sessionStore,
                                     coordinator: coordinator,
                                     enrollment: enrollment,
                                     ourNostrPublicKey: nil)
        pairing.registerInviteEchoTag = { npub, id in log.append(.register(npub: npub, inviteID: id)) }
        pairing.unregisterInviteEchoTag = { npub in log.append(.unregister(npub: npub)) }
        return Harness(pairing: pairing, enrollment: enrollment,
                       sessionStore: sessionStore, ble: ble, log: log)
    }

    /// A live invite from a separate "other phone"; `withNpub` controls whether
    /// the payload carries the minter's Nostr key.
    private func makeMinterInvite(withNpub: Bool) throws -> (string: String, invite: Invite) {
        let minter = SignalSessionStore()
        let payload = PairingPayload(bundle: try minter.localPrekeyBundle(),
                                     nostrPublicKey: withNpub ? minterNpub : nil)
        let invite = Invite.mint(payload: payload,
                                 now: Int64(Date().timeIntervalSince1970 * 1000))
        return (PairingService.encodeInvite(invite), invite)
    }

    // MARK: T1 — remote redeem

    func testRemoteRedeemPublishesOnceInsideTheEchoTagRegistration() async throws {
        let h = try await makeHarness()
        let (string, invite) = try makeMinterInvite(withNpub: true)
        let peer = try h.sessionStore.peerIdentity(from: invite.payload.bundle)
        let rawKey = h.sessionStore.rawPublicKey(of: peer)

        let outcome = try await h.pairing.redeemInvite(string)

        guard case .redeemed = outcome else { return XCTFail("expected .redeemed, got \(outcome)") }
        XCTAssertEqual(h.ble.attempts, 1, "BLE is tried first")
        let events = h.log.events
        XCTAssertEqual(events.count, 3, "register → publish → unregister, nothing else: \(events)")
        XCTAssertEqual(events.first, .register(npub: minterNpub, inviteID: invite.id))
        guard events.count == 3, case .publish(let npub, _) = events[1] else {
            return XCTFail("second event must be the relay publish: \(events)")
        }
        XCTAssertEqual(npub, minterNpub)
        XCTAssertEqual(events.last, .unregister(npub: minterNpub))
        XCTAssertTrue(h.enrollment.contains(rawKey))
        XCTAssertFalse(h.enrollment.isVerified(rawKey))
        XCTAssertTrue(h.sessionStore.hasSession(with: peer))
    }

    // MARK: T2 — no link and the relay fails

    func testRemoteRedeemWithRelayFailureThrowsAndDoesNotEnroll() async throws {
        let h = try await makeHarness(relayFails: true)
        let (string, invite) = try makeMinterInvite(withNpub: true)
        let rawKey = h.sessionStore.rawPublicKey(of: try h.sessionStore.peerIdentity(from: invite.payload.bundle))

        do {
            _ = try await h.pairing.redeemInvite(string)
            XCTFail("both rails failed: redeem must throw")
        } catch {}

        XCTAssertFalse(h.enrollment.contains(rawKey), "a failed echo must not enroll")
        let events = h.log.events
        XCTAssertEqual(events.count, 3, "register → publish → unregister: \(events)")
        XCTAssertEqual(events.first, .register(npub: minterNpub, inviteID: invite.id))
        guard events.count == 3, case .publish = events[1] else {
            return XCTFail("the relay publish was attempted: \(events)")
        }
        XCTAssertEqual(events.last, .unregister(npub: minterNpub), "clearance runs on the throw")
    }

    // MARK: T3 — no npub and no link

    func testRedeemWithoutMinterNpubAndNoLinkThrowsWithoutTouchingTheRelay() async throws {
        let h = try await makeHarness()
        let (string, invite) = try makeMinterInvite(withNpub: false)
        let rawKey = h.sessionStore.rawPublicKey(of: try h.sessionStore.peerIdentity(from: invite.payload.bundle))

        do {
            _ = try await h.pairing.redeemInvite(string)
            XCTFail("no BLE link and no npub: nothing can carry the echo")
        } catch {}

        XCTAssertEqual(h.ble.attempts, 1)
        XCTAssertTrue(h.log.events.isEmpty, "no registration, no publish: \(h.log.events)")
        XCTAssertFalse(h.enrollment.contains(rawKey))
    }

    // MARK: T4 — the `.ack` arm still confirms a real delivery

    func testAckArmConfirmsATrackedDelivery() async throws {
        // Redeemer-side coordinator with a real router.
        let redeemerStore = SignalSessionStore()
        let coordinator = FirstContactCoordinator(store: redeemerStore, transport: BLEMeshTransport())
        let router = MessageRouter(transports: [FailingBLETransport()])
        await coordinator.setRouter(router)

        // Two real sessions: redeemer → minter prekey message, minter opens it.
        let minterStore = SignalSessionStore()
        let toMinter = try redeemerStore.establishSession(from: try minterStore.localPrekeyBundle())
        let first = try toMinter.seal(MessagePayload.text(Data("hi".utf8)).sealedPlaintext())
        let (redeemerAtMinter, _) = try minterStore.openInbound(first)

        // The redeemer is tracking a message; the minter acks it.
        let tracked = MessageID.random()
        await router.beginTracking(of: tracked)
        let ackSealed = try minterStore.session(with: redeemerAtMinter)
            .seal(MessagePayload.deliveryAck(wireID: tracked, hops: 0).sealedPlaintext())

        await coordinator.receive(Envelope(ciphertext: ackSealed))

        let update = await firstUpdate(from: router.deliveryUpdates, timeout: .seconds(5))
        XCTAssertEqual(update, DeliveryUpdate(id: tracked, state: .delivered))
    }

    /// First element of `stream`, or nil if none arrives within `timeout`.
    private func firstUpdate(from stream: AsyncStream<DeliveryUpdate>,
                             timeout: Duration) async -> DeliveryUpdate? {
        await withTaskGroup(of: DeliveryUpdate?.self) { group in
            group.addTask {
                var it = stream.makeAsyncIterator()
                return await it.next()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Test doubles

/// One ordered log shared by the echo-tag hooks and the relay rail, so the
/// register → publish → unregister SEQUENCE is observable.
private final class RoutingEventLog: @unchecked Sendable {
    enum Event: Equatable {
        case register(npub: Data, inviteID: Data)
        case publish(npub: Data, envelopeID: MessageID)
        case unregister(npub: Data)
    }
    private let lock = OSAllocatedUnfairLock(initialState: [Event]())
    var events: [Event] { lock.withLock { $0 } }
    func append(_ e: Event) { lock.withLock { $0.append(e) } }
}

/// A BLE rail with no link: counts each attempt, then throws `noReachablePeers`.
private final class FailingBLETransport: MeshTransport, @unchecked Sendable {
    let kind: TransportKind = .ble
    let incoming: AsyncStream<(link: UUID, envelope: Envelope)>
    private let cont: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var attempts: Int { count.withLock { $0 } }

    init() {
        var c: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation!
        self.incoming = AsyncStream { c = $0 }
        self.cont = c
    }

    func start() async throws {}
    func stop() { cont.finish() }
    func send(_ envelope: Envelope) async throws {
        count.withLock { $0 += 1 }
        throw TransportError.noReachablePeers
    }
    func relay(_ envelope: Envelope, excludingLinks: Set<UUID>) async {}
}

/// A relay rail that logs each publish into the shared log; throws if `fails`.
private final class LoggingAddressedTransport: MeshTransport, AddressedTransport, @unchecked Sendable {
    let kind: TransportKind = .internet
    let incoming: AsyncStream<(link: UUID, envelope: Envelope)>
    private let cont: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation
    private let log: RoutingEventLog
    private let fails: Bool

    init(log: RoutingEventLog, fails: Bool) {
        self.log = log
        self.fails = fails
        var c: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation!
        self.incoming = AsyncStream { c = $0 }
        self.cont = c
    }

    func start() async throws {}
    func stop() { cont.finish() }
    func send(_ envelope: Envelope) async throws { throw NostrTransportError.sendRequiresRecipient }
    func relay(_ envelope: Envelope, excludingLinks: Set<UUID>) async {}
    func publish(_ envelope: Envelope, to recipient: Data) async throws {
        log.append(.publish(npub: recipient, envelopeID: envelope.id))
        if fails { throw NostrTransportError.notConnected }
    }
}
