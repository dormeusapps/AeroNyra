//
//  NostrIdentityTests.swift
//  BeaconTests
//
//  Proves 8a's dependency-free identity: scalar validity, generation, the
//  nsec encoding, and the load-or-create persistence round-trip. No secp256k1,
//  no device — pure logic + Keychain. XCTest (project convention).
//

import XCTest
@testable import Beacon

final class NostrIdentityTests: XCTestCase {

    private var service: String!

    override func setUp() {
        super.setUp()
        service = "test.nostr.identity.\(UUID().uuidString)"
    }

    override func tearDown() {
        try? NostrSecretStore.destroy(service: service)
        super.tearDown()
    }

    // MARK: - Scalar validity

    func testZeroScalarRejected() {
        XCTAssertFalse(NostrIdentity.isValidScalar([UInt8](repeating: 0, count: 32)))
    }

    func testScalarAtOrderRejected() {
        // n itself is not a valid private key (valid range is [1, n-1]).
        let n: [UInt8] = [
            0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,
            0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFE,
            0xBA,0xAE,0xDC,0xE6,0xAF,0x48,0xA0,0x3B,
            0xBF,0xD2,0x5E,0x8C,0xD0,0x36,0x41,0x41,
        ]
        XCTAssertFalse(NostrIdentity.isValidScalar(n))
    }

    func testScalarOneIsValid() {
        var one = [UInt8](repeating: 0, count: 32); one[31] = 1
        XCTAssertTrue(NostrIdentity.isValidScalar(one))
    }

    func testScalarBelowOrderValid() {
        // n - 1 is the largest valid key.
        let nMinus1: [UInt8] = [
            0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,
            0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFE,
            0xBA,0xAE,0xDC,0xE6,0xAF,0x48,0xA0,0x3B,
            0xBF,0xD2,0x5E,0x8C,0xD0,0x36,0x41,0x40,
        ]
        XCTAssertTrue(NostrIdentity.isValidScalar(nMinus1))
    }

    func testWrongLengthRejected() {
        XCTAssertFalse(NostrIdentity.isValidScalar([UInt8](repeating: 1, count: 31)))
    }

    // MARK: - Generation

    func testGeneratedIdentityIsValidAndSized() throws {
        let id = try NostrIdentity()
        XCTAssertEqual(id.secretKeyBytes.count, 32)
        XCTAssertTrue(NostrIdentity.isValidScalar([UInt8](id.secretKeyBytes)))
    }

    func testGenerationIsUnique() throws {
        let a = try NostrIdentity()
        let b = try NostrIdentity()
        XCTAssertNotEqual(a.secretKeyBytes, b.secretKeyBytes)
    }

    // MARK: - Encoding

    func testNsecIsProducedAndRoundTrips() throws {
        let id = try NostrIdentity()
        let nsec = try XCTUnwrap(id.nsec)
        XCTAssertTrue(nsec.hasPrefix("nsec1"))
        XCTAssertEqual(NIP19.secretKey(fromNsec: nsec), id.secretKeyBytes)
    }

    func testPublicKeyDeferredUntil8b() throws {
        // The x-only pubkey/npub are intentionally not derived yet (Phase 8b).
        let id = try NostrIdentity()
        XCTAssertNil(id.publicKeyBytes)
        XCTAssertNil(id.npub)
    }

    // MARK: - Persistence

    func testLoadOrCreateGeneratesThenReloadsSame() throws {
        let first = try NostrIdentity.loadOrCreate(service: service)
        let second = try NostrIdentity.loadOrCreate(service: service)
        XCTAssertEqual(first.secretKeyBytes, second.secretKeyBytes)
    }

    func testLoadOrCreatePersistsToStore() throws {
        let id = try NostrIdentity.loadOrCreate(service: service)
        XCTAssertEqual(try NostrSecretStore.load(service: service), id.secretKeyBytes)
    }
}
