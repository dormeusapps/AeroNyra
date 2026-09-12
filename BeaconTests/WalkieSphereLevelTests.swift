//
//  WalkieSphereLevelTests.swift
//  BeaconTests
//
//  Pins `WalkieSphereLevel.select` (live PTT-over-IP, globe pulse loop 1):
//  the pure selector behind the walkie sphere's one level input. The
//  load-bearing bit: while a link to this peer EXISTS (reaching, connecting,
//  or live) a hold must NOT read the capture engine's meter — the engine never
//  runs under a link, so that meter is the stale tail of the previous voice
//  note and the sphere froze on it. Everything else pins today's order: my
//  mic on the note path, else the auto-playing inbound clip, else idle.
//

import XCTest
@testable import Beacon

final class WalkieSphereLevelTests: XCTestCase {

    // MARK: Note path (no link): the shipped behavior

    func testHoldOnNotePathReadsMic() {
        let level = WalkieSphereLevel.select(holding: true, link: .notes,
                                             micLevel: 0.7, inboundBusy: false,
                                             inboundLevel: 0)
        XCTAssertEqual(level, 0.7, accuracy: 0.0001)
    }

    func testHoldOnNotePathWithNoMeterYetReadsZero() {
        let level = WalkieSphereLevel.select(holding: true, link: .notes,
                                             micLevel: nil, inboundBusy: false,
                                             inboundLevel: 0)
        XCTAssertEqual(level, 0)
    }

    func testHoldOnNotePathBeatsInbound() {
        let level = WalkieSphereLevel.select(holding: true, link: .notes,
                                             micLevel: 0.3, inboundBusy: true,
                                             inboundLevel: 0.9)
        XCTAssertEqual(level, 0.3, accuracy: 0.0001, "my mic wins while I hold")
    }

    func testEndedReadsAsNotePath() {
        let level = WalkieSphereLevel.select(holding: true, link: .ended(.unreachable),
                                             micLevel: 0.5, inboundBusy: false,
                                             inboundLevel: 0)
        XCTAssertEqual(level, 0.5, accuracy: 0.0001, ".ended is the note path again")
    }

    // MARK: Inbound clip

    func testInboundClipDrivesTheSphereWhenNotHolding() {
        let level = WalkieSphereLevel.select(holding: false, link: .notes,
                                             micLevel: 0.8, inboundBusy: true,
                                             inboundLevel: 0.4)
        XCTAssertEqual(level, 0.4, accuracy: 0.0001)
    }

    func testInboundClipStillDrivesTheSphereUnderALink() {
        // Scenario 4: a note auto-plays under a live link; the sphere reacts to it.
        let level = WalkieSphereLevel.select(holding: false, link: .live,
                                             micLevel: 0.8, inboundBusy: true,
                                             inboundLevel: 0.4)
        XCTAssertEqual(level, 0.4, accuracy: 0.0001)
    }

    // MARK: Idle

    func testIdleIsZero() {
        let level = WalkieSphereLevel.select(holding: false, link: .notes,
                                             micLevel: 0.9, inboundBusy: false,
                                             inboundLevel: 0.9)
        XCTAssertEqual(level, 0, "a stale meter must not leak while idle")
    }

    // MARK: THE fix: a hold under a link never reads the stale capture meter

    func testHoldUnderEveryLinkStateIgnoresTheStaleMic() {
        for link in [WalkieLinkStatus.reaching, .connecting, .live] {
            let level = WalkieSphereLevel.select(holding: true, link: link,
                                                 micLevel: 0.95, inboundBusy: false,
                                                 inboundLevel: 0)
            XCTAssertEqual(level, 0, "\(link): the capture engine is not running, its meter is stale")
        }
    }

    func testHoldUnderALinkFallsThroughToAnInboundClip() {
        let level = WalkieSphereLevel.select(holding: true, link: .live,
                                             micLevel: 0.95, inboundBusy: true,
                                             inboundLevel: 0.2)
        XCTAssertEqual(level, 0.2, accuracy: 0.0001, "stale mic skipped; the clip still shows")
    }
}
