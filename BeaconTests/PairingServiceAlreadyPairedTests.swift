//
//  PairingServiceAlreadyPairedTests.swift
//  BeaconTests
//
//  Pins the ALREADY-PAIRED branch of `PairingService.redeemInvite` (the
//  read-compare-decide guard, "R4"): when the minter is already enrolled, the
//  redeem is a NO-OP — nothing sent on any transport, no echo tag registered,
//  no session established, nothing written to the allowlist or the invite
//  ledger — and it RETURNS `.alreadyPaired` instead of the same outcome as a
//  real redeem.
//
//  The positive control runs the SAME harness with the minter NOT enrolled and
//  requires exactly one BLE send, so the recorders are proven able to see a
//  send and the R4 pin cannot pass vacuously. Since Option A Part 2 it also
//  requires the no-ack relay fallback: the SAME envelope, published once,
//  inside one echo-tag register/unregister bracket (wait injected at 50 ms).
//
//  Uses REAL stores over throwaway temp dirs, a REAL FirstContactCoordinator,
//  and a REAL MessageRouter over two recording transports (BLE + addressed).
//  The allowlist clock ADVANCES on every read, so any re-enroll would change
//  `pairedAt` and break allowlist equality — "nothing written" is observable.
//

import XCTest
import CryptoKit
import os
@testable import Beacon

@MainActor
final class PairingServiceAlreadyPairedTests: XCTestCase {

    // MARK: Fixtures

    private struct Harness {
        let pairing: PairingService
        let enrollment: EnrollmentService
        let sessionStore: SignalSessionStore
        let allowlistStore: ContactAllowlistStore
        let pendingStore: PendingInvitesStore
        let ble: RecordingBLETransport
        let nostr: RecordingAddressedTransport
        let hooks: EchoTagHookRecorder
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pairing-already-paired.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeHarness() async throws -> Harness {
        let dir = try makeTempDirectory()
        let allowlistStore = try ContactAllowlistStore(
            directory: dir,
            dek: SymmetricKey(size: .bits256),
            keychainService: "test.already-paired.\(UUID().uuidString)")
        let pendingStore = try PendingInvitesStore(
            directory: dir,
            dek: SymmetricKey(size: .bits256),
            keychainService: "test.already-paired.pending.\(UUID().uuidString)")

        let sessionStore = SignalSessionStore()
        let coordinator = FirstContactCoordinator(store: sessionStore,
                                                  transport: BLEMeshTransport())
        await coordinator.enableReconnect(
            agreementPrivate: Curve25519.KeyAgreement.PrivateKey(),
            allowlistIdentities: [],
            verifiedIdentities: [])

        let ble = RecordingBLETransport()
        let nostr = RecordingAddressedTransport()
        await coordinator.setRouter(MessageRouter(transports: [ble, nostr]))

        // Advancing clock: every enroll stamps a distinct pairedAt.
        let tick = OSAllocatedUnfairLock(initialState: Int64(1_700_000_000_000))
        let enrollment = EnrollmentService(store: allowlistStore,
                                           pendingStore: pendingStore,
                                           coordinator: coordinator,
                                           nowMillis: {
                                               tick.withLock { $0 += 1_000; return $0 }
                                           })
        let pairing = PairingService(sessionStore: sessionStore,
                                     coordinator: coordinator,
                                     enrollment: enrollment,
                                     ourNostrPublicKey: nil,
                                     inviteEchoAckTimeout: .milliseconds(50))
        let hooks = EchoTagHookRecorder()
        pairing.registerInviteEchoTag = { _, _ in hooks.noteRegistered() }
        pairing.unregisterInviteEchoTag = { _ in hooks.noteUnregistered() }

        return Harness(pairing: pairing, enrollment: enrollment,
                       sessionStore: sessionStore,
                       allowlistStore: allowlistStore, pendingStore: pendingStore,
                       ble: ble, nostr: nostr, hooks: hooks)
    }

    /// A live invite string minted by a separate "other phone" identity, with
    /// an npub so the redeem path would register the echo tag if it got there.
    private func makeMinterInvite() throws -> (string: String, bundle: PrekeyBundle) {
        let minter = SignalSessionStore()
        let bundle = try minter.localPrekeyBundle()
        let payload = PairingPayload(bundle: bundle,
                                     nostrPublicKey: Data(repeating: 7, count: 32))
        let invite = Invite.mint(payload: payload,
                                 now: Int64(Date().timeIntervalSince1970 * 1000))
        return (PairingService.encodeInvite(invite), bundle)
    }

    // MARK: R4 — already enrolled: no-op, reported distinctly

    func testAlreadyEnrolledRedeemIsNoOpAndReturnsAlreadyPaired() async throws {
        let h = try await makeHarness()
        let (inviteString, bundle) = try makeMinterInvite()
        let peer = try h.sessionStore.peerIdentity(from: bundle)
        let rawKey = h.sessionStore.rawPublicKey(of: peer)

        // A healthy, VERIFIED pairing already exists (K1).
        try await h.enrollment.enroll(identity: rawKey, verified: true)
        let allowlistBefore = try h.allowlistStore.load()
        let pendingBefore = try h.pendingStore.load()

        let outcome = try await h.pairing.redeemInvite(inviteString)

        // Returned outcome: .alreadyPaired with the minter's hint.
        guard case .alreadyPaired(let hint) = outcome else {
            return XCTFail("expected .alreadyPaired, got \(outcome)")
        }
        XCTAssertEqual(hint, String(peer.userIDHex.prefix(6)).uppercased())

        // Nothing sent — on either rail — and no echo tag ever registered.
        XCTAssertTrue(h.ble.sent.isEmpty, "no BLE send on the already-paired branch")
        XCTAssertTrue(h.nostr.publishedTo.isEmpty, "no relay publish on the already-paired branch")
        XCTAssertEqual(h.hooks.registered, 0, "echo tag must not be registered")
        XCTAssertEqual(h.hooks.unregistered, 0, "the defer must not be reached")

        // No session established with the minter (the coordinator was never called).
        XCTAssertFalse(h.sessionStore.hasSession(with: peer))

        // Nothing written: allowlist (clock advances, so a re-enroll would differ)
        // and invite ledger are exactly as before; the contact stays VERIFIED.
        XCTAssertEqual(try h.allowlistStore.load(), allowlistBefore)
        XCTAssertEqual(try h.pendingStore.load(), pendingBefore)
        XCTAssertTrue(h.enrollment.isVerified(rawKey), "K1: verified stays true")
    }

    // MARK: Positive control — not enrolled: a real redeem, and the recorders see it

    func testNotEnrolledRedeemSendsEchoAndReturnsRedeemed() async throws {
        let h = try await makeHarness()
        let (inviteString, bundle) = try makeMinterInvite()
        let peer = try h.sessionStore.peerIdentity(from: bundle)
        let rawKey = h.sessionStore.rawPublicKey(of: peer)

        let outcome = try await h.pairing.redeemInvite(inviteString)

        guard case .redeemed(let result) = outcome else {
            return XCTFail("expected .redeemed, got \(outcome)")
        }
        XCTAssertEqual(result.rawKey, rawKey)

        // Option A, Part 2: the echo goes out exactly once on BLE. No minter is
        // here to ack, so after the injected wait the SAME envelope falls back
        // to the relay, inside one register → publish → unregister bracket.
        XCTAssertEqual(h.ble.sent.count, 1, "the recorder must see the real echo send")
        let delivery = await h.pairing.lastInviteEchoDelivery?.value
        XCTAssertEqual(delivery, .relayFallbackSent)
        XCTAssertEqual(h.nostr.published.map(\.recipient), [Data(repeating: 7, count: 32)])
        XCTAssertEqual(h.nostr.published.first?.envelopeID, h.ble.sent.first?.id,
                       "the fallback is the SAME envelope, so the minter dedups it")
        XCTAssertEqual(h.hooks.registered, 1)
        XCTAssertEqual(h.hooks.unregistered, 1)

        // Session established and the minter enrolled UNVERIFIED.
        XCTAssertTrue(h.sessionStore.hasSession(with: peer))
        XCTAssertTrue(h.enrollment.contains(rawKey))
        XCTAssertFalse(h.enrollment.isVerified(rawKey))
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
    func send(_ envelope: Envelope) async throws { log.withLock { $0.append(envelope) } }
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
