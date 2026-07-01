//
//  SessionKeyWipeTests.swift
//  BeaconTests
//
//  Verifies the session-DEK erase (Security/Session/SessionKeyWipe).
//
//  Each test uses a UNIQUE throwaway Keychain service so runs never collide and
//  never touch the real `com.aeronyra.sessionkey.v1` DEK. Asserts the three
//  properties the emergency wipe relies on:
//    • an existing DEK is destroyed (a subsequent load-or-create mints a NEW,
//      different key — proof the old one is gone);
//    • re-wiping already-wiped state is clean (idempotent — the Wipeable contract);
//    • wiping a never-created key is clean (nothing to erase).
//

import XCTest
import CryptoKit
@testable import Beacon

final class SessionKeyWipeTests: XCTestCase {

    /// A unique service per test, torn down afterward so a failing assertion
    /// can't leave a stray Keychain item behind.
    private func makeService() -> String {
        let service = "test.wipe.sessionkey.\(UUID().uuidString)"
        addTeardownBlock { try? SessionStoreKey.destroy(service: service) }
        return service
    }

    // MARK: Destroys an existing key

    func testWipeDestroysExistingKey() async throws {
        let service = makeService()

        // Provision a DEK, capture its bytes.
        let original = try SessionStoreKey.loadOrCreate(service: service)
        let originalBytes = original.withUnsafeBytes { Data($0) }

        // Wipe it.
        let wipe = SessionKeyWipe(service: service)
        try await wipe.wipe()

        // A fresh load-or-create must mint a DIFFERENT key — proving the old one
        // was actually removed (not just re-read).
        let regenerated = try SessionStoreKey.loadOrCreate(service: service)
        let regeneratedBytes = regenerated.withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(originalBytes, regeneratedBytes,
                          "post-wipe load must mint a new key, not return the old one")
    }

    // MARK: Idempotency

    func testWipeIsIdempotent() async throws {
        let service = makeService()
        _ = try SessionStoreKey.loadOrCreate(service: service)

        let wipe = SessionKeyWipe(service: service)
        try await wipe.wipe()          // destroys
        try await wipe.wipe()          // second pass over absent key is clean
    }

    // MARK: Clean when never created

    func testWipeOnAbsentKeyIsClean() async throws {
        // A service that was never provisioned — wipe must not throw.
        let service = "test.wipe.sessionkey.absent.\(UUID().uuidString)"
        let wipe = SessionKeyWipe(service: service)
        try await wipe.wipe()
    }
}
