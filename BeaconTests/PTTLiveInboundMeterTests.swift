//
//  PTTLiveInboundMeterTests.swift
//  BeaconTests
//
//  Pins `PTTLiveInboundMeter` (globe pulse, loop 4): the pure join of "which
//  peer's BLE-live session is open toward me" (from the coordinator's
//  open/close events) and "their level" (from PTTPlayer's per-frame meter).
//  Load-bearing: a sample with no session open is DROPPED (a straggling frame
//  after a close can never move the sphere); a close for another peer does
//  not blank the active session; the per-peer read is nil for anyone else.
//
//  `PTTPlayer.onLevel` itself is not pinned — the player drives a real
//  AVAudioEngine and has no tests today; the device check is its proof.
//

import XCTest
@testable import Beacon

@MainActor
final class PTTLiveInboundMeterTests: XCTestCase {

    private let alice = Data(repeating: 0xA1, count: 32)
    private let bob   = Data(repeating: 0xB2, count: 32)

    func testIdleReadsNilAndDropsSamples() {
        let meter = PTTLiveInboundMeter()
        XCTAssertNil(meter.activePeer)
        meter.report(0.8)
        XCTAssertEqual(meter.level, 0, "no session: the sample is dropped")
        XCTAssertNil(meter.level(for: alice))
    }

    func testOpenThenReportIsReadableForThatPeerOnly() {
        let meter = PTTLiveInboundMeter()
        meter.sessionOpened(peerKey: alice)
        XCTAssertEqual(meter.level(for: alice), 0, "open, silent so far")
        meter.report(0.6)
        XCTAssertEqual(meter.level(for: alice)!, 0.6, accuracy: 0.0001)
        XCTAssertNil(meter.level(for: bob), "someone else's cover sees nothing")
    }

    func testReportClampsToTheMeterRange() {
        let meter = PTTLiveInboundMeter()
        meter.sessionOpened(peerKey: alice)
        meter.report(1.7)
        XCTAssertEqual(meter.level, 1)
        meter.report(-0.2)
        XCTAssertEqual(meter.level, 0)
    }

    func testCloseForTheActivePeerZeroesAndClears() {
        let meter = PTTLiveInboundMeter()
        meter.sessionOpened(peerKey: alice)
        meter.report(0.6)
        meter.sessionClosed(peerKey: alice)
        XCTAssertNil(meter.activePeer)
        XCTAssertEqual(meter.level, 0)
        XCTAssertNil(meter.level(for: alice))
        meter.report(0.9)
        XCTAssertEqual(meter.level, 0, "a straggling frame after the close is dropped")
    }

    func testCloseForAnotherPeerDoesNothing() {
        let meter = PTTLiveInboundMeter()
        meter.sessionOpened(peerKey: alice)
        meter.report(0.6)
        meter.sessionClosed(peerKey: bob)
        XCTAssertEqual(meter.activePeer, alice)
        XCTAssertEqual(meter.level(for: alice)!, 0.6, accuracy: 0.0001)
    }

    func testANewSessionReplacesTheOldOneAndResetsTheLevel() {
        let meter = PTTLiveInboundMeter()
        meter.sessionOpened(peerKey: alice)
        meter.report(0.6)
        meter.sessionOpened(peerKey: bob)
        XCTAssertEqual(meter.activePeer, bob)
        XCTAssertEqual(meter.level, 0, "alice's last sample must not show as bob's")
        XCTAssertNil(meter.level(for: alice))
        XCTAssertEqual(meter.level(for: bob), 0)
    }

    func testReopeningTheSamePeerKeepsTheLevelContinuous() {
        // A re-open for the same peer (a new spurt's session) does not blank a
        // level that is about to be overwritten by the next frame anyway.
        let meter = PTTLiveInboundMeter()
        meter.sessionOpened(peerKey: alice)
        meter.report(0.6)
        meter.sessionOpened(peerKey: alice)
        XCTAssertEqual(meter.level(for: alice)!, 0.6, accuracy: 0.0001)
    }
}
