//
//  StoreWipeKeyFirstTests.swift
//  BeaconTests
//
//  Pins KEY-BEFORE-FILE in every sealed store's `wipe()`: when the file
//  removal fails, the DEK must already be destroyed, so what survives is an
//  unreadable file — never a usable (file, key) pair a later identity could
//  load (the failed-erase leftover gap).
//
//  Each test uses a REAL Keychain DEK under a throwaway service, makes the
//  store directory unwritable (the removal fails), and checks the key is gone:
//  `loadOrCreate` on the same service then mints a DIFFERENT key, which cannot
//  open the surviving file.
//

import XCTest
import CryptoKit
@testable import Beacon

final class StoreWipeKeyFirstTests: XCTestCase {

    private func bytes(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { Data($0) } }

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wipe-keyfirst.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    /// Shared shape: build → save → dir read-only → wipe must THROW (file stays)
    /// → the key must already be gone → a fresh key cannot open the file.
    private func assertKeyDestroyedBeforeFile(
        make: (URL, SymmetricKey, String) throws -> any Wipeable,
        save: (any Wipeable) throws -> Void,
        loadFails: (URL, SymmetricKey, String) throws -> Bool
    ) async throws {
        let dir = try makeDir()
        let service = "test.wipe.keyfirst.\(UUID().uuidString)"
        addTeardownBlock { try? SessionStoreKey.destroy(service: service) }
        let original = try SessionStoreKey.loadOrCreate(service: service)
        let store = try make(dir, original, service)
        try save(store)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        var threw = false
        do { try await store.wipe() } catch { threw = true }
        XCTAssertTrue(threw, "precondition: the file removal must fail on a read-only dir")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)

        let fresh = try SessionStoreKey.loadOrCreate(service: service)
        XCTAssertNotEqual(bytes(fresh), bytes(original),
                          "the DEK must be destroyed BEFORE the file removal is attempted")
        XCTAssertTrue(try loadFails(dir, fresh, service),
                      "the surviving file must be unreadable under any new key")
    }

    func testContactAllowlistStoreDestroysKeyFirst() async throws {
        try await assertKeyDestroyedBeforeFile(
            make: { try ContactAllowlistStore(directory: $0, dek: $1, keychainService: $2) },
            save: { store in
                var a = ContactAllowlist()
                a.enroll(identity: Data(repeating: 1, count: 32), at: 1, verified: true)
                try (store as! ContactAllowlistStore).save(a)
            },
            loadFails: { dir, key, svc in
                (try? ContactAllowlistStore(directory: dir, dek: key, keychainService: svc).load()) == nil
            })
    }

    func testPendingInvitesStoreDestroysKeyFirst() async throws {
        try await assertKeyDestroyedBeforeFile(
            make: { try PendingInvitesStore(directory: $0, dek: $1, keychainService: $2) },
            save: { store in
                var p = PendingInvites()
                p.register(id: Data(repeating: 2, count: 16), expiresAt: 9_999_999_999_999)
                try (store as! PendingInvitesStore).save(p)
            },
            loadFails: { dir, key, svc in
                (try? PendingInvitesStore(directory: dir, dek: key, keychainService: svc).load()) == nil
            })
    }

    func testBlockedContactsStoreDestroysKeyFirst() async throws {
        try await assertKeyDestroyedBeforeFile(
            make: { try BlockedContactsStore(directory: $0, dek: $1, keychainService: $2) },
            save: { store in
                try (store as! BlockedContactsStore).save(
                    [BlockedContact(rawKey: Data(repeating: 3, count: 32), blockedAt: 1,
                                    petname: nil, wasVerified: false)])
            },
            loadFails: { dir, key, svc in
                (try? BlockedContactsStore(directory: dir, dek: key, keychainService: svc).load()) == nil
            })
    }

    func testProcessedEventLedgerStoreDestroysKeyFirst() async throws {
        try await assertKeyDestroyedBeforeFile(
            make: { try ProcessedEventLedgerStore(directory: $0, dek: $1, keychainService: $2) },
            save: { store in
                var l = ProcessedEventLedger()
                _ = l.containsOrInsert("a" + String(repeating: "0", count: 63))
                try (store as! ProcessedEventLedgerStore).save(l)
            },
            loadFails: { dir, key, svc in
                (try? ProcessedEventLedgerStore(directory: dir, dek: key, keychainService: svc).load()) == nil
            })
    }
}
