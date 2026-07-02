// MessagePayloadTests.swift
// BeaconTests
//
// Phase 8d-0 — the npub-bootstrap MessagePayload case (.nostrIdentity, tag 5).
//
// Covers: round-trip encode/decode, the on-wire tag byte, strict 32-byte body
// validation on the untrusted parse path, the forward-compat unknown-tag guard,
// and a regression guard pinning the four pre-existing tag values so a future
// edit can't silently renumber the wire.
//

import XCTest
@testable import Beacon

final class MessagePayloadTests: XCTestCase {
    
    // A deterministic stand-in for a 32-byte x-only secp256k1 public key.
    private let key32 = Data((0..<32).map { UInt8($0) })
    
    // MARK: - Round-trip
    
    func testNostrIdentityRoundTrip() {
        let payload = MessagePayload.nostrIdentity(key32)
        let wire = payload.encoded()
        let decoded = MessagePayload.decode(wire)
        
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded?.kind, .nostrIdentity)
        XCTAssertEqual(decoded?.body, key32)
    }
    
    func testAnnounceBuilderProducesNostrIdentityCase() {
        let payload = MessagePayload.nostrIdentityAnnounce(pubkey: key32)
        XCTAssertEqual(payload, .nostrIdentity(key32))
        XCTAssertEqual(payload.kind, .nostrIdentity)
        XCTAssertEqual(payload.body, key32)
    }
    
    // MARK: - On-wire tag byte
    
    func testNostrIdentityTagByteIsFive() {
        XCTAssertEqual(WirePayloadKind.nostrIdentity.rawValue, 5)
        let wire = MessagePayload.nostrIdentity(key32).encoded()
        XCTAssertEqual(wire.first, 5)
        XCTAssertEqual(wire.count, 1 + 32)            // tag + 32-byte body
    }
    
    // MARK: - Strict body validation (untrusted parse path)
    
    func testParseNostrIdentityAcceptsExactlyThirtyTwoBytes() {
        XCTAssertEqual(MessagePayload.parseNostrIdentity(key32), key32)
    }
    
    func testParseNostrIdentityRejectsWrongLengths() {
        XCTAssertNil(MessagePayload.parseNostrIdentity(Data()))               // empty
        XCTAssertNil(MessagePayload.parseNostrIdentity(Data(count: 31)))      // short
        XCTAssertNil(MessagePayload.parseNostrIdentity(Data(count: 33)))      // long
    }
    
    func testDecodeIsPermissiveButParseIsStrict() {
        // decode() splits tag from body without length-checking; the strict
        // 32-byte rule lives only in parseNostrIdentity (mirrors ack behaviour).
        let badWire = Data([WirePayloadKind.nostrIdentity.rawValue]) + Data(count: 10)
        let decoded = MessagePayload.decode(badWire)
        XCTAssertEqual(decoded?.kind, .nostrIdentity)         // decode succeeds
        XCTAssertNil(MessagePayload.parseNostrIdentity(decoded!.body))  // parse rejects
    }
    
    // MARK: - Forward compatibility
    
    func testDecodeIgnoresUnknownTag() {
        let unknownTag: UInt8 = 99
        XCTAssertNil(WirePayloadKind(rawValue: unknownTag))
        let wire = Data([unknownTag]) + key32
        XCTAssertNil(MessagePayload.decode(wire))
    }
    
    func testDecodeReturnsNilOnEmptyBuffer() {
        XCTAssertNil(MessagePayload.decode(Data()))
    }
    
    // MARK: - Regression: the wire numbering must not drift
    
    func testExistingTagValuesUnchanged() {
        XCTAssertEqual(WirePayloadKind.text.rawValue,          1)
        XCTAssertEqual(WirePayloadKind.mediaManifest.rawValue, 2)
        XCTAssertEqual(WirePayloadKind.mediaChunk.rawValue,    3)
        XCTAssertEqual(WirePayloadKind.ack.rawValue,           4)
        XCTAssertEqual(WirePayloadKind.nostrIdentity.rawValue, 5)
        XCTAssertEqual(WirePayloadKind.reconnectHello.rawValue, 6)
        XCTAssertEqual(WirePayloadKind.inviteEcho.rawValue,     7)
        XCTAssertEqual(WirePayloadKind.allCases.count,          7)
    }
    
    func testTextStillRoundTripsAlongsideNewKind() {
        let text = MessagePayload.text(Data("hello".utf8))
        XCTAssertEqual(MessagePayload.decode(text.encoded()), text)
    }
}
