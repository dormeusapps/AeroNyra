// NostrTransportFramingTests.swift
// BeaconTests
//
// Phase 8d-1 — the pure NIP-01 wire framing inside NostrTransport: building the
// REQ subscription, building the EVENT publish frame, and parsing relay frames
// back into RelayMessage. No socket, no network — just the bytes-on-the-wire
// contract. The websocket I/O around these is verified on a live relay.
//

import XCTest
@testable import Beacon

final class NostrTransportFramingTests: XCTestCase {

    private let pubHex = String(repeating: "a", count: 64)   // 32-byte x-only key
    private let sigHex = String(repeating: "b", count: 128)  // 64-byte schnorr sig

    /// A decode-only NostrEvent (no signing needed — framing doesn't validate).
    private func sampleEvent(kind: Int = NostrGiftWrap.wrapKind,
                             content: String = "hello") -> NostrEvent {
        let json = """
        {"id":"\(pubHex)","pubkey":"\(pubHex)","created_at":1700000000,\
        "kind":\(kind),"tags":[["p","\(pubHex)"]],"content":"\(content)","sig":"\(sigHex)"}
        """
        return NostrEvent(jsonData: Data(json.utf8))!
    }

    // MARK: - REQ subscription (v59 Stage 5: inbox tags, never the npub)

    func testSubscriptionFrameShapeCarriesTagsNotTheNpub() throws {
        let tags = ["b1c25406911c8c4c9f9b0b9c154018f81f2022ca5371eac1fb03b78849c49ba0",
                    "e2040b8422ba4aa5e05e44d9bad5d1e5c8182a1101c612c6bf75e023cec8882a"]
        let data = NostrTransport.subscriptionFrame(subscriptionID: "sub1", tags: tags)
        let top = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])

        XCTAssertEqual(top[0] as? String, "REQ")
        XCTAssertEqual(top[1] as? String, "sub1")

        let filter = try XCTUnwrap(top[2] as? [String: Any])
        XCTAssertEqual(filter["kinds"] as? [Int], [NostrGiftWrap.wrapKind])  // 1059 only
        XCTAssertEqual(filter["#p"] as? [String], tags)                      // the planned tags, verbatim order
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(pubHex),
                       "an npub must never appear in a subscription frame")
    }

    func testCloseFrameShape() throws {
        let data = NostrTransport.closeFrame(subscriptionID: "sub1")
        let top = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
        XCTAssertEqual(top.count, 2)
        XCTAssertEqual(top[0] as? String, "CLOSE")
        XCTAssertEqual(top[1] as? String, "sub1")
    }

    /// Queue item 2: the subscription id names nothing. 16 lowercase hex, no
    /// `aeronyra-` prefix, fresh per call.
    func testSubscriptionIDIsRandomAndUnbranded() {
        let ids = (0..<50).map { _ in NostrTransport.randomSubscriptionID() }
        XCTAssertEqual(Set(ids).count, 50)
        for id in ids {
            XCTAssertEqual(id.count, 16)
            XCTAssertTrue(id.allSatisfy { "0123456789abcdef".contains($0) })
            XCTAssertFalse(id.lowercased().contains("aeronyra"))
        }
    }

    /// The real bytes of a full contact page on the wire: 1,920 values through
    /// the production frame builder with a production-shaped id, against the
    /// smallest configured relay frame (nos.lol, 131,072). The other two
    /// relays allow 1,000,000.
    func testFullPageSubscriptionFrameFitsTheSmallestRelayFrame() throws {
        var rng = SystemRandomNumberGenerator()
        let tags = (0..<1_920).map { _ in
            (0..<32).map { _ in String(format: "%02x", UInt8.random(in: UInt8.min...UInt8.max, using: &rng)) }.joined()
        }.sorted()
        let data = NostrTransport.subscriptionFrame(subscriptionID: NostrTransport.randomSubscriptionID(), tags: tags)
        XCTAssertLessThanOrEqual(data.count, 131_072, "nos.lol maxWebsocketPayloadSize")
        XCTAssertGreaterThan(data.count, 128_000, "sanity: ~67 bytes per value")
        XCTAssertLessThanOrEqual(tags.count, 2_047, "strfry per-filter value cap")
    }

    // MARK: - EVENT publish

    func testPublishFrameEmbedsEventFaithfully() throws {
        let event = sampleEvent()
        let data = try XCTUnwrap(NostrTransport.publishFrame(event: event))
        let top = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])

        XCTAssertEqual(top[0] as? String, "EVENT")

        // The embedded object must round-trip back to the identical event.
        let eventObj = try XCTUnwrap(top[1] as? [String: Any])
        let reData = try JSONSerialization.data(withJSONObject: eventObj)
        let roundTripped = try XCTUnwrap(NostrEvent(jsonData: reData))
        XCTAssertEqual(roundTripped, event)
    }

    // MARK: - Parse relay frames

    func testParseEventFrame() throws {
        let event = sampleEvent(content: "round-trip")
        let eventObj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(event.jsonData())) as? [String: Any]
        )
        let frame = try JSONSerialization.data(withJSONObject: ["EVENT", "subX", eventObj] as [Any])

        guard case let .event(subID, parsed) = try XCTUnwrap(NostrTransport.parseRelayFrame(frame)) else {
            return XCTFail("expected .event")
        }
        XCTAssertEqual(subID, "subX")
        XCTAssertEqual(parsed, event)
    }

    func testParseEOSE() throws {
        let frame = try JSONSerialization.data(withJSONObject: ["EOSE", "subX"] as [Any])
        XCTAssertEqual(NostrTransport.parseRelayFrame(frame),
                       .endOfStoredEvents(subscriptionID: "subX"))
    }

    func testParseOK() throws {
        let frame = try JSONSerialization.data(
            withJSONObject: ["OK", pubHex, true, "stored"] as [Any])
        XCTAssertEqual(NostrTransport.parseRelayFrame(frame),
                       .ok(eventID: pubHex, accepted: true, message: "stored"))
    }

    func testParseNotice() throws {
        let frame = try JSONSerialization.data(withJSONObject: ["NOTICE", "slow down"] as [Any])
        XCTAssertEqual(NostrTransport.parseRelayFrame(frame), .notice("slow down"))
    }

    func testParseClosed() throws {
        let frame = try JSONSerialization.data(
            withJSONObject: ["CLOSED", "subX", "rate-limited"] as [Any])
        XCTAssertEqual(NostrTransport.parseRelayFrame(frame),
                       .closed(subscriptionID: "subX", message: "rate-limited"))
    }

    func testParseUnknownTagMapsToUnknown() throws {
        let frame = try JSONSerialization.data(withJSONObject: ["AUTH", "challenge"] as [Any])
        XCTAssertEqual(NostrTransport.parseRelayFrame(frame), .unknown)
    }

    func testParseGarbageReturnsNil() {
        XCTAssertNil(NostrTransport.parseRelayFrame(Data("not json at all".utf8)))
        // A JSON object (not an array) is also not a relay frame.
        let obj = try! JSONSerialization.data(withJSONObject: ["k": "v"])
        XCTAssertNil(NostrTransport.parseRelayFrame(obj))
    }
}
