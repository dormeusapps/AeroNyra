// PendingInvitesStoreTests.swift
// BeaconTests
//
// Persistence-layer tests for `PendingInvitesStore` (STEP 7c-2). Mirrors the
// `ContactAllowlistStore` test contract: missing→empty, save/load round-trip,
// corrupt→throws, wrong-DEK→throws, and wipe removes the file + is idempotent.
//
// Each test uses a throwaway temp directory, an ephemeral in-RAM DEK (no
// Keychain), and a unique keychainService so `wipe()`'s DEK-destroy is isolated
// and a no-op on the never-created key.

import XCTest
import CryptoKit
@testable import Beacon

final class PendingInvitesStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-store-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let dir, FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func makeStore(dek: SymmetricKey = SymmetricKey(size: .bits256)) throws -> PendingInvitesStore {
        try PendingInvitesStore(directory: dir,
                                dek: dek,
                                keychainService: "test.pendinginvites.\(UUID().uuidString)")
    }

    private func sampleLedger() -> PendingInvites {
        var led = PendingInvites()
        led.register(id: Data([0x03] + Array(repeating: UInt8(0x00), count: 15)), expiresAt: 1_700_000_123_456)
        led.register(id: Data([0x01] + Array(repeating: UInt8(0xaa), count: 15)), expiresAt: 1_700_000_000_000)
        led.register(id: Data([0x02] + Array(repeating: UInt8(0xff), count: 15)), expiresAt: 1_700_000_600_000)
        return led
    }

    // MARK: - Missing → empty

    func testMissingFileYieldsEmptyLedger() throws {
        let store = try makeStore()
        let led = try store.load()
        XCTAssertEqual(led.count, 0)
        XCTAssertEqual(led.entries, [:])
    }

    // MARK: - Round-trip

    func testSaveThenLoadRoundTrips() throws {
        let dek = SymmetricKey(size: .bits256)
        let a = try makeStore(dek: dek)
        let ledger = sampleLedger()
        try a.save(ledger)

        // A fresh store over the same dir + dek must reproduce the ledger.
        let b = try PendingInvitesStore(directory: dir, dek: dek,
                                        keychainService: "test.pendinginvites.reload")
        XCTAssertEqual(try b.load().entries, ledger.entries)
    }

    func testEmptyLedgerRoundTrips() throws {
        let dek = SymmetricKey(size: .bits256)
        let a = try makeStore(dek: dek)
        try a.save(PendingInvites())
        let b = try PendingInvitesStore(directory: dir, dek: dek,
                                        keychainService: "test.pendinginvites.reload2")
        XCTAssertEqual(try b.load().count, 0)
    }

    // MARK: - Corrupt / wrong key → throws

    func testCorruptFileThrows() throws {
        let store = try makeStore()
        try store.save(sampleLedger())
        // Overwrite the sealed file with too-short garbage (< nonce+tag) so
        // ChaChaPoly.SealedBox(combined:) rejects it.
        let sealURL = dir.appendingPathComponent("pending-invites.v1.seal", isDirectory: false)
        try Data([0x00, 0x01, 0x02, 0x03, 0x04]).write(to: sealURL)
        XCTAssertThrowsError(try store.load())
    }

    func testWrongDEKThrows() throws {
        let a = try makeStore(dek: SymmetricKey(size: .bits256))
        try a.save(sampleLedger())
        // Same file, different DEK → ChaChaPoly.open auth failure.
        let b = try PendingInvitesStore(directory: dir,
                                        dek: SymmetricKey(size: .bits256),
                                        keychainService: "test.pendinginvites.wrongdek")
        XCTAssertThrowsError(try b.load())
    }

    // MARK: - Wipe

    func testWipeRemovesFileAndIsIdempotent() async throws {
        let store = try makeStore()
        try store.save(sampleLedger())
        let sealURL = dir.appendingPathComponent("pending-invites.v1.seal", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealURL.path))

        try await store.wipe()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sealURL.path))
        // Post-wipe load is the first-launch case again.
        XCTAssertEqual(try store.load().count, 0)
        // Second wipe is a no-op, not a throw.
        try await store.wipe()
    }
}
