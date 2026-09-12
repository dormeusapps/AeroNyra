//
//  PTTLinkLocalLevelTests.swift
//  BeaconTests
//
//  Pins `PTTLinkController.localAudioLevel()` (globe pulse, loop 3): the
//  controller asks the media session for my own level ONLY while the link
//  is `.open` AND a press is un-muting the mic. Idle, opening, open-but-
//  released, closed: nil without touching the session — so nothing is ever
//  polled between presses (each real read is a stats request). Also pins
//  the protocol's fail-closed default for a session that does not meter.
//
//  The engine's local meter loop is deliberately NOT pinned (timer loop —
//  same ruling as the open timeout).
//

import XCTest
@testable import Beacon

@MainActor
private final class LocallyMeteredFakeMedia: PTTLinkMediaSession {
    var onConnected: (() -> Void)?
    var onFailed: (() -> Void)?
    var onRemoteEnded: (() -> Void)?
    var level: Double? = 0.33
    /// Counts real reads, so "nil without touching the session" is pinnable.
    private(set) var reads = 0
    func localAudioLevel() async -> Double? { reads += 1; return level }
    func makeOffer() async throws -> String { "offer-sdp" }
    func makeAnswer(remoteOffer: String) async throws -> String { "answer-sdp" }
    func start(remoteAnswer: String) async throws {}
    func close() {}
    func setMicMuted(_ muted: Bool) {}
    func setSpeakerEnabled(_ enabled: Bool) {}
}

/// A session with NO local level of its own — exercises the protocol default.
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
final class PTTLinkLocalLevelTests: XCTestCase {

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

    func testIdleReadsNilWithoutTouchingTheSession() async {
        let session = LocallyMeteredFakeMedia()
        let controller = PTTLinkController(sendSignal: { _, _ in },
                                           makeMediaSession: { session })
        let level = await controller.localAudioLevel()
        XCTAssertNil(level)
        XCTAssertEqual(session.reads, 0)
    }

    func testOpeningReadsNilWithoutTouchingTheSession() async {
        let session = LocallyMeteredFakeMedia()
        let controller = PTTLinkController(sendSignal: { _, _ in },
                                           makeMediaSession: { session })
        await controller.open(to: peer)
        let level = await controller.localAudioLevel()
        XCTAssertNil(level, "reaching: nothing transmits")
        XCTAssertEqual(session.reads, 0)
    }

    func testOpenButReleasedReadsNilWithoutTouchingTheSession() async {
        let session = LocallyMeteredFakeMedia()
        let controller = await openLink(with: session)
        let level = await controller.localAudioLevel()
        XCTAssertNil(level, "open, no press: the mic is muted, nothing to meter")
        XCTAssertEqual(session.reads, 0, "no stats request between presses")
    }

    func testPressingReadsTheSessionLive() async {
        let session = LocallyMeteredFakeMedia()
        let controller = await openLink(with: session)
        XCTAssertTrue(controller.pressBegan())
        var level = await controller.localAudioLevel()
        XCTAssertEqual(level, 0.33)
        session.level = 0.05
        level = await controller.localAudioLevel()
        XCTAssertEqual(level, 0.05, "a live read, not a snapshot")
        XCTAssertEqual(session.reads, 2)
    }

    func testReleaseStopsTheReads() async {
        let session = LocallyMeteredFakeMedia()
        let controller = await openLink(with: session)
        controller.pressBegan()
        _ = await controller.localAudioLevel()
        controller.pressEnded()
        let level = await controller.localAudioLevel()
        XCTAssertNil(level)
        XCTAssertEqual(session.reads, 1, "released: no further request")
    }

    func testCloseMidPressReadsNil() async {
        let session = LocallyMeteredFakeMedia()
        let controller = await openLink(with: session)
        controller.pressBegan()
        controller.close()
        XCTAssertFalse(controller.isTransmitting, "every close forces the mic flag off")
        let level = await controller.localAudioLevel()
        XCTAssertNil(level)
        XCTAssertEqual(session.reads, 0)
    }

    func testAnUnmeteredSessionReadsNilWhilePressing() async {
        let controller = await openLink(with: UnmeteredFakeMedia())
        controller.pressBegan()
        let level = await controller.localAudioLevel()
        XCTAssertNil(level, "protocol default fails closed")
    }
}
