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

    // MARK: - REQ subscription

    func testSubscriptionFrameShape() throws {
        let data = NostrTransport.subscriptionFrame(subscriptionID: "sub1",
                                                    recipientPubkeyHex: pubHex)
        let top = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])

        XCTAssertEqual(top[0] as? String, "REQ")
        XCTAssertEqual(top[1] as? String, "sub1")

        let filter = try XCTUnwrap(top[2] as? [String: Any])
        XCTAssertEqual(filter["kinds"] as? [Int], [NostrGiftWrap.wrapKind])  // 1059 only
        XCTAssertEqual(filter["#p"] as? [String], [pubHex])                  // tagged to us
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
