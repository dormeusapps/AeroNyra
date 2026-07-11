//
//  WebRTCCallMediaTests.swift
//  BeaconTests
//
//  P2 seam tests for the concrete CallMediaSession.
//
//  • ICE-server mapping: the config seam's tiers (TURN+STUN / STUN-only /
//    nothing) map to exactly the RTCIceServer list they should — including
//    the rule that a TURN URL WITHOUT credentials is dropped, not sent broken.
//  • Loopback connect: two real WebRTCCallMedia instances exchange the actual
//    sealed-SDP payload strings (offer/answer, non-trickle, host candidates
//    only — no config) and must BOTH reach onConnected over the simulator's
//    loopback. This drives the true makeOffer → makeAnswer → start path the
//    state machine uses, end to end, with no servers.
//  • Camera/mic toggles flip track state in-band (no wire anywhere near).
//
//  XCTest only (not Swift Testing), per project standard.
//

import XCTest
import WebRTC
@testable import Beacon

final class WebRTCCallMediaTests: XCTestCase {

    /// HERMETIC AUDIO: the loopback test proves ICE/DTLS/SDP, not speaker
    /// output — but libwebrtc starts a live audio unit by default, which
    /// ABORTS (SIGABRT) when a parallel test clone holds the simulator's
    /// audio hardware. Manual-audio mode keeps the audio unit down for the
    /// test process only; the production path is untouched.
    override func setUp() {
        super.setUp()
        let session = RTCAudioSession.sharedInstance()
        session.useManualAudio = true
        session.isAudioEnabled = false
    }

    override func tearDown() {
        let session = RTCAudioSession.sharedInstance()
        session.useManualAudio = false
        super.tearDown()
    }

    // MARK: ICE mapping

    func testICEMapping_turnAndStunFullyConfigured() {
        let config = CallICEConfig(stunURLs: ["stun:s.example:3478"],
                                   turnURLs: ["turn:t.example:3478?transport=udp"],
                                   turnUsername: "user",
                                   turnCredential: "pass")
        let servers = WebRTCCallMedia.iceServers(from: config)
        XCTAssertEqual(servers.count, 2)
        XCTAssertEqual(servers[0].urlStrings, ["stun:s.example:3478"])
        XCTAssertEqual(servers[1].urlStrings, ["turn:t.example:3478?transport=udp"])
        XCTAssertEqual(servers[1].username, "user")
        XCTAssertEqual(servers[1].credential, "pass")
    }

    func testICEMapping_turnWithoutCredentialsIsDropped() {
        let config = CallICEConfig(stunURLs: ["stun:s.example:3478"],
                                   turnURLs: ["turn:t.example:3478"],
                                   turnUsername: "",
                                   turnCredential: "")
        XCTAssertFalse(config.hasTURN)
        let servers = WebRTCCallMedia.iceServers(from: config)
        XCTAssertEqual(servers.count, 1, "credential-less TURN must drop to STUN-only")
        XCTAssertEqual(servers[0].urlStrings, ["stun:s.example:3478"])
    }

    func testICEMapping_emptyConfigIsHostOnly() {
        XCTAssertTrue(WebRTCCallMedia.iceServers(from: CallICEConfig()).isEmpty)
    }

    // MARK: Capture format selection (pure; adaptive-quality settings)

    private typealias Candidate = WebRTCCallMedia.CaptureFormatCandidate

    func testBestFormat_picks720pWhenPresent() {
        let formats: [Candidate] = [
            .init(width: 640, height: 480, minFrameRate: 1, maxFrameRate: 30),
            .init(width: 1280, height: 720, minFrameRate: 1, maxFrameRate: 30),
            .init(width: 1920, height: 1080, minFrameRate: 1, maxFrameRate: 30),
            .init(width: 3840, height: 2160, minFrameRate: 1, maxFrameRate: 30),
        ]
        XCTAssertEqual(WebRTCCallMedia.bestFormatIndex(of: formats), 1)
    }

    func testBestFormat_onlySub720PicksBestAvailable() {
        let formats: [Candidate] = [
            .init(width: 352, height: 288, minFrameRate: 1, maxFrameRate: 30),
            .init(width: 640, height: 480, minFrameRate: 1, maxFrameRate: 30),
            .init(width: 960, height: 540, minFrameRate: 1, maxFrameRate: 30),
        ]
        XCTAssertEqual(WebRTCCallMedia.bestFormatIndex(of: formats), 2,
                       "closest-to-1280 must win on an older camera")
    }

    func testBestFormat_ignoresExoticHighFPSOnlyFormats() {
        let formats: [Candidate] = [
            .init(width: 1280, height: 720, minFrameRate: 60, maxFrameRate: 240),  // slo-mo only
            .init(width: 640, height: 480, minFrameRate: 1, maxFrameRate: 30),
        ]
        XCTAssertEqual(WebRTCCallMedia.bestFormatIndex(of: formats), 1,
                       "a >30fps-only format cannot run a 30fps call and must be ignored")
    }

    func testBestFormat_sharpnessBeatsFrameRateTieBreak() {
        let formats: [Candidate] = [
            .init(width: 640, height: 480, minFrameRate: 1, maxFrameRate: 30),
            .init(width: 1280, height: 720, minFrameRate: 1, maxFrameRate: 24),
        ]
        XCTAssertEqual(WebRTCCallMedia.bestFormatIndex(of: formats), 1,
                       "1280×720@24 beats 640×480@30 — sharpness is the primary score")
    }

    func testBestFormat_emptyListIsNil() {
        XCTAssertNil(WebRTCCallMedia.bestFormatIndex(of: []))
    }

    // MARK: Loopback connect (the seam driven end to end)

    @MainActor
    func testLoopbackConnect_offerAnswerConnectsBothEnds() async throws {
        let caller = WebRTCCallMedia(config: CallICEConfig())
        let callee = WebRTCCallMedia(config: CallICEConfig())
        defer { caller.close(); callee.close() }

        let callerConnected = expectation(description: "caller connected")
        let calleeConnected = expectation(description: "callee connected")
        caller.onConnected = { callerConnected.fulfill() }
        callee.onConnected = { calleeConnected.fulfill() }
        caller.onFailed = { XCTFail("caller media failed") }
        callee.onFailed = { XCTFail("callee media failed") }

        // The exact strings the sealed channel would carry.
        let offer = try await caller.makeOffer()
        XCTAssertTrue(offer.contains("a=fingerprint:"),
                      "the sealed SDP must carry the DTLS-SRTP fingerprint")
        XCTAssertLessThanOrEqual(offer.utf8.count, CallSignal.maxSDPBytes,
                                 "a real offer must fit the wire ceiling")

        let answer = try await callee.makeAnswer(remoteOffer: offer)
        XCTAssertTrue(answer.contains("a=fingerprint:"))
        XCTAssertLessThanOrEqual(answer.utf8.count, CallSignal.maxSDPBytes)

        try await caller.start(remoteAnswer: answer)

        await fulfillment(of: [callerConnected, calleeConnected], timeout: 20)

        // Adaptive-quality knobs: the retained sender must actually carry the
        // locked ceiling + degradation preference on both ends.
        for (label, media) in [("caller", caller), ("callee", callee)] {
            let sender = try XCTUnwrap(media.videoSender, "\(label): video sender not retained")
            let parameters = sender.parameters
            XCTAssertEqual(parameters.degradationPreference?.intValue,
                           RTCDegradationPreference.maintainFramerate.rawValue,
                           "\(label): degradation preference not maintainFramerate")
            XCTAssertFalse(parameters.encodings.isEmpty, "\(label): no encodings")
            for encoding in parameters.encodings {
                XCTAssertEqual(encoding.maxBitrateBps?.intValue,
                               WebRTCCallMedia.maxVideoBitrateBps,
                               "\(label): bitrate ceiling not applied")
            }
        }
    }

    // MARK: In-band controls

    @MainActor
    func testControls_cameraAndMuteFlipTrackStateInBand() async throws {
        let media = WebRTCCallMedia(config: CallICEConfig(), cameraInitiallyEnabled: false)
        defer { media.close() }
        _ = try await media.makeOffer()   // tracks exist after assembly

        XCTAssertFalse(media.cameraEnabled)
        media.setCameraEnabled(true)
        XCTAssertTrue(media.cameraEnabled)
        media.setCameraEnabled(false)
        XCTAssertFalse(media.cameraEnabled)

        XCTAssertFalse(media.micMuted)
        media.setMicMuted(true)
        XCTAssertTrue(media.micMuted)
        media.setMicMuted(false)
        XCTAssertFalse(media.micMuted)
    }
}
