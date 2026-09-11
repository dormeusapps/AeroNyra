// CallControllerTests.swift
// Pins the FaceTime-v1 call state machine (`Core/Calls/CallController.swift`)
// AS IT BEHAVES TODAY, against a fake `CallMediaSession` and a captured
// `sendSignal` seam. Written before `PTTLinkController` lands beside it so
// the shared seams have a baseline.
//
// PINNING DISCIPLINE: every test here asserts current behavior, including
// behavior that may later be changed deliberately. Three such cases are
// marked `PINNED-AS-IS` below; when any of them is fixed on purpose, its pin
// FAILS ON PURPOSE — rewrite the pin, never restore the old behavior:
//   • the busy rule auto-declines a new `.request` in EVERY non-idle state,
//     including `.ended` (the terminal state the UI has not yet reset from);
//   • `onFailed` during `.active` ends as `.connectFailed`, not `.hungUp`;
//   • an inbound `.decline` while `.incomingRinging` matches on call id only,
//     not peer identity (every other inbound arm checks both).
// None is corrected here.
//
// DELIBERATELY UNPINNED — the ring TIMER path. `CallController.ringTimeout`
// is a `public static let` of 45 s consumed directly by `Task.sleep`; there
// is no injectable clock or duration, so the timer-driven `.ended(.timedOut)`
// transition can only be observed by a real 45-second wait. The operator
// ruled that test out (it taxes every run and proves only that `Task.sleep`
// works). The decline-driven `.timedOut` transition and the `onMissedCall`
// hook ARE pinned (`testRemoteDeclineWhileIncomingRingingIsMissedCall`).
// This is a known gap, not an oversight; `PTTLinkController` gets an
// injectable duration from the start for exactly this reason.
//

import XCTest
@testable import Beacon

@MainActor
final class CallControllerTests: XCTestCase {

    // MARK: - Fixtures

    private let peerA = Data(repeating: 0xA1, count: 32)
    private let peerB = Data(repeating: 0xB2, count: 32)
    private let idX = Data(repeating: 0x01, count: CallSignal.callIDByteCount)
    private let idY = Data(repeating: 0x02, count: CallSignal.callIDByteCount)

    // MARK: - Outgoing: happy path

    func testOutgoingHappyPath() async throws {
        let h = Harness()

        await h.controller.startCall(peerKey: peerA)

        // One media session, one offer, one sealed request to the peer.
        XCTAssertEqual(h.sessions.count, 1)
        XCTAssertEqual(h.session.makeOfferCalls, 1)
        guard case .outgoingRinging(let callID, let peerKey) = h.controller.state else {
            return XCTFail("expected outgoingRinging, got \(h.controller.state)")
        }
        XCTAssertEqual(callID.count, CallSignal.callIDByteCount)
        XCTAssertEqual(peerKey, peerA)
        XCTAssertEqual(h.sent.count, 1)
        XCTAssertEqual(h.sent[0].signal, .request(callID: callID, sdp: "offer-sdp"))
        XCTAssertEqual(h.sent[0].peer, peerA)

        // Their answer: apply it, go connecting.
        await h.controller.handleInbound(.answer(callID: callID, sdp: "answer-sdp"), from: peerA)
        XCTAssertEqual(h.controller.state, .connecting(callID: callID, peerKey: peerA))
        XCTAssertEqual(h.session.startCalls, ["answer-sdp"])

        // ICE up: active. A second connected callback is ignored.
        h.session.onConnected?()
        XCTAssertEqual(h.controller.state, .active(callID: callID, peerKey: peerA))
        h.session.onConnected?()
        XCTAssertEqual(h.controller.state, .active(callID: callID, peerKey: peerA))

        XCTAssertEqual(h.states, [
            .outgoingRinging(callID: callID, peerKey: peerA),
            .connecting(callID: callID, peerKey: peerA),
            .active(callID: callID, peerKey: peerA),
        ])
        XCTAssertEqual(h.session.closeCalls, 0)
        XCTAssertEqual(h.missedCalls, [])
    }

    func testStartCallWhileNotIdleIsNoOp() async {
        let h = Harness()
        await h.controller.startCall(peerKey: peerA)
        let ringing = h.controller.state

        await h.controller.startCall(peerKey: peerB)

        XCTAssertEqual(h.controller.state, ringing)
        XCTAssertEqual(h.sessions.count, 1)
        XCTAssertEqual(h.sent.count, 1)
    }

    func testStartCallMediaOfferThrowsEndsFailed() async {
        let h = Harness()
        h.nextOffer = .failure(FakeError.media)

        await h.controller.startCall(peerKey: peerA)

        XCTAssertEqual(h.controller.state, .ended(.failed))
        XCTAssertEqual(h.sent.count, 0, "nothing is sealed when the offer fails")
        XCTAssertEqual(h.session.closeCalls, 1)
        XCTAssertEqual(h.states, [.ended(.failed)])
    }

    func testStartCallSendThrowsEndsFailedAfterRinging() async {
        // Current order: state flips to outgoingRinging BEFORE the send, so a
        // failed send is observed as ringing → ended(.failed).
        let h = Harness()
        h.sendError = FakeError.send

        await h.controller.startCall(peerKey: peerA)

        XCTAssertEqual(h.controller.state, .ended(.failed))
        XCTAssertEqual(h.states.count, 2)
        guard case .outgoingRinging = h.states[0] else {
            return XCTFail("expected ringing first, got \(h.states[0])")
        }
        XCTAssertEqual(h.session.closeCalls, 1)
    }

    func testCancelOutgoingSendsDeclineAndEndsHungUp() async throws {
        let h = Harness()
        await h.controller.startCall(peerKey: peerA)
        let callID = try XCTUnwrap(h.controller.state.callID)

        await h.controller.cancelOutgoing()

        XCTAssertEqual(h.controller.state, .ended(.hungUp))
        XCTAssertEqual(h.sent.last?.signal, .decline(callID: callID))
        XCTAssertEqual(h.sent.last?.peer, peerA)
        XCTAssertEqual(h.session.closeCalls, 1)
        XCTAssertEqual(h.missedCalls, [])
    }

    func testCancelOutgoingIsNoOpOutsideOutgoingRinging() async {
        let h = Harness()
        await h.controller.cancelOutgoing()                     // idle
        XCTAssertEqual(h.controller.state, .idle)

        await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)
        await h.controller.cancelOutgoing()                     // incomingRinging
        XCTAssertEqual(h.controller.state,
                       .incomingRinging(callID: idX, peerKey: peerA, sdpOffer: "offer"))
        XCTAssertEqual(h.sent.count, 0)
    }

    // MARK: - Incoming: ring, accept, decline

    func testInboundRequestWhileIdleRings() async {
        let h = Harness()

        await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)

        XCTAssertEqual(h.controller.state,
                       .incomingRinging(callID: idX, peerKey: peerA, sdpOffer: "offer"))
        XCTAssertEqual(h.sent.count, 0)
        XCTAssertEqual(h.sessions.count, 0, "no media session until Accept")
    }

    func testAcceptHappyPath() async {
        let h = Harness()
        await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)

        await h.controller.accept()

        XCTAssertEqual(h.sessions.count, 1)
        XCTAssertEqual(h.session.makeAnswerCalls, ["offer"])
        XCTAssertEqual(h.controller.state, .connecting(callID: idX, peerKey: peerA))
        XCTAssertEqual(h.sent.count, 1)
        XCTAssertEqual(h.sent[0].signal, .answer(callID: idX, sdp: "answer-sdp"))
        XCTAssertEqual(h.sent[0].peer, peerA)

        h.session.onConnected?()
        XCTAssertEqual(h.controller.state, .active(callID: idX, peerKey: peerA))
        XCTAssertEqual(h.states, [
            .incomingRinging(callID: idX, peerKey: peerA, sdpOffer: "offer"),
            .connecting(callID: idX, peerKey: peerA),
            .active(callID: idX, peerKey: peerA),
        ])
    }

    func testAcceptIsNoOpOutsideIncomingRinging() async {
        let h = Harness()
        await h.controller.accept()                             // idle
        XCTAssertEqual(h.controller.state, .idle)
        XCTAssertEqual(h.sessions.count, 0)

        await h.controller.startCall(peerKey: peerA)
        let ringing = h.controller.state
        await h.controller.accept()                             // outgoingRinging
        XCTAssertEqual(h.controller.state, ringing)
        XCTAssertEqual(h.sessions.count, 1)
    }

    func testAcceptMediaAnswerThrowsEndsFailed() async {
        let h = Harness()
        h.nextAnswer = .failure(FakeError.media)
        await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)

        await h.controller.accept()

        XCTAssertEqual(h.controller.state, .ended(.failed))
        XCTAssertEqual(h.sent.count, 0, "no answer is sealed when media fails")
        XCTAssertEqual(h.session.closeCalls, 1)
    }

    func testAcceptSendThrowsEndsFailedAfterConnecting() async {
        // Same ordering as the outgoing side: connecting is entered before
        // the send, so a failed send reads connecting → ended(.failed).
        let h = Harness()
        h.sendError = FakeError.send
        await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)

        await h.controller.accept()

        XCTAssertEqual(h.controller.state, .ended(.failed))
        XCTAssertEqual(h.states, [
            .incomingRinging(callID: idX, peerKey: peerA, sdpOffer: "offer"),
            .connecting(callID: idX, peerKey: peerA),
            .ended(.failed),
        ])
        XCTAssertEqual(h.session.closeCalls, 1)
    }

    func testDeclineSendsDeclineAndEndsDeclined() async {
        let h = Harness()
        await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)

        await h.controller.decline()

        XCTAssertEqual(h.controller.state, .ended(.declined))
        XCTAssertEqual(h.sent.count, 1)
        XCTAssertEqual(h.sent[0].signal, .decline(callID: idX))
        XCTAssertEqual(h.sent[0].peer, peerA)
        XCTAssertEqual(h.sessions.count, 0, "declining never builds a media session")
        XCTAssertEqual(h.missedCalls, [], "a local decline is not a missed call")
    }

    func testDeclineIsNoOpOutsideIncomingRinging() async {
        let h = Harness()
        await h.controller.decline()                            // idle
        XCTAssertEqual(h.controller.state, .idle)
        await h.controller.startCall(peerKey: peerA)
        let ringing = h.controller.state
        await h.controller.decline()                            // outgoingRinging
        XCTAssertEqual(h.controller.state, ringing)
        XCTAssertEqual(h.sent.count, 1, "only the original request went out")
    }

    // MARK: - The busy rule (PINNED-AS-IS; PTT pre-emption will revisit)

    /// `handleInbound(.request)` in ANY non-idle state seals a `.decline` for
    /// the NEW call id back to whoever sent it, and leaves the current call,
    /// its state, and its media untouched. Pinned for every non-idle state
    /// reachable today, including `.ended`.
    func testBusyRuleAutoDeclinesNewRequestInEveryNonIdleState() async throws {
        // outgoingRinging
        do {
            let h = Harness()
            await h.controller.startCall(peerKey: peerA)
            try await assertBusy(h, label: "outgoingRinging")
        }
        // incomingRinging (a second ring, different peer)
        do {
            let h = Harness()
            await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)
            try await assertBusy(h, label: "incomingRinging")
        }
        // connecting
        do {
            let h = Harness()
            await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)
            await h.controller.accept()
            try await assertBusy(h, label: "connecting")
        }
        // active
        do {
            let h = Harness()
            await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)
            await h.controller.accept()
            h.session.onConnected?()
            try await assertBusy(h, label: "active")
        }
        // ended — PINNED-AS-IS, KNOWN BUG: a terminal state the UI has not
        // reset from still counts as busy and declines the new ring. WHEN THIS
        // BUG IS FIXED, THIS ARM FAILS ON PURPOSE — that is the pin doing its
        // job, not a regression. Do not restore the bug to make it green;
        // rewrite this arm to assert the fixed behavior.
        do {
            let h = Harness()
            await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)
            await h.controller.decline()
            try await assertBusy(h, label: "ended")
        }
    }

    private func assertBusy(_ h: Harness, label: String) async throws {
        let before = h.controller.state
        let sentBefore = h.sent.count
        let sessionsBefore = h.sessions.count
        let closesBefore = h.sessions.map(\.closeCalls)

        await h.controller.handleInbound(.request(callID: idY, sdp: "other-offer"), from: peerB)

        XCTAssertEqual(h.controller.state, before, "[\(label)] state must not change")
        XCTAssertEqual(h.sent.count, sentBefore + 1, "[\(label)] exactly one decline goes out")
        XCTAssertEqual(h.sent.last?.signal, .decline(callID: idY), "[\(label)]")
        XCTAssertEqual(h.sent.last?.peer, peerB, "[\(label)] declined to the NEW caller")
        XCTAssertEqual(h.sessions.count, sessionsBefore, "[\(label)] no new media session")
        XCTAssertEqual(h.sessions.map(\.closeCalls), closesBefore, "[\(label)] current media untouched")
    }

    // MARK: - Remote decline

    func testRemoteDeclineWhileOutgoingRingingEndsRemoteDeclined() async throws {
        let h = Harness()
        await h.controller.startCall(peerKey: peerA)
        let callID = try XCTUnwrap(h.controller.state.callID)

        await h.controller.handleInbound(.decline(callID: callID), from: peerA)

        XCTAssertEqual(h.controller.state, .ended(.remoteDeclined))
        XCTAssertEqual(h.session.closeCalls, 1)
        XCTAssertEqual(h.missedCalls, [], "a remote decline is not a missed call")
    }

    func testRemoteDeclineWhileIncomingRingingIsMissedCall() async {
        // Caller cancelled while our banner was up: reads as timedOut, and
        // fires the missed-call hook exactly once.
        let h = Harness()
        await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)

        await h.controller.handleInbound(.decline(callID: idX), from: peerA)

        XCTAssertEqual(h.controller.state, .ended(.timedOut))
        XCTAssertEqual(h.missedCalls, [peerA])
        XCTAssertEqual(h.sent.count, 0)
        XCTAssertEqual(h.sessions.count, 0)
    }

    // MARK: - Connect failure and hang-up

    func testAnswerStartThrowsEndsConnectFailed() async throws {
        let h = Harness()
        h.nextStart = .failure(FakeError.media)
        await h.controller.startCall(peerKey: peerA)
        let callID = try XCTUnwrap(h.controller.state.callID)

        await h.controller.handleInbound(.answer(callID: callID, sdp: "answer-sdp"), from: peerA)

        XCTAssertEqual(h.controller.state, .ended(.connectFailed))
        XCTAssertEqual(h.states.map(\.isConnecting), [false, true, false])
        XCTAssertEqual(h.session.closeCalls, 1)
    }

    func testMediaFailedWhileConnectingEndsConnectFailed() async {
        let h = Harness()
        await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)
        await h.controller.accept()

        h.session.onFailed?()

        XCTAssertEqual(h.controller.state, .ended(.connectFailed))
        XCTAssertEqual(h.session.closeCalls, 1)
        XCTAssertEqual(h.missedCalls, [])
    }

    func testMediaFailedWhileActiveEndsConnectFailed() async {
        // PINNED-AS-IS: a media failure after connect is reported with the
        // same reason as a never-connected call. Controller-only today: the
        // WebRTC wrapper fires onRemoteEnded (not onFailed) once connected,
        // so this arm is unreachable through WebRTCCallMedia. It may surface
        // once PTTLinkController drives the same seam differently. If the
        // reason is changed deliberately, this test fails on purpose.
        let h = Harness()
        await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)
        await h.controller.accept()
        h.session.onConnected?()

        h.session.onFailed?()

        XCTAssertEqual(h.controller.state, .ended(.connectFailed))
        XCTAssertEqual(h.session.closeCalls, 1)
    }

    func testRemoteEndedWhileActiveEndsHungUp() async {
        let h = Harness()
        await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)
        await h.controller.accept()
        h.session.onConnected?()

        h.session.onRemoteEnded?()

        XCTAssertEqual(h.controller.state, .ended(.hungUp))
        XCTAssertEqual(h.session.closeCalls, 1)
        XCTAssertEqual(h.sent.count, 1, "no wire signal post-connect")
    }

    func testRemoteEndedWhileConnectingIsIgnored() async {
        let h = Harness()
        await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)
        await h.controller.accept()

        h.session.onRemoteEnded?()

        XCTAssertEqual(h.controller.state, .connecting(callID: idX, peerKey: peerA))
        XCTAssertEqual(h.session.closeCalls, 0)
    }

    func testHangUpFromActiveAndConnecting() async {
        // active
        do {
            let h = Harness()
            await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)
            await h.controller.accept()
            h.session.onConnected?()
            h.controller.hangUp()
            XCTAssertEqual(h.controller.state, .ended(.hungUp))
            XCTAssertEqual(h.session.closeCalls, 1)
            XCTAssertEqual(h.sent.count, 1, "hang-up sends nothing: closing RTC is the signal")
        }
        // connecting
        do {
            let h = Harness()
            await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)
            await h.controller.accept()
            h.controller.hangUp()
            XCTAssertEqual(h.controller.state, .ended(.hungUp))
            XCTAssertEqual(h.session.closeCalls, 1)
        }
    }

    func testHangUpIsNoOpOutsideActiveAndConnecting() async {
        let h = Harness()
        h.controller.hangUp()                                   // idle
        XCTAssertEqual(h.controller.state, .idle)

        await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)
        h.controller.hangUp()                                   // incomingRinging
        XCTAssertEqual(h.controller.state,
                       .incomingRinging(callID: idX, peerKey: peerA, sdpOffer: "offer"))

        let h2 = Harness()
        await h2.controller.startCall(peerKey: peerA)
        let ringing = h2.controller.state
        h2.controller.hangUp()                                  // outgoingRinging
        XCTAssertEqual(h2.controller.state, ringing)
        XCTAssertEqual(h2.session.closeCalls, 0)
    }

    // MARK: - Stale / unknown-callID frames

    func testStaleAnswerFramesAreDropped() async throws {
        let h = Harness()
        await h.controller.startCall(peerKey: peerA)
        let callID = try XCTUnwrap(h.controller.state.callID)
        let ringing = h.controller.state

        // Wrong call id, right peer.
        await h.controller.handleInbound(.answer(callID: idY, sdp: "x"), from: peerA)
        XCTAssertEqual(h.controller.state, ringing)
        // Right call id, wrong peer.
        await h.controller.handleInbound(.answer(callID: callID, sdp: "x"), from: peerB)
        XCTAssertEqual(h.controller.state, ringing)

        XCTAssertEqual(h.session.startCalls, [], "no stale answer reaches media")
        XCTAssertEqual(h.sent.count, 1)
    }

    func testStaleDeclineFramesAreDropped() async throws {
        // outgoingRinging, wrong id
        do {
            let h = Harness()
            await h.controller.startCall(peerKey: peerA)
            let ringing = h.controller.state
            await h.controller.handleInbound(.decline(callID: idY), from: peerA)
            XCTAssertEqual(h.controller.state, ringing)
            XCTAssertEqual(h.session.closeCalls, 0)
        }
        // incomingRinging, wrong id
        do {
            let h = Harness()
            await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)
            await h.controller.handleInbound(.decline(callID: idY), from: peerA)
            XCTAssertEqual(h.controller.state,
                           .incomingRinging(callID: idX, peerKey: peerA, sdpOffer: "offer"))
            XCTAssertEqual(h.missedCalls, [])
        }
        // incomingRinging, right id, DIFFERENT peer — PINNED-AS-IS, KNOWN
        // INCONSISTENCY: the incoming-decline arm matches on call id only,
        // where every other inbound arm checks peer AND id. Not practically
        // exploitable (16 random bytes; impact is ending an already-ringing
        // call) but it is a security-bearing path. Tracked as its own handoff
        // item; deliberate fix later, not on this branch. When fixed, this
        // arm fails on purpose — rewrite it, do not restore the behavior.
        do {
            let h = Harness()
            await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)
            await h.controller.handleInbound(.decline(callID: idX), from: peerB)
            XCTAssertEqual(h.controller.state, .ended(.timedOut))
            XCTAssertEqual(h.missedCalls, [peerA], "hook reports the ORIGINAL caller")
        }
    }

    func testAnswerAndDeclineOutsideRingingAreDropped() async {
        // idle
        do {
            let h = Harness()
            await h.controller.handleInbound(.answer(callID: idX, sdp: "x"), from: peerA)
            await h.controller.handleInbound(.decline(callID: idX), from: peerA)
            XCTAssertEqual(h.controller.state, .idle)
            XCTAssertEqual(h.sent.count, 0)
            XCTAssertEqual(h.sessions.count, 0)
        }
        // active
        do {
            let h = Harness()
            await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)
            await h.controller.accept()
            h.session.onConnected?()
            await h.controller.handleInbound(.answer(callID: idX, sdp: "x"), from: peerA)
            await h.controller.handleInbound(.decline(callID: idX), from: peerA)
            XCTAssertEqual(h.controller.state, .active(callID: idX, peerKey: peerA))
            XCTAssertEqual(h.session.startCalls, [])
            XCTAssertEqual(h.session.closeCalls, 0)
        }
    }

    // MARK: - Stale media callbacks (a previous attempt's session)

    func testStaleSessionCallbacksAreIgnored() async throws {
        let h = Harness()

        // Attempt 1: ring, remote declines, UI resets.
        await h.controller.startCall(peerKey: peerA)
        let id1 = try XCTUnwrap(h.controller.state.callID)
        await h.controller.handleInbound(.decline(callID: id1), from: peerA)
        h.controller.reset()
        let old = h.sessions[0]

        // Attempt 2: ring, answered, connecting.
        await h.controller.startCall(peerKey: peerB)
        let id2 = try XCTUnwrap(h.controller.state.callID)
        await h.controller.handleInbound(.answer(callID: id2, sdp: "answer-sdp"), from: peerB)
        XCTAssertEqual(h.controller.state, .connecting(callID: id2, peerKey: peerB))

        // The OLD session's callbacks must not touch attempt 2.
        old.onConnected?()
        XCTAssertEqual(h.controller.state, .connecting(callID: id2, peerKey: peerB))
        old.onFailed?()
        XCTAssertEqual(h.controller.state, .connecting(callID: id2, peerKey: peerB))

        h.sessions[1].onConnected?()
        XCTAssertEqual(h.controller.state, .active(callID: id2, peerKey: peerB))
        old.onRemoteEnded?()
        XCTAssertEqual(h.controller.state, .active(callID: id2, peerKey: peerB))
        XCTAssertEqual(h.sessions[1].closeCalls, 0)
    }

    // MARK: - reset()

    func testResetOnlyLeavesEnded() async {
        let h = Harness()
        h.controller.reset()                                    // idle
        XCTAssertEqual(h.controller.state, .idle)
        XCTAssertEqual(h.states, [], "no-op reset does not notify")

        await h.controller.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)
        h.controller.reset()                                    // incomingRinging
        XCTAssertEqual(h.controller.state,
                       .incomingRinging(callID: idX, peerKey: peerA, sdpOffer: "offer"))

        await h.controller.decline()
        XCTAssertEqual(h.controller.state, .ended(.declined))
        h.controller.reset()                                    // ended
        XCTAssertEqual(h.controller.state, .idle)
        XCTAssertEqual(h.states.last, .idle)

        // Idle again: a new ring is accepted, not auto-declined.
        await h.controller.handleInbound(.request(callID: idY, sdp: "offer2"), from: peerB)
        XCTAssertEqual(h.controller.state,
                       .incomingRinging(callID: idY, peerKey: peerB, sdpOffer: "offer2"))
    }
}

// MARK: - Test doubles

private enum FakeError: Error { case media, send }

/// The `CallMediaSession` seam, scripted per call and recording every call.
@MainActor
private final class FakeMediaSession: CallMediaSession {
    var onConnected: (() -> Void)?
    var onFailed: (() -> Void)?
    var onRemoteEnded: (() -> Void)?

    var offerResult: Result<String, Error> = .success("offer-sdp")
    var answerResult: Result<String, Error> = .success("answer-sdp")
    var startResult: Result<Void, Error> = .success(())

    private(set) var makeOfferCalls = 0
    private(set) var makeAnswerCalls: [String] = []
    private(set) var startCalls: [String] = []
    private(set) var closeCalls = 0

    func makeOffer() async throws -> String {
        makeOfferCalls += 1
        return try offerResult.get()
    }

    func makeAnswer(remoteOffer: String) async throws -> String {
        makeAnswerCalls.append(remoteOffer)
        return try answerResult.get()
    }

    func start(remoteAnswer: String) async throws {
        startCalls.append(remoteAnswer)
        try startResult.get()
    }

    func close() { closeCalls += 1 }
}

/// One controller with both seams captured. Every `makeMediaSession` call
/// yields a fresh fake (recorded in `sessions`) so stale-session tests can
/// hold the previous attempt's handle.
@MainActor
private final class Harness {
    let controller: CallController
    private(set) var sessions: [FakeMediaSession] = []
    private(set) var sent: [(signal: CallSignal, peer: Data)] = []
    private(set) var states: [CallController.State] = []
    private(set) var missedCalls: [Data] = []

    /// Scripted results for the NEXT session created.
    var nextOffer: Result<String, Error> = .success("offer-sdp")
    var nextAnswer: Result<String, Error> = .success("answer-sdp")
    var nextStart: Result<Void, Error> = .success(())
    /// When set, every `sendSignal` throws this after recording the frame.
    var sendError: Error?

    /// The most recently created session.
    var session: FakeMediaSession { sessions[sessions.count - 1] }

    init() {
        var makeSession: (() -> CallMediaSession)!
        var send: ((CallSignal, Data) async throws -> Void)!
        controller = CallController(
            sendSignal: { signal, peer in try await send(signal, peer) },
            makeMediaSession: { makeSession() })
        makeSession = { [unowned self] in
            let s = FakeMediaSession()
            s.offerResult = self.nextOffer
            s.answerResult = self.nextAnswer
            s.startResult = self.nextStart
            self.sessions.append(s)
            return s
        }
        send = { [unowned self] signal, peer in
            self.sent.append((signal, peer))
            if let error = self.sendError { throw error }
        }
        controller.onStateChange = { [unowned self] in self.states.append($0) }
        controller.onMissedCall = { [unowned self] in self.missedCalls.append($0) }
    }
}

// MARK: - State conveniences

private extension CallController.State {
    var callID: Data? {
        switch self {
        case .outgoingRinging(let id, _), .connecting(let id, _), .active(let id, _):
            return id
        case .incomingRinging(let id, _, _):
            return id
        case .idle, .ended:
            return nil
        }
    }

    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }
}
