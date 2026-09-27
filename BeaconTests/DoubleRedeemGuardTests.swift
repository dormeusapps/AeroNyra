//
//  DoubleRedeemGuardTests.swift
//  BeaconTests
//
//  Pins the double-redeem guard in `PairingService.redeemInvite`: the SAME
//  invite redeemed twice at once (a tapped link and a paste, or two
//  differently encoded strings) establishes ONE session and sends ONE echo;
//  the second attempt is refused with `.redeemInProgress` instead of
//  replacing the session (which broke every later message silently). The
//  guard is released on every exit, so a later redeem is not blocked.
//
//  Same real-stores harness as PairingServiceAlreadyPairedTests.
//

import XCTest
import CryptoKit
import os
@testable import Beacon

@MainActor
final class DoubleRedeemGuardTests: XCTestCase {

    private struct Harness {
        let pairing: PairingService
        let enrollment: EnrollmentService
        let sessionStore: SignalSessionStore
        let ble: RecordingBLETransport
    }

    private func makeHarness() async throws -> Harness {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("double-redeem.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let sessionStore = SignalSessionStore()
        let coordinator = FirstContactCoordinator(store: sessionStore, transport: BLEMeshTransport())
        await coordinator.enableReconnect(agreementPrivate: Curve25519.KeyAgreement.PrivateKey(),
                                          allowlistIdentities: [], verifiedIdentities: [])
        let ble = RecordingBLETransport()
        await coordinator.setRouter(MessageRouter(transports: [ble, RecordingAddressedTransport()]))
        let enrollment = EnrollmentService(
            store: try ContactAllowlistStore(directory: dir, dek: SymmetricKey(size: .bits256),
                                             keychainService: "test.dr.a.\(UUID().uuidString)"),
            pendingStore: try PendingInvitesStore(directory: dir, dek: SymmetricKey(size: .bits256),
                                                  keychainService: "test.dr.p.\(UUID().uuidString)"),
            coordinator: coordinator)
        let pairing = PairingService(sessionStore: sessionStore, coordinator: coordinator,
                                     enrollment: enrollment, ourNostrPublicKey: nil,
                                     inviteEchoAckTimeout: .milliseconds(20))
        pairing.registerInviteEchoTag = { _, _ in }
        pairing.unregisterInviteEchoTag = { _ in }
        return Harness(pairing: pairing, enrollment: enrollment, sessionStore: sessionStore, ble: ble)
    }

    private func makeMinterInvite() throws -> (string: String, bundle: PrekeyBundle) {
        let minter = SignalSessionStore()
        let bundle = try minter.localPrekeyBundle()
        let payload = PairingPayload(bundle: bundle, nostrPublicKey: Data(repeating: 7, count: 32))
        let invite = Invite.mint(payload: payload, now: Int64(Date().timeIntervalSince1970 * 1000))
        return (PairingService.encodeInvite(invite), bundle)
    }

    private func attempt(_ h: Harness, _ s: String) async -> Result<PairingService.RedeemOutcome, Error> {
        do { return .success(try await h.pairing.redeemInvite(s)) } catch { return .failure(error) }
    }

    func testConcurrentRedeemsOfTheSameInviteEstablishOnceAndRefuseTheSecond() async throws {
        let h = try await makeHarness()
        let (invite, bundle) = try makeMinterInvite()
        let rawKey = h.sessionStore.rawPublicKey(of: try h.sessionStore.peerIdentity(from: bundle))

        // Link + paste of the same invite: a differently spelled string.
        async let first = attempt(h, invite)
        async let second = attempt(h, "  \(invite)\n")
        let results = await [first, second]

        let redeemed = results.filter { if case .success(.redeemed) = $0 { return true }; return false }
        let refused = results.filter {
            if case .failure(PairingService.PairError.redeemInProgress) = $0 { return true }; return false
        }
        XCTAssertEqual(redeemed.count, 1, "exactly one redeem goes through")
        XCTAssertEqual(refused.count, 1, "the concurrent one is refused, not run")
        XCTAssertEqual(h.ble.sent.count, 1, "ONE echo — no second session, no second echo")
        XCTAssertTrue(h.enrollment.contains(rawKey))
    }

    func testGuardIsReleasedAfterARedeemFinishes() async throws {
        let h = try await makeHarness()
        let (invite, _) = try makeMinterInvite()
        _ = try await h.pairing.redeemInvite(invite)
        // A later redeem of the same invite is NOT refused as in-progress: it
        // reaches the already-paired branch (the guard was released).
        let again = try await h.pairing.redeemInvite(invite)
        guard case .alreadyPaired = again else { return XCTFail("expected .alreadyPaired, got \(again)") }
    }

    func testGuardIsReleasedAfterAFailedRedeem() async throws {
        let h = try await makeHarness()
        // An invite with NO npub while BLE refuses every send: the redeem
        // passes the guard, then throws (nothing can carry the echo).
        let minter = SignalSessionStore()
        let invite = PairingService.encodeInvite(Invite.mint(
            payload: PairingPayload(bundle: try minter.localPrekeyBundle(), nostrPublicKey: nil),
            now: Int64(Date().timeIntervalSince1970 * 1000)))
        h.ble.failSends = true
        let failed = await attempt(h, invite)
        guard case .failure(let e) = failed, !(e is PairingService.PairError) else {
            return XCTFail("precondition: a downstream failure after the guard, got \(failed)")
        }
        // The SAME invite again, now deliverable: the guard must have been released.
        h.ble.failSends = false
        let again = await attempt(h, invite)
        guard case .success(.redeemed) = again else {
            return XCTFail("the guard must be released on a throw, got \(again)")
        }
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
    let incoming: AsyncStream<(link: UUID, envelope: Envelope)>
    private let cont: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation
    private let log = OSAllocatedUnfairLock(initialState: [Envelope]())
    var sent: [Envelope] { log.withLock { $0 } }

    init() {
        var c: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation!
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
    let incoming: AsyncStream<(link: UUID, envelope: Envelope)>
    private let cont: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation
    private let log = OSAllocatedUnfairLock(initialState: [Published]())
    var published: [Published] { log.withLock { $0 } }
    var publishedTo: [Data] { published.map(\.recipient) }

    init() {
        var c: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation!
        self.incoming = AsyncStream { c = $0 }
        self.cont = c
    }

    func start() async throws {}
    func stop() { cont.finish() }
    func send(_ envelope: Envelope) async throws { throw NostrTransportError.sendRequiresRecipient }
    func relay(_ envelope: Envelope, excludingLinks: Set<UUID>) async {}
    func publish(_ envelope: Envelope, to recipient: Data) async throws {
        log.withLock { $0.append(Published(recipient: recipient, envelopeID: envelope.id)) }
    }
}
