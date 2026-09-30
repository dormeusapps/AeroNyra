//
//  TermsAcceptanceStoreTests.swift
//  BeaconTests
//
//  Pins the Terms of Use acceptance record: no record, an older version, a
//  version 1 defaults record or an unreadable file all mean NOT accepted
//  (fail closed); the current version is accepted; the file is excluded from
//  backup; accepting removes the version 1 key; the erase step deletes the
//  record and is idempotent.
//

import XCTest
@testable import Beacon

final class TermsAcceptanceStoreTests: XCTestCase {

    private func makeStore() -> TermsAcceptanceStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("terms-acceptance.\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return TermsAcceptanceStore(directory: dir)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "terms-acceptance-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testCurrentVersionIsTwo() {
        XCTAssertEqual(TermsVersion.current, 2)
    }

    func testNoRecordIsNotAccepted() {
        let store = makeStore()
        XCTAssertNil(store.load())
        XCTAssertFalse(store.isAccepted())
    }

    func testOlderVersionIsNotAccepted() throws {
        let store = makeStore()
        try store.recordAcceptance(version: TermsVersion.current - 1, legacyDefaults: makeDefaults())
        XCTAssertEqual(store.load()?.version, TermsVersion.current - 1)
        XCTAssertFalse(store.isAccepted())
    }

    func testCurrentVersionIsAccepted() throws {
        let store = makeStore()
        let when = Date(timeIntervalSince1970: 1_790_000_000)
        try store.recordAcceptance(at: when, legacyDefaults: makeDefaults())
        XCTAssertEqual(store.load(), TermsAcceptanceRecord(version: TermsVersion.current, acceptedAt: when))
        XCTAssertTrue(store.isAccepted())
    }

    /// Version 1 lived in UserDefaults. It must never count.
    func testLegacyDefaultsRecordIsNeverRead() {
        let store = makeStore()
        UserDefaults.standard.set(["version": 99, "acceptedAt": Date()],
                                  forKey: TermsAcceptanceStore.legacyDefaultsKey)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: TermsAcceptanceStore.legacyDefaultsKey) }
        XCTAssertFalse(store.isAccepted())
    }

    func testUnreadableFileIsNotAccepted() throws {
        let store = makeStore()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertNil(store.load())
        XCTAssertFalse(store.isAccepted())
    }

    func testRecordIsExcludedFromBackup() throws {
        let store = makeStore()
        try store.recordAcceptance(legacyDefaults: makeDefaults())
        let values = try store.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testAcceptingRemovesLegacyKey() throws {
        let store = makeStore()
        let defaults = makeDefaults()
        defaults.set(["version": 1, "acceptedAt": Date()], forKey: TermsAcceptanceStore.legacyDefaultsKey)
        try store.recordAcceptance(legacyDefaults: defaults)
        XCTAssertNil(defaults.object(forKey: TermsAcceptanceStore.legacyDefaultsKey))
    }

    func testWipeDeletesRecordAndIsIdempotent() async throws {
        let store = makeStore()
        try store.recordAcceptance(legacyDefaults: makeDefaults())
        XCTAssertTrue(store.isAccepted())
        let wipe = TermsAcceptanceWipe(store: store)
        try await wipe.wipe()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertFalse(store.isAccepted())
        try await wipe.wipe()   // no file: still no error
    }
}
