//
//  InviteEchoRelayRetryTests.swift
//  BeaconTests
//
//  Pins option (a): an invite-echo relay publish that NO socket took
//  (`.waitingForRange` — the pre-reconnect window after a resume) is retried
//  ONCE after a pause; each attempt is its own register → publish →
//  unregister bracket; `.notDelivered` is terminal (never retried); on the
//  background fallback, an erase that cancels during the pause publishes
//  nothing more. Retry pause injected at 30 ms.
//

import XCTest
import CryptoKit
import os
@testable import Beacon

@MainActor
final class InviteEchoRelayRetryTests: XCTestCase {

    private struct Harness {
        let pairing: PairingService
        let enrollment: EnrollmentService
        let sessionStore: SignalSessionStore
        let ble: RecordingBLETransport
        let nostr: RecordingAddressedTransport
        let hooks: EchoTagHookRecorder
    }

    private func makeHarness() async throws -> Harness {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("echo-retry.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let sessionStore = SignalSessionStore()
        let coordinator = FirstContactCoordinator(store: sessionStore, transport: BLEMeshTransport())
        await coordinator.enableReconnect(agreementPrivate: Curve25519.KeyAgreement.PrivateKey(),
                                          allowlistIdentities: [], verifiedIdentities: [])
        let ble = RecordingBLETransport()
        let nostr = RecordingAddressedTransport()
        await coordinator.setRouter(MessageRouter(transports: [ble, nostr]))
        let enrollment = EnrollmentService(
            store: try ContactAllowlistStore(directory: dir, dek: SymmetricKey(size: .bits256),
                                             keychainService: "test.retry.a.\(UUID().uuidString)"),
            pendingStore: try PendingInvitesStore(directory: dir, dek: SymmetricKey(size: .bits256),
                                                  keychainService: "test.retry.p.\(UUID().uuidString)"),
            coordinator: coordinator)
        let pairing = PairingService(sessionStore: sessionStore, coordinator: coordinator,
                                     enrollment: enrollment, ourNostrPublicKey: nil,
                                     inviteEchoAckTimeout: .milliseconds(20),
                                     inviteEchoRelayRetryDelay: .milliseconds(30))
        let hooks = EchoTagHookRecorder()
        pairing.registerInviteEchoTag = { _, _ in hooks.noteRegistered() }
        pairing.unregisterInviteEchoTag = { _ in hooks.noteUnregistered() }
        return Harness(pairing: pairing, enrollment: enrollment, sessionStore: sessionStore,
                       ble: ble, nostr: nostr, hooks: hooks)
    }

    private func makeMinterInvite() throws -> (string: String, rawKey: (SignalSessionStore) throws -> Data) {
        let minter = SignalSessionStore()
        let bundle = try minter.localPrekeyBundle()
        let invite = Invite.mint(payload: PairingPayload(bundle: bundle, nostrPublicKey: Data(repeating: 7, count: 32)),
                                 now: Int64(Date().timeIntervalSince1970 * 1000))
        return (PairingService.encodeInvite(invite), { $0.rawPublicKey(of: try $0.peerIdentity(from: bundle)) })
    }

    // MARK: Redeem path (no BLE link → relay now)

    func testRelayMissedOnceThenSucceedsOnTheRetry() async throws {
        let h = try await makeHarness()
        h.ble.failSends = true
        h.nostr.failFirst.withLock { $0 = 1 }
        let (s, raw) = try makeMinterInvite()

        let outcome = try await h.pairing.redeemInvite(s)

        guard case .redeemed = outcome else { return XCTFail("expected .redeemed, got \(outcome)") }
        XCTAssertEqual(h.nostr.attempts.withLock { $0 }, 2)
        XCTAssertEqual(h.nostr.published.count, 1, "published exactly once")
        XCTAssertEqual(h.hooks.registered, 2, "each attempt is its own bracket")
        XCTAssertEqual(h.hooks.unregistered, 2)
        XCTAssertTrue(h.enrollment.contains(try raw(h.sessionStore)))
    }

    func testBothAttemptsMissedThrowsAndDoesNotEnroll() async throws {
        let h = try await makeHarness()
        h.ble.failSends = true
        h.nostr.failFirst.withLock { $0 = 5 }
        let (s, raw) = try makeMinterInvite()

        do { _ = try await h.pairing.redeemInvite(s); XCTFail("both attempts missed: must throw") } catch {}

        XCTAssertEqual(h.nostr.attempts.withLock { $0 }, 2, "exactly ONE retry, no more")
        XCTAssertEqual(h.hooks.registered, 2)
        XCTAssertEqual(h.hooks.unregistered, 2)
        XCTAssertFalse(h.enrollment.contains(try raw(h.sessionStore)))
    }

    func testNotDeliveredIsTerminalAndNeverRetried() async throws {
        let h = try await makeHarness()
        h.ble.failSends = true
        h.nostr.untaggable = true
        let (s, _) = try makeMinterInvite()

        do { _ = try await h.pairing.redeemInvite(s); XCTFail("must throw") } catch {}

        XCTAssertEqual(h.nostr.attempts.withLock { $0 }, 1, ".notDelivered is terminal")
        XCTAssertEqual(h.hooks.registered, 1)
    }

    // MARK: Background fallback (BLE sent, no ack)

    func testFallbackSucceedsOnTheRetry() async throws {
        let h = try await makeHarness()
        h.nostr.failFirst.withLock { $0 = 1 }
        let (s, _) = try makeMinterInvite()

        _ = try await h.pairing.redeemInvite(s)
        let delivery = await h.pairing.lastInviteEchoDelivery?.value

        XCTAssertEqual(delivery, .relayFallbackSent)
        XCTAssertEqual(h.nostr.attempts.withLock { $0 }, 2)
        XCTAssertEqual(h.nostr.published.count, 1)
        XCTAssertEqual(h.hooks.registered, 2)
        XCTAssertEqual(h.hooks.unregistered, 2)
    }

    func testEraseCancellingDuringThePausePublishesNothingMore() async throws {
        let h = try await makeHarness()
        h.nostr.failFirst.withLock { $0 = 5 }
        let (s, _) = try makeMinterInvite()

        _ = try await h.pairing.redeemInvite(s)
        // Wait until the FIRST fallback attempt has been made, then cancel (an
        // erase) while the retry pause is running.
        while h.nostr.attempts.withLock({ $0 }) < 1 { await Task.yield() }
        h.pairing.cancelInviteEchoDeliveries()
        let delivery = await h.pairing.lastInviteEchoDelivery?.value

        XCTAssertEqual(delivery, .cancelled)
        XCTAssertEqual(h.nostr.attempts.withLock { $0 }, 1, "no attempt after the cancel")
        XCTAssertEqual(h.hooks.registered, 1)
        XCTAssertEqual(h.hooks.unregistered, 1)
    }
}

// MARK: - Test doubles

/// Counts calls to PairingService's echo-tag hooks.
private final class EchoTagHookRecorder: @unchecked Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: (registered: 0, unregistered: 0))
    var registered: Int { counts.withLock { $0.registered } }
    var unregistered: Int { counts.withLock { $0.unregistered } }
    func noteRegistered() { counts.withLock { $0.registered += 1 } }
    func noteUnregistered() { counts.withLock { $0.unregistered += 1 } }
}

/// A BLE transport that ACCEPTS every send and records it.
private final class RecordingBLETransport: MeshTransport, @unchecked Sendable {
    let kind: TransportKind = .ble
    let incoming: AsyncStream<(link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)>
    private let cont: AsyncStream<(link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)>.Continuation
    private let log = OSAllocatedUnfairLock(initialState: [Envelope]())
    var sent: [Envelope] { log.withLock { $0 } }

    init() {
        var c: AsyncStream<(link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)>.Continuation!
        self.incoming = AsyncStream { c = $0 }
        self.cont = c
    }

    func start() async throws {}
    func stop() { cont.finish() }
    var failSends = false
    func send(_ envelope: Envelope) async throws {
        if failSends { throw TransportError.noReachablePeers }
        log.withLock { $0.append(envelope) }
    }
    func relay(_ envelope: Envelope, excludingLinks: Set<UUID>) async {}
}

/// An addressed (relay) transport that records every publish: recipient and
/// the envelope id (so "same envelope as BLE" is checkable).
private final class RecordingAddressedTransport: MeshTransport, AddressedTransport, @unchecked Sendable {
    struct Published: Equatable, Sendable {
        let recipient: Data
        let envelopeID: MessageID
    }
    let kind: TransportKind = .internet
    let incoming: AsyncStream<(link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)>
    private let cont: AsyncStream<(link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)>.Continuation
    private let log = OSAllocatedUnfairLock(initialState: [Published]())
    var published: [Published] { log.withLock { $0 } }
    var publishedTo: [Data] { published.map(\.recipient) }

    init() {
        var c: AsyncStream<(link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)>.Continuation!
        self.incoming = AsyncStream { c = $0 }
        self.cont = c
    }

    func start() async throws {}
    func stop() { cont.finish() }
    func send(_ envelope: Envelope) async throws { throw NostrTransportError.sendRequiresRecipient }
    func relay(_ envelope: Envelope, excludingLinks: Set<UUID>) async {}
    /// Publishes that throw `.notConnected` (router → `.waitingForRange`) before one succeeds.
    let failFirst = OSAllocatedUnfairLock(initialState: 0)
    /// Every publish throws `.untaggableRecipient` (router → terminal `.notDelivered`).
    var untaggable = false
    let attempts = OSAllocatedUnfairLock(initialState: 0)
    func publish(_ envelope: Envelope, to recipient: Data) async throws {
        attempts.withLock { $0 += 1 }
        if untaggable { throw NostrTransportError.untaggableRecipient }
        let fail = failFirst.withLock { n -> Bool in if n > 0 { n -= 1; return true }; return false }
        if fail { throw NostrTransportError.notConnected }
        log.withLock { $0.append(Published(recipient: recipient, envelopeID: envelope.id)) }
    }
}
