//
//  NostrSubscriptionFrameDeterminismTests.swift
//  BeaconTests
//
//  2026-09-19 · Test D finding. The transport re-sends a REQ only when its bytes
//  differ from the last frame sent on that socket (`lastSentFrames`), which
//  makes "unchanged plan sends nothing" a documented guarantee (handoff §1.4,
//  §4 item 8). `subscriptionFrame` built the filter as a Swift dictionary and
//  serialized it with default options, so `kinds` and `#p` came out in either
//  order and the guarantee held only by chance — Test D captured 128,690-byte
//  page re-sends at +62 s, +87 s and after every reconnect with no set change.
//
//  These tests pin byte-identity for one input, the fixed key order, and that
//  the only thing that changes the bytes is the input.
//  XCTest only (not Swift Testing), per project standard.
//

import XCTest
@testable import Beacon

final class NostrSubscriptionFrameDeterminismTests: XCTestCase {

    private func tags(_ n: Int, seed: UInt8) -> [String] {
        (0..<n).map { i in
            (0..<32).map { j in String(format: "%02x", UInt8(truncatingIfNeeded: Int(seed) &+ i &* 7 &+ j)) }.joined()
        }.sorted()
    }

    /// The defect as observed: the same input must serialize to the same
    /// bytes every time, not "usually".
    func testSameInputYieldsByteIdenticalFramesAcrossManyBuilds() {
        let t = tags(1_920, seed: 3)
        let first = NostrTransport.subscriptionFrame(subscriptionID: "0123456789abcdef", tags: t)
        XCTAssertFalse(first.isEmpty)
        for _ in 0..<200 {
            XCTAssertEqual(NostrTransport.subscriptionFrame(subscriptionID: "0123456789abcdef", tags: t), first)
        }
    }

    /// Small frames too (the invite-echo set is 3 values).
    func testEchoSizedFrameIsByteIdentical() {
        let t = tags(3, seed: 9)
        let a = NostrTransport.subscriptionFrame(subscriptionID: "fedcba9876543210", tags: t)
        for _ in 0..<200 {
            XCTAssertEqual(NostrTransport.subscriptionFrame(subscriptionID: "fedcba9876543210", tags: t), a)
        }
    }

    /// The key order is fixed and known: `#p` sorts before `kinds`, so the
    /// frame is exactly `["REQ","<id>",{"#p":[…],"kinds":[1059]}]`.
    func testKeyOrderIsFixed() throws {
        let t = tags(2, seed: 1)
        let data = NostrTransport.subscriptionFrame(subscriptionID: "00ff00ff00ff00ff", tags: t)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix(##"["REQ","00ff00ff00ff00ff",{"#p":[""##), text)
        XCTAssertTrue(text.hasSuffix(##"],"kinds":[1059]}]"##), text)
        XCTAssertEqual(text, ##"["REQ","00ff00ff00ff00ff",{"#p":["\##(t[0])","\##(t[1])"],"kinds":[1059]}]"##)
    }

    /// Only the input changes the bytes: a different id, or one different
    /// tag, must produce a different frame — the re-send rule depends on
    /// both directions of that equivalence.
    func testOnlyTheInputChangesTheBytes() {
        let t = tags(60, seed: 5)
        let base = NostrTransport.subscriptionFrame(subscriptionID: "aaaaaaaaaaaaaaaa", tags: t)
        XCTAssertNotEqual(NostrTransport.subscriptionFrame(subscriptionID: "bbbbbbbbbbbbbbbb", tags: t), base)
        var t2 = t; t2[0] = String(repeating: "f", count: 64)
        XCTAssertNotEqual(NostrTransport.subscriptionFrame(subscriptionID: "aaaaaaaaaaaaaaaa", tags: t2.sorted()), base)
    }

    /// The frame still parses as the NIP-01 shape the relays expect.
    func testFrameStillParsesAsREQWithKindsAndTags() throws {
        let t = tags(4, seed: 2)
        let data = NostrTransport.subscriptionFrame(subscriptionID: "1234567890abcdef", tags: t)
        let top = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [Any])
        XCTAssertEqual(top[0] as? String, "REQ")
        XCTAssertEqual(top[1] as? String, "1234567890abcdef")
        let filter = try XCTUnwrap(top[2] as? [String: Any])
        XCTAssertEqual(filter["kinds"] as? [Int], [1059])
        XCTAssertEqual(filter["#p"] as? [String], t)
    }
}
