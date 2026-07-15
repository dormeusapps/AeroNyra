//
//  PTTSessionOwnerTests.swift
//  BeaconTests
//
//  PTT C-3a, exercised HARDWARE-FREE: the session side effects and the player
//  go behind the owner's injectable seams (`PTTAudioSessionControlling`,
//  `PTTLivePlayout`), so these tests never touch the real `AVAudioSession`
//  (whose setCategory/setActive can throw on the simulator) and never build
//  an AVAudioEngine graph. Covered: the IC8 flag transitions, open/close
//  idempotency, the opened() ordering contract (activate → flag → pre-empt →
//  ready), the fail-closed activation-failure contract (§2.1 point 2), the
//  last-close release, and the interruption ending policy.
//

import XCTest
@testable import Beacon

@MainActor
final class PTTSessionOwnerTests: XCTestCase {

    /// One shared, ordered record of every side effect across both spies and
    /// the pre-empt closure — call ORDERING is the contract under test.
    private final class Recorder {
        var log: [String] = []
        func note(_ s: String) { log.append(s) }
    }

    private final class SessionSpy: PTTAudioSessionControlling {
        let rec: Recorder
        var throwOnActivate = false
        init(_ rec: Recorder) { self.rec = rec }
        struct Boom: Error {}
        func activateForPTT() throws {
            rec.note("activate")
            if throwOnActivate { throw Boom() }
        }
        func deactivate() { rec.note("deactivate") }
    }

    private final class PlayoutSpy: PTTLivePlayout {
        let rec: Recorder
        init(_ rec: Recorder) { self.rec = rec }
        func readyForSession() { rec.note("ready") }
        func drop(link: UUID) { rec.note("drop(\(link.uuidString.prefix(4)))") }
    }

    private func makeOwner(throwOnActivate: Bool = false)
        -> (PTTSessionOwner, Recorder) {
        let rec = Recorder()
        let session = SessionSpy(rec)
        session.throwOnActivate = throwOnActivate
        let owner = PTTSessionOwner(player: PlayoutSpy(rec), audioSession: session)
        return (owner, rec)
    }

    // MARK: Open — ordering + flag

    func testOpenActivatesRaisesFlagPreemptsThenReadies() {
        let (owner, rec) = makeOwner()
        var flagAtPreempt: Bool?
        owner.preemptPlayback = { [weak owner] in
            rec.note("preempt")
            flagAtPreempt = owner?.isLive
        }

        XCTAssertFalse(owner.isLive)
        owner.opened(link: UUID())

        // The tested contract: activate, then pre-empt, then ready — never
        // the player before the pre-empt.
        XCTAssertEqual(rec.log, ["activate", "preempt", "ready"])
        XCTAssertTrue(owner.isLive)
        // IC8 flag was already up when the pre-empt ran (activate → flag → preempt).
        XCTAssertEqual(flagAtPreempt, true)
    }

    func testOpenWithoutPreemptClosureStillReadies() {
        let (owner, rec) = makeOwner()               // preemptPlayback stays nil (inert)
        owner.opened(link: UUID())
        XCTAssertEqual(rec.log, ["activate", "ready"])
        XCTAssertTrue(owner.isLive)
    }

    func testActivationFailureFailsClosed() {
        // §2.1 point 2: the IC8 flag asserts a fact about the AUDIO SESSION,
        // not the wire. A throw must not raise the flag, pre-empt, or ready —
        // a raised flag over a phantom session would suppress VoicePlayer's
        // setActive(false) and background music would never resume (F2).
        let (owner, rec) = makeOwner(throwOnActivate: true)
        owner.preemptPlayback = { rec.note("preempt") }
        owner.opened(link: UUID())
        XCTAssertEqual(rec.log, ["activate"])        // attempted, nothing else
        XCTAssertFalse(owner.isLive)
    }

    func testActivationFailureIsNotTrackedSoNextOpenRetries() {
        // Activate-then-commit: a failed FIRST-link activation must not leave
        // the link in `openLinks` (that would make every later open look like
        // a join and never retry — a permanently phantom session). The next
        // open is a 0→1 edge again and retries activation, which self-heals.
        let rec = Recorder()
        let session = SessionSpy(rec)
        session.throwOnActivate = true
        let owner = PTTSessionOwner(player: PlayoutSpy(rec), audioSession: session)
        owner.preemptPlayback = { rec.note("preempt") }

        let link = UUID()
        owner.opened(link: link)                     // fails — link not tracked
        XCTAssertEqual(rec.log, ["activate"])
        XCTAssertFalse(owner.isLive)

        session.throwOnActivate = false              // transient failure clears
        owner.opened(link: link)                     // same link retries the 0→1 edge
        XCTAssertEqual(rec.log, ["activate", "activate", "preempt", "ready"])
        XCTAssertTrue(owner.isLive)

        owner.closed(link: link)                     // and closes cleanly
        XCTAssertFalse(owner.isLive)
        XCTAssertEqual(rec.log.last, "deactivate")
    }

    // MARK: Close — flag + release

    func testCloseDropsLowersFlagThenDeactivates() {
        let (owner, rec) = makeOwner()
        let link = UUID()
        owner.opened(link: link)
        rec.log.removeAll()

        owner.closed(link: link)

        XCTAssertEqual(rec.log, ["drop(\(link.uuidString.prefix(4)))", "deactivate"])
        XCTAssertFalse(owner.isLive)
    }

    // MARK: Idempotency

    func testDoubleOpenIsIdempotent() {
        let (owner, rec) = makeOwner()
        owner.preemptPlayback = { rec.note("preempt") }
        let link = UUID()
        owner.opened(link: link)
        owner.opened(link: link)                     // second open: no-op
        XCTAssertEqual(rec.log, ["activate", "preempt", "ready"])
        XCTAssertTrue(owner.isLive)
    }

    func testDoubleCloseIsIdempotent() {
        let (owner, rec) = makeOwner()
        let link = UUID()
        owner.opened(link: link)
        owner.closed(link: link)
        let after = rec.log
        owner.closed(link: link)                     // second close: no-op
        owner.closed(link: UUID())                   // never-opened link: no-op
        XCTAssertEqual(rec.log, after)               // no extra drop/deactivate
        XCTAssertFalse(owner.isLive)
    }

    func testCloseWithoutOpenIsNoop() {
        let (owner, rec) = makeOwner()
        owner.closed(link: UUID())
        XCTAssertEqual(rec.log, [])
        XCTAssertFalse(owner.isLive)
    }

    // MARK: Concurrent wire sessions (activate on first, release on last)

    func testSecondLinkJoinsWithoutReactivationAndLastCloseReleases() {
        let (owner, rec) = makeOwner()
        let a = UUID(), b = UUID()
        owner.opened(link: a)
        owner.opened(link: b)                        // joins; no second activate
        XCTAssertEqual(rec.log, ["activate", "ready"])

        owner.closed(link: a)                        // one still live → no release
        XCTAssertTrue(owner.isLive)
        XCTAssertFalse(rec.log.contains("deactivate"))

        owner.closed(link: b)                        // last close → flag down + release
        XCTAssertFalse(owner.isLive)
        XCTAssertEqual(rec.log.last, "deactivate")
        XCTAssertEqual(rec.log.filter { $0 == "deactivate" }.count, 1)
    }

    // MARK: Interruption (CallEngine's v1 policy, mirrored)

    func testInterruptionBeganEndsAllSessionsAndReleases() {
        let (owner, rec) = makeOwner()
        let a = UUID(), b = UUID()
        owner.opened(link: a)
        owner.opened(link: b)
        rec.log.removeAll()

        owner.interruptionBegan()

        XCTAssertFalse(owner.isLive)                 // flag lowered
        XCTAssertEqual(rec.log.filter { $0.hasPrefix("drop(") }.count, 2)
        XCTAssertEqual(rec.log.last, "deactivate")   // session released once
        XCTAssertEqual(rec.log.filter { $0 == "deactivate" }.count, 1)
    }

    func testInterruptionWhileIdleIsNoop() {
        let (owner, rec) = makeOwner()
        owner.interruptionBegan()
        XCTAssertEqual(rec.log, [])
        XCTAssertFalse(owner.isLive)
    }
}
