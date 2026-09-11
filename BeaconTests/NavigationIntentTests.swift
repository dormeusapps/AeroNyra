//
//  NavigationIntentTests.swift
//  BeaconTests
//
//  Pins the take-once contract of the app's programmatic-navigation
//  primitive (deep link from the responder banner, step 5).
//

import XCTest
@testable import Beacon

@MainActor
final class NavigationIntentTests: XCTestCase {

    private let a = Data(repeating: 0xA1, count: 32)
    private let b = Data(repeating: 0xB2, count: 32)

    func testWalkieRequestIsTakenOnceForItsPeer() {
        let intent = NavigationIntent()
        intent.openWalkie(with: a)
        XCTAssertTrue(intent.takeWalkieRequest(for: a))
        XCTAssertNil(intent.request, "cleared on take")
        XCTAssertFalse(intent.takeWalkieRequest(for: a), "never re-fires")
    }

    func testWrongPeerLeavesTheRequestInPlace() {
        let intent = NavigationIntent()
        intent.openWalkie(with: a)
        XCTAssertFalse(intent.takeWalkieRequest(for: b))
        XCTAssertNotNil(intent.request)
        XCTAssertTrue(intent.takeWalkieRequest(for: a))
    }

    func testNonWalkieRequestIsNotTakenAsWalkie() {
        let intent = NavigationIntent()
        intent.open(a, walkie: false)
        XCTAssertFalse(intent.takeWalkieRequest(for: a))
        XCTAssertNotNil(intent.request, "a plain open is not consumed by the walkie path")
    }

    func testTwoRequestsForTheSamePeerAreDistinct() {
        let intent = NavigationIntent()
        intent.openWalkie(with: a)
        let first = intent.request
        intent.openWalkie(with: a)
        XCTAssertNotEqual(first, intent.request, "the token makes a repeat tap observable")
    }
}
