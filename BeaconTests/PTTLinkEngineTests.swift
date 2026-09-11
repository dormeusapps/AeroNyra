// PTTLinkEngineTests.swift
// Pins `PTTLinkEngine` (step 4): the composition-root face of the link.
//   • lifecycle policy mirrors CallEngine — interruption or backgrounding
//     closes an opening/open link with the VISIBLE `.interrupted` reason,
//     and the engine never re-opens on its own;
//   • `preempt()` passes through as `.preempted`;
//   • the state / transmit mirrors track the controller;
//   • the auto-answer policy is consulted (false → decline, no media).
//

import XCTest
@testable import Beacon

@MainActor
final class PTTLinkEngineTests: XCTestCase {

    private let peerA = Data(repeating: 0xA1, count: 32)
    private let idX = Data(repeating: 0x11, count: 16)

    func testInterruptionClosesOpeningLinkAsInterrupted() async {
        let h = Harness()
        await h.engine.open(to: peerA)
        guard case .opening = h.engine.state else { return XCTFail("expected opening") }

        h.engine.interruptionBegan()

        XCTAssertEqual(h.engine.state, .closed(.interrupted))
        XCTAssertEqual(h.session?.closeCalls, 1)
        XCTAssertTrue(PTTLinkController.CloseReason.interrupted.isUserVisible)
    }

    func testBackgroundClosesOpenLinkAndStaysClosedAfterwards() async {
        let h = Harness()
        await h.engine.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerA)
        h.session?.onConnected?()
        XCTAssertEqual(h.engine.state, .open(linkID: idX, peerKey: peerA, role: .responder))

        h.engine.didEnterBackground()

        XCTAssertEqual(h.engine.state, .closed(.interrupted))
        XCTAssertEqual(h.session?.closeCalls, 1)
        // Nothing here re-opens: a second edge is a no-op.
        h.engine.didEnterBackground()
        h.engine.interruptionBegan()
        XCTAssertEqual(h.engine.state, .closed(.interrupted))
        XCTAssertEqual(h.sessions.count, 1)
    }

    func testLifecycleEdgesAreNoOpsWhenIdle() {
        let h = Harness()
        h.engine.interruptionBegan()
        h.engine.didEnterBackground()
        XCTAssertEqual(h.engine.state, .idle)
        XCTAssertEqual(h.sessions.count, 0)
    }

    func testPreemptPassesThroughAsPreempted() async {
        let h = Harness()
        await h.engine.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerA)
        h.session?.onConnected?()
        h.engine.preempt()
        XCTAssertEqual(h.engine.state, .closed(.preempted))
        XCTAssertEqual(h.session?.closeCalls, 1)
        XCTAssertFalse(PTTLinkController.CloseReason.preempted.isUserVisible)
    }

    func testMirrorsTrackTheController() async {
        let h = Harness()
        XCTAssertEqual(h.engine.state, h.engine.controller.state)
        await h.engine.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerA)
        XCTAssertEqual(h.engine.state, h.engine.controller.state)
        h.session?.onConnected?()
        XCTAssertEqual(h.engine.state, h.engine.controller.state)

        XCTAssertFalse(h.engine.isTransmitting)
        XCTAssertTrue(h.engine.pressBegan())
        XCTAssertTrue(h.engine.isTransmitting)
        XCTAssertTrue(h.engine.pressEnded())
        XCTAssertFalse(h.engine.isTransmitting)

        h.engine.close()
        XCTAssertEqual(h.engine.state, .closed(.localClosed))
        h.engine.reset()
        XCTAssertEqual(h.engine.state, .idle)
    }

    func testAutoAnswerPolicyIsConsulted() async {
        let h = Harness(policy: { false })
        await h.engine.handleInbound(.pttRequest(callID: idX, sdp: "o"), from: peerA)
        XCTAssertEqual(h.engine.state, .idle)
        XCTAssertEqual(h.sessions.count, 0)
        XCTAssertEqual(h.sent, [.decline(callID: idX)])
    }
}

// MARK: - Test doubles

@MainActor
private final class FakeLinkMedia: PTTLinkMediaSession {
    var onConnected: (() -> Void)?
    var onFailed: (() -> Void)?
    var onRemoteEnded: (() -> Void)?
    private(set) var closeCalls = 0
    func makeOffer() async throws -> String { "offer-sdp" }
    func makeAnswer(remoteOffer: String) async throws -> String { "answer-sdp" }
    func start(remoteAnswer: String) async throws {}
    func close() { closeCalls += 1 }
    func setMicMuted(_ muted: Bool) {}
    func setSpeakerEnabled(_ enabled: Bool) {}
}

@MainActor
private final class Harness {
    let engine: PTTLinkEngine
    private(set) var sessions: [FakeLinkMedia] = []
    private(set) var sent: [CallSignal] = []
    var session: FakeLinkMedia? { sessions.last }

    init(policy: @escaping () -> Bool = { true }) {
        var make: (() -> PTTLinkMediaSession)!
        var recordSend: ((CallSignal) -> Void)!
        engine = PTTLinkEngine(
            sendSignal: { signal, _ in recordSend(signal) },
            autoAnswerPolicy: policy,
            makeMediaSession: { make() })
        make = { [unowned self] in
            let s = FakeLinkMedia()
            self.sessions.append(s)
            return s
        }
        recordSend = { [unowned self] in self.sent.append($0) }
    }
}
