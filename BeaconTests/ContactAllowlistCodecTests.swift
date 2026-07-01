//
//  ContactAllowlistCodecTests.swift
//  BeaconTests
//
//  STEP 7a-1 — the at-rest ContactAllowlist codec.
//
//  The KAT vectors below were computed OUT of the Swift implementation (a
//  standalone script), per the project rule that a primitive is anchored to an
//  externally-computed vector before any code is trusted. The encoder is checked
//  to REPRODUCE these bytes; the decoder is checked to round-trip and to REJECT
//  malformed input (a persisted admission set must never silently mutate).
//
//  Format v1: [version:1][count:2 BE] + count*([id:32][pairedAt:8 Int64 BE][verified:1]),
//  entries emitted sorted ascending by identity.
//
//  XCTest only.
//

import XCTest
@testable import Beacon

final class ContactAllowlistCodecTests: XCTestCase {

    // MARK: - Fixtures + KAT constants (externally computed)

    /// identity = 0x00 0x01 … 0x1f
    private let id0to31 = Data((0..<32).map { UInt8($0) })
    private let idAA = Data(repeating: 0xAA, count: 32)
    private let id11 = Data(repeating: 0x11, count: 32)
    private let pairedV2: Int64 = 1_719_849_600_000

    /// Empty set.
    private let katEmpty = "010000"
    /// Single entry: id0to31, pairedAt=1719849600000, verified=true.
    private let katSingle =
        "010001" +
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" +
        "000001906f064400" + "01"
    /// Two entries handed in as (idAA,1000,false) then (id11,2000,true);
    /// canonical sort must place id11 (0x11..) BEFORE idAA (0xAA..).
    private let katTwoSorted =
        "010002" +
        "1111111111111111111111111111111111111111111111111111111111111111" +
        "00000000000007d0" + "01" +
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" +
        "00000000000003e8" + "00"

    // MARK: - Encode reproduces the KAT bytes

    func testEncodeEmptyMatchesKAT() throws {
        let out = try ContactAllowlistCodec.encode(ContactAllowlist())
        XCTAssertEqual(out.hexString, katEmpty)
    }

    func testEncodeSingleMatchesKAT() throws {
        var a = ContactAllowlist()
        a.enroll(identity: id0to31, at: pairedV2, verified: true)
        let out = try ContactAllowlistCodec.encode(a)
        XCTAssertEqual(out.hexString, katSingle)
    }

    func testEncodeIsCanonicalRegardlessOfInsertionOrder() throws {
        // Insert AA first, 11 second — the encoder must still emit 11 before AA.
        var a = ContactAllowlist()
        a.enroll(identity: idAA, at: 1000, verified: false)
        a.enroll(identity: id11, at: 2000, verified: true)
        XCTAssertEqual(try ContactAllowlistCodec.encode(a).hexString, katTwoSorted)

        // And the reverse insertion order yields the identical bytes.
        var b = ContactAllowlist()
        b.enroll(identity: id11, at: 2000, verified: true)
        b.enroll(identity: idAA, at: 1000, verified: false)
        XCTAssertEqual(try ContactAllowlistCodec.encode(b).hexString, katTwoSorted)
    }

    // MARK: - Decode round-trips the KAT bytes

    func testDecodeSingleRoundTrip() throws {
        let a = try ContactAllowlistCodec.decode(Data(hex: katSingle))
        XCTAssertEqual(a.count, 1)
        XCTAssertTrue(a.contains(identity: id0to31))
        XCTAssertEqual(a.entry(for: id0to31)?.pairedAt, pairedV2)
        XCTAssertEqual(a.entry(for: id0to31)?.verified, true)
    }

    func testDecodeEmptyRoundTrip() throws {
        let a = try ContactAllowlistCodec.decode(Data(hex: katEmpty))
        XCTAssertEqual(a.count, 0)
    }

    func testEncodeDecodeIsIdentity() throws {
        var a = ContactAllowlist()
        a.enroll(identity: id0to31, at: pairedV2, verified: true)
        a.enroll(identity: idAA, at: 1000, verified: false)
        a.enroll(identity: id11, at: -5, verified: true)   // negative pairedAt round-trips too
        let restored = try ContactAllowlistCodec.decode(try ContactAllowlistCodec.encode(a))
        XCTAssertEqual(restored, a)
    }

    // MARK: - Strict decode rejections

    func testDecodeRejectsShortBuffer() {
        XCTAssertThrowsError(try ContactAllowlistCodec.decode(Data([0x01, 0x00]))) {
            XCTAssertEqual($0 as? ContactAllowlistCodec.CodecError, .shortBuffer)
        }
    }

    func testDecodeRejectsUnknownVersion() {
        var bytes = Data(hex: katSingle); bytes[0] = 0x02
        XCTAssertThrowsError(try ContactAllowlistCodec.decode(bytes)) {
            XCTAssertEqual($0 as? ContactAllowlistCodec.CodecError, .unknownVersion(0x02))
        }
    }

    func testDecodeRejectsLengthMismatch() {
        let bytes = Data(hex: katSingle) + Data([0x00])   // one trailing byte
        XCTAssertThrowsError(try ContactAllowlistCodec.decode(bytes)) {
            guard case .lengthMismatch = ($0 as? ContactAllowlistCodec.CodecError) else {
                return XCTFail("expected .lengthMismatch, got \($0)")
            }
        }
    }

    func testDecodeRejectsBadVerifiedByte() {
        var bytes = Data(hex: katSingle)
        bytes[bytes.count - 1] = 0x02                      // verified flag → invalid
        XCTAssertThrowsError(try ContactAllowlistCodec.decode(bytes)) {
            XCTAssertEqual($0 as? ContactAllowlistCodec.CodecError, .badVerifiedByte(0x02))
        }
    }

    func testDecodeRejectsDuplicateIdentity() {
        // Hand-craft a 2-entry blob whose two identities are identical.
        let entry = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f" +
                    "000001906f064400" + "01"
        let dup = Data(hex: "010002" + entry + entry)
        XCTAssertThrowsError(try ContactAllowlistCodec.decode(dup)) {
            XCTAssertEqual($0 as? ContactAllowlistCodec.CodecError, .duplicateIdentity)
        }
    }
}

// MARK: - Local hex helpers (test-only)

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init(hex: String) {
        var out = [UInt8]()
        out.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            out.append(UInt8(hex[idx..<next], radix: 16)!)
            idx = next
        }
        self = Data(out)
    }
}
