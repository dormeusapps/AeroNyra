// MessagePayloadInviteEchoV2Tests.swift
// BeaconTests
//
// Covers the `.inviteEchoV2` payload kind (npub-bootstrap over pure Nostr):
// the encoded form is `[0x0B] ‖ inviteID(16) ‖ redeemerNpub(32)`, mirroring
// MessagePayloadInviteEchoTests (tag 7), which stays untouched as the
// backward-decode pin — a V1 (id-only) echo must keep decoding forever.
//
// Properties:
//   • the on-wire tag is 11 and never collides with an existing kind;
//   • encoded() == [0x0B] ‖ id ‖ npub (49 bytes), and decode() round-trips;
//   • the builder/parser pair round-trips and splits the halves correctly, and
//     parse strictly rejects any body that isn't exactly 48 bytes (the
//     untrusted-input boundary, same discipline as parseInviteEcho /
//     parseNostrIdentity);
//   • cross-tag confusion is pinned: a V1-tagged 48-byte wire decodes as
//     `.inviteEcho` and V1's strict parse rejects it; a V2-tagged 16-byte wire
//     decodes as `.inviteEchoV2` and V2's strict parse rejects it — neither
//     version's body can be smuggled through the other's parser;
//   • sealedPlaintext()/decodeSealed() round-trips through PayloadPadding and
//     lands in the SAME 256-byte bucket as V1, so V2 is wire-indistinguishable
//     from every other small kind (no tier crossing).

import XCTest
@testable import Beacon

final class MessagePayloadInviteEchoV2Tests: XCTestCase {

    // 16-byte fixture id: 00 01 02 … 0f (same fixture as the V1 KATs)
    private let id16 = Data((0..<16).map { UInt8($0) })
    // 32-byte fixture npub: a0 a1 … bf (disjoint from the id bytes, so a
    // mis-split of the body cannot accidentally pass the equality checks)
    private let npub32 = Data((0..<32).map { UInt8(0xA0 + $0) })

    private var body48: Data { id16 + npub32 }

    func testKindTagIsElevenAndUnique() {
        XCTAssertEqual(WirePayloadKind.inviteEchoV2.rawValue, 11)
        // No other kind shares the tag.
        let tags = WirePayloadKind.allCases.map(\.rawValue)
        XCTAssertEqual(tags.count, Set(tags).count)
    }

    func testEncodedIsTagThenBody() {
        let encoded = MessagePayload.inviteEchoV2(body48).encoded()
        XCTAssertEqual(encoded, Data([0x0B]) + id16 + npub32)   // 49 bytes
        XCTAssertEqual(encoded.count, 49)
    }

    func testDecodeRoundTrips() {
        let wire = Data([0x0B]) + id16 + npub32
        XCTAssertEqual(MessagePayload.decode(wire), .inviteEchoV2(body48))
    }

    func testBuilderAndBody() {
        let p = MessagePayload.inviteEchoV2(inviteID: id16, redeemerNostrPubkey: npub32)
        XCTAssertEqual(p, .inviteEchoV2(body48))
        XCTAssertEqual(p.body, body48)
        XCTAssertEqual(p.kind, .inviteEchoV2)
    }

    func testParseAcceptsExactly48AndSplitsHalves() {
        let parsed = MessagePayload.parseInviteEchoV2(body48)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.inviteID, id16)
        XCTAssertEqual(parsed?.redeemerNostrPubkey, npub32)
    }

    func testParseRejectsWrongLength() {
        XCTAssertNil(MessagePayload.parseInviteEchoV2(Data(repeating: 0xAB, count: 47)))
        XCTAssertNil(MessagePayload.parseInviteEchoV2(Data(repeating: 0xAB, count: 49)))
        XCTAssertNil(MessagePayload.parseInviteEchoV2(id16))     // a bare V1 body
        XCTAssertNil(MessagePayload.parseInviteEchoV2(npub32))   // a bare npub
        XCTAssertNil(MessagePayload.parseInviteEchoV2(Data()))
    }

    func testCrossTagConfusionIsRejected() {
        // A V2-sized body under the V1 tag decodes as V1 — and V1's strict
        // 16-byte parse rejects it. No npub can be smuggled through tag 7.
        let v1TaggedWire = Data([0x07]) + body48
        XCTAssertEqual(MessagePayload.decode(v1TaggedWire), .inviteEcho(body48))
        XCTAssertNil(MessagePayload.parseInviteEcho(body48))

        // A V1-sized body under the V2 tag decodes as V2 — and V2's strict
        // 48-byte parse rejects it. A truncated echo cannot half-redeem.
        let v2TaggedWire = Data([0x0B]) + id16
        XCTAssertEqual(MessagePayload.decode(v2TaggedWire), .inviteEchoV2(id16))
        XCTAssertNil(MessagePayload.parseInviteEchoV2(id16))
    }

    func testSealedRoundTripThroughPadding() {
        // V2 is a SMALL kind → sealedPlaintext pads it; decodeSealed unpads —
        // and it fills the SAME 256-byte bucket as the 17-byte V1 (49 + 4-byte
        // length header = 53 → 256), so the version is not visible on the wire.
        let p = MessagePayload.inviteEchoV2(body48)
        let sealed = p.sealedPlaintext()
        XCTAssertNotEqual(sealed, p.encoded())                  // padding was applied
        XCTAssertEqual(sealed.count, 256)                       // same tier as V1
        XCTAssertEqual(MessagePayload.decodeSealed(sealed), p)
    }
}
