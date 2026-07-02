// PendingInvitesCodecTests.swift
// BeaconTests
//
// KAT-anchored tests for `PendingInvitesCodec` (STEP 7c-2). Every expected byte
// string here was computed OUTSIDE the Swift implementation and is recorded in
// docs/PENDING_INVITES_CODEC_KAT.md. Changing a vector here WITHOUT recomputing
// the whole set in that doc is forbidden.
//
// Coverage:
//   • encode(empty/single/three) == V0/V1/V2 byte-for-byte.
//   • V2 is built via `register` in the OUT-OF-ORDER sequence hi→lo→mid, so the
//     test actually exercises the canonical ascending-by-id sort.
//   • decode(V0/V1/V2) reproduces the exact {id → expiresAt} map.
//   • round-trip decode(encode(x)).entries == x.entries.
//   • each negative blob throws its mapped CodecError case.

import XCTest
@testable import Beacon

final class PendingInvitesCodecTests: XCTestCase {

    // MARK: - Fixtures (must match PENDING_INVITES_CODEC_KAT.md)

    private let idS  = hex("00112233445566778899aabbccddeeff")
    private let idLo  = Data([0x01] + Array(repeating: UInt8(0xaa), count: 15))
    private let idMid = Data([0x02] + Array(repeating: UInt8(0xff), count: 15))
    private let idHi  = Data([0x03] + Array(repeating: UInt8(0x00), count: 15))

    private let e1: Int64 = 1_700_000_000_000
    private let e2: Int64 = 1_700_000_600_000
    private let e3: Int64 = 1_700_000_123_456

    // Canonical blobs.
    private let v0 = hex("010000")
    private let v1 = hex("01000100112233445566778899aabbccddeeff0000018bcfe56800")
    private let v2 = hex("01000301aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0000018bcfe56800" +
                         "02ffffffffffffffffffffffffffffff0000018bcfee8fc0" +
                         "030000000000000000000000000000000000018bcfe74a40")

    // MARK: - Positive: encode == canonical bytes

    func testEncodeEmpty() throws {
        let out = try PendingInvitesCodec.encode(PendingInvites())
        XCTAssertEqual(out, v0)
    }

    func testEncodeSingle() throws {
        var led = PendingInvites()
        led.register(id: idS, expiresAt: e1)
        XCTAssertEqual(try PendingInvitesCodec.encode(led), v1)
    }

    /// Sort proof: feed hi→lo→mid, expect emitted lo→mid→hi (== V2).
    func testEncodeThreeIsCanonicalRegardlessOfInsertionOrder() throws {
        var led = PendingInvites()
        led.register(id: idHi,  expiresAt: e3)
        led.register(id: idLo,  expiresAt: e1)
        led.register(id: idMid, expiresAt: e2)
        XCTAssertEqual(try PendingInvitesCodec.encode(led), v2)
    }

    // MARK: - Positive: decode reproduces the map

    func testDecodeEmpty() throws {
        let led = try PendingInvitesCodec.decode(v0)
        XCTAssertEqual(led.entries, [:])
        XCTAssertEqual(led.count, 0)
    }

    func testDecodeSingle() throws {
        let led = try PendingInvitesCodec.decode(v1)
        XCTAssertEqual(led.entries, [idS: e1])
    }

    func testDecodeThree() throws {
        let led = try PendingInvitesCodec.decode(v2)
        XCTAssertEqual(led.entries, [idLo: e1, idMid: e2, idHi: e3])
    }

    // MARK: - Round-trip

    func testRoundTrip() throws {
        var led = PendingInvites()
        led.register(id: idHi,  expiresAt: e3)
        led.register(id: idLo,  expiresAt: e1)
        led.register(id: idMid, expiresAt: e2)
        let back = try PendingInvitesCodec.decode(PendingInvitesCodec.encode(led))
        XCTAssertEqual(back.entries, led.entries)
    }

    // MARK: - Negative: strict decode throws mapped errors

    func testDecodeShortBufferThrows() {
        XCTAssertThrowsError(try PendingInvitesCodec.decode(hex("0100"))) {
            XCTAssertEqual($0 as? PendingInvitesCodec.CodecError, .shortBuffer)
        }
    }

    func testDecodeUnknownVersionThrows() {
        let blob = hex("02000100112233445566778899aabbccddeeff0000018bcfe56800")
        XCTAssertThrowsError(try PendingInvitesCodec.decode(blob)) {
            XCTAssertEqual($0 as? PendingInvitesCodec.CodecError, .unknownVersion(0x02))
        }
    }

    func testDecodeLengthMismatchThrows() {
        // count says 2, only one 24-byte record present → expected 51, actual 27.
        let blob = hex("01000200112233445566778899aabbccddeeff0000018bcfe56800")
        XCTAssertThrowsError(try PendingInvitesCodec.decode(blob)) {
            XCTAssertEqual($0 as? PendingInvitesCodec.CodecError,
                           .lengthMismatch(expected: 51, actual: 27))
        }
    }

    func testDecodeDuplicateIDThrows() {
        // count 2, same idS twice; length is a valid 51 bytes so it reaches the dup check.
        let blob = hex("01000200112233445566778899aabbccddeeff0000018bcfe56800" +
                       "00112233445566778899aabbccddeeff0000018bcfee8fc0")
        XCTAssertThrowsError(try PendingInvitesCodec.decode(blob)) {
            XCTAssertEqual($0 as? PendingInvitesCodec.CodecError, .duplicateID)
        }
    }
}

// MARK: - Local hex helper (test-only)

private func hex(_ s: String) -> Data {
    precondition(s.count % 2 == 0, "hex string must have even length")
    var d = Data(capacity: s.count / 2)
    var idx = s.startIndex
    while idx < s.endIndex {
        let next = s.index(idx, offsetBy: 2)
        guard let byte = UInt8(s[idx..<next], radix: 16) else {
            preconditionFailure("invalid hex byte")
        }
        d.append(byte)
        idx = next
    }
    return d
}
