//
//  ContactRemovalRequestTests.swift
//  BeaconTests
//
//  Pins the SAS "Doesn't match" row-removal hand-off: the chats root may take
//  (and then delete) a discarded contact ONLY once that Peer is out of the
//  navigation path — the path holds the Peer object, so deleting it while it
//  is still there is the deleted-row-under-a-mounted-view hazard. Take-once.
//

import XCTest
@testable import Beacon

@MainActor
final class ContactRemovalRequestTests: XCTestCase {

    private let k = Data(repeating: 0xAB, count: 32)
    private let other = Data(repeating: 0xCD, count: 32)

    func testNotTakenWhileThePeerIsStillInThePath() {
        let r = ContactRemovalRequest()
        r.post(k)
        XCTAssertNil(r.takeIfClear(pathKeys: [k]), "must wait while the chat is still in the stack")
        XCTAssertNotNil(r.request, "the request stays pending")
        XCTAssertNil(r.takeIfClear(pathKeys: [other, k]))
    }

    func testTakenOnceThePeerHasLeftThePath() {
        let r = ContactRemovalRequest()
        r.post(k)
        XCTAssertEqual(r.takeIfClear(pathKeys: []), k)
        XCTAssertNil(r.request)
        XCTAssertNil(r.takeIfClear(pathKeys: []), "take-once")
    }

    func testAnotherPeerInThePathDoesNotBlock() {
        let r = ContactRemovalRequest()
        r.post(k)
        XCTAssertEqual(r.takeIfClear(pathKeys: [other]), k)
    }

    func testNothingPendingTakesNothing() {
        XCTAssertNil(ContactRemovalRequest().takeIfClear(pathKeys: []))
    }
}
