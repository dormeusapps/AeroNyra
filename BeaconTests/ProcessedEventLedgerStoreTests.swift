//
//  ProcessedEventLedgerStoreTests.swift
//  BeaconTests
//
//  The processed-event ledger store's first tests, and the pin for its erase
//  TOMBSTONE: once `wipe()` has run, this instance refuses every later `save()`
//  — so a transport left alive across an erase cannot recreate the file under
//  the DEK the wipe destroyed.
//
//    • save → load round trip (baseline; nothing covered the store before)
//    • after wipe: file gone, save throws `.wiped`, file stays gone
//    • a FRESH instance on the same directory saves normally (per-instance)
//    • wipe is idempotent
//    • saves racing a wipe: once wipe returns, no file exists, and none appears
//

import XCTest
import CryptoKit
@testable import Beacon

final class ProcessedEventLedgerStoreTests: XCTestCase {

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-store.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeStore(in dir: URL) throws -> ProcessedEventLedgerStore {
        try ProcessedEventLedgerStore(directory: dir,
                                      dek: SymmetricKey(size: .bits256),
                                      keychainService: "test.ledger-store.\(UUID().uuidString)")
    }

    private func ledgerFile(in dir: URL) -> URL {
        dir.appendingPathComponent("nostr-event-ledger.v1.seal", isDirectory: false)
    }

    private func ledger(_ ids: String...) -> ProcessedEventLedger {
        var l = ProcessedEventLedger()
        for id in ids { _ = l.containsOrInsert(id) }
        return l
    }

    func testSaveThenLoadRoundTrips() throws {
        let dir = try makeDirectory()
        let store = try makeStore(in: dir)
        try store.save(ledger("a", "b"))
        let loaded = try store.load()
        XCTAssertTrue(loaded.contains("a"))
        XCTAssertTrue(loaded.contains("b"))
        XCTAssertFalse(loaded.contains("c"))
    }

    func testSaveAfterWipeIsRefusedAndWritesNothing() async throws {
        let dir = try makeDirectory()
        let store = try makeStore(in: dir)
        try store.save(ledger("a"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledgerFile(in: dir).path))

        try await store.wipe()
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerFile(in: dir).path))

        XCTAssertThrowsError(try store.save(ledger("late"))) { error in
            XCTAssertEqual(error as? ProcessedEventLedgerStore.StoreError, .wiped)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerFile(in: dir).path),
                       "a save after wipe must not recreate the file")
    }

    func testFreshInstanceAfterWipeSavesNormally() async throws {
        let dir = try makeDirectory()
        let old = try makeStore(in: dir)
        try old.save(ledger("old"))
        try await old.wipe()

        let fresh = try makeStore(in: dir)              // the new identity's store
        try fresh.save(ledger("new"))
        XCTAssertTrue(try fresh.load().contains("new"), "the tombstone is per instance")
    }

    func testWipeIsIdempotent() async throws {
        let store = try makeStore(in: try makeDirectory())
        try await store.wipe()
        try await store.wipe()
    }

    func testSavesRacingAWipeLeaveNoFile() async throws {
        let dir = try makeDirectory()
        let store = try makeStore(in: dir)
        try store.save(ledger("seed"))

        // Many saves in flight on other threads while the wipe runs.
        let ledgers = (0..<200).map { ledger("id-\($0)") }
        await withTaskGroup(of: Void.self) { group in
            for l in ledgers {
                group.addTask { try? store.save(l) }
            }
            group.addTask { try? await store.wipe() }
        }
        // Whatever interleaving happened, the wipe ran after every save that
        // wrote, and every save after it was refused.
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerFile(in: dir).path))
        XCTAssertThrowsError(try store.save(ledger("after")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerFile(in: dir).path))
    }
}
