//
//  NostrIdentityTests.swift
//  BeaconTests
//
//  Proves the Nostr identity: scalar validity, generation, the nsec encoding,
//  the load-or-create persistence round-trip (8a), and — as of 8b-i-1 — x-only
//  public-key derivation and the npub encoding against a known-answer vector.
//  XCTest (project convention). Device-free.
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

    // MARK: - Encoding (nsec)

    func testNsecIsProducedAndRoundTrips() throws {
        let id = try NostrIdentity()
        let nsec = try XCTUnwrap(id.nsec)
        XCTAssertTrue(nsec.hasPrefix("nsec1"))
        XCTAssertEqual(NIP19.secretKey(fromNsec: nsec), id.secretKeyBytes)
    }

    // MARK: - Public key derivation (8b-i-1)

    /// Known-answer vector derived from first principles: the secret scalar 1
    /// has public key equal to the secp256k1 generator G, whose x-coordinate is
    /// a published constant. G has an even y, so the x-only key is G.x unchanged.
    /// This pins the whole secret → pubkey → npub pipeline to a value anyone can
    /// verify independently of this code.
    func testKnownVectorSecretOneDerivesGeneratorX() throws {
        var secret = [UInt8](repeating: 0, count: 32); secret[31] = 1
        let id = NostrIdentity(secretKeyBytes: Data(secret))

        let expectedPubHex =
            "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
        let expectedNpub =
            "npub10xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqpkge6d"

        let pub = try XCTUnwrap(id.publicKeyBytes, "pubkey derivation returned nil")
        XCTAssertEqual(pub.count, 32)
        XCTAssertEqual(hex(pub), expectedPubHex)

        let npub = try XCTUnwrap(id.npub, "npub should be non-nil once pubkey derives")
        XCTAssertEqual(npub, expectedNpub)
    }

    /// A freshly generated identity produces a well-formed npub that decodes back
    /// to its own derived public-key bytes (encode/derive consistency).
    func testGeneratedIdentityNpubRoundTrips() throws {
        let id = try NostrIdentity()
        let pub = try XCTUnwrap(id.publicKeyBytes)
        let npub = try XCTUnwrap(id.npub)
        XCTAssertTrue(npub.hasPrefix("npub1"))
        XCTAssertEqual(NIP19.publicKey(fromNpub: npub), pub)
    }

    /// Derivation is deterministic: the same secret always yields the same pubkey.
    func testDerivationIsDeterministic() throws {
        let id = try NostrIdentity()
        XCTAssertEqual(id.publicKeyBytes, id.publicKeyBytes)
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

    // MARK: -

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
