//
//  SwiftDataStoreWipeTests.swift
//  BeaconTests
//
//  Verifies the SwiftData message-store erase (Security/Wipe/SwiftDataStoreWipe).
//
//  These are filesystem-behavioral tests against an INJECTED temporary directory
//  — they never touch the real Application Support store. They assert the four
//  properties the emergency wipe relies on:
//    • a full store (default.store + -wal + -shm) is deleted;
//    • re-wiping already-wiped state is clean (idempotent — the Wipeable contract);
//    • a partial store (primary only, no sidecars) still wipes clean;
//    • an empty / nonexistent directory is clean (nothing to erase).
//

import XCTest
@testable import Beacon

final class SwiftDataStoreWipeTests: XCTestCase {

    private let storeFileNames = [
        "default.store",
        "default.store-wal",
        "default.store-shm",
    ]

    // MARK: Helpers

    /// A fresh temporary directory, torn down after the test.
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wipe.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Write a non-empty dummy file for each of the given names into `dir`.
    private func writeFiles(_ names: [String], into dir: URL) throws {
        for name in names {
            let url = dir.appendingPathComponent(name)
            try Data("stub".utf8).write(to: url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "precondition: \(name) should exist before wipe")
        }
    }

    private func assertNoneExist(_ names: [String], in dir: URL,
                                 file: StaticString = #filePath, line: UInt = #line) {
        for name in names {
            let url = dir.appendingPathComponent(name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                           "\(name) should be gone after wipe", file: file, line: line)
        }
    }

    // MARK: Full store

    func testWipesStoreAndSidecars() async throws {
        let dir = try makeTempDirectory()
        try writeFiles(storeFileNames, into: dir)

        let wipe = try SwiftDataStoreWipe(directory: dir)
        try await wipe.wipe()

        assertNoneExist(storeFileNames, in: dir)
    }

    // MARK: Idempotency

    func testWipeIsIdempotent() async throws {
        let dir = try makeTempDirectory()
        try writeFiles(storeFileNames, into: dir)

        let wipe = try SwiftDataStoreWipe(directory: dir)
        try await wipe.wipe()          // erases
        try await wipe.wipe()          // second pass over already-empty state is clean

        assertNoneExist(storeFileNames, in: dir)
    }

    // MARK: Partial store (sidecars absent)

    func testWipesWithSidecarsMissing() async throws {
        let dir = try makeTempDirectory()
        // Only the primary store file exists; -wal / -shm are absent (a valid
        // real state after a checkpoint).
        try writeFiles(["default.store"], into: dir)

        let wipe = try SwiftDataStoreWipe(directory: dir)
        try await wipe.wipe()          // must not throw on the missing sidecars

        assertNoneExist(storeFileNames, in: dir)
    }

    // MARK: Empty directory

    func testWipeOnEmptyDirectoryIsClean() async throws {
        let dir = try makeTempDirectory()   // nothing written

        let wipe = try SwiftDataStoreWipe(directory: dir)
        try await wipe.wipe()               // nothing to erase → clean

        assertNoneExist(storeFileNames, in: dir)
    }

    // MARK: Leaves unrelated files alone

    func testDoesNotTouchUnrelatedFiles() async throws {
        let dir = try makeTempDirectory()
        try writeFiles(storeFileNames, into: dir)
        let bystander = dir.appendingPathComponent("keep.me")
        try Data("keep".utf8).write(to: bystander)

        let wipe = try SwiftDataStoreWipe(directory: dir)
        try await wipe.wipe()

        assertNoneExist(storeFileNames, in: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bystander.path),
                      "wipe must only remove the store files, not siblings")
    }
}
