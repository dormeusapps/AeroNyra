//
//  ChaCha20Tests.swift
//  BeaconTests
//
//  Phase 8c-i-1 — RFC 8439 ChaCha20 stream-cipher tests for
//  Core/Nostr/ChaCha20.swift.
//
//  Anchored on the canonical RFC 8439 §2.4.2 encryption vector (the
//  "Ladies and Gentlemen..." plaintext, key 00..1f, nonce 00..004a..00,
//  initial counter 1), reproduced clean-room. Encryption and decryption are the
//  same XOR, so the round-trip is the same call with the same parameters.
//

import XCTest
@testable import Beacon

final class ChaCha20Tests: XCTestCase {

    func testRFC8439EncryptionVector() {
        let key = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        let nonce = hex("000000000000004a00000000")
        let plaintext = Data(
            "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
                .utf8)
        let expected = hex(
            "6e2e359a2568f98041ba0728dd0d6981" +
            "e97e7aec1d4360c20a27afccfd9fae0b" +
            "f91b65c5524733ab8f593dabcd62b357" +
            "1639d624e65152ab8f530c359f0861d8" +
            "07ca0dbf500d6a6156a38e088a22b65e" +
            "52bc514d16ccf806818ce91ab7793736" +
            "5af90bbf74a35be6b40b8eedf2785e42" +
            "874d")

        let ciphertext = ChaCha20.xor(plaintext, key: key, nonce: nonce, counter: 1)
        XCTAssertEqual(ciphertext, expected, "RFC 8439 §2.4.2 ciphertext mismatch")
    }

    func testRoundTrip() {
        let key = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        let nonce = hex("000000000000004a00000000")
        let plaintext = Data(
            "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
                .utf8)

        guard let ciphertext = ChaCha20.xor(plaintext, key: key, nonce: nonce, counter: 1) else {
            return XCTFail("encryption returned nil")
        }
        let recovered = ChaCha20.xor(ciphertext, key: key, nonce: nonce, counter: 1)
        XCTAssertEqual(recovered, plaintext, "decrypt(encrypt(x)) must equal x")
    }

    func testDefaultCounterRoundTripAtVariousLengths() {
        let key = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        let nonce = hex("000000000000004a00000000")
        // Cross block boundaries: empty, sub-block, exactly one block, over one block.
        for len in [0, 1, 63, 64, 65, 200] {
            let plaintext = Data((0..<len).map { UInt8($0 & 0xff) })
            guard let ct = ChaCha20.xor(plaintext, key: key, nonce: nonce) else {
                return XCTFail("encryption returned nil at len \(len)")
            }
            XCTAssertEqual(ct.count, len, "output length must equal input length at len \(len)")
            let rt = ChaCha20.xor(ct, key: key, nonce: nonce)
            XCTAssertEqual(rt, plaintext, "round-trip failed at len \(len)")
        }
    }

    func testRejectsWrongLengthKeyOrNonce() {
        let data = Data([1, 2, 3])
        let goodKey = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        let goodNonce = hex("000000000000004a00000000")
        XCTAssertNil(ChaCha20.xor(data, key: goodKey.dropLast(), nonce: goodNonce),
                     "31-byte key must be rejected")
        XCTAssertNil(ChaCha20.xor(data, key: goodKey, nonce: goodNonce.dropLast()),
                     "11-byte nonce must be rejected")
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
