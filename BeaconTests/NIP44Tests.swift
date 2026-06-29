//
//  NIP44Tests.swift
//  BeaconTests
//
//  Phase 8c-i-2 — NIP-44 v2 tests for Core/Nostr/NIP44.swift.
//
//  Anchored on the official NIP-44 vectors (paulmillr/nip44 nip44.vectors.json),
//  validated clean-room before embedding:
//   - get_conversation_key[0]  -> conversationKey derivation
//   - encrypt_decrypt[0], [1]  -> deterministic encrypt (fixed nonce) + decrypt
//   - calc_padded_len rows      -> padding
//

import XCTest
@testable import Beacon

final class NIP44Tests: XCTestCase {

    // get_conversation_key[0]
    private let gckSec1 = "315e59ff51cb9209768cf7da80791ddcaae56ac9775eb25b6dee1234bc5d2268"
    private let gckPub2 = "c2f9d9948dc8c7c38321e4b85c8558872eafa0641cd269db76848a6073e69133"
    private let gckConvKey = "3dfef0ce2a4d80a25e7a328accf73448ef67096f65f79588e358d9a0eb9013f1"

    // encrypt_decrypt[0]
    private let ed0Sec1 = "0000000000000000000000000000000000000000000000000000000000000001"
    private let ed0Sec2 = "0000000000000000000000000000000000000000000000000000000000000002"
    private let ed0ConvKey = "c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d"
    private let ed0Nonce = "0000000000000000000000000000000000000000000000000000000000000001"
    private let ed0Plaintext = "a"
    private let ed0Payload = "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb"

    // encrypt_decrypt[1]  (plaintext is 🍕🫃)
    private let ed1ConvKey = "c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d"
    private let ed1Nonce = "f00000000000000000000000000000f00000000000000000000000000000000f"
    private let ed1Plaintext = "\u{1F355}\u{1FAC3}"
    private let ed1Payload = "AvAAAAAAAAAAAAAAAAAAAPAAAAAAAAAAAAAAAAAAAAAPSKSK6is9ngkX2+cSq85Th16oRTISAOfhStnixqZziKMDvB0QQzgFZdjLTPicCJaV8nDITO+QfaQ61+KbWQIOO2Yj"

    // MARK: Conversation key

    func testConversationKeyKnownAnswer() throws {
        let ck = try NIP44.conversationKey(mySecret: hex(gckSec1), peerPublicKey: hex(gckPub2))
        XCTAssertEqual(ck, hex(gckConvKey))
    }

    func testConversationKeyIsSymmetric() throws {
        guard let pub1 = Secp256k1.xOnlyPublicKey(fromSecretKey: hex(ed0Sec1)),
              let pub2 = Secp256k1.xOnlyPublicKey(fromSecretKey: hex(ed0Sec2)) else {
            return XCTFail("pubkey derivation failed")
        }
        let ab = try NIP44.conversationKey(mySecret: hex(ed0Sec1), peerPublicKey: pub2)
        let ba = try NIP44.conversationKey(mySecret: hex(ed0Sec2), peerPublicKey: pub1)
        XCTAssertEqual(ab, ba)
        XCTAssertEqual(ab, hex(ed0ConvKey), "derived conversation key must match the vector")
    }

    // MARK: Encrypt (deterministic, fixed nonce)

    func testEncryptKnownAnswer() throws {
        let p0 = try NIP44.encrypt(plaintext: ed0Plaintext,
                                   conversationKey: hex(ed0ConvKey),
                                   nonce: hex(ed0Nonce))
        XCTAssertEqual(p0, ed0Payload)

        let p1 = try NIP44.encrypt(plaintext: ed1Plaintext,
                                   conversationKey: hex(ed1ConvKey),
                                   nonce: hex(ed1Nonce))
        XCTAssertEqual(p1, ed1Payload)
    }

    func testDecryptKnownAnswer() throws {
        XCTAssertEqual(try NIP44.decrypt(payload: ed0Payload, conversationKey: hex(ed0ConvKey)),
                       ed0Plaintext)
        XCTAssertEqual(try NIP44.decrypt(payload: ed1Payload, conversationKey: hex(ed1ConvKey)),
                       ed1Plaintext)
    }

    // MARK: Round-trip with a random nonce

    func testEncryptDecryptRoundTripRandomNonce() throws {
        let ck = hex(ed0ConvKey)
        let message = "the quick brown fox jumps over the lazy dog 🦊"
        let payloadA = try NIP44.encrypt(plaintext: message, conversationKey: ck)
        let payloadB = try NIP44.encrypt(plaintext: message, conversationKey: ck)
        XCTAssertNotEqual(payloadA, payloadB, "fresh nonce should make payloads differ")
        XCTAssertEqual(try NIP44.decrypt(payload: payloadA, conversationKey: ck), message)
        XCTAssertEqual(try NIP44.decrypt(payload: payloadB, conversationKey: ck), message)
    }

    // MARK: Padding

    func testCalcPaddedLen() {
        let cases: [(Int, Int)] = [(16, 32), (32, 32), (33, 64), (65, 96),
                                   (200, 224), (1020, 1024), (65536, 65536)]
        for (input, expected) in cases {
            XCTAssertEqual(NIP44.calcPaddedLen(input), expected, "calcPaddedLen(\(input))")
        }
    }

    // MARK: Negative

    func testDecryptRejectsTamperedCiphertext() {
        var bytes = [UInt8](Data(base64Encoded: ed0Payload)!)
        bytes[40] ^= 0x01   // flip a byte inside the ciphertext region
        let tampered = Data(bytes).base64EncodedString()
        XCTAssertThrowsError(try NIP44.decrypt(payload: tampered, conversationKey: hex(ed0ConvKey))) {
            XCTAssertEqual($0 as? NIP44Error, .invalidMAC)
        }
    }

    func testDecryptRejectsWrongVersion() {
        var bytes = [UInt8](Data(base64Encoded: ed0Payload)!)
        bytes[0] = 0x03
        let wrongVersion = Data(bytes).base64EncodedString()
        XCTAssertThrowsError(try NIP44.decrypt(payload: wrongVersion, conversationKey: hex(ed0ConvKey))) {
            XCTAssertEqual($0 as? NIP44Error, .invalidPayload)
        }
    }

    func testEncryptRejectsEmptyPlaintext() {
        XCTAssertThrowsError(try NIP44.encrypt(plaintext: "", conversationKey: hex(ed0ConvKey))) {
            XCTAssertEqual($0 as? NIP44Error, .invalidPlaintextLength)
        }
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
