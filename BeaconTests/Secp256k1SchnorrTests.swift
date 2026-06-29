//
//  Secp256k1SchnorrTests.swift
//  BeaconTests
//
//  Phase 8b-ii — BIP-340 schnorr signing / verification tests for
//  Core/Nostr/Secp256k1.swift.
//
//  The C curve module (Csecp256k1) is APP-target only; these tests reach it
//  through `@testable import Beacon` and never import Csecp256k1 directly
//  (the Secp256k1Probe pattern from 8b-i-0). Do not add C build settings to
//  the test target.
//
//  Anchoring strategy: `sign` draws fresh BIP-340 auxiliary randomness on every
//  call, so its output is non-deterministic and cannot be compared to a fixed
//  signature vector. The external anchor is therefore the VERIFY path, checked
//  against canonical BIP-340 test vectors (bitcoin/bips bip-0340/test-vectors.csv):
//    - vector 1 (32-byte message): a published (pubkey, msg, sig) triple that
//      MUST verify true.
//    - vector 7 (negated message): the same pubkey/msg with a sig that MUST
//      verify false.
//  `sign` is then exercised via a sign -> verify round-trip whose public key is
//  derived by the already-known-answer-tested `xOnlyPublicKey`.
//

import XCTest
@testable import Beacon

final class Secp256k1SchnorrTests: XCTestCase {

    // MARK: BIP-340 canonical vectors (hex, exactly as published)

    // Vector 1.
    private let v1SecretKey = "B7E151628AED2A6ABF7158809CF4F3C762E7160F38B4DA56A784D9045190CFEF"
    private let v1PublicKey = "DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659"
    private let v1Message   = "243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89"
    private let v1Signature = "6896BD60EEAE296DB48A229FF71DFE071BDE413E6D43F917DC8DCF8C78DE33418906D11AC976ABCCB20B091292BFF4EA897EFCB639EA871CFA95F6DE339E4B0A"

    // Vector 7: same public key + message as vector 1, but a signature over a
    // negated message — MUST verify false.
    private let v7BadSignature = "1FA62E331EDBC21C394792D2AB1100A7B432B013DF3F6FF4F99FCB33E0E1515F28890B3EDB6E7189B630448B515CE4F8622A954CFE545735AAEA5134FCCDB2BD"

    // MARK: Verify — known answers

    func testVerifyAcceptsCanonicalVector() {
        let ok = Secp256k1.verify(signature64: hex(v1Signature),
                                  messageHash32: hex(v1Message),
                                  xOnlyPublicKey: hex(v1PublicKey))
        XCTAssertTrue(ok, "BIP-340 vector 1 must verify true")
    }

    func testVerifyRejectsCanonicalFalseVector() {
        let ok = Secp256k1.verify(signature64: hex(v7BadSignature),
                                  messageHash32: hex(v1Message),
                                  xOnlyPublicKey: hex(v1PublicKey))
        XCTAssertFalse(ok, "BIP-340 vector 7 (negated message) must verify false")
    }

    // MARK: Derivation cross-check (anchors sign's key source)

    func testVectorSecretDerivesVectorPublicKey() {
        let derived = Secp256k1.xOnlyPublicKey(fromSecretKey: hex(v1SecretKey))
        XCTAssertEqual(derived, hex(v1PublicKey),
                       "vector 1 secret must derive vector 1 x-only public key")
    }

    // MARK: Sign -> verify round-trip

    func testSignThenVerifyRoundTrip() {
        let message = hex(v1Message)
        let secret = hex(v1SecretKey)

        guard let signature = Secp256k1.sign(messageHash32: message, secretKey: secret) else {
            return XCTFail("sign returned nil for a valid secret/message")
        }
        XCTAssertEqual(signature.count, 64, "schnorr signature must be 64 bytes")

        guard let publicKey = Secp256k1.xOnlyPublicKey(fromSecretKey: secret) else {
            return XCTFail("derivation returned nil for a valid secret")
        }

        let ok = Secp256k1.verify(signature64: signature,
                                  messageHash32: message,
                                  xOnlyPublicKey: publicKey)
        XCTAssertTrue(ok, "freshly signed message must verify under the derived key")
    }

    func testSignIsNonDeterministic() {
        let message = hex(v1Message)
        let secret = hex(v1SecretKey)

        guard let first = Secp256k1.sign(messageHash32: message, secretKey: secret),
              let second = Secp256k1.sign(messageHash32: message, secretKey: secret) else {
            return XCTFail("sign returned nil for a valid secret/message")
        }
        // Fresh aux randomness per call -> the two signatures must differ...
        XCTAssertNotEqual(first, second, "BIP-340 aux randomness should vary per call")

        // ...yet both must verify.
        guard let publicKey = Secp256k1.xOnlyPublicKey(fromSecretKey: secret) else {
            return XCTFail("derivation returned nil for a valid secret")
        }
        XCTAssertTrue(Secp256k1.verify(signature64: first, messageHash32: message, xOnlyPublicKey: publicKey))
        XCTAssertTrue(Secp256k1.verify(signature64: second, messageHash32: message, xOnlyPublicKey: publicKey))
    }

    // MARK: Negative — verify rejects tampering

    func testVerifyRejectsTamperedSignature() {
        var signature = [UInt8](hex(v1Signature))
        signature[0] ^= 0x01   // perturb r
        let ok = Secp256k1.verify(signature64: Data(signature),
                                  messageHash32: hex(v1Message),
                                  xOnlyPublicKey: hex(v1PublicKey))
        XCTAssertFalse(ok, "a single flipped signature byte must fail verification")
    }

    func testVerifyRejectsWrongMessage() {
        var message = [UInt8](hex(v1Message))
        message[0] ^= 0x01
        let ok = Secp256k1.verify(signature64: hex(v1Signature),
                                  messageHash32: Data(message),
                                  xOnlyPublicKey: hex(v1PublicKey))
        XCTAssertFalse(ok, "a valid signature must not verify against a different message")
    }

    // MARK: Negative — input validation

    func testSignRejectsWrongLengthInputs() {
        let good32 = hex(v1Message)
        XCTAssertNil(Secp256k1.sign(messageHash32: good32.dropLast(), secretKey: hex(v1SecretKey)),
                     "31-byte message must be rejected")
        XCTAssertNil(Secp256k1.sign(messageHash32: good32, secretKey: hex(v1SecretKey).dropLast()),
                     "31-byte secret must be rejected")
    }

    func testSignRejectsInvalidScalar() {
        let zeroSecret = Data(repeating: 0, count: 32)   // not a valid scalar
        XCTAssertNil(Secp256k1.sign(messageHash32: hex(v1Message), secretKey: zeroSecret),
                     "all-zero secret must be rejected")
    }

    func testVerifyRejectsWrongLengthInputs() {
        XCTAssertFalse(Secp256k1.verify(signature64: hex(v1Signature).dropLast(),
                                        messageHash32: hex(v1Message),
                                        xOnlyPublicKey: hex(v1PublicKey)),
                       "63-byte signature must be rejected")
        XCTAssertFalse(Secp256k1.verify(signature64: hex(v1Signature),
                                        messageHash32: hex(v1Message).dropLast(),
                                        xOnlyPublicKey: hex(v1PublicKey)),
                       "31-byte message must be rejected")
        XCTAssertFalse(Secp256k1.verify(signature64: hex(v1Signature),
                                        messageHash32: hex(v1Message),
                                        xOnlyPublicKey: hex(v1PublicKey).dropLast()),
                       "31-byte public key must be rejected")
    }

    // MARK: Helpers

    /// Decode an even-length hex string to Data. Fails the test on malformed input.
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
