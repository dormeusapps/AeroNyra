// MessagePayloadSealedTests.swift
// BeaconTests
//
// Tests for the Phase 9b padded sealed-plaintext format: MessagePayload
// .sealedPlaintext() (sender side) and .decodeSealed() (receiver side). Pure
// Data logic — no crypto, no hardware. Separate from MessagePayloadTests.swift
// so the existing tag/encode coverage is left untouched.

import XCTest
@testable import Beacon

final class MessagePayloadSealedTests: XCTestCase {

    // MARK: Padded kinds round-trip

    func testTextRoundTripsThroughSeal() {
        let original = MessagePayload.text(Data("hello world".utf8))
        let recovered = MessagePayload.decodeSealed(original.sealedPlaintext())
        XCTAssertEqual(recovered, original)
    }

    func testEmptyTextRoundTrips() {
        let original = MessagePayload.text(Data())
        XCTAssertEqual(MessagePayload.decodeSealed(original.sealedPlaintext()), original)
    }

    func testAckRoundTripsThroughSeal() {
        let original = MessagePayload.deliveryAck(wireID: .random(), hops: 3)
        let recovered = MessagePayload.decodeSealed(original.sealedPlaintext())
        XCTAssertEqual(recovered, original)
        // And the ack body still parses after the round-trip.
        if case .ack(let body) = recovered! {
            let parsed = MessagePayload.parseDeliveryAck(body)
            XCTAssertEqual(parsed?.hops, 3)
        } else {
            XCTFail("expected .ack")
        }
    }

    func testNostrIdentityRoundTripsThroughSeal() {
        let key = Data((0..<32).map { UInt8($0) })
        let original = MessagePayload.nostrIdentityAnnounce(pubkey: key)
        let recovered = MessagePayload.decodeSealed(original.sealedPlaintext())
        XCTAssertEqual(recovered, original)
        if case .nostrIdentity(let body) = recovered! {
            XCTAssertEqual(MessagePayload.parseNostrIdentity(body), key)
        } else {
            XCTFail("expected .nostrIdentity")
        }
    }

    // MARK: Padded kinds collapse to a fixed length

    func testSmallPaddedKindsAllShareOneLength() {
        let text  = MessagePayload.text(Data("ok".utf8)).sealedPlaintext()
        let ack   = MessagePayload.deliveryAck(wireID: .random(), hops: 0).sealedPlaintext()
        let nostr = MessagePayload.nostrIdentityAnnounce(pubkey: Data(repeating: 7, count: 32)).sealedPlaintext()
        XCTAssertEqual(text.count, 256)
        XCTAssertEqual(ack.count, 256)
        XCTAssertEqual(nostr.count, 256)
    }

    // MARK: Media is exempt (unpadded, byte-identical to encoded())

    func testMediaManifestIsNotPadded() {
        let payload = MessagePayload.mediaManifest(Data("{\"x\":1}".utf8))
        XCTAssertEqual(payload.sealedPlaintext(), payload.encoded())
        XCTAssertEqual(MessagePayload.decodeSealed(payload.sealedPlaintext()), payload)
    }

    func testMediaChunkIsNotPadded() {
        // A realistic 4096-byte chunk plaintext ([tag] ‖ 24B header ‖ payload).
        let chunkBody = Data((0..<4095).map { UInt8($0 % 256) })
        let payload = MessagePayload.mediaChunk(chunkBody)
        let sealed = payload.sealedPlaintext()
        XCTAssertEqual(sealed, payload.encoded())
        XCTAssertEqual(sealed.count, 1 + chunkBody.count)   // no padding added
        XCTAssertEqual(MessagePayload.decodeSealed(sealed), payload)
    }

    // MARK: Disambiguation invariant

    func testPaddedKindsNeverLeadWithAMediaTag() {
        // decodeSealed distinguishes media from padded by the leading byte, so a
        // padded payload must never start with mediaManifest(2)/mediaChunk(3).
        let payloads: [MessagePayload] = [
            .text(Data("x".utf8)),
            .text(Data(repeating: 0x41, count: 5000)),
            .deliveryAck(wireID: .random(), hops: 7),
            .nostrIdentityAnnounce(pubkey: Data(repeating: 9, count: 32))
        ]
        for p in payloads {
            let first = p.sealedPlaintext().first
            XCTAssertNotEqual(first, WirePayloadKind.mediaManifest.rawValue)
            XCTAssertNotEqual(first, WirePayloadKind.mediaChunk.rawValue)
        }
    }

    // MARK: Large text still round-trips (spans buckets)

    func testLargeTextRoundTrips() {
        let original = MessagePayload.text(Data(repeating: 0x5A, count: 20000))
        let sealed = original.sealedPlaintext()
        XCTAssertEqual(sealed.count % PayloadBucket.sizes.last!, 0)  // multiple of 16384
        XCTAssertEqual(MessagePayload.decodeSealed(sealed), original)
    }

    // MARK: Malformed inbound

    func testDecodeSealedRejectsUnpaddableNonMedia() {
        // A short buffer that isn't media (leading byte 1 = text) and is too
        // short to hold a padding length header → undecodable (nil), e.g. a
        // pre-9b unpadded text. Caller treats nil as "drop".
        XCTAssertNil(MessagePayload.decodeSealed(Data([0x01, 0x68])))
    }
}
