// MessagePayloadReconnectHelloTests.swift
// BeaconTests
//
// Step 5d-1 (Closed-Contact): the `MessagePayload.reconnectHello` codec.
//
// The reconnect-hello is the sealed "it's-me" of the reconnection auth handshake
// (RECONNECT_AUTH_WIRING_5d.md §2.2). It reuses the existing tagged-plaintext
// machinery wholesale — a new `WirePayloadKind` (6), a 1-byte version-tag body,
// and the same `PayloadPadding` small-kind path text/ack/nostrIdentity already
// take — so this suite pins exactly that:
//
//   • wire framing      — encoded() is [tag=6 ‖ version=0x01], the on-wire bytes
//   • decode round-trip — encoded() → decode() recovers the payload
//   • padding inverse   — decodeSealed(sealedPlaintext()) is the identity (9b)
//   • indistinguishability — sealed length equals other SMALL kinds' (the §2.2
//                            property: byte-indistinguishable from a short
//                            .whisper, without hardcoding the bucket constant)
//   • disambiguation    — a padded hello is never misread as media, and media
//                          still round-trips unpadded through decodeSealed
//   • strict parser     — exactly-1-byte boundary, slice-index safe
//   • forward-compat    — tag 6 is now known; an unknown tag still decodes nil
//
// XCTest only; no live path is touched (pure primitive, green in isolation).

import XCTest
@testable import Beacon

final class MessagePayloadReconnectHelloTests: XCTestCase {

    // MARK: Wire framing (the on-wire bytes, pinned)

    /// encoded() == [tag, version] == [6, 1]. This is the framing anchor: tag
    /// byte 6 (WirePayloadKind.reconnectHello) followed by the 0x01 version.
    func testEncodedFramingIsTagThenVersion() {
        let p = MessagePayload.reconnectHelloV1()
        XCTAssertEqual(p.encoded(), Data([6, 1]),
                       "reconnectHello v1 must serialize to [tag=6 ‖ version=0x01]")
    }

    func testKindAndRawValue() {
        XCTAssertEqual(MessagePayload.reconnectHelloV1().kind, .reconnectHello)
        XCTAssertEqual(WirePayloadKind.reconnectHello.rawValue, 6)
    }

    func testVersionConstantIsOne() {
        XCTAssertEqual(MessagePayload.reconnectHelloVersion, 0x01)
    }

    func testBodyIsTheSingleVersionByte() {
        XCTAssertEqual(MessagePayload.reconnectHelloV1().body, Data([0x01]))
    }

    func testReconnectHelloIsCaseIterable() {
        XCTAssertTrue(WirePayloadKind.allCases.contains(.reconnectHello))
    }

    // MARK: decode round-trip (tag split, no padding)

    func testDecodeRoundTrip() {
        let p = MessagePayload.reconnectHelloV1()
        XCTAssertEqual(MessagePayload.decode(p.encoded()), p)
    }

    func testDecodeYieldsReconnectHelloKind() {
        let decoded = MessagePayload.decode(Data([6, 1]))
        XCTAssertEqual(decoded, .reconnectHello(Data([0x01])))
    }

    // MARK: Padding inverse (Phase 9b: decodeSealed ∘ sealedPlaintext == id)

    func testSealedPlaintextRoundTrip() {
        let p = MessagePayload.reconnectHelloV1()
        XCTAssertEqual(MessagePayload.decodeSealed(p.sealedPlaintext()), p,
                       "decodeSealed must invert sealedPlaintext for reconnectHello")
    }

    /// Padding actually happened: the small kind is collapsed to a bucket, so
    /// the sealed form is strictly larger than the 2-byte encoded form.
    func testSealedPlaintextIsPadded() {
        let p = MessagePayload.reconnectHelloV1()
        XCTAssertGreaterThan(p.sealedPlaintext().count, p.encoded().count,
                             "a SMALL kind must be padded up to a bucket by sealedPlaintext")
    }

    // MARK: Indistinguishability (RECONNECT_AUTH_WIRING_5d.md §2.2)

    /// The whole point of padding the hello: on the wire it must be
    /// byte-indistinguishable in LENGTH from any other short sealed message.
    /// Assert equal sealed length against the other SMALL kinds (a short text
    /// and a realistic 17-byte ack), without hardcoding the bucket size — they
    /// all land in the smallest tier.
    func testSealedLengthMatchesOtherSmallKinds() {
        let hello = MessagePayload.reconnectHelloV1().sealedPlaintext()
        let text  = MessagePayload.text(Data("hi".utf8)).sealedPlaintext()
        let ack   = MessagePayload.ack(Data(count: 17)).sealedPlaintext()
        XCTAssertEqual(hello.count, text.count,
                       "a reconnectHello must seal to the same length as a short text")
        XCTAssertEqual(hello.count, ack.count,
                       "a reconnectHello must seal to the same length as a short ack")
    }

    // MARK: decodeSealed disambiguation (leading-byte routing)

    /// A padded hello must NOT begin with a media tag (2 or 3); otherwise
    /// decodeSealed's leading-byte fast path would misroute it as media. The pad
    /// header's high byte is 0x00 for any realistic size, so this holds — pin it.
    func testSealedHelloDoesNotLeadWithMediaTag() {
        let first = MessagePayload.reconnectHelloV1().sealedPlaintext().first
        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, WirePayloadKind.mediaManifest.rawValue)
        XCTAssertNotEqual(first, WirePayloadKind.mediaChunk.rawValue)
    }

    /// Media is exempt from padding and must still round-trip through
    /// decodeSealed unchanged — confirming the new kind did not disturb the
    /// media branch.
    func testMediaStillRoundTripsUnpaddedThroughDecodeSealed() {
        let m = MessagePayload.mediaManifest(Data([0x10, 0x20, 0x30]))
        XCTAssertEqual(m.sealedPlaintext(), m.encoded(), "media is padding-exempt")
        XCTAssertEqual(MessagePayload.decodeSealed(m.sealedPlaintext()), m)
    }

    // MARK: Strict parser (untrusted-input boundary)

    func testParseReconnectHelloReturnsVersion() {
        XCTAssertEqual(MessagePayload.parseReconnectHello(Data([0x01])), 0x01)
        XCTAssertEqual(MessagePayload.parseReconnectHello(Data([0x07])), 0x07)
    }

    func testParseReconnectHelloRejectsWrongLength() {
        XCTAssertNil(MessagePayload.parseReconnectHello(Data()),        "empty body rejected")
        XCTAssertNil(MessagePayload.parseReconnectHello(Data([0, 0])),  "2-byte body rejected")
    }

    /// The parser must read by `startIndex`, not a hardcoded 0: a body sliced off
    /// a larger buffer (as produced by `dropFirst` without re-wrapping) has a
    /// nonzero start index. Indexing by 0 there would trap; this proves it does
    /// not, and reads the correct byte.
    func testParseReconnectHelloIsSliceIndexSafe() {
        let sliced = Data([0xAA, 0xBB, 0x01]).dropFirst(2)   // startIndex == 2, count 1
        XCTAssertEqual(sliced.count, 1)
        XCTAssertEqual(MessagePayload.parseReconnectHello(sliced), 0x01)
    }

    /// End-to-end: build → encode → decode → extract body → parse the version.
    func testBuilderToParserPipeline() {
        let built = MessagePayload.reconnectHelloV1()
        guard case let .reconnectHello(body)? = MessagePayload.decode(built.encoded()) else {
            return XCTFail("expected a reconnectHello back from decode")
        }
        XCTAssertEqual(MessagePayload.parseReconnectHello(body),
                       MessagePayload.reconnectHelloVersion)
    }

    // MARK: Forward-compat (unknown tags ignored, not misread)

    func testKnownTagSixDecodes() {
        XCTAssertNotNil(MessagePayload.decode(Data([6, 1])),
                        "tag 6 is now a known kind")
    }

    func testUnknownTagStillDecodesNil() {
        XCTAssertNil(MessagePayload.decode(Data([7, 1])),
                     "an unknown tag (7) must decode to nil, not be misread")
        XCTAssertNil(MessagePayload.decode(Data()), "empty buffer decodes nil")
    }
}
