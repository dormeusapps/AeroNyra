//
//  SwipeRevealTests.swift
//  BeaconTests
//
//  Pins the Home row swipe (SwipeRevealRow.swift): a left swipe past a third
//  of the actions' width opens the row, a short or rightward one doesn't, a
//  swipe back closes an open row, and the drag never travels past the
//  actions or to the right. Which actions a row shows is ChatActions.row
//  (ChatSafetyStateTests).
//

import XCTest
@testable import Beacon

final class SwipeRevealTests: XCTestCase {

    private let width: CGFloat = 2 * SwipeReveal.buttonWidth   // two actions side by side

    func testALeftSwipePastAThirdOpens() {
        XCTAssertTrue(SwipeReveal.settlesOpen(translation: -width / 2, wasOpen: false, revealWidth: width))
        XCTAssertFalse(SwipeReveal.settlesOpen(translation: -width / 4, wasOpen: false, revealWidth: width))
        XCTAssertFalse(SwipeReveal.settlesOpen(translation: width, wasOpen: false, revealWidth: width),
                       "a right swipe never opens")
    }

    func testASwipeBackClosesAnOpenRow() {
        XCTAssertFalse(SwipeReveal.settlesOpen(translation: width, wasOpen: true, revealWidth: width))
        XCTAssertTrue(SwipeReveal.settlesOpen(translation: width / 4, wasOpen: true, revealWidth: width),
                      "a small nudge back leaves it open")
    }

    func testNoActionsNeverOpens() {
        XCTAssertFalse(SwipeReveal.settlesOpen(translation: -500, wasOpen: false, revealWidth: 0))
    }

    func testTheDragIsClamped() {
        XCTAssertEqual(SwipeReveal.offset(translation: -1000, wasOpen: false, revealWidth: width), -width)
        XCTAssertEqual(SwipeReveal.offset(translation: 300, wasOpen: false, revealWidth: width), 0)
        XCTAssertEqual(SwipeReveal.offset(translation: 40, wasOpen: true, revealWidth: width), -width + 40)
    }
}
