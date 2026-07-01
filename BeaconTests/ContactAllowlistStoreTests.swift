//
//  ContactAllowlistStoreTests.swift
//  BeaconTests
//
//  STEP 7a-2 — the sealed at-rest ContactAllowlist store.
//
//  Exercises the real seal/open path (ChaChaPoly + a fresh SymmetricKey) against
//  a throwaway temp directory. The DEK Keychain service is a per-test random
//  string, so `wipe()`'s key-destroy can never touch a production Keychain item.
//
//  Pins the locked failure posture: missing file → empty (first launch), but a
//  wrong key / corrupt / tampered file THROWS rather than silently emptying the
//  admission set.
//
//  XCTest only.
//

import XCTest
import CryptoKit
@testable import Beacon

final class ContactAllowlistStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("allowlist-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
    }

    private func makeStore(dek: SymmetricKey) throws -> ContactAllowlistStore {
        try ContactAllowlistStore(directory: dir,
                                  dek: dek,
                                  keychainService: "test.allowlist.\(UUID().uuidString)")
    }

    private func sampleAllowlist() -> ContactAllowlist {
        var a = ContactAllowlist()
        a.enroll(identity: Data((0..<32).map { UInt8($0) }), at: 1_719_849_600_000, verified: true)
        a.enroll(identity: Data(repeating: 0xAB, count: 32), at: 42, verified: false)
        return a
    }

    // MARK: - Round-trip

    func testMissingFileLoadsEmpty() throws {
        let store = try makeStore(dek: SymmetricKey(size: .bits256))
        XCTAssertEqual(try store.load().count, 0)
    }

    func testSaveThenLoadRoundTripsAcrossInstances() throws {
        let key = SymmetricKey(size: .bits256)
        let original = sampleAllowlist()

        try makeStore(dek: key).save(original)

        // A fresh instance over the same directory + key must recover the set.
        let reloaded = try makeStore(dek: key).load()
        XCTAssertEqual(reloaded, original)
    }

    func testSaveOverwritesPreviousSet() throws {
        let key = SymmetricKey(size: .bits256)
        let store = try makeStore(dek: key)

        try store.save(sampleAllowlist())          // 2 contacts
        var smaller = ContactAllowlist()
        smaller.enroll(identity: Data(repeating: 0x01, count: 32), at: 7, verified: true)
        try store.save(smaller)                     // 1 contact

        let reloaded = try makeStore(dek: key).load()
        XCTAssertEqual(reloaded, smaller)
        XCTAssertEqual(reloaded.count, 1)
    }

    // MARK: - Failure posture (throw loud, never silently empty)

    func testWrongKeyThrows() throws {
        try makeStore(dek: SymmetricKey(size: .bits256)).save(sampleAllowlist())
        let wrongKeyStore = try makeStore(dek: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try wrongKeyStore.load(),
                             "a wrong DEK must fail the AEAD open, not yield an empty set")
    }

    func testCorruptFileThrows() throws {
        let key = SymmetricKey(size: .bits256)
        _ = try makeStore(dek: key)   // ensures the directory exists
        let fileURL = dir.appendingPathComponent("contact-allowlist.v1.seal")
        try Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01]).write(to: fileURL)

        XCTAssertThrowsError(try makeStore(dek: key).load(),
                             "a non-sealed-box file must throw, not decode to empty")
    }

    func testTamperedCiphertextThrows() throws {
        let key = SymmetricKey(size: .bits256)
        try makeStore(dek: key).save(sampleAllowlist())

        let fileURL = dir.appendingPathComponent("contact-allowlist.v1.seal")
        var bytes = try Data(contentsOf: fileURL)
        bytes[bytes.count - 1] ^= 0xFF          // flip a tag/ciphertext byte
        try bytes.write(to: fileURL)

        XCTAssertThrowsError(try makeStore(dek: key).load(),
                             "a tampered sealed file must fail authentication")
    }

    // MARK: - Wipe

    func testWipeRemovesFileAndReloadsEmpty() async throws {
        let key = SymmetricKey(size: .bits256)
        let store = try makeStore(dek: key)
        try store.save(sampleAllowlist())

        try await store.wipe()

        let fileURL = dir.appendingPathComponent("contact-allowlist.v1.seal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(try makeStore(dek: key).load().count, 0)
    }

    func testWipeIsIdempotent() async throws {
        let store = try makeStore(dek: SymmetricKey(size: .bits256))
        try await store.wipe()               // nothing saved yet
        try await store.wipe()               // second wipe must not throw
    }
}
