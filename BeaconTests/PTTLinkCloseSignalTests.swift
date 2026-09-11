//
//  PTTLinkCloseSignalTests.swift
//  BeaconTests
//
//  Pins the CLOSE SIGNAL (Rubins' ruling 2026-09-11, "end it and tell them"):
//  a local close sends `.decline(linkID)` on the signal rail (kind 10 reused
//  — no new wire kind), and a decline for OUR CURRENT link id from its peer,
//  while connecting or open, ends the link as remote-ended at once instead
//  of waiting for ICE decay. The awaiting-answer arm (busy decline →
//  remoteDeclined) is unchanged; a stale id is dropped.
//

import XCTest
@testable import Beacon

@MainActor
final class PTTLinkCloseSignalTests: XCTestCase {

    private let peerA = Data(repeating: 0xA1, count: 32)
    private let peerB = Data(repeating: 0xB2, count: 32)
    private let theirID = Data(repeating: 0x33, count: 16)
    private let staleID = Data(repeating: 0x44, count: 16)

    /// The close signal is fire-and-forget on a Task; let it run.
    private func settle() async { for _ in 0..<4 { await Task.yield() } }

    // MARK: - Sending

    func testCloseFromOpenAsInitiatorSendsDeclineWithLinkID() async throws {
        let h = Harness()
        await h.controller.open(to: peerA)
        let id = try XCTUnwrap(h.controller.state.linkID)
        await h.controller.handleInbound(.answer(callID: id, sdp: "a"), from: peerA)
        h.session.onConnected?()
        XCTAssertTrue(h.controller.isOpen)
        h.sent.removeAll()

        h.controller.close()
        await settle()
        XCTAssertEqual(h.sent.map(\.signal), [.decline(callID: id)])
        XCTAssertEqual(h.sent.map(\.peer), [peerA])
        XCTAssertEqual(h.controller.state, .closed(.localClosed))
    }

    func testCloseFromOpenAsResponderSendsDeclineWithLinkID() async {
        let h = Harness()
        await h.controller.handleInbound(.pttRequest(callID: theirID, sdp: "o"), from: peerA)
        h.session.onConnected?()
        XCTAssertTrue(h.controller.isOpen)
        h.sent.removeAll()

        h.controller.close(reason: .interrupted)
        await settle()
        XCTAssertEqual(h.sent.map(\.signal), [.decline(callID: theirID)])
        XCTAssertEqual(h.controller.state, .closed(.interrupted))
    }

    func testCloseFromOpeningSendsDecline() async throws {
        let h = Harness()
        await h.controller.open(to: peerA)
        let id = try XCTUnwrap(h.controller.state.linkID)
        h.sent.removeAll()

        h.controller.close()
        await settle()
        XCTAssertEqual(h.sent.map(\.signal), [.decline(callID: id)])
    }

    // MARK: - Receiving

    func testDeclineForCurrentIDWhileOpenEndsAsRemoteEnded() async throws {
        let h = Harness()
        await h.controller.open(to: peerA)
        let id = try XCTUnwrap(h.controller.state.linkID)
        await h.controller.handleInbound(.answer(callID: id, sdp: "a"), from: peerA)
        h.session.onConnected?()

        await h.controller.handleInbound(.decline(callID: id), from: peerA)
        XCTAssertEqual(h.controller.state, .closed(.remoteEnded))
        XCTAssertEqual(h.session.closeCalls, 1, "media torn down at once, not by decay")
    }

    func testDeclineForCurrentIDWhileConnectingEndsAsRemoteEnded() async {
        let h = Harness()
        await h.controller.handleInbound(.pttRequest(callID: theirID, sdp: "o"), from: peerA)
        guard case .opening(_, _, .responder, .connecting) = h.controller.state else {
            return XCTFail("expected responder connecting")
        }
        await h.controller.handleInbound(.decline(callID: theirID), from: peerA)
        XCTAssertEqual(h.controller.state, .closed(.remoteEnded))
    }

    func testDeclineForStaleIDOrWrongPeerIsDropped() async throws {
        let h = Harness()
        await h.controller.open(to: peerA)
        let id = try XCTUnwrap(h.controller.state.linkID)
        await h.controller.handleInbound(.answer(callID: id, sdp: "a"), from: peerA)
        h.session.onConnected?()

        await h.controller.handleInbound(.decline(callID: staleID), from: peerA)
        XCTAssertTrue(h.controller.isOpen, "stale id: nothing changes")
        await h.controller.handleInbound(.decline(callID: id), from: peerB)
        XCTAssertTrue(h.controller.isOpen, "right id, wrong peer: nothing changes")
    }

    func testAwaitingAnswerArmIsUnchanged() async throws {
        let h = Harness()
        await h.controller.open(to: peerA)
        let id = try XCTUnwrap(h.controller.state.linkID)
        await h.controller.handleInbound(.decline(callID: id), from: peerA)
        XCTAssertEqual(h.controller.state, .closed(.remoteDeclined), "a busy decline still reads as declined")
    }
}

// MARK: - Harness (minimal: fake media + send recorder)

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
    let controller: PTTLinkController
    private(set) var sessions: [FakeLinkMedia] = []
    var sent: [(signal: CallSignal, peer: Data)] = []
    var session: FakeLinkMedia { sessions[sessions.count - 1] }

    init() {
        var send: ((CallSignal, Data) async throws -> Void)!
        var make: (() -> PTTLinkMediaSession)!
        controller = PTTLinkController(
            sendSignal: { signal, peer in try await send(signal, peer) },
            makeMediaSession: { make() },
            openTimeout: .seconds(20),
            autoAnswerPolicy: { true })
        make = { [unowned self] in
            let s = FakeLinkMedia()
            self.sessions.append(s)
            return s
        }
        send = { [unowned self] signal, peer in self.sent.append((signal, peer)) }
    }
}
