//
//  IdentityTests.swift
//  BeaconTests
//
//  Verifies the identity layer (Security/Identity) without any UI.
//
//  Two groups:
//   • Pure logic — generation, public-identity shape, blob round-trip. Fast,
//     deterministic, no Keychain. These always run anywhere.
//   • Keychain integration — save/load/delete against the real Keychain on the
//     simulator. They use `.deviceUnlockOnly` protection (works without a
//     device passcode) and a unique service per test, cleaning up before and
//     after so runs never collide.
//

import XCTest
import CryptoKit
@testable import Beacon

final class IdentityTests: XCTestCase {

    // MARK: Pure logic

    func testGenerateProducesDistinctKeys() {
        let a = IdentityKeypair.generate()
        let b = IdentityKeypair.generate()

        // Two fresh identities must differ (sanity check on the CSPRNG path).
        XCTAssertNotEqual(a.publicIdentity, b.publicIdentity)
    }

    func testPublicIdentityShape() {
        let identity = IdentityKeypair.generate()
        let pub = identity.publicIdentity

        // Curve25519 raw public keys are 32 bytes each.
        XCTAssertEqual(pub.agreementKey.count, 32)
        XCTAssertEqual(pub.signingKey.count, 32)

        // The user ID is the agreement (X25519) public key.
        XCTAssertEqual(pub.userID, pub.agreementKey)
        XCTAssertEqual(pub.userIDHex.count, 64)   // 32 bytes -> 64 hex chars
    }

    func testPrivateBlobIsFixedSize() {
        let identity = IdentityKeypair.generate()
        let blob = identity.serializedPrivateBlob()
        XCTAssertEqual(blob.count, IdentityKeypair.blobSize)   // 64
    }

    func testPrivateBlobRoundTrip() throws {
        let original = IdentityKeypair.generate()
        let blob = original.serializedPrivateBlob()

        let restored = try IdentityKeypair(privateBlob: blob)

        // Reconstructed keys must match the originals byte-for-byte.
        XCTAssertEqual(restored.agreement.rawRepresentation,
                       original.agreement.rawRepresentation)
        XCTAssertEqual(restored.signing.rawRepresentation,
                       original.signing.rawRepresentation)
        XCTAssertEqual(restored.publicIdentity, original.publicIdentity)
    }

    func testCorruptBlobRejected() {
        // Wrong length must throw, not silently truncate or pad.
        let tooShort = Data(repeating: 0, count: 32)
        XCTAssertThrowsError(try IdentityKeypair(privateBlob: tooShort)) { error in
            XCTAssertEqual(error as? IdentityError, .corruptedKeyData)
        }
    }

    // MARK: Keychain integration

    /// A throwaway store bound to a unique service, scrubbed before and after.
    private func makeCleanStore() throws -> IdentityStore {
        let service = "test.identity.\(UUID().uuidString)"
        let store = IdentityStore(service: service, protection: .deviceUnlockOnly)
        try store.delete()   // ensure a clean slate
        addTeardownBlock { try? store.delete() }
        return store
    }

    func testSaveThenLoadMatches() throws {
        let store = try makeCleanStore()
        let identity = IdentityKeypair.generate()

        try store.save(identity)
        let loaded = try store.load()

        XCTAssertEqual(loaded.publicIdentity, identity.publicIdentity)
        XCTAssertEqual(loaded.agreement.rawRepresentation,
                       identity.agreement.rawRepresentation)
        XCTAssertEqual(loaded.signing.rawRepresentation,
                       identity.signing.rawRepresentation)
    }

    func testLoadWithoutSaveThrowsNotFound() throws {
        let store = try makeCleanStore()
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? IdentityError, .notFound)
        }
    }

    func testSaveRefusesToOverwriteByDefault() throws {
        let store = try makeCleanStore()
        try store.save(IdentityKeypair.generate())

        // A second save without overwrite must be refused.
        XCTAssertThrowsError(try store.save(IdentityKeypair.generate())) { error in
            XCTAssertEqual(error as? IdentityError, .alreadyExists)
        }
    }

    /// The default (no-overwrite) save not only THROWS on a duplicate — it must
    /// leave the stored item byte-for-byte unchanged. This is the property
    /// `completeOnboarding` now relies on: the `false` default is its guard
    /// against a fresh key clobbering a surviving identity, so a refused save
    /// must be a true no-op, not a partial write. Digests, never raw key bytes,
    /// so a failure message can't print private material.
    func testSaveWithoutOverwriteLeavesStoredBlobIntact() throws {
        let store = try makeCleanStore()
        let original = IdentityKeypair.generate()
        try store.save(original)

        let intruder = IdentityKeypair.generate()
        XCTAssertThrowsError(try store.save(intruder)) { error in
            XCTAssertEqual(error as? IdentityError, .alreadyExists)
        }

        let loaded = try store.load()
        XCTAssertEqual(SHA256.hash(data: loaded.serializedPrivateBlob()),
                       SHA256.hash(data: original.serializedPrivateBlob()),
                       "the ORIGINAL identity must survive a refused save")
        XCTAssertNotEqual(SHA256.hash(data: loaded.serializedPrivateBlob()),
                          SHA256.hash(data: intruder.serializedPrivateBlob()),
                          "the intruder key must NOT have been written")
    }

    func testLoadOrCreateIsStable() throws {
        let store = try makeCleanStore()

        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()

        // Second call must return the SAME identity, not mint a new one.
        XCTAssertEqual(first.publicIdentity, second.publicIdentity)
    }

    func testDeleteThenLoadOrCreateMintsFreshIdentity() throws {
        let store = try makeCleanStore()

        let first = try store.loadOrCreate()
        try store.delete()
        let second = try store.loadOrCreate()

        // After deletion, a new identity is generated — different from the first.
        XCTAssertNotEqual(first.publicIdentity, second.publicIdentity)
    }

    func testDeleteIsIdempotent() throws {
        let store = try makeCleanStore()
        // Deleting a non-existent item must not throw.
        XCTAssertNoThrow(try store.delete())
        try store.save(IdentityKeypair.generate())
        XCTAssertNoThrow(try store.delete())
        XCTAssertNoThrow(try store.delete())
    }

    // MARK: Secure Enclave availability

    func testSecureEnclaveUnavailableOnSimulator() throws {
        // Documents the environment rather than asserting a hard requirement:
        // on the simulator the Enclave is absent and the wrapper init throws;
        // on a device it succeeds. Either is valid — we just confirm the two
        // agree with each other.
        if SecureEnclaveWrapper.isAvailable {
            XCTAssertNoThrow(try SecureEnclaveWrapper(service: "test.se.\(UUID().uuidString)"))
        } else {
            XCTAssertThrowsError(try SecureEnclaveWrapper(service: "test.se.\(UUID().uuidString)")) { error in
                XCTAssertEqual(error as? SecureEnclaveError, .unavailable)
            }
        }
    }
}
