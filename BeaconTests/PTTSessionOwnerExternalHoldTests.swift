//
//  PTTSessionOwnerExternalHoldTests.swift
//  BeaconTests
//
//  Pins the EXTERNAL HOLD on `PTTSessionOwner` (live PTT-over-IP, step 5) and
//  the link engine's registration of it. The hold is how a WebRTC walkie
//  link keeps the IC8 flag raised so every `setActive(false)` guard in the
//  app holds while the link is up — the fix for a link going silently deaf
//  when any other audio owner finishes. Hardware-free via the owner's
//  injectable session seam, same spy pattern as PTTSessionOwnerTests.
//
//  Contract pinned:
//    • hold raises `isLive` and NEVER activates (WebRTC owns activation);
//    • the last release — no BLE session, no other hold — lowers the flag
//      and deactivates exactly once (the polite, music-resumes release);
//    • a BLE session closing while a hold exists does NOT deactivate;
//    • a hold releasing while a BLE session is live does NOT deactivate;
//    • a BLE session opening while only a hold exists still activates
//      (fail closed: the flag asserts an activated session);
//    • hold/release are idempotent per id;
//    • an interruption closes BLE sessions but keeps the hold;
//    • PTTLinkEngine holds on .opening/.open and releases on .closed/.idle,
//      re-keys across glare, and is inert when no owner is wired.
//

import XCTest
@testable import Beacon

@MainActor
final class PTTSessionOwnerExternalHoldTests: XCTestCase {

    override func tearDown() {
        MainActor.assumeIsolated { PTTSessionOwner.shared = nil }
        super.tearDown()
    }

    private final class Recorder {
        var log: [String] = []
    }

    private final class SessionSpy: PTTAudioSessionControlling {
        let rec: Recorder
        init(_ rec: Recorder) { self.rec = rec }
        func activateForPTT() throws { rec.log.append("activate") }
        func deactivate() { rec.log.append("deactivate") }
    }

    private func makeOwner() -> (PTTSessionOwner, Recorder) {
        let rec = Recorder()
        return (PTTSessionOwner(audioSession: SessionSpy(rec)), rec)
    }

    private func id(_ byte: UInt8) -> Data { Data(repeating: byte, count: 16) }
    private let peer = Data(repeating: 0xA1, count: 32)

    // MARK: - Owner semantics

    func testHoldRaisesFlagWithoutActivating() {
        let (owner, rec) = makeOwner()
        owner.hold(externalID: id(1))
        XCTAssertTrue(owner.isLive)
        XCTAssertEqual(rec.log, [], "a hold never touches the session")
    }

    func testLastReleaseLowersFlagAndDeactivatesOnce() {
        let (owner, rec) = makeOwner()
        owner.hold(externalID: id(1))
        owner.release(externalID: id(1))
        XCTAssertFalse(owner.isLive)
        XCTAssertEqual(rec.log, ["deactivate"])
        owner.release(externalID: id(1))                    // double-release: no-op
        XCTAssertEqual(rec.log, ["deactivate"])
    }

    func testHoldIsIdempotentPerID() {
        let (owner, rec) = makeOwner()
        owner.hold(externalID: id(1))
        owner.hold(externalID: id(1))
        owner.release(externalID: id(1))
        XCTAssertFalse(owner.isLive, "one hold, one release")
        XCTAssertEqual(rec.log, ["deactivate"])
    }

    func testTwoHoldsReleaseOnlyOnTheLast() {
        let (owner, rec) = makeOwner()
        owner.hold(externalID: id(1))
        owner.hold(externalID: id(2))
        owner.release(externalID: id(1))
        XCTAssertTrue(owner.isLive)
        XCTAssertEqual(rec.log, [])
        owner.release(externalID: id(2))
        XCTAssertFalse(owner.isLive)
        XCTAssertEqual(rec.log, ["deactivate"])
    }

    func testBLECloseWhileHeldDoesNotDeactivate() {
        let (owner, rec) = makeOwner()
        owner.hold(externalID: id(1))
        owner.opened(pttID: id(7), peerKey: peer)           // BLE opens under the hold
        XCTAssertEqual(rec.log, ["activate"], "fail closed: a BLE session still activates")
        owner.closed(pttID: id(7))
        XCTAssertTrue(owner.isLive, "the link still holds the session live")
        XCTAssertEqual(rec.log, ["activate"], "no deactivation under a hold")
        owner.release(externalID: id(1))
        XCTAssertFalse(owner.isLive)
        XCTAssertEqual(rec.log, ["activate", "deactivate"])
    }

    func testReleaseWhileBLELiveDoesNotDeactivate() {
        let (owner, rec) = makeOwner()
        owner.opened(pttID: id(7), peerKey: peer)
        owner.hold(externalID: id(1))
        owner.release(externalID: id(1))
        XCTAssertTrue(owner.isLive, "the BLE session still owns it")
        XCTAssertEqual(rec.log, ["activate"])
        owner.closed(pttID: id(7))
        XCTAssertFalse(owner.isLive)
        XCTAssertEqual(rec.log, ["activate", "deactivate"])
    }

    func testInterruptionClosesBLESessionsButKeepsHold() {
        let (owner, rec) = makeOwner()
        owner.hold(externalID: id(1))
        owner.opened(pttID: id(7), peerKey: peer)
        owner.interruptionBegan()
        XCTAssertTrue(owner.isLive, "the hold survives; the link engine handles its own interruption")
        XCTAssertEqual(rec.log, ["activate"])
        owner.release(externalID: id(1))
        XCTAssertEqual(rec.log, ["activate", "deactivate"])
    }

    // MARK: - PTTLinkEngine registration

    func testEngineHoldsOnOpeningAndReleasesOnClose() async {
        let (owner, rec) = makeOwner()
        PTTSessionOwner.shared = owner
        let h = EngineHarness()

        await h.engine.open(to: peer)                       // .opening(awaitingAnswer)
        XCTAssertTrue(owner.isLive, "held from the FIRST opening state")
        XCTAssertEqual(rec.log, [])

        h.engine.close()                                    // .closed(.localClosed)
        XCTAssertFalse(owner.isLive)
        XCTAssertEqual(rec.log, ["deactivate"], "released once, by the owner, after media close")

        h.engine.reset()                                    // .idle: nothing more
        XCTAssertEqual(rec.log, ["deactivate"])
    }

    func testEngineHoldSpansResponderOpenAndRemoteEnd() async {
        let (owner, rec) = makeOwner()
        PTTSessionOwner.shared = owner
        let h = EngineHarness()

        await h.engine.handleInbound(.pttRequest(callID: id(9), sdp: "o"), from: peer)
        XCTAssertTrue(owner.isLive)
        h.session?.onConnected?()
        XCTAssertTrue(owner.isLive, "same id, hold unchanged across opening → open")
        XCTAssertEqual(rec.log, [])

        h.session?.onRemoteEnded?()                         // controller-internal close
        XCTAssertFalse(owner.isLive)
        XCTAssertEqual(rec.log, ["deactivate"])
    }

    func testEngineRekeysHoldAcrossGlare() async {
        let (owner, rec) = makeOwner()
        PTTSessionOwner.shared = owner
        let h = EngineHarness()

        await h.engine.open(to: peer)
        // Their lower id wins: the controller abandons ours and answers theirs.
        await h.engine.handleInbound(.pttRequest(callID: Data(repeating: 0x00, count: 16), sdp: "o"), from: peer)
        guard case .opening(_, _, .responder, _) = h.engine.state else {
            return XCTFail("expected responder opening after glare loss")
        }
        XCTAssertTrue(owner.isLive, "held under the new id")
        XCTAssertEqual(rec.log, [], "re-key never deactivates mid-hand-off")

        h.engine.close()
        XCTAssertFalse(owner.isLive)
        XCTAssertEqual(rec.log, ["deactivate"])
    }

    func testEngineIsInertWithoutAnOwner() async {
        PTTSessionOwner.shared = nil
        let h = EngineHarness()
        await h.engine.open(to: peer)
        h.engine.close()
        XCTAssertFalse(PTTSessionOwner.isLive)
    }
}

// MARK: - Engine harness

@MainActor
private final class FakeLinkMedia: PTTLinkMediaSession {
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
private final class EngineHarness {
    let engine: PTTLinkEngine
    private(set) var sessions: [FakeLinkMedia] = []
    var session: FakeLinkMedia? { sessions.last }

    init() {
        var make: (() -> PTTLinkMediaSession)!
        engine = PTTLinkEngine(
            sendSignal: { _, _ in },
            autoAnswerPolicy: { true },
            makeMediaSession: { make() })
        make = { [unowned self] in
            let s = FakeLinkMedia()
            self.sessions.append(s)
            return s
        }
    }
}
