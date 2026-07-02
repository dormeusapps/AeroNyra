// MessagePayloadInviteEchoTests.swift
// BeaconTests
//
// Covers the STEP 7c-2 `.inviteEcho` payload kind. Vectors are fixed/anchored:
// the encoded form is `[0x07] ‖ inviteID(16)`, mirroring how `.ack` /
// `.nostrIdentity` / `.reconnectHello` are tested inline (a trivial tagged body
// needs no separate KAT doc, only its own strict parser check).
//
// Properties:
//   • the on-wire tag is 7 and never collides with an existing kind;
//   • encoded() == [0x07] ‖ id, and decode() round-trips;
//   • the builder/parser pair round-trips, and parse strictly rejects any body
//     that isn't exactly 16 bytes (the untrusted-input boundary);
//   • sealedPlaintext()/decodeSealed() round-trips through PayloadPadding, so the
//     echo is a padded (length-hiding) small kind like ack/hello.

import XCTest
@testable import Beacon

final class MessagePayloadInviteEchoTests: XCTestCase {

    // 16-byte fixture id: 00 01 02 … 0f
    private let id16 = Data((0..<16).map { UInt8($0) })

    func testKindTagIsSevenAndUnique() {
        XCTAssertEqual(WirePayloadKind.inviteEcho.rawValue, 7)
        // No other kind shares the tag.
        let tags = WirePayloadKind.allCases.map(\.rawValue)
        XCTAssertEqual(tags.count, Set(tags).count)
    }

    func testEncodedIsTagThenBody() {
        let encoded = MessagePayload.inviteEcho(id16).encoded()
        XCTAssertEqual(encoded, Data([0x07]) + id16)          // 17 bytes
        XCTAssertEqual(encoded.count, 17)
    }

    func testDecodeRoundTrips() {
        let wire = Data([0x07]) + id16
        XCTAssertEqual(MessagePayload.decode(wire), .inviteEcho(id16))
    }

    func testBuilderAndBody() {
        let p = MessagePayload.inviteEchoV1(inviteID: id16)
        XCTAssertEqual(p, .inviteEcho(id16))
        XCTAssertEqual(p.body, id16)
        XCTAssertEqual(p.kind, .inviteEcho)
    }

    func testParseInviteEchoAcceptsExactly16() {
        XCTAssertEqual(MessagePayload.parseInviteEcho(id16), id16)
    }

    func testParseInviteEchoRejectsWrongLength() {
        XCTAssertNil(MessagePayload.parseInviteEcho(Data(repeating: 0xAB, count: 15)))
        XCTAssertNil(MessagePayload.parseInviteEcho(Data(repeating: 0xAB, count: 17)))
        XCTAssertNil(MessagePayload.parseInviteEcho(Data()))
    }

    func testSealedRoundTripThroughPadding() {
        // The echo is a SMALL kind → sealedPlaintext pads it; decodeSealed unpads.
        let p = MessagePayload.inviteEcho(id16)
        let sealed = p.sealedPlaintext()
        XCTAssertNotEqual(sealed, p.encoded())                // padding was applied
        XCTAssertEqual(MessagePayload.decodeSealed(sealed), p)
    }
}
