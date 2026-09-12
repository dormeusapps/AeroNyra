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
//  own voice while holding on a LIVE link (loop 3, mine wins), else my mic
//  on the note path, else the auto-playing inbound clip, else (loop 4) the
//  peer's voice on a BLE-live session from this peer, else (loop 2) the
//  peer's voice on a LIVE link, else idle.
//

import XCTest
@testable import Beacon

final class WalkieSphereLevelTests: XCTestCase {

    // MARK: Note path (no link): the shipped behavior

    func testHoldOnNotePathReadsMic() {
        let level = WalkieSphereLevel.select(holding: true, link: .notes,
                                             micLevel: 0.7, inboundBusy: false,
                                             inboundLevel: 0, linkRemoteLevel: 0, linkLocalLevel: 0, liveInboundLevel: nil)
        XCTAssertEqual(level, 0.7, accuracy: 0.0001)
    }

    func testHoldOnNotePathWithNoMeterYetReadsZero() {
        let level = WalkieSphereLevel.select(holding: true, link: .notes,
                                             micLevel: nil, inboundBusy: false,
                                             inboundLevel: 0, linkRemoteLevel: 0, linkLocalLevel: 0, liveInboundLevel: nil)
        XCTAssertEqual(level, 0)
    }

    func testHoldOnNotePathBeatsInbound() {
        let level = WalkieSphereLevel.select(holding: true, link: .notes,
                                             micLevel: 0.3, inboundBusy: true,
                                             inboundLevel: 0.9, linkRemoteLevel: 0, linkLocalLevel: 0, liveInboundLevel: nil)
        XCTAssertEqual(level, 0.3, accuracy: 0.0001, "my mic wins while I hold")
    }

    func testEndedReadsAsNotePath() {
        let level = WalkieSphereLevel.select(holding: true, link: .ended(.unreachable),
                                             micLevel: 0.5, inboundBusy: false,
                                             inboundLevel: 0, linkRemoteLevel: 0, linkLocalLevel: 0, liveInboundLevel: nil)
        XCTAssertEqual(level, 0.5, accuracy: 0.0001, ".ended is the note path again")
    }

    // MARK: Inbound clip

    func testInboundClipDrivesTheSphereWhenNotHolding() {
        let level = WalkieSphereLevel.select(holding: false, link: .notes,
                                             micLevel: 0.8, inboundBusy: true,
                                             inboundLevel: 0.4, linkRemoteLevel: 0, linkLocalLevel: 0, liveInboundLevel: nil)
        XCTAssertEqual(level, 0.4, accuracy: 0.0001)
    }

    func testInboundClipStillDrivesTheSphereUnderALink() {
        // Scenario 4: a note auto-plays under a live link; the sphere reacts to it.
        let level = WalkieSphereLevel.select(holding: false, link: .live,
                                             micLevel: 0.8, inboundBusy: true,
                                             inboundLevel: 0.4, linkRemoteLevel: 0, linkLocalLevel: 0, liveInboundLevel: nil)
        XCTAssertEqual(level, 0.4, accuracy: 0.0001)
    }

    // MARK: Idle

    func testIdleIsZero() {
        let level = WalkieSphereLevel.select(holding: false, link: .notes,
                                             micLevel: 0.9, inboundBusy: false,
                                             inboundLevel: 0.9, linkRemoteLevel: 0, linkLocalLevel: 0, liveInboundLevel: nil)
        XCTAssertEqual(level, 0, "a stale meter must not leak while idle")
    }

    // MARK: THE fix: a hold under a link never reads the stale capture meter

    func testHoldUnderEveryLinkStateIgnoresTheStaleMic() {
        for link in [WalkieLinkStatus.reaching, .connecting, .live] {
            let level = WalkieSphereLevel.select(holding: true, link: link,
                                                 micLevel: 0.95, inboundBusy: false,
                                                 inboundLevel: 0, linkRemoteLevel: 0, linkLocalLevel: 0, liveInboundLevel: nil)
            XCTAssertEqual(level, 0, "\(link): the capture engine is not running, its meter is stale")
        }
    }

    func testHoldWhileOpeningFallsThroughToAnInboundClip() {
        // Reaching / connecting: no link level exists yet, so a hold with a
        // clip auto-playing shows the clip (never the stale capture meter).
        for link in [WalkieLinkStatus.reaching, .connecting] {
            let level = WalkieSphereLevel.select(holding: true, link: link,
                                                 micLevel: 0.95, inboundBusy: true,
                                                 inboundLevel: 0.2, linkRemoteLevel: 0, linkLocalLevel: 0, liveInboundLevel: nil)
            XCTAssertEqual(level, 0.2, accuracy: 0.0001, "\(link): stale mic skipped; the clip still shows")
        }
    }

    func testHoldOnALiveLinkBeatsAnInboundClip() {
        // Loop 3 (mine wins): on a LIVE link a hold shows MY level even while
        // a clip auto-plays — the same precedence the note path has, where a
        // hold beats a clip. Was a loop-1 pin of the interim state.
        let level = WalkieSphereLevel.select(holding: true, link: .live,
                                             micLevel: 0.95, inboundBusy: true,
                                             inboundLevel: 0.2, linkRemoteLevel: 0, linkLocalLevel: 0.5, liveInboundLevel: nil)
        XCTAssertEqual(level, 0.5, accuracy: 0.0001, "holding on live: mine, not the clip")
    }

    // MARK: Loop 2: the peer's voice on a live link

    func testLiveLinkShowsThePeersVoice() {
        let level = WalkieSphereLevel.select(holding: false, link: .live,
                                             micLevel: nil, inboundBusy: false,
                                             inboundLevel: 0, linkRemoteLevel: 0.6, linkLocalLevel: 0, liveInboundLevel: nil)
        XCTAssertEqual(level, 0.6, accuracy: 0.0001)
    }

    func testHoldUnderALiveLinkWithNoLocalLevelYetShowsNothingStale() {
        // Loop 3: a hold on a live link shows MY level (mine wins). With no
        // local sample yet it is 0 — never the stale capture meter, and not
        // the peer's level either (that is loop 3's precedence ruling).
        let level = WalkieSphereLevel.select(holding: true, link: .live,
                                             micLevel: 0.95, inboundBusy: false,
                                             inboundLevel: 0, linkRemoteLevel: 0.6, linkLocalLevel: 0, liveInboundLevel: nil)
        XCTAssertEqual(level, 0, "stale mic skipped; mine wins over theirs while holding")
    }

    func testRemoteLevelIsIgnoredUnlessTheLinkIsLive() {
        for link in [WalkieLinkStatus.notes, .reaching, .connecting, .ended(.remoteEnded)] {
            let level = WalkieSphereLevel.select(holding: false, link: link,
                                                 micLevel: nil, inboundBusy: false,
                                                 inboundLevel: 0, linkRemoteLevel: 0.6, linkLocalLevel: 0, liveInboundLevel: nil)
            XCTAssertEqual(level, 0, "\(link): a leftover remote level must not move the sphere")
        }
    }

    func testAnAutoPlayingClipStillBeatsTheLinkLevel() {
        // Scenario 4 under a live link: the clip is the louder claim on the sphere.
        let level = WalkieSphereLevel.select(holding: false, link: .live,
                                             micLevel: nil, inboundBusy: true,
                                             inboundLevel: 0.3, linkRemoteLevel: 0.6, linkLocalLevel: 0, liveInboundLevel: nil)
        XCTAssertEqual(level, 0.3, accuracy: 0.0001)
    }

    // MARK: Loop 3: my own voice while holding on a live link (mine wins)

    func testHoldOnALiveLinkShowsMyVoice() {
        let level = WalkieSphereLevel.select(holding: true, link: .live,
                                             micLevel: 0.95, inboundBusy: false,
                                             inboundLevel: 0, linkRemoteLevel: 0,
                                             linkLocalLevel: 0.5, liveInboundLevel: nil)
        XCTAssertEqual(level, 0.5, accuracy: 0.0001, "the link's local level, not the stale capture meter")
    }

    func testHoldOnALiveLinkWhileThePeerTalksStillShowsMyVoice() {
        // Mine wins (Rubins, 2026-09-12): the outbound pulse exists so I
        // know my mic is live while I hold; the peer talking over my hold is
        // the rare case and must not take the sphere from me.
        let level = WalkieSphereLevel.select(holding: true, link: .live,
                                             micLevel: nil, inboundBusy: false,
                                             inboundLevel: 0, linkRemoteLevel: 0.9,
                                             linkLocalLevel: 0.2, liveInboundLevel: nil)
        XCTAssertEqual(level, 0.2, accuracy: 0.0001)
    }

    func testLocalLevelIsIgnoredUnlessHoldingOnALiveLink() {
        // Not holding on live → the peer's level, never a leftover local one.
        let released = WalkieSphereLevel.select(holding: false, link: .live,
                                                micLevel: nil, inboundBusy: false,
                                                inboundLevel: 0, linkRemoteLevel: 0.4,
                                                linkLocalLevel: 0.8, liveInboundLevel: nil)
        XCTAssertEqual(released, 0.4, accuracy: 0.0001, "released: theirs shows")
        // Holding but not live (reaching / connecting) → 0: no link levels yet.
        for link in [WalkieLinkStatus.reaching, .connecting] {
            let level = WalkieSphereLevel.select(holding: true, link: link,
                                                 micLevel: nil, inboundBusy: false,
                                                 inboundLevel: 0, linkRemoteLevel: 0.4,
                                                 linkLocalLevel: 0.8, liveInboundLevel: nil)
            XCTAssertEqual(level, 0, "\(link): nothing transmits before open")
        }
        // Holding on the note path → the capture meter, never a link level.
        let notes = WalkieSphereLevel.select(holding: true, link: .notes,
                                             micLevel: 0.3, inboundBusy: false,
                                             inboundLevel: 0, linkRemoteLevel: 0.4,
                                             linkLocalLevel: 0.8, liveInboundLevel: nil)
        XCTAssertEqual(notes, 0.3, accuracy: 0.0001, "note path: the capture meter")
    }

    // MARK: Loop 4: the peer's voice on a BLE-live session (no link)

    func testLiveInboundSessionShowsThePeersVoice() {
        let level = WalkieSphereLevel.select(holding: false, link: .notes,
                                             micLevel: nil, inboundBusy: false,
                                             inboundLevel: 0, linkRemoteLevel: 0,
                                             linkLocalLevel: 0, liveInboundLevel: 0.55)
        XCTAssertEqual(level, 0.55, accuracy: 0.0001)
    }

    func testHoldOnTheNotePathBeatsALiveInboundSession() {
        // Half-duplex feel: while I hold, my mic (the capture meter) wins —
        // the same rule as a hold over an auto-playing clip.
        let level = WalkieSphereLevel.select(holding: true, link: .notes,
                                             micLevel: 0.3, inboundBusy: false,
                                             inboundLevel: 0, linkRemoteLevel: 0,
                                             linkLocalLevel: 0, liveInboundLevel: 0.9)
        XCTAssertEqual(level, 0.3, accuracy: 0.0001)
    }

    func testAClipBeatsALiveInboundSessionWhichBeatsTheLinkLevel() {
        let clip = WalkieSphereLevel.select(holding: false, link: .notes,
                                            micLevel: nil, inboundBusy: true,
                                            inboundLevel: 0.2, linkRemoteLevel: 0,
                                            linkLocalLevel: 0, liveInboundLevel: 0.9)
        XCTAssertEqual(clip, 0.2, accuracy: 0.0001, "the clip is the louder claim")
        // A BLE-live session while an IP link is ALSO live: the player is
        // audibly playing the session, so it wins over the link's remote read.
        let both = WalkieSphereLevel.select(holding: false, link: .live,
                                            micLevel: nil, inboundBusy: false,
                                            inboundLevel: 0, linkRemoteLevel: 0.7,
                                            linkLocalLevel: 0, liveInboundLevel: 0.4)
        XCTAssertEqual(both, 0.4, accuracy: 0.0001)
        // No session (nil) → the link's remote level as before.
        let linkOnly = WalkieSphereLevel.select(holding: false, link: .live,
                                                micLevel: nil, inboundBusy: false,
                                                inboundLevel: 0, linkRemoteLevel: 0.7,
                                                linkLocalLevel: 0, liveInboundLevel: nil)
        XCTAssertEqual(linkOnly, 0.7, accuracy: 0.0001)
    }
}
