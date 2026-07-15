//
//  PTTSessionOwnerTests.swift
//  BeaconTests
//
//  PTT C-3a (re-keyed by C-3b′ §3.5), exercised HARDWARE-FREE: the session
//  side effects go behind the owner's injectable seam
//  (`PTTAudioSessionControlling`), so these tests never touch the real
//  `AVAudioSession` (whose setCategory/setActive can throw on the simulator).
//  The owner is keyed by SESSION (pttID) and holds no player — player
//  eviction is the coordinator's, link-keyed at `.pttClose` (C-3c). Covered:
//  the IC8 flag transitions, open/close idempotency per pttID, the opened()
//  ordering contract (activate → flag → pre-empt), the fail-closed
//  activation-failure contract (§2.1 point 2), the last-close release, and
//  the interruption ending policy.
//

import XCTest
@testable import Beacon

@MainActor
final class PTTSessionOwnerTests: XCTestCase {

    /// `PTTSessionOwner.shared` is process-global; it is weak (so it clears
    /// on dealloc anyway), but reset it explicitly so no test's owner ever
    /// leaks into another test.
    override func tearDown() {
        MainActor.assumeIsolated { PTTSessionOwner.shared = nil }
        super.tearDown()
    }

    /// One shared, ordered record of every side effect across the session spy
    /// and the pre-empt closure — call ORDERING is the contract under test.
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

    private func makeOwner(throwOnActivate: Bool = false)
        -> (PTTSessionOwner, Recorder) {
        let rec = Recorder()
        let session = SessionSpy(rec)
        session.throwOnActivate = throwOnActivate
        let owner = PTTSessionOwner(audioSession: session)
        return (owner, rec)
    }

    /// A deterministic 16-byte session id, the shape of a wire pttID.
    private func pttID(_ byte: UInt8) -> Data { Data(repeating: byte, count: 16) }
    /// A stand-in raw peer key (identity — never the refcount key).
    private let peer = Data(repeating: 0xAB, count: 32)

    // MARK: Open — ordering + flag

    func testOpenActivatesRaisesFlagThenPreempts() {
        let (owner, rec) = makeOwner()
        var flagAtPreempt: Bool?
        owner.preemptPlayback = { [weak owner] in
            rec.note("preempt")
            flagAtPreempt = owner?.isLive
        }

        XCTAssertFalse(owner.isLive)
        owner.opened(pttID: pttID(1), peerKey: peer)

        // The tested contract: activate, then pre-empt — the pre-empt never
        // runs before the session is really active.
        XCTAssertEqual(rec.log, ["activate", "preempt"])
        XCTAssertTrue(owner.isLive)
        // IC8 flag was already up when the pre-empt ran (activate → flag → preempt).
        XCTAssertEqual(flagAtPreempt, true)
    }

    func testOpenWithoutPreemptClosureStillActivates() {
        let (owner, rec) = makeOwner()               // preemptPlayback stays nil (inert)
        owner.opened(pttID: pttID(1), peerKey: peer)
        XCTAssertEqual(rec.log, ["activate"])
        XCTAssertTrue(owner.isLive)
    }

    func testActivationFailureFailsClosed() {
        // §2.1 point 2: the IC8 flag asserts a fact about the AUDIO SESSION,
        // not the wire. A throw must not raise the flag or pre-empt — a
        // raised flag over a phantom session would suppress VoicePlayer's
        // setActive(false) and background music would never resume (F2).
        let (owner, rec) = makeOwner(throwOnActivate: true)
        owner.preemptPlayback = { rec.note("preempt") }
        owner.opened(pttID: pttID(1), peerKey: peer)
        XCTAssertEqual(rec.log, ["activate"])        // attempted, nothing else
        XCTAssertFalse(owner.isLive)
    }

    func testActivationFailureIsNotTrackedSoNextOpenRetries() {
        // Activate-then-commit: a failed FIRST activation must not leave the
        // pttID in `openSessions` (that would make every later open look like
        // a join and never retry — a permanently phantom session). The next
        // open is a 0→1 edge again and retries activation, which self-heals.
        let rec = Recorder()
        let session = SessionSpy(rec)
        session.throwOnActivate = true
        let owner = PTTSessionOwner(audioSession: session)
        owner.preemptPlayback = { rec.note("preempt") }

        let id = pttID(1)
        owner.opened(pttID: id, peerKey: peer)       // fails — pttID not tracked
        XCTAssertEqual(rec.log, ["activate"])
        XCTAssertFalse(owner.isLive)

        session.throwOnActivate = false              // transient failure clears
        owner.opened(pttID: id, peerKey: peer)       // same session retries the 0→1 edge
        XCTAssertEqual(rec.log, ["activate", "activate", "preempt"])
        XCTAssertTrue(owner.isLive)

        owner.closed(pttID: id)                      // and closes cleanly
        XCTAssertFalse(owner.isLive)
        XCTAssertEqual(rec.log.last, "deactivate")
    }

    // MARK: Close — flag + release

    func testCloseLowersFlagThenDeactivates() {
        let (owner, rec) = makeOwner()
        let id = pttID(1)
        owner.opened(pttID: id, peerKey: peer)
        rec.log.removeAll()

        owner.closed(pttID: id)

        // No player eviction here — that is the coordinator's, link-keyed at
        // `.pttClose` (§3.5). The owner only releases the audio session.
        XCTAssertEqual(rec.log, ["deactivate"])
        XCTAssertFalse(owner.isLive)
    }

    // MARK: Idempotency

    func testDoubleOpenIsIdempotent() {
        let (owner, rec) = makeOwner()
        owner.preemptPlayback = { rec.note("preempt") }
        let id = pttID(1)
        owner.opened(pttID: id, peerKey: peer)
        owner.opened(pttID: id, peerKey: peer)       // second open: no-op
        XCTAssertEqual(rec.log, ["activate", "preempt"])
        XCTAssertTrue(owner.isLive)
    }

    func testDoubleCloseIsIdempotent() {
        let (owner, rec) = makeOwner()
        let id = pttID(1)
        owner.opened(pttID: id, peerKey: peer)
        owner.closed(pttID: id)
        let after = rec.log
        owner.closed(pttID: id)                      // second close: no-op
        owner.closed(pttID: pttID(9))                // never-opened session: no-op
        XCTAssertEqual(rec.log, after)               // no extra deactivate
        XCTAssertFalse(owner.isLive)
    }

    func testCloseWithoutOpenIsNoop() {
        let (owner, rec) = makeOwner()
        owner.closed(pttID: pttID(1))
        XCTAssertEqual(rec.log, [])
        XCTAssertFalse(owner.isLive)
    }

    // MARK: Concurrent wire sessions (activate on first, release on last)

    func testSecondSessionJoinsWithoutReactivationAndLastCloseReleases() {
        // Two DISTINCT pttIDs from the SAME peer count as two sessions —
        // the refcount is keyed by session, not identity (§3.5).
        let (owner, rec) = makeOwner()
        let a = pttID(1), b = pttID(2)
        owner.opened(pttID: a, peerKey: peer)
        owner.opened(pttID: b, peerKey: peer)        // joins; no second activate
        XCTAssertEqual(rec.log, ["activate"])

        owner.closed(pttID: a)                       // one still live → no release
        XCTAssertTrue(owner.isLive)
        XCTAssertFalse(rec.log.contains("deactivate"))

        owner.closed(pttID: b)                       // last close → flag down + release
        XCTAssertFalse(owner.isLive)
        XCTAssertEqual(rec.log.last, "deactivate")
        XCTAssertEqual(rec.log.filter { $0 == "deactivate" }.count, 1)
    }

    // MARK: Interruption (CallEngine's v1 policy, mirrored)

    func testInterruptionBeganEndsAllSessionsAndReleases() {
        let (owner, rec) = makeOwner()
        owner.opened(pttID: pttID(1), peerKey: peer)
        owner.opened(pttID: pttID(2), peerKey: peer)
        rec.log.removeAll()

        owner.interruptionBegan()

        XCTAssertFalse(owner.isLive)                 // flag lowered
        XCTAssertEqual(rec.log, ["deactivate"])      // session released exactly once
    }

    func testInterruptionWhileIdleIsNoop() {
        let (owner, rec) = makeOwner()
        owner.interruptionBegan()
        XCTAssertEqual(rec.log, [])
        XCTAssertFalse(owner.isLive)
    }

    // MARK: Static lookup (§2.1 point 5 — the guard-site accessor)

    func testStaticIsLiveIsFalseWhenSharedIsNil() {
        PTTSessionOwner.shared = nil                 // pre-C-3c world: unwired
        XCTAssertFalse(PTTSessionOwner.isLive)       // guard inert by construction
    }

    func testStaticIsLiveIsALookupThroughSharedNotACopy() {
        let (owner, _) = makeOwner()
        PTTSessionOwner.shared = owner
        XCTAssertFalse(PTTSessionOwner.isLive)       // wired but not live yet

        let id = pttID(1)
        owner.opened(pttID: id, peerKey: peer)
        XCTAssertTrue(PTTSessionOwner.isLive)        // tracks the instance flag…
        owner.closed(pttID: id)
        XCTAssertFalse(PTTSessionOwner.isLive)       // …in both directions: no drift
    }

    func testStaticIsLiveIsFalseAfterSharedOwnerDeallocates() {
        var owner: PTTSessionOwner? = makeOwner().0
        PTTSessionOwner.shared = owner
        owner?.opened(pttID: pttID(1), peerKey: peer)
        XCTAssertTrue(PTTSessionOwner.isLive)

        owner = nil                                  // weak → shared self-clears
        XCTAssertNil(PTTSessionOwner.shared)
        XCTAssertFalse(PTTSessionOwner.isLive)       // fails closed, no crash
    }
}
