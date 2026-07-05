//
//  ReconnectTimeoutExtensionTests.swift
//  BeaconTests
//
//  Closed-Contact STEP 0 (A) — reconnect-aware delivery timeout.
//
//  THE MECHANISM A RESTS ON. During a peer's reconnect, a delivery ack can be
//  delayed by link churn. Before A, the router's stuck-send timer ran to
//  completion regardless and flipped a still-unconfirmed row to `.notDelivered`,
//  making the sender's chip lie and triggering a needless auto-retry. A adds
//  `MessageRouter.extendTimeout(for:by:)`: a PER-MESSAGE, identity-free hook that
//  re-arms a live timer with a fresh deadline so the delayed ack has room to land.
//  The caller that owns peer↔message (MessageInbox) decides WHICH ids to extend;
//  the router never learns the peer — preserving its no-recipiency design.
//
//  WHAT THIS SUITE PROVES (router level — where the primitive lives):
//    • extendTimeout is INERT where it must be — it creates no tracking for an
//      unknown id, and does not disturb a message that already reached a terminal
//      state (an ack that already won the race); and
//    • it actually MOVES the deadline — an un-extended short timer fires and fails
//      the message, while the same timer, once extended, does NOT fire in the same
//      window (the original timer was cancelled and replaced).
//  The two timing tests are a matched pair: the control proves the timer fires at
//  all, so the extension test's non-firing is meaningful rather than vacuous.
//
//  WHAT THIS SUITE DELIBERATELY DOES NOT PROVE, and why (honest scope, matching
//  WarmInboundSessionsTests naming its load-bearing property as hardware-owed).
//  The PER-PEER GRACE ORCHESTRATION lives in MessageInbox (main-actor + SwiftData):
//  resolving a reconnected peer to its in-flight wire ids, deferring that peer's
//  `flushUndelivered` until the grace elapses, and the deferred-flush scheduling.
//  Exercising it needs a ModelContainer plus a FirstContactCoordinator (whose init
//  takes a concrete BLEMeshTransport — CoreBluetooth in a unit test), so the full
//  reconnect → hold-retry → ack-wins → no-needless-resend loop is the two-phone
//  walk-out-and-back hardware check (SESSION_HANDOFF_v19, "AFTER THE FIX"): sender
//  shows DELIVERED, and — with B2 underneath — the receiver shows no duplicate.
//
//  XCTest only.
//

import XCTest
@testable import Beacon

final class ReconnectTimeoutExtensionTests: XCTestCase {

    /// A router with no transports: the tracking + timeout surface under test
    /// (beginTracking / startDeliveryTimeout / extendTimeout / state) touches no
    /// transport, so this needs neither a transport double nor `start()`.
    private func makeRouter() -> MessageRouter { MessageRouter(transports: []) }

    // MARK: - Inert where it must be

    func testExtendIgnoresUntrackedID() async {
        let router = makeRouter()
        let id = MessageID.random()
        await router.extendTimeout(for: id, by: .seconds(60))
        let state = await router.state(of: id)
        XCTAssertNil(state, "extendTimeout must not create tracking for an unknown id")
    }

    func testExtendDoesNotDisturbTerminalMessage() async {
        let router = makeRouter()
        let id = MessageID.random()
        await router.beginTracking(of: id)
        await router.confirmDelivery(of: id, hops: 0)   // → .delivered (terminal)
        await router.extendTimeout(for: id, by: .seconds(60))
        let state = await router.state(of: id)
        XCTAssertEqual(state, .delivered,
                       "extend must not resurrect or re-arm a message that already settled")
    }

    // MARK: - Actually moves the deadline (matched pair)

    /// Control: an un-extended short timer fires and fails the message. Establishes
    /// that the timer fires at all, so the extension test below is not vacuous.
    func testUnextendedShortTimerFires() async throws {
        let router = makeRouter()
        let id = MessageID.random()
        await router.beginTracking(of: id)
        await router.startDeliveryTimeout(for: id, after: .milliseconds(200))

        try await Task.sleep(for: .milliseconds(600))   // well past 200ms

        let state = await router.state(of: id)
        XCTAssertEqual(state, .notDelivered,
                       "an un-extended short timer must fire and mark the message .notDelivered")
    }

    /// The extension cancels the original short timer and installs a far-future one,
    /// so the message does NOT time out in the same window the control failed in.
    func testExtendPreventsFireInTheOriginalWindow() async throws {
        let router = makeRouter()
        let id = MessageID.random()
        await router.beginTracking(of: id)
        await router.startDeliveryTimeout(for: id, after: .milliseconds(200))
        await router.extendTimeout(for: id, by: .seconds(60))   // replaces the 200ms timer

        try await Task.sleep(for: .milliseconds(600))   // the control failed by here

        let state = await router.state(of: id)
        XCTAssertEqual(state, .sent,
                       "extend must cancel the original short timer; the message must not time out")
    }

    // MARK: - .cast is never timed (P0 pin)
    //
    // A relay-committed (`.cast`) message has NO bounded ack deadline — the wrap
    // waits at the relay until the peer next connects. `commitToRelay` cancels
    // any timer on purpose; before the guard, the reconnect-grace path's
    // `extendTimeout` silently re-armed one, and ~10s after walking back into
    // BLE range the timer fired and flipped "cast · will surface" to a false
    // "tap to resend". These pins hold the invariant "no timer is ever armed
    // for a cast commit" at both arm sites, prove we did NOT over-guard (a
    // `.sent` entry still times out), and prove the ack path was untouched.

    func testExtendDoesNotArmTimerOnCastEntry() async throws {
        let router = makeRouter()
        let id = MessageID.random()
        await router.beginTracking(of: id)
        await router.commitToRelay(id)                          // → .cast, timer cancelled
        await router.extendTimeout(for: id, by: .milliseconds(200))

        try await Task.sleep(for: .milliseconds(600))   // the .sent control fires by here

        let state = await router.state(of: id)
        XCTAssertEqual(state, .cast,
                       "extendTimeout must be a no-op on .cast — no timer may ever demote a relay commit")
    }

    func testStartDeliveryTimeoutIsNoOpOnCastEntry() async throws {
        let router = makeRouter()
        let id = MessageID.random()
        await router.beginTracking(of: id)
        await router.commitToRelay(id)                          // → .cast
        await router.startDeliveryTimeout(for: id, after: .milliseconds(200))

        try await Task.sleep(for: .milliseconds(600))

        let state = await router.state(of: id)
        XCTAssertEqual(state, .cast,
                       "startDeliveryTimeout must be a no-op on .cast")
    }

    /// Negative control (no over-guarding): a `.sent` entry given a SHORT
    /// extension still times out — the guard removed `.cast` from timing, not
    /// timers from `.sent`.
    func testExtendStillArmsTimerForSentEntry() async throws {
        let router = makeRouter()
        let id = MessageID.random()
        await router.beginTracking(of: id)                      // .sent
        await router.extendTimeout(for: id, by: .milliseconds(200))

        try await Task.sleep(for: .milliseconds(600))

        let state = await router.state(of: id)
        XCTAssertEqual(state, .notDelivered,
                       "a .sent entry's extended timer must still fire — the guard is .cast-only")
    }

    /// The ack path is untouched: a real delivery ack still surfaces `.cast`.
    func testAckStillSurfacesCastEntry() async {
        let router = makeRouter()
        let id = MessageID.random()
        await router.beginTracking(of: id)
        await router.commitToRelay(id)
        await router.confirmDelivery(of: id, hops: 0)
        let state = await router.state(of: id)
        XCTAssertEqual(state, .delivered,
                       "a real ack must still surface a .cast row to .delivered")
    }

    /// And a real failure ack can still fail it — only TIMERS are ruled out.
    func testFailureAckStillFailsCastEntry() async {
        let router = makeRouter()
        let id = MessageID.random()
        await router.beginTracking(of: id)
        await router.commitToRelay(id)
        await router.confirmFailure(of: id)
        let state = await router.state(of: id)
        XCTAssertEqual(state, .notDelivered,
                       "confirmFailure must still be able to demote a .cast row")
    }
}
