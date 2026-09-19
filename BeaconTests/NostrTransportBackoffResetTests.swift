//
//  NostrTransportBackoffResetTests.swift
//  BeaconTests
//
//  2026-09-19 · Test A finding, pinned: the reconnect counter was zeroed on
//  EVERY received frame, so a relay that answers each REQ with a CLOSED reset
//  the backoff each time and it never grew (133 connects to relay.damus.io in
//  ten minutes). Only a frame that proves the relay is serving us — EVENT /
//  EOSE / OK — may reset it. Pure classifier; the handler wiring is one line.
//  XCTest only (not Swift Testing), per project standard.
//

import XCTest
@testable import Beacon

final class NostrTransportBackoffResetTests: XCTestCase {

    func testServingFramesResetBackoff() {
        let event = NostrEvent(id: String(repeating: "0", count: 64),
                               pubkey: String(repeating: "1", count: 64),
                               createdAt: 0, kind: 1059, tags: [], content: "",
                               sig: String(repeating: "2", count: 128))
        XCTAssertTrue(NostrTransport.resetsReconnectBackoff(.event(subscriptionID: "s", event: event)))
        XCTAssertTrue(NostrTransport.resetsReconnectBackoff(.endOfStoredEvents(subscriptionID: "s")))
        XCTAssertTrue(NostrTransport.resetsReconnectBackoff(.ok(eventID: "e", accepted: true, message: "")))
        // A rejected publish is still the relay serving the socket.
        XCTAssertTrue(NostrTransport.resetsReconnectBackoff(.ok(eventID: "e", accepted: false, message: "duplicate:")))
    }

    func testTalkingFramesDoNotResetBackoff() {
        XCTAssertFalse(NostrTransport.resetsReconnectBackoff(.notice("slow down")))
        XCTAssertFalse(NostrTransport.resetsReconnectBackoff(
            .closed(subscriptionID: "s", message: "ERROR: auth-required: requested filter requires authentication")))
        XCTAssertFalse(NostrTransport.resetsReconnectBackoff(
            .closed(subscriptionID: "s", message: "rate-limited: transient")))
        XCTAssertFalse(NostrTransport.resetsReconnectBackoff(.unknown))
    }

}
