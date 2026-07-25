//
//  PairingServiceEpochTests.swift
//  BeaconTests
//
//  Verifies `PairingService.verificationEpoch` — the observable REPAINT SIGNAL
//  for verified-state changes (STEP 7f reactivity).
//
//  The epoch is a repaint trigger ONLY, never truth: views touch it inside their
//  verified checks so SwiftUI registers a dependency, then still re-read
//  `isVerified(_:)` against the live allowlist. These tests pin both halves:
//    • the signal FIRES on every façade mutation that may change verified state
//      (markVerified, QR pairFromScanned, revoke) — unconditionally, including
//      the enrollment layer's silent no-op paths, since the façade cannot tell
//      success from no-op;
//    • the signal never DRIVES truth — bumping it moves no isVerified answer.
//
//  Uses REAL stores over throwaway temp dirs (the genuine seal→write→read path)
//  and a REAL FirstContactCoordinator with reconnect enabled, so pairFromScanned
//  exercises the production onBundle closed-contact gate, not a stub.
//

import XCTest
import CryptoKit
@testable import Beacon

@MainActor
final class PairingServiceEpochTests: XCTestCase {

    // MARK: Fixtures

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pairing-epoch.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private struct Harness {
        let pairing: PairingService
        let enrollment: EnrollmentService
        let sessionStore: SignalSessionStore
        let coordinator: FirstContactCoordinator
    }

    /// A full façade over real stores + a real coordinator. Reconnect is enabled
    /// (empty seed) so `pairFromScanned`'s enroll→onBundle path passes the live
    /// closed-contact gate exactly as in production.
    private func makeHarness() async throws -> Harness {
        let dir = try makeTempDirectory()
        let store = try ContactAllowlistStore(
            directory: dir,
            dek: SymmetricKey(size: .bits256),
            keychainService: "test.pairing-epoch.\(UUID().uuidString)")
        let pendingStore = try PendingInvitesStore(
            directory: dir,
            dek: SymmetricKey(size: .bits256),
            keychainService: "test.pairing-epoch.pending.\(UUID().uuidString)")

        let sessionStore = SignalSessionStore()
        let coordinator = FirstContactCoordinator(store: sessionStore,
                                                  transport: BLEMeshTransport())
        await coordinator.enableReconnect(
            agreementPrivate: Curve25519.KeyAgreement.PrivateKey(),
            allowlistIdentities: [],
            verifiedIdentities: [])

        let enrollment = EnrollmentService(store: store,
                                           pendingStore: pendingStore,
                                           coordinator: coordinator,
                                           nowMillis: { 1_700_000_000_000 })
        let pairing = PairingService(sessionStore: sessionStore,
                                     coordinator: coordinator,
                                     enrollment: enrollment,
                                     ourNostrPublicKey: nil)
        return Harness(pairing: pairing, enrollment: enrollment,
                       sessionStore: sessionStore, coordinator: coordinator)
    }

    /// 32 random bytes — a well-formed raw identity.
    private func makeIdentity() -> Data {
        var b = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &b)
        return Data(b)
    }

    // MARK: The signal fires

    func testMarkVerifiedBumpsEpoch() async throws {
        let h = try await makeHarness()
        let id = makeIdentity()
        try await h.enrollment.enroll(identity: id, verified: false)

        let before = h.pairing.verificationEpoch
        try await h.pairing.markVerified(id)

        XCTAssertEqual(h.pairing.verificationEpoch, before + 1)
        XCTAssertTrue(h.pairing.isVerified(id))
    }

    func testMarkVerifiedNoOpStillBumps() async throws {
        // The enrollment layer no-ops silently on a not-enrolled identity; the
        // façade cannot tell, so it must bump anyway (a spurious repaint is
        // harmless; a missed one is the stale-gate bug).
        let h = try await makeHarness()
        let stranger = makeIdentity()

        let before = h.pairing.verificationEpoch
        try await h.pairing.markVerified(stranger)

        XCTAssertEqual(h.pairing.verificationEpoch, before + 1)
        XCTAssertFalse(h.pairing.isVerified(stranger))   // truth unchanged
    }

    func testPairFromScannedBumpsEpoch() async throws {
        let us = try await makeHarness()
        let peer = try await makeHarness()   // the other phone
        let peerQR = try peer.pairing.makeOurQRString()

        let before = us.pairing.verificationEpoch
        let result = try await us.pairing.pairFromScanned(peerQR)

        XCTAssertGreaterThan(us.pairing.verificationEpoch, before)
        XCTAssertTrue(us.pairing.isVerified(result.rawKey))
    }

    func testRevokeBumpsEpoch() async throws {
        let h = try await makeHarness()
        let id = makeIdentity()
        try await h.enrollment.enroll(identity: id, verified: true)

        let before = h.pairing.verificationEpoch
        try await h.pairing.revoke(id)

        XCTAssertEqual(h.pairing.verificationEpoch, before + 1)
        XCTAssertFalse(h.pairing.isVerified(id))
    }

    // MARK: The signal is never truth

    func testEpochDoesNotDriveVerifiedTruth() async throws {
        let h = try await makeHarness()
        let verified = makeIdentity()
        let unverified = makeIdentity()
        try await h.enrollment.enroll(identity: verified, verified: true)
        try await h.enrollment.enroll(identity: unverified, verified: false)

        // Drive the counter hard via no-op bumps (markVerified on strangers);
        // no isVerified answer may move with it.
        let before = h.pairing.verificationEpoch
        for _ in 0..<5 {
            try await h.pairing.markVerified(makeIdentity())
        }

        XCTAssertEqual(h.pairing.verificationEpoch, before + 5)
        XCTAssertTrue(h.pairing.isVerified(verified))
        XCTAssertFalse(h.pairing.isVerified(unverified))
    }
}
