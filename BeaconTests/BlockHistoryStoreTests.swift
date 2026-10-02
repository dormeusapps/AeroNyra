//
//  BlockHistoryStoreTests.swift
//  BeaconTests
//
//  Pins `BlockHistoryStore` (v68 §5a, commit C2 — not yet wired): block
//  periods per contact and refused envelope ids survive a relaunch; a missing
//  file is empty and readable; a present-but-unreadable file boots empty,
//  marks the store unreadable, refuses to record a period, silently ignores a
//  refused id, and is never written (byte-identical afterwards); the refused
//  ids are a FIFO capped at 8,192; wipe destroys the key before the file.
//

import XCTest
import CryptoKit
@testable import Beacon

final class BlockHistoryStoreTests: XCTestCase {

    private let alice = Data(repeating: 0xA1, count: 32)
    private let bob = Data(repeating: 0xB0, count: 32)

    private func id(_ n: Int) -> Data {
        var d = Data(count: 16)
        withUnsafeBytes(of: UInt64(n).bigEndian) { d.replaceSubrange(8..<16, with: $0) }
        return d
    }

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("block-history.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private func fileURL(_ dir: URL) -> URL {
        dir.appendingPathComponent(BlockHistoryStore.fileName)
    }

    private func store(_ dir: URL, _ key: SymmetricKey, capacity: Int = BlockHistoryStore.defaultCapacity,
                       saveDelay: TimeInterval = 3600) throws -> BlockHistoryStore {
        try BlockHistoryStore(directory: dir, dek: key, keychainService: "test.bh.\(UUID().uuidString)",
                              capacity: capacity, saveDelay: saveDelay)
    }

    // MARK: - round trip

    func testRoundTrip() throws {
        let dir = try makeDir()
        let key = SymmetricKey(size: .bits256)
        let s = try store(dir, key)
        try s.recordPeriod(rawKey: alice, blockedAt: 1_000, unblockedAt: 2_000)
        s.recordRefused(id(1))
        try s.flush()

        let reloaded = try store(dir, key)
        XCTAssertTrue(reloaded.isReadable)
        XCTAssertEqual(reloaded.periods(for: alice), [BlockPeriod(blockedAt: 1_000, unblockedAt: 2_000)])
        XCTAssertTrue(reloaded.isRefused(id(1)))
        XCTAssertFalse(reloaded.isRefused(id(2)))
    }

    func testSeveralPeriodsForOneContact() throws {
        let dir = try makeDir()
        let key = SymmetricKey(size: .bits256)
        let s = try store(dir, key)
        try s.recordPeriod(rawKey: alice, blockedAt: 1_000, unblockedAt: 2_000)
        try s.recordPeriod(rawKey: alice, blockedAt: 5_000, unblockedAt: 9_000)
        try s.recordPeriod(rawKey: alice, blockedAt: 5_000, unblockedAt: 9_000)   // retried: no duplicate
        let expected = [BlockPeriod(blockedAt: 1_000, unblockedAt: 2_000),
                        BlockPeriod(blockedAt: 5_000, unblockedAt: 9_000)]
        XCTAssertEqual(s.periods(for: alice), expected)
        XCTAssertEqual(try store(dir, key).periods(for: alice), expected)
    }

    func testSeparateContactsStaySeparate() throws {
        let dir = try makeDir()
        let key = SymmetricKey(size: .bits256)
        let s = try store(dir, key)
        try s.recordPeriod(rawKey: alice, blockedAt: 1_000, unblockedAt: 2_000)
        try s.recordPeriod(rawKey: bob, blockedAt: 3_000, unblockedAt: 4_000)
        let reloaded = try store(dir, key)
        XCTAssertEqual(reloaded.periods(for: alice), [BlockPeriod(blockedAt: 1_000, unblockedAt: 2_000)])
        XCTAssertEqual(reloaded.periods(for: bob), [BlockPeriod(blockedAt: 3_000, unblockedAt: 4_000)])
        XCTAssertEqual(reloaded.periods(for: Data(repeating: 0xC0, count: 32)), [])
    }

    func testAPeriodEndingBeforeItStartsIsRefused() throws {
        let s = try store(try makeDir(), SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try s.recordPeriod(rawKey: alice, blockedAt: 2_000, unblockedAt: 1_000)) {
            XCTAssertEqual($0 as? BlockHistoryStore.StoreError, .invalidPeriod)
        }
        XCTAssertEqual(s.periods(for: alice), [])
    }

    // MARK: - missing file

    func testAMissingFileIsEmptyReadableAndRecordingWorks() throws {
        let dir = try makeDir()
        let key = SymmetricKey(size: .bits256)
        let s = try store(dir, key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL(dir).path), "precondition: no file")
        XCTAssertTrue(s.isReadable)
        XCTAssertEqual(s.periods(for: alice), [])
        XCTAssertFalse(s.isRefused(id(1)))

        try s.recordPeriod(rawKey: alice, blockedAt: 1_000, unblockedAt: 2_000)
        s.recordRefused(id(1))
        XCTAssertTrue(s.isRefused(id(1)))
        try s.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL(dir).path))
    }

    // MARK: - unreadable file

    private func assertUnreadableRule(dir: URL, key: SymmetricKey) throws {
        let before = try Data(contentsOf: fileURL(dir))
        let s = try store(dir, key, saveDelay: 0)
        XCTAssertFalse(s.isReadable)
        XCTAssertEqual(s.periods(for: alice), [])

        XCTAssertThrowsError(try s.recordPeriod(rawKey: alice, blockedAt: 1_000, unblockedAt: 2_000)) {
            XCTAssertEqual($0 as? BlockHistoryStore.StoreError, .unreadable)
        }
        XCTAssertEqual(s.periods(for: alice), [])

        s.recordRefused(id(1))                       // silent no-op: no throw
        XCTAssertFalse(s.isRefused(id(1)))
        XCTAssertNoThrow(try s.flush())

        // Past the (zero) save delay: nothing may have been written.
        let settled = expectation(description: "utility queue drained")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: fileURL(dir)), before, "the unreadable file must be untouched")
    }

    func testACorruptFileBootsEmptyUnreadableAndIsNeverWritten() throws {
        let dir = try makeDir()
        try Data("not a sealed box".utf8).write(to: fileURL(dir))
        try assertUnreadableRule(dir: dir, key: SymmetricKey(size: .bits256))
    }

    func testAFileSealedUnderAnotherKeyIsTreatedTheSame() throws {
        let dir = try makeDir()
        let other = try store(dir, SymmetricKey(size: .bits256))
        try other.recordPeriod(rawKey: alice, blockedAt: 1_000, unblockedAt: 2_000)
        try assertUnreadableRule(dir: dir, key: SymmetricKey(size: .bits256))
    }

    // MARK: - refused-id FIFO

    func testThe8193rdRefusedIDEvictsTheFirst() throws {
        let dir = try makeDir()
        let key = SymmetricKey(size: .bits256)
        let s = try store(dir, key)
        XCTAssertEqual(BlockHistoryStore.defaultCapacity, 8192)
        for n in 1...8192 { s.recordRefused(id(n)) }
        XCTAssertTrue(s.isRefused(id(1)), "precondition: at the cap, nothing evicted yet")
        s.recordRefused(id(8193))
        XCTAssertFalse(s.isRefused(id(1)), "the oldest id is evicted first")
        XCTAssertTrue(s.isRefused(id(2)))
        XCTAssertTrue(s.isRefused(id(8193)))

        try s.flush()
        let reloaded = try store(dir, key)
        XCTAssertFalse(reloaded.isRefused(id(1)))
        XCTAssertTrue(reloaded.isRefused(id(2)))
        XCTAssertTrue(reloaded.isRefused(id(8193)))
    }

    // MARK: - relaunch

    func testPeriodsAndRefusedIDsSurviveARelaunch() throws {
        let dir = try makeDir()
        let key = SymmetricKey(size: .bits256)
        do {
            let s = try store(dir, key, saveDelay: 0.05)
            try s.recordPeriod(rawKey: alice, blockedAt: 1_000, unblockedAt: 2_000)
            s.recordRefused(id(7))
            s.recordRefused(id(8))
            // The DEBOUNCED write, not flush(): wait for the file to carry the ids.
            let saved = expectation(description: "debounced save landed")
            func poll(_ tries: Int) {
                if (try? store(dir, key).isRefused(id(8))) == true { saved.fulfill(); return }
                guard tries > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll(tries - 1) }
            }
            poll(100)
            wait(for: [saved], timeout: 10)
            withExtendedLifetime(s) {}
        }
        let relaunched = try store(dir, key)
        XCTAssertTrue(relaunched.isReadable)
        XCTAssertEqual(relaunched.periods(for: alice), [BlockPeriod(blockedAt: 1_000, unblockedAt: 2_000)])
        XCTAssertTrue(relaunched.isRefused(id(7)))
        XCTAssertTrue(relaunched.isRefused(id(8)))
    }

    // MARK: - wipe

    func testWipeDestroysTheKeyBeforeTheFile() async throws {
        let dir = try makeDir()
        let service = "test.wipe.keyfirst.\(UUID().uuidString)"
        addTeardownBlock { try? SessionStoreKey.destroy(service: service) }
        let original = try SessionStoreKey.loadOrCreate(service: service)
        let s = try BlockHistoryStore(directory: dir, dek: original, keychainService: service)
        try s.recordPeriod(rawKey: alice, blockedAt: 1_000, unblockedAt: 2_000)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        var threw = false
        do { try await s.wipe() } catch { threw = true }
        XCTAssertTrue(threw, "precondition: the file removal must fail on a read-only dir")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)

        let fresh = try SessionStoreKey.loadOrCreate(service: service)
        XCTAssertNotEqual(fresh.withUnsafeBytes { Data($0) }, original.withUnsafeBytes { Data($0) },
                          "the DEK must be destroyed BEFORE the file removal is attempted")
        let reopened = try BlockHistoryStore(directory: dir, dek: fresh, keychainService: service)
        XCTAssertFalse(reopened.isReadable, "the surviving file must be unreadable under any new key")
    }

    func testNothingIsWrittenAfterWipe() async throws {
        let dir = try makeDir()
        let s = try store(dir, SymmetricKey(size: .bits256))
        try s.recordPeriod(rawKey: alice, blockedAt: 1_000, unblockedAt: 2_000)
        try await s.wipe()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL(dir).path))
        XCTAssertThrowsError(try s.recordPeriod(rawKey: bob, blockedAt: 3_000, unblockedAt: 4_000)) {
            XCTAssertEqual($0 as? BlockHistoryStore.StoreError, .wiped)
        }
        s.recordRefused(id(1))
        try s.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL(dir).path))
    }
}
