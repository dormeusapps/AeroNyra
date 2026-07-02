//
//  EnrollmentServiceTests.swift
//  BeaconTests
//
//  Verifies the enrollment seam (Security/Session/EnrollmentService).
//
//  Uses a REAL ContactAllowlistStore + PendingInvitesStore against throwaway temp
//  directories + fixed DEKs (the genuine encode→seal→write→read→decode path), and a
//  spy conforming to `ReconnectEnrolling` to observe the coordinator notification.
//  A fixed clock makes `pairedAt`/expiry deterministic; a TestClock drives expiry.
//
//  Properties under test:
//    • enroll(verified:) records the right verified state (QR true / invite false);
//    • enroll persists (a fresh store instance over the same file+DEK sees it);
//    • enroll notifies the reconnect layer with the raw identity — AFTER persist;
//    • markVerified promotes an enrolled-unverified contact, persisted;
//    • revoke removes, persisted;
//    • the 32-byte identity guard rejects a wrong-width key;
//    • re-enroll replaces the record;
//    • INVITE LEDGER (7c-2): mint registers + persists; a valid echo burns + enrolls
//      unverified + notifies; replay/unknown/expired echoes return false and enroll
//      no one; a malformed redeemer identity throws BEFORE any burn; construction
//      prunes an expired seeded ledger.
//

import XCTest
import CryptoKit
@testable import Beacon

@MainActor
final class EnrollmentServiceTests: XCTestCase {

    // MARK: Spy

    /// Records every identity the seam told the reconnect layer about, in order.
    private actor ReconnectSpy: ReconnectEnrolling {
        private(set) var added: [Data] = []
        func addReconnectContact(rawIdentity: Data) async { added.append(rawIdentity) }
        func addedCount() -> Int { added.count }
        func contains(_ id: Data) -> Bool { added.contains(id) }
    }

    // MARK: Fixtures

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enroll.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// An allowlist store over a temp dir with a FIXED in-test DEK (no Keychain).
    /// The keychainService is a unique throwaway so `wipe()` (unused here) is safe.
    private func makeStore(in dir: URL) throws -> ContactAllowlistStore {
        let dek = SymmetricKey(size: .bits256)
        return try ContactAllowlistStore(
            directory: dir,
            dek: dek,
            keychainService: "test.enroll.\(UUID().uuidString)")
    }

    /// A pending-invite store over a temp dir with a throwaway DEK + service. Most
    /// tests don't reload it, so a random DEK is fine; the mint-persistence test
    /// builds its own with a known DEK so a second instance can reload.
    private func makePendingStore(in dir: URL) throws -> PendingInvitesStore {
        let dek = SymmetricKey(size: .bits256)
        return try PendingInvitesStore(
            directory: dir,
            dek: dek,
            keychainService: "test.pending.\(UUID().uuidString)")
    }

    /// 32 random bytes — a well-formed raw identity.
    private func makeIdentity() -> Data {
        var b = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &b)
        return Data(b)
    }

    /// A minimal well-formed PairingPayload (contents are opaque to the ledger;
    /// mint only wraps it in an Invite, so a stub bundle + absent Nostr key suffice).
    private func makePayload() -> PairingPayload {
        PairingPayload(bundle: PrekeyBundle(data: Data([0xDE, 0xAD, 0xBE, 0xEF])),
                       nostrPublicKey: nil)
    }

    private let fixedNow: @Sendable () -> Int64 = { 1_700_000_000_000 }   // fixed ms

    // MARK: Enroll — verified state

    func testEnrollVerifiedRecordsVerified() async throws {
        let dir = try makeTempDirectory()
        let store = try makeStore(in: dir)
        let spy = ReconnectSpy()
        let svc = EnrollmentService(store: store, pendingStore: try makePendingStore(in: dir),
                                    coordinator: spy, nowMillis: fixedNow)
        let id = makeIdentity()

        try await svc.enroll(identity: id, verified: true)

        XCTAssertTrue(svc.contains(id))
        XCTAssertTrue(svc.isVerified(id))
        XCTAssertEqual(svc.count, 1)
    }

    func testEnrollUnverifiedRecordsUnverified() async throws {
        let dir = try makeTempDirectory()
        let store = try makeStore(in: dir)
        let spy = ReconnectSpy()
        let svc = EnrollmentService(store: store, pendingStore: try makePendingStore(in: dir),
                                    coordinator: spy, nowMillis: fixedNow)
        let id = makeIdentity()

        try await svc.enroll(identity: id, verified: false)

        XCTAssertTrue(svc.contains(id))
        XCTAssertFalse(svc.isVerified(id))
    }

    // MARK: Enroll — persistence (save-then-adopt actually wrote)

    func testEnrollPersistsAcrossStoreInstances() async throws {
        let dir = try makeTempDirectory()
        let dek = SymmetricKey(size: .bits256)
        let svcName = "test.enroll.\(UUID().uuidString)"

        // First store + service: enroll.
        let store1 = try ContactAllowlistStore(directory: dir, dek: dek, keychainService: svcName)
        let spy = ReconnectSpy()
        let svc = EnrollmentService(store: store1, pendingStore: try makePendingStore(in: dir),
                                    coordinator: spy, nowMillis: fixedNow)
        let id = makeIdentity()
        try await svc.enroll(identity: id, verified: true)

        // A SECOND store over the same file + DEK must decode the persisted set.
        let store2 = try ContactAllowlistStore(directory: dir, dek: dek, keychainService: svcName)
        let reloaded = try store2.load()
        XCTAssertTrue(reloaded.contains(identity: id))
        XCTAssertTrue(reloaded.isVerified(identity: id))
    }

    // MARK: Enroll — notifies the reconnect layer, with the raw identity

    func testEnrollNotifiesCoordinator() async throws {
        let dir = try makeTempDirectory()
        let store = try makeStore(in: dir)
        let spy = ReconnectSpy()
        let svc = EnrollmentService(store: store, pendingStore: try makePendingStore(in: dir),
                                    coordinator: spy, nowMillis: fixedNow)
        let id = makeIdentity()

        try await svc.enroll(identity: id, verified: true)

        let count = await spy.addedCount()
        let told = await spy.contains(id)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(told)
    }

    // MARK: markVerified promotes + persists

    func testMarkVerifiedPromotesAndPersists() async throws {
        let dir = try makeTempDirectory()
        let dek = SymmetricKey(size: .bits256)
        let svcName = "test.enroll.\(UUID().uuidString)"
        let store1 = try ContactAllowlistStore(directory: dir, dek: dek, keychainService: svcName)
        let spy = ReconnectSpy()
        let svc = EnrollmentService(store: store1, pendingStore: try makePendingStore(in: dir),
                                    coordinator: spy, nowMillis: fixedNow)
        let id = makeIdentity()

        try await svc.enroll(identity: id, verified: false)   // invite → unverified
        XCTAssertFalse(svc.isVerified(id))

        try await svc.markVerified(identity: id)              // SAS confirm
        XCTAssertTrue(svc.isVerified(id))

        // Persisted: a fresh store sees verified.
        let store2 = try ContactAllowlistStore(directory: dir, dek: dek, keychainService: svcName)
        XCTAssertTrue(try store2.load().isVerified(identity: id))

        // markVerified does NOT re-notify the reconnect layer (enroll already did).
        let count = await spy.addedCount()
        XCTAssertEqual(count, 1)
    }

    func testMarkVerifiedOnUnpairedIsNoOp() async throws {
        let dir = try makeTempDirectory()
        let store = try makeStore(in: dir)
        let spy = ReconnectSpy()
        let svc = EnrollmentService(store: store, pendingStore: try makePendingStore(in: dir),
                                    coordinator: spy, nowMillis: fixedNow)

        // Not enrolled — must not throw, must not create anything.
        try await svc.markVerified(identity: makeIdentity())
        XCTAssertEqual(svc.count, 0)
    }

    // MARK: revoke removes + persists

    func testRevokeRemovesAndPersists() async throws {
        let dir = try makeTempDirectory()
        let dek = SymmetricKey(size: .bits256)
        let svcName = "test.enroll.\(UUID().uuidString)"
        let store1 = try ContactAllowlistStore(directory: dir, dek: dek, keychainService: svcName)
        let spy = ReconnectSpy()
        let svc = EnrollmentService(store: store1, pendingStore: try makePendingStore(in: dir),
                                    coordinator: spy, nowMillis: fixedNow)
        let id = makeIdentity()

        try await svc.enroll(identity: id, verified: true)
        XCTAssertTrue(svc.contains(id))

        try await svc.revoke(identity: id)
        XCTAssertFalse(svc.contains(id))
        XCTAssertEqual(svc.count, 0)

        // Persisted: a fresh store no longer sees it.
        let store2 = try ContactAllowlistStore(directory: dir, dek: dek, keychainService: svcName)
        XCTAssertFalse(try store2.load().contains(identity: id))
    }

    // MARK: Guards

    func testEnrollRejectsNonStandardIdentity() async throws {
        let dir = try makeTempDirectory()
        let store = try makeStore(in: dir)
        let spy = ReconnectSpy()
        let svc = EnrollmentService(store: store, pendingStore: try makePendingStore(in: dir),
                                    coordinator: spy, nowMillis: fixedNow)

        let shortID = Data(repeating: 0xAB, count: 16)   // not 32 bytes
        do {
            try await svc.enroll(identity: shortID, verified: true)
            XCTFail("expected nonStandardIdentity")
        } catch EnrollmentService.EnrollmentError.nonStandardIdentity(let n) {
            XCTAssertEqual(n, 16)
        }
        XCTAssertEqual(svc.count, 0)
        let told = await spy.addedCount()
        XCTAssertEqual(told, 0)   // a rejected enroll never touches the coordinator
    }

    // MARK: Re-enroll replaces

    func testReEnrollReplacesRecord() async throws {
        let dir = try makeTempDirectory()
        let store = try makeStore(in: dir)
        let spy = ReconnectSpy()
        let svc = EnrollmentService(store: store, pendingStore: try makePendingStore(in: dir),
                                    coordinator: spy, nowMillis: fixedNow)
        let id = makeIdentity()

        try await svc.enroll(identity: id, verified: false)
        XCTAssertFalse(svc.isVerified(id))

        // Re-enroll (e.g. re-pair after key change) as verified → replaces.
        try await svc.enroll(identity: id, verified: true)
        XCTAssertTrue(svc.isVerified(id))
        XCTAssertEqual(svc.count, 1)   // still one contact, not two
    }

    // MARK: Invite ledger (7c-2) — mint

    func testMintInviteRegistersAndPersists() async throws {
        let dir = try makeTempDirectory()
        let allow = try makeStore(in: dir)
        // Known DEK + service so a second pending store can reload the sealed file.
        let dek = SymmetricKey(size: .bits256)
        let svcName = "test.pending.\(UUID().uuidString)"
        let pStore1 = try PendingInvitesStore(directory: dir, dek: dek, keychainService: svcName)
        let spy = ReconnectSpy()
        let svc = EnrollmentService(store: allow, pendingStore: pStore1,
                                    coordinator: spy, nowMillis: fixedNow)

        let invite = try await svc.mintInvite(payload: makePayload())

        XCTAssertEqual(svc.pendingInviteCount, 1)
        XCTAssertTrue(svc.isInvitePending(invite.id))
        // No enrollment happens at mint.
        XCTAssertEqual(svc.count, 0)
        let told = await spy.addedCount()
        XCTAssertEqual(told, 0)

        // Persisted: a fresh pending store over the same dir + DEK sees the id.
        let pStore2 = try PendingInvitesStore(directory: dir, dek: dek, keychainService: svcName)
        let reloaded = try pStore2.load()
        XCTAssertEqual(reloaded.entries[invite.id], invite.expiresAt)
    }

    // MARK: Invite ledger (7c-2) — redeem

    func testRedeemValidEchoBurnsAndEnrollsUnverified() async throws {
        let dir = try makeTempDirectory()
        let spy = ReconnectSpy()
        let svc = EnrollmentService(store: try makeStore(in: dir),
                                    pendingStore: try makePendingStore(in: dir),
                                    coordinator: spy, nowMillis: fixedNow)
        let invite = try await svc.mintInvite(payload: makePayload())
        XCTAssertEqual(svc.pendingInviteCount, 1)

        let redeemer = makeIdentity()
        let ok = try await svc.redeemEcho(inviteID: invite.id, redeemerIdentity: redeemer)

        XCTAssertTrue(ok)
        XCTAssertTrue(svc.contains(redeemer))
        XCTAssertFalse(svc.isVerified(redeemer))          // unverified, pending SAS
        XCTAssertFalse(svc.isInvitePending(invite.id))    // burned
        XCTAssertEqual(svc.pendingInviteCount, 0)

        let count = await spy.addedCount()
        let told = await spy.contains(redeemer)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(told)
    }

    func testRedeemReplayReturnsFalseAndDoesNotDoubleEnroll() async throws {
        let dir = try makeTempDirectory()
        let spy = ReconnectSpy()
        let svc = EnrollmentService(store: try makeStore(in: dir),
                                    pendingStore: try makePendingStore(in: dir),
                                    coordinator: spy, nowMillis: fixedNow)
        let invite = try await svc.mintInvite(payload: makePayload())
        let redeemer = makeIdentity()

        let first = try await svc.redeemEcho(inviteID: invite.id, redeemerIdentity: redeemer)
        let second = try await svc.redeemEcho(inviteID: invite.id, redeemerIdentity: redeemer)

        XCTAssertTrue(first)
        XCTAssertFalse(second)               // replay of a burned id — no-op
        XCTAssertEqual(svc.count, 1)         // still exactly one contact
        let count = await spy.addedCount()
        XCTAssertEqual(count, 1)             // enrolled exactly once
    }

    func testRedeemUnknownEchoReturnsFalse() async throws {
        let dir = try makeTempDirectory()
        let spy = ReconnectSpy()
        let svc = EnrollmentService(store: try makeStore(in: dir),
                                    pendingStore: try makePendingStore(in: dir),
                                    coordinator: spy, nowMillis: fixedNow)
        // An id that was never minted.
        let bogus = Data(repeating: 0x5A, count: Invite.idByteCount)
        let ok = try await svc.redeemEcho(inviteID: bogus, redeemerIdentity: makeIdentity())

        XCTAssertFalse(ok)
        XCTAssertEqual(svc.count, 0)
        let count = await spy.addedCount()
        XCTAssertEqual(count, 0)
    }

    func testRedeemExpiredEchoReturnsFalse() async throws {
        let dir = try makeTempDirectory()
        let spy = ReconnectSpy()
        let clock = TestClock(1_700_000_000_000)
        let svc = EnrollmentService(store: try makeStore(in: dir),
                                    pendingStore: try makePendingStore(in: dir),
                                    coordinator: spy, nowMillis: { clock.now() })
        // Short TTL, then advance the clock past expiry + skew.
        let invite = try await svc.mintInvite(payload: makePayload(), ttlMillis: 1_000)
        clock.advance(by: 1_000 + Invite.defaultSkewMillis + 1)

        let ok = try await svc.redeemEcho(inviteID: invite.id, redeemerIdentity: makeIdentity())

        XCTAssertFalse(ok)
        XCTAssertEqual(svc.count, 0)         // no enroll on an expired echo
    }

    func testRedeemRejectsNonStandardIdentityBeforeBurning() async throws {
        let dir = try makeTempDirectory()
        let spy = ReconnectSpy()
        let svc = EnrollmentService(store: try makeStore(in: dir),
                                    pendingStore: try makePendingStore(in: dir),
                                    coordinator: spy, nowMillis: fixedNow)
        let invite = try await svc.mintInvite(payload: makePayload())
        let shortID = Data(repeating: 0xAB, count: 16)   // not 32 bytes

        do {
            _ = try await svc.redeemEcho(inviteID: invite.id, redeemerIdentity: shortID)
            XCTFail("expected nonStandardIdentity")
        } catch EnrollmentService.EnrollmentError.nonStandardIdentity(let n) {
            XCTAssertEqual(n, 16)
        }
        // The invite must NOT have been burned by a rejected identity.
        XCTAssertTrue(svc.isInvitePending(invite.id))
        XCTAssertEqual(svc.pendingInviteCount, 1)
        XCTAssertEqual(svc.count, 0)
        let told = await spy.addedCount()
        XCTAssertEqual(told, 0)
    }

    // MARK: Invite ledger (7c-2) — construction pruning

    func testConstructionPrunesExpiredPending() async throws {
        let dir = try makeTempDirectory()
        let spy = ReconnectSpy()

        // Seed a ledger with an id that already expired well before the fixed clock.
        var seed = PendingInvites()
        let expiredID = Data(repeating: 0x11, count: Invite.idByteCount)
        seed.register(id: expiredID, expiresAt: 1_600_000_000_000)   // << fixedNow

        let svc = EnrollmentService(store: try makeStore(in: dir),
                                    pendingStore: try makePendingStore(in: dir),
                                    coordinator: spy,
                                    initialPending: seed,
                                    nowMillis: fixedNow)

        XCTAssertEqual(svc.pendingInviteCount, 0)          // pruned at construction
        XCTAssertFalse(svc.isInvitePending(expiredID))
    }
}

// MARK: - Test clock (advanceable, thread-safe)

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Int64
    init(_ start: Int64) { self.t = start }
    func now() -> Int64 { lock.lock(); defer { lock.unlock() }; return t }
    func advance(by delta: Int64) { lock.lock(); t += delta; lock.unlock() }
}
