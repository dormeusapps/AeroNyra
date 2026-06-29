//
//  Secp256k1ECDHTests.swift
//  BeaconTests
//
//  Phase 8c-i-0 — raw secp256k1 ECDH shared-X tests for Core/Nostr/Secp256k1.swift.
//
//  The C curve module (Csecp256k1) is APP-target only; these tests reach it via
//  `@testable import Beacon` and never import Csecp256k1 directly.
//
//  Known-answer vector computed independently (x((sec_a * sec_b) * G), which is
//  parity-independent and therefore equals x(sec_a * Pub_b) == x(sec_b * Pub_a)):
//    sec_a    = B7E1...CFEF   (also BIP-340 vector 1's secret)
//    sec_b    = C90F...E5C9
//    pub_a(x) = DFF1...BA659
//    pub_b(x) = DD30...74EB8
//    shared_x = CA77...557627
//

import XCTest
@testable import Beacon

final class Secp256k1ECDHTests: XCTestCase {

    private let secA = "B7E151628AED2A6ABF7158809CF4F3C762E7160F38B4DA56A784D9045190CFEF"
    private let secB = "C90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B14E5C9"
    private let pubA = "DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659"
    private let pubB = "DD308AFEC5777E13121FA72B9CC1B7CC0139715309B086C960E18FD969774EB8"
    private let sharedX = "CA77AD739864D3F6F599F93842F48C89D5A9A7D0C867B767D53BF96F03557627"

    // MARK: Known answer

    func testEcdhMatchesKnownSharedX() {
        let ab = Secp256k1.ecdh(secretKey: hex(secA), peerXOnlyPublicKey: hex(pubB))
        XCTAssertEqual(ab, hex(sharedX), "ecdh(sec_a, pub_b) must equal the known shared X")

        let ba = Secp256k1.ecdh(secretKey: hex(secB), peerXOnlyPublicKey: hex(pubA))
        XCTAssertEqual(ba, hex(sharedX), "ecdh(sec_b, pub_a) must equal the known shared X")
    }

    // MARK: Symmetry (the property NIP-44's conversation key relies on)

    func testEcdhIsSymmetric() {
        guard let pa = Secp256k1.xOnlyPublicKey(fromSecretKey: hex(secA)),
              let pb = Secp256k1.xOnlyPublicKey(fromSecretKey: hex(secB)) else {
            return XCTFail("derivation returned nil for a valid secret")
        }
        let ab = Secp256k1.ecdh(secretKey: hex(secA), peerXOnlyPublicKey: pb)
        let ba = Secp256k1.ecdh(secretKey: hex(secB), peerXOnlyPublicKey: pa)
        XCTAssertNotNil(ab)
        XCTAssertEqual(ab, ba, "ecdh must be symmetric across the two parties")
    }

    // MARK: Derivation cross-check (the helper's pubkeys feed ecdh)

    func testDerivedPublicKeysMatchVectors() {
        XCTAssertEqual(Secp256k1.xOnlyPublicKey(fromSecretKey: hex(secA)), hex(pubA))
        XCTAssertEqual(Secp256k1.xOnlyPublicKey(fromSecretKey: hex(secB)), hex(pubB))
    }

    // MARK: Negative — input validation

    func testEcdhRejectsWrongLengthInputs() {
        XCTAssertNil(Secp256k1.ecdh(secretKey: hex(secA).dropLast(), peerXOnlyPublicKey: hex(pubB)),
                     "31-byte secret must be rejected")
        XCTAssertNil(Secp256k1.ecdh(secretKey: hex(secA), peerXOnlyPublicKey: hex(pubB).dropLast()),
                     "31-byte peer key must be rejected")
    }

    func testEcdhRejectsInvalidScalar() {
        let zeroSecret = Data(repeating: 0, count: 32)   // not a valid scalar
        XCTAssertNil(Secp256k1.ecdh(secretKey: zeroSecret, peerXOnlyPublicKey: hex(pubB)),
                     "all-zero secret must be rejected")
    }

    func testEcdhRejectsPeerKeyNotOnCurve() {
        // A value exceeding the field size is not a valid x-coordinate
        // (BIP-340 vector 14's "exceeds field size" x).
        let badPeer = "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC30"
        XCTAssertNil(Secp256k1.ecdh(secretKey: hex(secA), peerXOnlyPublicKey: hex(badPeer)),
                     "a peer key that is not a valid curve x-coordinate must be rejected")
    }

    // MARK: Helpers

    private func hex(_ string: String) -> Data {
        precondition(string.count % 2 == 0, "hex string must have even length")
        var bytes = [UInt8]()
        bytes.reserveCapacity(string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else {
                fatalError("invalid hex byte in test vector")
            }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
