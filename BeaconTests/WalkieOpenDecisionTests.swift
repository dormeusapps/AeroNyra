//
//  WalkieOpenDecisionTests.swift
//  BeaconTests
//
//  Pins `WalkieOpenDecision.decide` (loop 5, mode selection): the pure rule
//  behind `StreamView.openWalkieLink`. The load-bearing bit — the one that
//  was ABSENT until 2026-09-12 and shipped absent in build 11: a peer
//  reachable over BLE right now never gets an IP link attempt. The rest pins
//  the cover's existing ownership rules: a link to THIS peer is adopted in
//  either transport state, someone else's link is closed first.
//

import XCTest
@testable import Beacon

final class WalkieOpenDecisionTests: XCTestCase {

    private let me   = Data(repeating: 0xA1, count: 32)
    private let them = Data(repeating: 0xB2, count: 32)

    // MARK: THE rule

    func testNearWithNoLinkStaysOnBLE() {
        XCTAssertEqual(WalkieOpenDecision.decide(near: true, linkPeer: nil, peer: me), .stayOnBLE,
                       "a near peer never gets an IP link attempt")
    }

    func testFarWithNoLinkOpensTheIPLink() {
        XCTAssertEqual(WalkieOpenDecision.decide(near: false, linkPeer: nil, peer: me), .open)
    }

    // MARK: A link to THIS peer is adopted regardless of transport

    func testExistingLinkToThisPeerIsAdoptedWhenFar() {
        XCTAssertEqual(WalkieOpenDecision.decide(near: false, linkPeer: me, peer: me), .adopt)
    }

    func testExistingLinkToThisPeerIsAdoptedWhenNearToo() {
        // They opened at us (e.g. an unfixed build 11 peer standing next to
        // us): the link works — keep it rather than tear it down for BLE.
        XCTAssertEqual(WalkieOpenDecision.decide(near: true, linkPeer: me, peer: me), .adopt)
    }

    // MARK: Someone else's link is closed first; then the same rule applies

    func testOtherPeersLinkIsClosedThenBLEWhenNear() {
        XCTAssertEqual(WalkieOpenDecision.decide(near: true, linkPeer: them, peer: me),
                       .closeOtherThenStayOnBLE)
    }

    func testOtherPeersLinkIsClosedThenOpenedWhenFar() {
        XCTAssertEqual(WalkieOpenDecision.decide(near: false, linkPeer: them, peer: me),
                       .closeOtherThenOpen)
    }

    // MARK: Exhaustive: every input maps to exactly one arm, and only the
    // two "not near, not adopted" arms ever open a link

    func testOnlyTheFarArmsOpenALink() {
        let opening: Set<WalkieOpenDecision> = [.open, .closeOtherThenOpen]
        for near in [true, false] {
            for linkPeer in [nil, me, them] {
                let d = WalkieOpenDecision.decide(near: near, linkPeer: linkPeer, peer: me)
                if near {
                    XCTAssertFalse(opening.contains(d), "near=\(near) link=\(String(describing: linkPeer?.first)): must not open")
                } else if linkPeer != me {
                    XCTAssertTrue(opening.contains(d), "far, no link to me: must open")
                }
            }
        }
    }
}
