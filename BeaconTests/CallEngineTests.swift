// CallEngineTests.swift
// Pins the live PTT-over-IP PRE-EMPTION seam in `CallEngine` (step 4) — the
// load-bearing guarantee that a call's media session is never created while
// a walkie link's media session is alive (the WebRTC audio device module is
// process-global; two live sessions silently kill each other's audio).
//
// Pinned through the REAL CallController with a fake media session injected
// through CallEngine's test seam:
//   • ORDER: `preemptLink` fires BEFORE call media is created — for voice,
//     video, and accept — because it sits at the top of the media factory
//     (the only place call media is born), not at the call sites.
//   • IN-FLIGHT WINDOW: while `makeOffer` is suspended (ICE gathering, up to
//     5 s in the app), `state` still reads `.idle` but `isCallInProgress`
//     reads TRUE. That flag is what stops a `.pttRequest` in the window from
//     auto-answering into a second media session.
//   • RING RULE: a `.request` while idle pre-empts; a `.request` while busy
//     does not (CallController would auto-decline it); `.pttRequest` never.
//   • `isCallInProgress` truth table across every state; nil hook is a no-op.
//

import XCTest
@testable import Beacon

@MainActor
final class CallEngineTests: XCTestCase {

    private let peerA = Data(repeating: 0xA1, count: 32)
    private let idX = Data(repeating: 0x11, count: 16)
    private let idY = Data(repeating: 0x22, count: 16)

    // MARK: - Order: pre-empt, then media

    func testStartVoiceCallPreemptsBeforeMediaIsCreated() async {
        let h = Harness()
        await h.engine.startVoiceCall(peerKey: peerA)
        XCTAssertEqual(h.journal, ["preempt", "media(camera:false)"])
        guard case .outgoingRinging = h.engine.state else {
            return XCTFail("expected outgoingRinging, got \(h.engine.state)")
        }
        XCTAssertTrue(h.engine.isCallInProgress)
    }

    func testStartVideoCallPreemptsBeforeMediaIsCreated() async {
        let h = Harness()
        await h.engine.startVideoCall(peerKey: peerA)
        XCTAssertEqual(h.journal, ["preempt", "media(camera:true)"])
    }

    func testAcceptPreemptsBeforeMediaIsCreated() async {
        let h = Harness()
        await h.engine.handleInbound(.request(callID: idX, sdp: "offer"), from: peerA)
        XCTAssertEqual(h.journal, ["preempt"], "the ring itself pre-empts (idle)")
        XCTAssertEqual(h.engine.state, .incomingRinging(callID: idX, peerKey: peerA, sdpOffer: "offer"))

        await h.engine.accept(withCamera: true)
        XCTAssertEqual(h.journal, ["preempt", "preempt", "media(camera:true)"])
        XCTAssertEqual(h.engine.state, .connecting(callID: idX, peerKey: peerA))
    }

    func testNilHookIsNoOp() async {
        let h = Harness(installHook: false)
        await h.engine.startVoiceCall(peerKey: peerA)
        XCTAssertEqual(h.journal, ["media(camera:false)"])
        await h.engine.handleInbound(.request(callID: idX, sdp: "o"), from: peerA)   // busy: declined
        XCTAssertEqual(h.journal, ["media(camera:false)"])
    }

    // MARK: - The in-flight window

    func testInFlightWindowReadsBusyWhileStateIsStillIdle() async {
        let h = Harness(gateOffer: true)

        let call = Task { await h.engine.startVoiceCall(peerKey: peerA) }
        await h.waitUntil("offer entered") { h.media?.offerEntered == true }

        // Media exists, state has NOT moved: this is the window.
        XCTAssertEqual(h.engine.state, .idle)
        XCTAssertEqual(h.journal, ["preempt", "media(camera:false)"])
        XCTAssertTrue(h.engine.isCallInProgress, "the window must read busy")

        h.media?.releaseOffer()
        await call.value
        guard case .outgoingRinging = h.engine.state else {
            return XCTFail("expected outgoingRinging, got \(h.engine.state)")
        }
        XCTAssertTrue(h.engine.isCallInProgress)
    }

    func testInFlightFlagClearsWhenOfferFails() async {
        let h = Harness()
        h.offerFails = true
        await h.engine.startVoiceCall(peerKey: peerA)
        XCTAssertEqual(h.engine.state, .ended(.failed))
        XCTAssertFalse(h.engine.isCallInProgress)
        h.engine.reset()
        XCTAssertEqual(h.engine.state, .idle)
        XCTAssertFalse(h.engine.isCallInProgress, "idle after reset is free")
    }

    // MARK: - isCallInProgress truth table

    func testIsCallInProgressAcrossStates() async {
        let h = Harness()
        XCTAssertFalse(h.engine.isCallInProgress)                       // idle

        await h.engine.handleInbound(.request(callID: idX, sdp: "o"), from: peerA)
        XCTAssertTrue(h.engine.isCallInProgress)                        // incomingRinging

        await h.engine.accept(withCamera: false)
        XCTAssertTrue(h.engine.isCallInProgress)                        // connecting

        h.media?.onConnected?()
        XCTAssertEqual(h.engine.state, .active(callID: idX, peerKey: peerA))
        XCTAssertTrue(h.engine.isCallInProgress)                        // active

        h.engine.hangUp()
        XCTAssertEqual(h.engine.state, .ended(.hungUp))
        XCTAssertFalse(h.engine.isCallInProgress)                       // ended: media torn down

        h.engine.reset()
        XCTAssertFalse(h.engine.isCallInProgress)                       // idle again

        await h.engine.startVoiceCall(peerKey: peerA)
        XCTAssertTrue(h.engine.isCallInProgress)                        // outgoingRinging
    }

    // MARK: - Ring rule

    func testInboundRequestWhileIdlePreempts() async {
        let h = Harness()
        await h.engine.handleInbound(.request(callID: idX, sdp: "o"), from: peerA)
        XCTAssertEqual(h.journal, ["preempt"])
        XCTAssertEqual(h.sent.count, 0, "a ring while idle sends nothing")
    }

    func testInboundRequestWhileBusyDoesNotPreempt() async {
        let h = Harness()
        await h.engine.handleInbound(.request(callID: idX, sdp: "o"), from: peerA)
        let before = h.journal
        await h.engine.handleInbound(.request(callID: idY, sdp: "o2"), from: peerA)
        XCTAssertEqual(h.journal, before, "a ring CallController auto-declines must not kill a link")
        XCTAssertEqual(h.sent.last, .decline(callID: idY))
    }

    func testInboundRequestWhileEndedDoesNotPreempt() async {
        // CallController auto-declines in .ended (its known bug); the user
        // never sees this ring, so a link must survive it.
        let h = Harness()
        h.offerFails = true
        await h.engine.startVoiceCall(peerKey: peerA)
        XCTAssertEqual(h.engine.state, .ended(.failed))
        let before = h.journal
        await h.engine.handleInbound(.request(callID: idX, sdp: "o"), from: peerA)
        XCTAssertEqual(h.journal, before)
        XCTAssertEqual(h.sent.last, .decline(callID: idX))
    }

    func testPTTRequestAndOtherKindsNeverPreempt() async {
        let h = Harness()
        await h.engine.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerA)
        await h.engine.handleInbound(.answer(callID: idX, sdp: "a"), from: peerA)
        await h.engine.handleInbound(.decline(callID: idX), from: peerA)
        XCTAssertEqual(h.journal, [])
        XCTAssertEqual(h.engine.state, .idle)
        XCTAssertEqual(h.sent.count, 0)
    }
}

// MARK: - Test doubles

private enum FakeError: Error { case offer }

/// A `CallMediaSession` whose `makeOffer` can be held open on a continuation
/// so the in-flight window is observable.
@MainActor
private final class GatedMedia: CallMediaSession {
    var onConnected: (() -> Void)?
    var onFailed: (() -> Void)?
    var onRemoteEnded: (() -> Void)?

    let gated: Bool
    let fails: Bool
    private(set) var offerEntered = false
    private var gate: CheckedContinuation<Void, Never>?

    init(gated: Bool, fails: Bool) {
        self.gated = gated
        self.fails = fails
    }

    func makeOffer() async throws -> String {
        offerEntered = true
        if gated {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in gate = c }
        }
        if fails { throw FakeError.offer }
        return "offer-sdp"
    }
    func releaseOffer() {
        gate?.resume()
        gate = nil
    }
    func makeAnswer(remoteOffer: String) async throws -> String { "answer-sdp" }
    func start(remoteAnswer: String) async throws {}
    func close() {}
}

@MainActor
private final class Harness {
    let engine: CallEngine
    private(set) var journal: [String] = []
    private(set) var sent: [CallSignal] = []
    private(set) var media: GatedMedia?
    var offerFails = false

    init(gateOffer: Bool = false, installHook: Bool = true) {
        var record: ((String) -> Void)!
        var makeMedia: ((Bool) -> CallMediaSession)!
        var recordSend: ((CallSignal) -> Void)!
        engine = CallEngine(
            sendSignal: { signal, _ in recordSend(signal) },
            onMissedCall: { _ in },
            makeMediaSession: { cameraOn in makeMedia(cameraOn) })
        record = { [unowned self] in self.journal.append($0) }
        recordSend = { [unowned self] in self.sent.append($0) }
        makeMedia = { [unowned self] cameraOn in
            let m = GatedMedia(gated: gateOffer, fails: self.offerFails)
            self.media = m
            record("media(camera:\(cameraOn))")
            return m
        }
        if installHook {
            engine.preemptLink = { record("preempt") }
        }
    }

    func waitUntil(_ label: String, timeout: TimeInterval = 2,
                   _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for: \(label)")
    }
}
