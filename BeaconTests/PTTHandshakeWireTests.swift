//
//  PTTHandshakeWireTests.swift
//  BeaconTests
//
//  KAT pins for PTT Part A — the open/close handshake wire bodies and the
//  directional recv-key derivation. Vectors were computed EXTERNALLY (independent
//  HMAC-SHA256) and are frozen here: if the wire encoding of `.pttOpen` /
//  `.pttClose`, the tag numbers (12/13), or the HKDF schedule drift, these fail.
//  S on the wire is security-critical, so the malformed-length rejections are
//  pinned too.
//

import XCTest
import CryptoKit
@testable import Beacon

final class PTTHandshakeWireTests: XCTestCase {

    // Fixed inputs shared with the external vector computation.
    private let pttID = Data((0x10...0x1f).map { UInt8($0) })      // 10 11 … 1f (16)
    private let secret = Data(repeating: 0x5A, count: 32)          // S = 0x5A × 32

    private func hexData(_ s: String) -> Data {
        var out = [UInt8]()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return Data(out)
    }

    // MARK: 1 — wire bodies match the external vectors, byte-for-byte

    func testPTTOpenBodyVector() {
        let expected = hexData(
            "101112131415161718191a1b1c1d1e1f" +
            "5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a")
        XCTAssertEqual(expected.count, 48)
        let payload = MessagePayload.pttOpenV1(pttID: pttID, secret: secret)
        XCTAssertEqual(payload.body, expected)                    // pttID(16) ‖ S(32)
        XCTAssertEqual(payload.kind, .pttOpen)
        XCTAssertEqual(WirePayloadKind.pttOpen.rawValue, 12)
        // encoded() = [kind] ‖ body
        XCTAssertEqual(payload.encoded(), Data([12]) + expected)
    }

    func testPTTCloseBodyVector() {
        let expected = hexData("101112131415161718191a1b1c1d1e1f")
        XCTAssertEqual(expected.count, 16)
        let payload = MessagePayload.pttCloseV1(pttID: pttID)
        XCTAssertEqual(payload.body, expected)                    // pttID(16)
        XCTAssertEqual(payload.kind, .pttClose)
        XCTAssertEqual(WirePayloadKind.pttClose.rawValue, 13)
        XCTAssertEqual(payload.encoded(), Data([13]) + expected)
    }

    // MARK: 2 — decode round-trips and the parsers split the fields

    func testDecodeRoundTripAndSplit() {
        let openWire = MessagePayload.pttOpenV1(pttID: pttID, secret: secret).encoded()
        guard case .pttOpen(let openBody)? = MessagePayload.decode(openWire) else {
            return XCTFail("pttOpen did not decode")
        }
        let split = MessagePayload.parsePTTOpen(openBody)
        XCTAssertEqual(split?.pttID, pttID)
        XCTAssertEqual(split?.secret, secret)

        let closeWire = MessagePayload.pttCloseV1(pttID: pttID).encoded()
        guard case .pttClose(let closeBody)? = MessagePayload.decode(closeWire) else {
            return XCTFail("pttClose did not decode")
        }
        XCTAssertEqual(MessagePayload.parsePTTClose(closeBody), pttID)
    }

    // MARK: 3 — decode REJECTS any body length ≠ 48 / 16 (S is security-critical)

    func testDecodeRejectsWrongLengths() {
        // pttOpen (tag 12): only 48 is valid.
        XCTAssertNil(MessagePayload.decode(Data([12]) + Data(repeating: 0, count: 47)))
        XCTAssertNil(MessagePayload.decode(Data([12]) + Data(repeating: 0, count: 49)))
        XCTAssertNotNil(MessagePayload.decode(Data([12]) + Data(repeating: 0, count: 48)))
        // pttClose (tag 13): only 16 is valid.
        XCTAssertNil(MessagePayload.decode(Data([13]) + Data(repeating: 0, count: 15)))
        XCTAssertNil(MessagePayload.decode(Data([13]) + Data(repeating: 0, count: 17)))
        XCTAssertNotNil(MessagePayload.decode(Data([13]) + Data(repeating: 0, count: 16)))
        // Parsers reject the same.
        XCTAssertNil(MessagePayload.parsePTTOpen(Data(repeating: 0, count: 47)))
        XCTAssertNil(MessagePayload.parsePTTClose(Data(repeating: 0, count: 15)))
    }

    // MARK: 4 — directional recv keys from S match the external HKDF vectors

    func testDirectionalKeysVector() {
        let keys = PTTSessionCrypto.directionalKeys(secret: SymmetricKey(data: secret))
        let ir = keys.initiatorToResponder.withUnsafeBytes { Data($0) }
        let ri = keys.responderToInitiator.withUnsafeBytes { Data($0) }
        XCTAssertEqual(ir, hexData("896e8199c4b066ae0c4586a195b58db6ca10e94ab7b3137156d50a6125d558ab"))
        XCTAssertEqual(ri, hexData("68621a06b307b16e3f3a21ba0d4b76d2fec353b697da007d91e9f180eadd2b1c"))
    }
}
