//
//  BackupExclusionTests.swift
//  BeaconTests
//
//  Pins the backup exclusion (INVARIANT: nothing readable leaves the device):
//  the helper marks a folder excluded from backup and the value reads back;
//  it creates a missing folder; running it again is harmless; a failure never
//  escapes it; the boot entry excludes the real Application Support; and
//  `bootstrap()` calls it first, before the terms gate and before the model
//  container or the session stack can be built.
//

import XCTest
@testable import Beacon

final class BackupExclusionTests: XCTestCase {

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-exclusion.\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// The value as stored, read through a fresh URL (no cached values).
    private func isExcluded(_ url: URL) throws -> Bool {
        let fresh = URL(fileURLWithPath: url.path, isDirectory: true)
        return try XCTUnwrap(fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup)
    }

    func testTheFolderIsExcludedAfterTheHelperRuns() throws {
        let dir = try makeDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertFalse(try isExcluded(dir), "precondition: a new folder is backed up")

        XCTAssertTrue(BackupExclusion.excludeFromBackup(dir))
        XCTAssertTrue(try isExcluded(dir))
    }

    func testAMissingFolderIsCreatedAndExcluded() throws {
        let dir = try makeDir()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "precondition")

        XCTAssertTrue(BackupExclusion.excludeFromBackup(dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertTrue(try isExcluded(dir))
    }

    func testRunningTwiceIsHarmless() throws {
        let dir = try makeDir()
        XCTAssertTrue(BackupExclusion.excludeFromBackup(dir))
        let file = dir.appendingPathComponent("default.store")
        try Data("x".utf8).write(to: file)
        XCTAssertTrue(BackupExclusion.excludeFromBackup(dir), "a second launch")
        XCTAssertTrue(try isExcluded(dir))
        XCTAssertEqual(try Data(contentsOf: file), Data("x".utf8), "contents untouched")
    }

    func testAFailureNeverEscapesTheHelper() throws {
        let dir = try makeDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blocker = dir.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: blocker)
        // A path whose parent is a regular file: the folder can't be created.
        let impossible = blocker.appendingPathComponent("child", isDirectory: true)

        XCTAssertFalse(BackupExclusion.excludeFromBackup(impossible), "reports failure, does not throw")
    }

    func testTheBootEntryExcludesApplicationSupport() throws {
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
        // The test host's own launch already excluded it: clear the flag first,
        // so this proves the boot entry sets it.
        var url = appSupport
        var cleared = URLResourceValues()
        cleared.isExcludedFromBackup = false
        try url.setResourceValues(cleared)
        XCTAssertFalse(try isExcluded(appSupport), "precondition: flag cleared")

        BackupExclusion.excludeApplicationSupport()
        XCTAssertTrue(try isExcluded(appSupport))
    }

    func testBootstrapExcludesFirstBeforeAnyStoreOpens() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Beacon/ContentView.swift"), encoding: .utf8)

        // The first statement of bootstrap() is the exclusion.
        let start = try XCTUnwrap(text.range(of: "    private func bootstrap() {\n"))
        let body = text[start.upperBound...]
        let firstStatement = body.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("//") }
        XCTAssertEqual(firstStatement, "BackupExclusion.excludeApplicationSupport()")

        // The terms gate, and with it the only path to the model container and
        // the session stack (bootRoute), come after it.
        let exclusion = try XCTUnwrap(body.range(of: "BackupExclusion.excludeApplicationSupport()"))
        let gate = try XCTUnwrap(body.range(of: "LaunchGate.run("))
        XCTAssertLessThan(exclusion.lowerBound, gate.lowerBound)
        let bootRouteCalls = text.components(separatedBy: "boot: { bootRoute() }").count - 1
        XCTAssertEqual(bootRouteCalls, 1, "bootRoute is reached only through the gate in bootstrap()")
        XCTAssertEqual(text.components(separatedBy: "bootRoute()").count - 1, 2,
                       "bootRoute: one definition, one call")
        XCTAssertEqual(text.components(separatedBy: "try makeModelContainer()").count - 1, 1,
                       "the model container is built only in bootRoute")
        XCTAssertEqual(text.components(separatedBy: "try makeSessionStack(").count - 1, 1,
                       "the session stack is built only in bootRoute")
        let bootRouteDef = try XCTUnwrap(text.range(of: "private func bootRoute()"))
        let container = try XCTUnwrap(text.range(of: "try makeModelContainer()"))
        XCTAssertGreaterThan(container.lowerBound, bootRouteDef.lowerBound)
    }
}
