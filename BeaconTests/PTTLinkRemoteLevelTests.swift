//
//  PTTLinkRemoteLevelTests.swift
//  BeaconTests
//
//  Pins `PTTLinkController.remoteAudioLevel` (globe pulse, loop 2): the
//  controller hands the media session's level through ONLY while the link is
//  `.open`. In every other state — idle, reaching, connecting, closed — it is
//  nil even if the session would report one, so a closing or superseded
//  session can never leak a level onto the sphere. Also pins the protocol's
//  fail-closed default: a media session that does not meter reads nil.
//
//  The engine's 20 Hz meter loop is deliberately NOT pinned (timer loop —
//  same ruling as the open timeout).
//

import XCTest
@testable import Beacon

@MainActor
private final class MeteredFakeMedia: PTTLinkMediaSession {
    var onConnected: (() -> Void)?
    var onFailed: (() -> Void)?
    var onRemoteEnded: (() -> Void)?
    var level: Double? = 0.42
    var remoteAudioLevel: Double? { level }
    func makeOffer() async throws -> String { "offer-sdp" }
    func makeAnswer(remoteOffer: String) async throws -> String { "answer-sdp" }
    func start(remoteAnswer: String) async throws {}
    func close() {}
    func setMicMuted(_ muted: Bool) {}
    func setSpeakerEnabled(_ enabled: Bool) {}
}

/// A session with NO level of its own — exercises the protocol default.
@MainActor
private final class UnmeteredFakeMedia: PTTLinkMediaSession {
    var onConnected: (() -> Void)?
    var onFailed: (() -> Void)?
    var onRemoteEnded: (() -> Void)?
    func makeOffer() async throws -> String { "offer-sdp" }
    func makeAnswer(remoteOffer: String) async throws -> String { "answer-sdp" }
    func start(remoteAnswer: String) async throws {}
    func close() {}
    func setMicMuted(_ muted: Bool) {}
    func setSpeakerEnabled(_ enabled: Bool) {}
}

@MainActor
final class PTTLinkRemoteLevelTests: XCTestCase {

    private let peer = Data(repeating: 0xB2, count: 32)

    /// Drives a controller to `.open` as the initiator against `session`.
    private func openLink(with session: PTTLinkMediaSession) async -> PTTLinkController {
        let controller = PTTLinkController(sendSignal: { _, _ in },
                                           makeMediaSession: { session })
        await controller.open(to: peer)
        guard let id = controller.state.linkID else {
            XCTFail("expected .opening"); return controller
        }
        await controller.handleInbound(.answer(callID: id, sdp: "answer-sdp"), from: peer)
        session.onConnected?()
        XCTAssertTrue(controller.isOpen)
        return controller
    }

    func testIdleReadsNil() {
        let controller = PTTLinkController(sendSignal: { _, _ in },
                                           makeMediaSession: { MeteredFakeMedia() })
        XCTAssertNil(controller.remoteAudioLevel)
    }

    func testOpeningReadsNilEvenThoughTheSessionHasALevel() async {
        let session = MeteredFakeMedia()
        let controller = PTTLinkController(sendSignal: { _, _ in },
                                           makeMediaSession: { session })
        await controller.open(to: peer)
        XCTAssertNotNil(controller.state.linkID, "reaching")
        XCTAssertNil(controller.remoteAudioLevel, "not open yet")
        guard let id = controller.state.linkID else { return }
        await controller.handleInbound(.answer(callID: id, sdp: "answer-sdp"), from: peer)
        XCTAssertNil(controller.remoteAudioLevel, "connecting: still not open")
    }

    func testOpenReadsTheSessionsLevelLive() async {
        let session = MeteredFakeMedia()
        let controller = await openLink(with: session)
        XCTAssertEqual(controller.remoteAudioLevel, 0.42)
        session.level = 0.07
        XCTAssertEqual(controller.remoteAudioLevel, 0.07, "a live read, not a snapshot")
        session.level = nil
        XCTAssertNil(controller.remoteAudioLevel, "the session's nil passes through")
    }

    func testClosedReadsNil() async {
        let session = MeteredFakeMedia()
        let controller = await openLink(with: session)
        controller.close()
        XCTAssertNil(controller.remoteAudioLevel)
        controller.reset()
        XCTAssertNil(controller.remoteAudioLevel)
    }

    func testRemoteEndedReadsNil() async {
        let session = MeteredFakeMedia()
        let controller = await openLink(with: session)
        session.onRemoteEnded?()
        XCTAssertNil(controller.remoteAudioLevel)
    }

    func testAnUnmeteredSessionReadsNilWhileOpen() async {
        let controller = await openLink(with: UnmeteredFakeMedia())
        XCTAssertNil(controller.remoteAudioLevel, "protocol default fails closed")
    }
}
