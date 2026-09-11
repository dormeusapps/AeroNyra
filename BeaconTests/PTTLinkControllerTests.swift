// PTTLinkControllerTests.swift
// Pins the live PTT-over-IP link state machine (`Core/Calls/PTTLinkController.swift`)
// AS DESIGNED, against a fake `PTTLinkMediaSession` and a captured send seam.
// Every media call and every send is written to ONE journal in order, so the
// load-bearing orderings are asserted literally:
//   • the track is muted AFTER the SDP is built and BEFORE it is sent;
//   • on connect: mute, then loudspeaker;
//   • `state` enters .opening BEFORE the offer/answer is built.
//
// DELIBERATE DESIGN CHOICES pinned here (do not "fix" to match CallController):
//   • `.closed` is treated like `.idle` for inbound requests and `open(to:)`
//     (CallController's `.ended` auto-decline is a known bug, pinned as-is there).
//   • glare resolves by the LOWER link id, both directions.
//   • the timeout is injected (50 ms here) and lands in a VISIBLE reason:
//     `.unreachable` before an answer, `.connectFailed` after.
//   • call-kind frames (`.request`) and unknown ids are dropped with NO reply.
//
// The responder's mic hardware goes live at `makeAnswer` (inside
// WebRTCCallMedia, not here); the `role` in the state is what step 5's banner
// hooks. Pinned: the role is `.responder` from the first state change.
//

import XCTest
@testable import Beacon

@MainActor
final class PTTLinkControllerTests: XCTestCase {

    private let peerA = Data(repeating: 0xA1, count: 32)
    private let peerB = Data(repeating: 0xB2, count: 32)
    private let idLow = Data(repeating: 0x00, count: 16)    // precedes any random id
    private let idHigh = Data(repeating: 0xFF, count: 16)   // follows any random id
    private let idX = Data(repeating: 0x33, count: 16)

    private let fast: Duration = .milliseconds(50)
    private func waitPastTimeout() async {
        try? await Task.sleep(for: .milliseconds(400))
    }

    // MARK: - Initiator

    func testInitiatorHappyPath() async throws {
        let h = Harness()

        await h.controller.open(to: peerA)

        let linkID = try XCTUnwrap(h.controller.state.linkID)
        XCTAssertEqual(linkID.count, 16)
        XCTAssertEqual(h.controller.state,
                       .opening(linkID: linkID, peerKey: peerA, role: .initiator, phase: .awaitingAnswer))
        XCTAssertEqual(h.sessions.count, 1)
        XCTAssertEqual(h.sent.count, 1)
        XCTAssertEqual(h.sent[0].signal, .pttRequest(callID: linkID, sdp: "offer-sdp"))
        XCTAssertEqual(h.sent[0].peer, peerA)
        // state → offer → mute → send, in that order.
        XCTAssertEqual(h.journal, ["state:opening", "offer", "mute:true", "send:pttRequest"])

        await h.controller.handleInbound(.answer(callID: linkID, sdp: "answer-sdp"), from: peerA)
        XCTAssertEqual(h.controller.state,
                       .opening(linkID: linkID, peerKey: peerA, role: .initiator, phase: .connecting))
        XCTAssertEqual(h.session.startCalls, ["answer-sdp"])

        h.session.onConnected?()
        XCTAssertEqual(h.controller.state, .open(linkID: linkID, peerKey: peerA, role: .initiator))
        XCTAssertTrue(h.controller.isOpen)
        XCTAssertEqual(Array(h.journal.suffix(3)), ["start", "mute:true", "speaker:true"])
        XCTAssertFalse(h.controller.isTransmitting)

        // The timer was cancelled on connect.
        await waitPastTimeout()
        XCTAssertTrue(h.controller.isOpen)
        XCTAssertEqual(h.session.closeCalls, 0)
    }

    func testOpenIsNoOpWhileOpeningOrOpen() async throws {
        let h = Harness()
        await h.controller.open(to: peerA)
        let first = h.controller.state
        await h.controller.open(to: peerB)
        XCTAssertEqual(h.controller.state, first)
        XCTAssertEqual(h.sessions.count, 1)
        XCTAssertEqual(h.sent.count, 1)

        let linkID = try XCTUnwrap(first.linkID)
        await h.controller.handleInbound(.answer(callID: linkID, sdp: "a"), from: peerA)
        h.session.onConnected?()
        await h.controller.open(to: peerB)
        XCTAssertEqual(h.controller.state, .open(linkID: linkID, peerKey: peerA, role: .initiator))
        XCTAssertEqual(h.sessions.count, 1)
    }

    func testOpenFromClosedIsAllowed() async {
        let h = Harness()
        h.nextOffer = .failure(FakeError.media)
        await h.controller.open(to: peerA)
        XCTAssertEqual(h.controller.state, .closed(.failed))

        h.nextOffer = .success("offer-sdp")
        await h.controller.open(to: peerA)
        guard case .opening(_, peerA, .initiator, .awaitingAnswer) = h.controller.state else {
            return XCTFail("expected a fresh opening, got \(h.controller.state)")
        }
        XCTAssertEqual(h.sessions.count, 2)
    }

    func testOfferThrowsClosesFailedWithNoSend() async {
        let h = Harness()
        h.nextOffer = .failure(FakeError.media)
        await h.controller.open(to: peerA)
        XCTAssertEqual(h.controller.state, .closed(.failed))
        XCTAssertEqual(h.sent.count, 0)
        XCTAssertEqual(h.session.closeCalls, 1)
        XCTAssertTrue(CloseReasonCheck.visible(.failed))
    }

    func testRequestSendThrowsClosesFailedAfterOpening() async {
        let h = Harness()
        h.sendError = FakeError.send
        await h.controller.open(to: peerA)
        XCTAssertEqual(h.controller.state, .closed(.failed))
        XCTAssertEqual(h.states.count, 2)
        guard case .opening = h.states[0] else { return XCTFail("expected opening first") }
        XCTAssertEqual(h.session.closeCalls, 1)
    }

    func testAnswerStartThrowsClosesConnectFailed() async throws {
        let h = Harness()
        h.nextStart = .failure(FakeError.media)
        await h.controller.open(to: peerA)
        let linkID = try XCTUnwrap(h.controller.state.linkID)
        await h.controller.handleInbound(.answer(callID: linkID, sdp: "a"), from: peerA)
        XCTAssertEqual(h.controller.state, .closed(.connectFailed))
        XCTAssertEqual(h.session.closeCalls, 1)
    }

    func testRemoteDeclineWhileAwaitingAnswerClosesRemoteDeclined() async throws {
        let h = Harness()
        await h.controller.open(to: peerA)
        let linkID = try XCTUnwrap(h.controller.state.linkID)
        await h.controller.handleInbound(.decline(callID: linkID), from: peerA)
        XCTAssertEqual(h.controller.state, .closed(.remoteDeclined))
        XCTAssertEqual(h.session.closeCalls, 1)
        // Late timer must not re-close.
        await waitPastTimeout()
        XCTAssertEqual(h.controller.state, .closed(.remoteDeclined))
    }

    /// RE-PINNED 2026-09-11 (close signal, scoping doc 11.13): a decline for
    /// our current id from its peer while connecting is the peer CLOSING —
    /// it used to be dropped. Full pins in PTTLinkCloseSignalTests.
    func testRemoteDeclineWhileConnectingEndsAsRemoteEnded() async throws {
        let h = Harness()
        await h.controller.open(to: peerA)
        let linkID = try XCTUnwrap(h.controller.state.linkID)
        await h.controller.handleInbound(.answer(callID: linkID, sdp: "a"), from: peerA)
        await h.controller.handleInbound(.decline(callID: linkID), from: peerA)
        XCTAssertEqual(h.controller.state, .closed(.remoteEnded))
    }

    // MARK: - Timeout (injected duration, visible terminal state)

    func testTimeoutWithoutAnswerIsUnreachable() async {
        // The default experience against every pre-kind-14 build: no reply ever.
        let h = Harness(openTimeout: fast)
        await h.controller.open(to: peerA)
        await waitPastTimeout()
        XCTAssertEqual(h.controller.state, .closed(.unreachable))
        XCTAssertEqual(h.session.closeCalls, 1)
        XCTAssertTrue(CloseReasonCheck.visible(.unreachable), "must render, never a quiet spinner")
    }

    func testTimeoutAfterAnswerIsConnectFailed() async throws {
        let h = Harness(openTimeout: fast)
        await h.controller.open(to: peerA)
        let linkID = try XCTUnwrap(h.controller.state.linkID)
        await h.controller.handleInbound(.answer(callID: linkID, sdp: "a"), from: peerA)
        await waitPastTimeout()
        XCTAssertEqual(h.controller.state, .closed(.connectFailed))
        XCTAssertEqual(h.session.closeCalls, 1)
    }

    func testResponderTimeoutIsConnectFailed() async {
        let h = Harness(openTimeout: fast)
        await h.controller.handleInbound(.pttRequest(callID: idX, sdp: "their-offer"), from: peerA)
        guard case .opening(idX, peerA, .responder, .connecting) = h.controller.state else {
            return XCTFail("expected responder connecting, got \(h.controller.state)")
        }
        await waitPastTimeout()
        XCTAssertEqual(h.controller.state, .closed(.connectFailed))
    }

    func testDefaultTimeoutIsTwentySeconds() {
        XCTAssertEqual(PTTLinkController.defaultOpenTimeout, .seconds(20))
    }

    // MARK: - Responder (auto-answer)

    func testResponderHappyPath() async {
        let h = Harness()

        await h.controller.handleInbound(.pttRequest(callID: idX, sdp: "their-offer"), from: peerA)

        XCTAssertEqual(h.controller.state,
                       .opening(linkID: idX, peerKey: peerA, role: .responder, phase: .connecting))
        XCTAssertEqual(h.sessions.count, 1)
        XCTAssertEqual(h.session.makeAnswerCalls, ["their-offer"])
        XCTAssertEqual(h.sent.count, 1)
        XCTAssertEqual(h.sent[0].signal, .answer(callID: idX, sdp: "answer-sdp"))
        XCTAssertEqual(h.sent[0].peer, peerA)
        // The role is .responder from the FIRST state change — step 5's hook
        // for the mic-live banner (hardware is live from makeAnswer).
        XCTAssertEqual(h.journal, ["state:opening", "answer", "mute:true", "send:answer"])
        if case .opening(_, _, let role, _) = h.states[0] {
            XCTAssertEqual(role, .responder)
        } else { XCTFail("first state should be opening") }

        h.session.onConnected?()
        XCTAssertEqual(h.controller.state, .open(linkID: idX, peerKey: peerA, role: .responder))
        XCTAssertEqual(Array(h.journal.suffix(2)), ["mute:true", "speaker:true"])
    }

    func testAutoAnswerPolicyFalseDeclines() async {
        let h = Harness(autoAnswerPolicy: { false })
        await h.controller.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerA)
        XCTAssertEqual(h.controller.state, .idle)
        XCTAssertEqual(h.sessions.count, 0)
        XCTAssertEqual(h.sent.count, 1)
        XCTAssertEqual(h.sent[0].signal, .decline(callID: idX))
        XCTAssertEqual(h.sent[0].peer, peerA)
    }

    func testResponderMakeAnswerThrowsClosesFailed() async {
        let h = Harness()
        h.nextAnswer = .failure(FakeError.media)
        await h.controller.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerA)
        XCTAssertEqual(h.controller.state, .closed(.failed))
        XCTAssertEqual(h.sent.count, 0)
        XCTAssertEqual(h.session.closeCalls, 1)
    }

    func testResponderAnswerSendThrowsClosesFailed() async {
        let h = Harness()
        h.sendError = FakeError.send
        await h.controller.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerA)
        XCTAssertEqual(h.controller.state, .closed(.failed))
        XCTAssertEqual(h.session.closeCalls, 1)
    }

    func testInboundRequestWhileClosedIsAutoAnswered() async {
        // DELIBERATE divergence from CallController's ended-state auto-decline.
        let h = Harness()
        h.nextOffer = .failure(FakeError.media)
        await h.controller.open(to: peerA)
        XCTAssertEqual(h.controller.state, .closed(.failed))

        await h.controller.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerB)

        XCTAssertEqual(h.controller.state,
                       .opening(linkID: idX, peerKey: peerB, role: .responder, phase: .connecting))
        XCTAssertEqual(h.sent.last?.signal, .answer(callID: idX, sdp: "answer-sdp"))
    }

    // MARK: - Busy rule

    func testBusyRuleDeclinesNewRequestWhileOpeningAndOpen() async throws {
        // opening (awaiting), different peer
        do {
            let h = Harness()
            await h.controller.open(to: peerA)
            let before = h.controller.state
            await h.controller.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerB)
            XCTAssertEqual(h.controller.state, before)
            XCTAssertEqual(h.sent.last?.signal, .decline(callID: idX))
            XCTAssertEqual(h.sent.last?.peer, peerB)
            XCTAssertEqual(h.sessions.count, 1)
            XCTAssertEqual(h.session.closeCalls, 0)
        }
        // opening (connecting, initiator), same peer — glare is over, this is busy
        do {
            let h = Harness()
            await h.controller.open(to: peerA)
            let linkID = try XCTUnwrap(h.controller.state.linkID)
            await h.controller.handleInbound(.answer(callID: linkID, sdp: "a"), from: peerA)
            let before = h.controller.state
            await h.controller.handleInbound(.pttRequest(callID: idLow, sdp: "o"), from: peerA)
            XCTAssertEqual(h.controller.state, before)
            XCTAssertEqual(h.sent.last?.signal, .decline(callID: idLow))
        }
        // opening (responder)
        do {
            let h = Harness()
            await h.controller.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerA)
            let before = h.controller.state
            await h.controller.handleInbound(.pttRequest(callID: idLow, sdp: "o2"), from: peerB)
            XCTAssertEqual(h.controller.state, before)
            XCTAssertEqual(h.sent.last?.signal, .decline(callID: idLow))
            XCTAssertEqual(h.sessions.count, 1)
        }
        // open
        do {
            let h = Harness()
            await h.controller.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerA)
            h.session.onConnected?()
            XCTAssertTrue(h.controller.isOpen)
            await h.controller.handleInbound(.pttRequest(callID: idLow, sdp: "o2"), from: peerB)
            XCTAssertTrue(h.controller.isOpen)
            XCTAssertEqual(h.sent.last?.signal, .decline(callID: idLow))
            XCTAssertEqual(h.session.closeCalls, 0)
        }
    }

    // MARK: - Glare (both opened at once; lower link id wins)

    func testGlareTheyWinWeAbandonOursAndAnswerTheirs() async throws {
        let h = Harness()
        await h.controller.open(to: peerA)
        let ourID = try XCTUnwrap(h.controller.state.linkID)
        XCTAssertTrue(idLow.lexicographicallyPrecedes(ourID))

        await h.controller.handleInbound(.pttRequest(callID: idLow, sdp: "their-offer"), from: peerA)

        // Ours torn down silently, theirs answered.
        XCTAssertEqual(h.sessions.count, 2)
        XCTAssertEqual(h.sessions[0].closeCalls, 1)
        XCTAssertEqual(h.sessions[1].makeAnswerCalls, ["their-offer"])
        XCTAssertEqual(h.controller.state,
                       .opening(linkID: idLow, peerKey: peerA, role: .responder, phase: .connecting))
        XCTAssertEqual(h.sent.map(\.signal), [
            .pttRequest(callID: ourID, sdp: "offer-sdp"),
            .answer(callID: idLow, sdp: "answer-sdp"),
        ], "no decline is sent for the abandoned attempt")

        // Their decline of our abandoned request arrives stale: dropped.
        await h.controller.handleInbound(.decline(callID: ourID), from: peerA)
        XCTAssertEqual(h.controller.state,
                       .opening(linkID: idLow, peerKey: peerA, role: .responder, phase: .connecting))
        // The old session's callbacks are dead.
        h.sessions[0].onConnected?()
        XCTAssertEqual(h.controller.state,
                       .opening(linkID: idLow, peerKey: peerA, role: .responder, phase: .connecting))

        h.sessions[1].onConnected?()
        XCTAssertEqual(h.controller.state, .open(linkID: idLow, peerKey: peerA, role: .responder))
    }

    func testGlareWeWinDeclineTheirsAndKeepOurs() async throws {
        let h = Harness()
        await h.controller.open(to: peerA)
        let ourID = try XCTUnwrap(h.controller.state.linkID)
        XCTAssertTrue(ourID.lexicographicallyPrecedes(idHigh))
        let before = h.controller.state

        await h.controller.handleInbound(.pttRequest(callID: idHigh, sdp: "their-offer"), from: peerA)

        XCTAssertEqual(h.controller.state, before)
        XCTAssertEqual(h.sessions.count, 1)
        XCTAssertEqual(h.session.closeCalls, 0)
        XCTAssertEqual(h.sent.last?.signal, .decline(callID: idHigh))
        XCTAssertEqual(h.sent.last?.peer, peerA)

        // They abandon theirs and answer ours.
        await h.controller.handleInbound(.answer(callID: ourID, sdp: "a"), from: peerA)
        h.session.onConnected?()
        XCTAssertEqual(h.controller.state, .open(linkID: ourID, peerKey: peerA, role: .initiator))
    }

    // MARK: - Media callbacks

    func testMediaFailedWhileOpeningIsConnectFailed() async {
        let h = Harness()
        await h.controller.open(to: peerA)
        h.session.onFailed?()
        XCTAssertEqual(h.controller.state, .closed(.connectFailed))
        XCTAssertEqual(h.session.closeCalls, 1)
    }

    func testMediaFailedWhileOpenIsRemoteEnded() async {
        let h = Harness()
        await h.controller.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerA)
        h.session.onConnected?()
        h.session.onFailed?()
        XCTAssertEqual(h.controller.state, .closed(.remoteEnded))
        XCTAssertEqual(h.session.closeCalls, 1)
    }

    func testRemoteEndedWhileOpenClosesAndWhileOpeningIsIgnored() async {
        let h = Harness()
        await h.controller.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerA)
        h.session.onRemoteEnded?()                              // opening: ignored
        XCTAssertEqual(h.controller.state,
                       .opening(linkID: idX, peerKey: peerA, role: .responder, phase: .connecting))
        h.session.onConnected?()
        h.session.onRemoteEnded?()                              // open: closed
        XCTAssertEqual(h.controller.state, .closed(.remoteEnded))
        XCTAssertEqual(h.session.closeCalls, 1)
    }

    func testDuplicateConnectedIsIgnored() async {
        let h = Harness()
        await h.controller.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerA)
        h.session.onConnected?()
        let journalCount = h.journal.count
        h.session.onConnected?()
        XCTAssertEqual(h.controller.state, .open(linkID: idX, peerKey: peerA, role: .responder))
        XCTAssertEqual(h.journal.count, journalCount, "no second mute/speaker pass")
    }

    func testSupersededSessionCallbacksAreIgnored() async throws {
        let h = Harness()
        await h.controller.open(to: peerA)
        let id1 = try XCTUnwrap(h.controller.state.linkID)
        await h.controller.handleInbound(.decline(callID: id1), from: peerA)
        h.controller.reset()
        let old = h.sessions[0]

        await h.controller.open(to: peerB)
        let id2 = try XCTUnwrap(h.controller.state.linkID)
        old.onConnected?()
        old.onFailed?()
        old.onRemoteEnded?()
        XCTAssertEqual(h.controller.state,
                       .opening(linkID: id2, peerKey: peerB, role: .initiator, phase: .awaitingAnswer))
        XCTAssertEqual(h.sessions[1].closeCalls, 0)
    }

    // MARK: - Frames that are not ours (fan-out safety)

    func testCallFramesAndUnknownIdsAreDroppedWithNoReply() async throws {
        // idle: a call ring, an answer, a decline — none are ours.
        do {
            let h = Harness()
            await h.controller.handleInbound(.request(callID: idX, sdp: "ring"), from: peerA)
            await h.controller.handleInbound(.answer(callID: idX, sdp: "a"), from: peerA)
            await h.controller.handleInbound(.decline(callID: idX), from: peerA)
            XCTAssertEqual(h.controller.state, .idle)
            XCTAssertEqual(h.sent.count, 0, "a call ring must never be declined by the link")
            XCTAssertEqual(h.sessions.count, 0)
        }
        // awaiting answer: wrong id, wrong peer, a call ring.
        do {
            let h = Harness()
            await h.controller.open(to: peerA)
            let linkID = try XCTUnwrap(h.controller.state.linkID)
            let before = h.controller.state
            await h.controller.handleInbound(.answer(callID: idX, sdp: "a"), from: peerA)
            await h.controller.handleInbound(.answer(callID: linkID, sdp: "a"), from: peerB)
            await h.controller.handleInbound(.decline(callID: idX), from: peerA)
            await h.controller.handleInbound(.decline(callID: linkID), from: peerB)
            await h.controller.handleInbound(.request(callID: idX, sdp: "ring"), from: peerA)
            XCTAssertEqual(h.controller.state, before)
            XCTAssertEqual(h.session.startCalls, [])
            XCTAssertEqual(h.sent.count, 1)
        }
        // open: an answer is meaningless; a decline for our id from the WRONG
        // peer is dropped; a decline for our id from ITS peer is the close
        // signal (re-pinned 2026-09-11, 11.13) and ends the link.
        do {
            let h = Harness()
            await h.controller.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerA)
            h.session.onConnected?()
            await h.controller.handleInbound(.answer(callID: idX, sdp: "a"), from: peerA)
            await h.controller.handleInbound(.decline(callID: idX), from: peerB)
            XCTAssertTrue(h.controller.isOpen)
            XCTAssertEqual(h.session.closeCalls, 0)
            await h.controller.handleInbound(.decline(callID: idX), from: peerA)
            XCTAssertEqual(h.controller.state, .closed(.remoteEnded))
            XCTAssertEqual(h.session.closeCalls, 1)
        }
    }

    // MARK: - Press / release

    func testPressAndReleaseGateTheMicOnlyWhileOpen() async {
        let h = Harness()
        // Not open: no-op, returns false.
        XCTAssertFalse(h.controller.pressBegan())
        XCTAssertFalse(h.controller.isTransmitting)
        await h.controller.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerA)
        XCTAssertFalse(h.controller.pressBegan(), "opening is not open")
        XCTAssertEqual(h.journal.filter { $0 == "mute:false" }.count, 0)

        h.session.onConnected?()
        var transmits: [Bool] = []
        h.controller.onTransmitChange = { transmits.append($0) }

        XCTAssertTrue(h.controller.pressBegan())
        XCTAssertTrue(h.controller.isTransmitting)
        XCTAssertEqual(h.journal.last, "mute:false")
        XCTAssertTrue(h.controller.pressEnded())
        XCTAssertFalse(h.controller.isTransmitting)
        XCTAssertEqual(h.journal.last, "mute:true")
        XCTAssertEqual(transmits, [true, false])
    }

    func testCloseWhilePressedForcesTransmittingFalse() async {
        let h = Harness()
        await h.controller.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerA)
        h.session.onConnected?()
        h.controller.pressBegan()
        XCTAssertTrue(h.controller.isTransmitting)

        h.controller.close()

        XCTAssertFalse(h.controller.isTransmitting)
        XCTAssertEqual(h.controller.state, .closed(.localClosed))
        XCTAssertFalse(h.controller.pressEnded(), "nothing to release once closed")
    }

    // MARK: - close / preempt / reset

    func testCloseFromEveryState() async throws {
        // idle: no-op
        do {
            let h = Harness()
            h.controller.close()
            XCTAssertEqual(h.controller.state, .idle)
            XCTAssertEqual(h.states, [])
        }
        // opening (awaiting)
        do {
            let h = Harness()
            await h.controller.open(to: peerA)
            h.controller.close()
            XCTAssertEqual(h.controller.state, .closed(.localClosed))
            XCTAssertEqual(h.session.closeCalls, 1)
            XCTAssertEqual(h.sent.count, 1, "no decline/cancel is sent on the wire")
            await waitPastTimeout()
            XCTAssertEqual(h.controller.state, .closed(.localClosed), "timer cancelled")
        }
        // opening (responder, connecting)
        do {
            let h = Harness()
            await h.controller.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerA)
            h.controller.close(reason: .interrupted)
            XCTAssertEqual(h.controller.state, .closed(.interrupted))
            XCTAssertEqual(h.session.closeCalls, 1)
        }
        // open
        do {
            let h = Harness()
            await h.controller.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerA)
            h.session.onConnected?()
            h.controller.close()
            XCTAssertEqual(h.controller.state, .closed(.localClosed))
            XCTAssertEqual(h.session.closeCalls, 1)
        }
        // closed: no-op, reason unchanged
        do {
            let h = Harness()
            await h.controller.open(to: peerA)
            let linkID = try XCTUnwrap(h.controller.state.linkID)
            await h.controller.handleInbound(.decline(callID: linkID), from: peerA)
            h.controller.close(reason: .interrupted)
            XCTAssertEqual(h.controller.state, .closed(.remoteDeclined))
            XCTAssertEqual(h.session.closeCalls, 1)
        }
    }

    func testPreemptIsCloseWithPreemptedReason() async {
        let h = Harness()
        await h.controller.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerA)
        h.session.onConnected?()
        h.controller.preempt()
        XCTAssertEqual(h.controller.state, .closed(.preempted))
        XCTAssertEqual(h.session.closeCalls, 1)
        XCTAssertFalse(CloseReasonCheck.visible(.preempted))
    }

    func testResetOnlyLeavesClosed() async {
        let h = Harness()
        h.controller.reset()
        XCTAssertEqual(h.controller.state, .idle)
        XCTAssertEqual(h.states, [])

        await h.controller.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerA)
        h.controller.reset()
        XCTAssertEqual(h.controller.state,
                       .opening(linkID: idX, peerKey: peerA, role: .responder, phase: .connecting))

        h.controller.close()
        h.controller.reset()
        XCTAssertEqual(h.controller.state, .idle)
        XCTAssertEqual(h.states.last, .idle)
    }

    // MARK: - Close reason visibility

    func testCloseReasonVisibility() {
        XCTAssertTrue(CloseReasonCheck.visible(.unreachable))
        XCTAssertTrue(CloseReasonCheck.visible(.remoteDeclined))
        XCTAssertTrue(CloseReasonCheck.visible(.connectFailed))
        XCTAssertTrue(CloseReasonCheck.visible(.remoteEnded))
        XCTAssertTrue(CloseReasonCheck.visible(.failed))
        XCTAssertTrue(CloseReasonCheck.visible(.interrupted))
        XCTAssertFalse(CloseReasonCheck.visible(.localClosed))
        XCTAssertFalse(CloseReasonCheck.visible(.preempted))
    }
}

// MARK: - Test doubles

private enum FakeError: Error { case media, send }

private enum CloseReasonCheck {
    static func visible(_ r: PTTLinkController.CloseReason) -> Bool { r.isUserVisible }
}

/// Ordered record of every media call and every send, shared by the fake
/// session and the harness so cross-object orderings are literal.
private final class Journal {
    var entries: [String] = []
}

@MainActor
private final class FakeLinkMedia: PTTLinkMediaSession {
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
    private(set) var micMuted: Bool?
    private(set) var speaker: Bool?

    private let journal: Journal
    init(journal: Journal) { self.journal = journal }

    func makeOffer() async throws -> String {
        makeOfferCalls += 1
        journal.entries.append("offer")
        return try offerResult.get()
    }
    func makeAnswer(remoteOffer: String) async throws -> String {
        makeAnswerCalls.append(remoteOffer)
        journal.entries.append("answer")
        return try answerResult.get()
    }
    func start(remoteAnswer: String) async throws {
        startCalls.append(remoteAnswer)
        journal.entries.append("start")
        try startResult.get()
    }
    func close() {
        closeCalls += 1
        journal.entries.append("close")
    }
    func setMicMuted(_ muted: Bool) {
        micMuted = muted
        journal.entries.append("mute:\(muted)")
    }
    func setSpeakerEnabled(_ enabled: Bool) {
        speaker = enabled
        journal.entries.append("speaker:\(enabled)")
    }
}

@MainActor
private final class Harness {
    let controller: PTTLinkController
    private let journalBox = Journal()
    private(set) var sessions: [FakeLinkMedia] = []
    private(set) var sent: [(signal: CallSignal, peer: Data)] = []
    private(set) var states: [PTTLinkController.State] = []

    var nextOffer: Result<String, Error> = .success("offer-sdp")
    var nextAnswer: Result<String, Error> = .success("answer-sdp")
    var nextStart: Result<Void, Error> = .success(())
    var sendError: Error?

    var journal: [String] { journalBox.entries }
    var session: FakeLinkMedia { sessions[sessions.count - 1] }

    init(openTimeout: Duration = PTTLinkController.defaultOpenTimeout,
         autoAnswerPolicy: @escaping () -> Bool = { true }) {
        var send: ((CallSignal, Data) async throws -> Void)!
        var make: (() -> PTTLinkMediaSession)!
        controller = PTTLinkController(
            sendSignal: { signal, peer in try await send(signal, peer) },
            makeMediaSession: { make() },
            openTimeout: openTimeout,
            autoAnswerPolicy: autoAnswerPolicy)
        make = { [unowned self] in
            let s = FakeLinkMedia(journal: self.journalBox)
            s.offerResult = self.nextOffer
            s.answerResult = self.nextAnswer
            s.startResult = self.nextStart
            self.sessions.append(s)
            return s
        }
        // weak, not unowned: the close signal (11.13) is a fire-and-forget
        // Task that can run after a test's harness is gone.
        send = { [weak self] signal, peer in
            guard let self else { return }
            self.sent.append((signal, peer))
            self.journalBox.entries.append("send:\(Self.name(of: signal))")
            if let error = self.sendError { throw error }
        }
        controller.onStateChange = { [unowned self] state in
            self.states.append(state)
            switch state {
            case .opening: self.journalBox.entries.append("state:opening")
            default: break
            }
        }
    }

    private static func name(of signal: CallSignal) -> String {
        switch signal {
        case .request: return "request"
        case .answer: return "answer"
        case .decline: return "decline"
        case .pttRequest: return "pttRequest"
        }
    }
}
