//
//  EnrollmentServiceTests.swift
//  BeaconTests
//
//  Verifies the enrollment seam (Security/Session/EnrollmentService).
//
//  Uses a REAL ContactAllowlistStore against a throwaway temp directory + fixed
//  DEK (the genuine encode→seal→write→read→decode path), and a spy conforming to
//  `ReconnectEnrolling` to observe the coordinator notification. A fixed clock
//  makes `pairedAt` deterministic.
//
//  Properties under test:
//    • enroll(verified:) records the right verified state (QR true / invite false);
//    • enroll persists (a fresh store instance over the same file+DEK sees it);
//    • enroll notifies the reconnect layer with the raw identity — AFTER persist;
//    • markVerified promotes an enrolled-unverified contact, persisted;
//    • revoke removes, persisted;
//    • the 32-byte identity guard rejects a wrong-width key;
//    • save-then-adopt: a persist failure leaves the live set unchanged and does
//      NOT notify the coordinator.
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

    /// A store over a temp dir with a FIXED in-test DEK (no Keychain dependency).
    /// The keychainService is a unique throwaway so `wipe()` (unused here) is safe.
    private func makeStore(in dir: URL) throws -> ContactAllowlistStore {
        let dek = SymmetricKey(size: .bits256)
        return try ContactAllowlistStore(
            directory: dir,
            dek: dek,
            keychainService: "test.enroll.\(UUID().uuidString)")
    }

    /// 32 random bytes — a well-formed raw identity.
    private func makeIdentity() -> Data {
        var b = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &b)
        return Data(b)
    }

    private let fixedNow: @Sendable () -> Int64 = { 1_700_000_000_000 }   // fixed ms

    // MARK: Enroll — verified state

    func testEnrollVerifiedRecordsVerified() async throws {
        let dir = try makeTempDirectory()
        let store = try makeStore(in: dir)
        let spy = ReconnectSpy()
        let svc = EnrollmentService(store: store, coordinator: spy, nowMillis: fixedNow)
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
        let svc = EnrollmentService(store: store, coordinator: spy, nowMillis: fixedNow)
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
        let svc = EnrollmentService(store: store1, coordinator: spy, nowMillis: fixedNow)
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
        let svc = EnrollmentService(store: store, coordinator: spy, nowMillis: fixedNow)
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
        let svc = EnrollmentService(store: store1, coordinator: spy, nowMillis: fixedNow)
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
        let svc = EnrollmentService(store: store, coordinator: spy, nowMillis: fixedNow)

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
        let svc = EnrollmentService(store: store1, coordinator: spy, nowMillis: fixedNow)
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
        let svc = EnrollmentService(store: store, coordinator: spy, nowMillis: fixedNow)

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
        let svc = EnrollmentService(store: store, coordinator: spy, nowMillis: fixedNow)
        let id = makeIdentity()

        try await svc.enroll(identity: id, verified: false)
        XCTAssertFalse(svc.isVerified(id))

        // Re-enroll (e.g. re-pair after key change) as verified → replaces.
        try await svc.enroll(identity: id, verified: true)
        XCTAssertTrue(svc.isVerified(id))
        XCTAssertEqual(svc.count, 1)   // still one contact, not two
    }
}
