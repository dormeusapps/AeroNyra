//
//  PTTRequestWireTests.swift
//  BeaconTests
//
//  Pins for wire kind 14 — `pttRequest`, the no-ring link request of live
//  PTT-over-IP. Freezes: the tag value, the byte-exact `[14] ‖ callID ‖ SDP`
//  encoding, body-identity with `callRequest` (kind 8), the strict parser's
//  rejections, the padding bucket (a kind-14 frame is the same size on the wire
//  as a kind-8 frame with the same SDP), forward-compat of the NEXT tag (15),
//  and the load-bearing safety fact for landing this step ahead of the rest:
//  CallController drops a `.pttRequest` in every state, so the kind is inert
//  until a consumer exists.
//

import XCTest
@testable import Beacon

final class PTTRequestWireTests: XCTestCase {

    // Fixed inputs: callID 10 11 … 1f (16 bytes), a short ASCII "SDP".
    private let callID = Data((0x10...0x1f).map { UInt8($0) })
    private let sdp = "v=0\r\no=- 1 1 IN IP6 ::1\r\n"

    // MARK: 1 — tag value, uniqueness, and the byte-exact encoding

    func testTagIsFourteenAndUnique() {
        XCTAssertEqual(WirePayloadKind.pttRequest.rawValue, 14)
        let tags = WirePayloadKind.allCases.map(\.rawValue)
        XCTAssertEqual(tags.count, Set(tags).count, "no other kind shares tag 14")
        // Not the BLE-live handshake pair.
        XCTAssertNotEqual(WirePayloadKind.pttRequest, .pttOpen)
        XCTAssertNotEqual(WirePayloadKind.pttRequest, .pttClose)
    }

    func testEncodedIsTagThenCallIDThenSDP() {
        let payload = MessagePayload.callSignal(.pttRequest(callID: callID, sdp: sdp))
        XCTAssertEqual(payload.kind, .pttRequest)
        let expectedBody = callID + Data(sdp.utf8)
        XCTAssertEqual(payload.body, expectedBody)
        XCTAssertEqual(payload.encoded(), Data([14]) + expectedBody)
        XCTAssertEqual(payload.encoded().count, 1 + 16 + sdp.utf8.count)
    }

    // MARK: 2 — body-identical to callRequest; only the tag differs

    func testBodyIsIdenticalToCallRequest() {
        let ptt = MessagePayload.callSignal(.pttRequest(callID: callID, sdp: sdp))
        let call = MessagePayload.callSignal(.request(callID: callID, sdp: sdp))
        XCTAssertEqual(ptt.body, call.body)
        XCTAssertEqual(ptt.encoded().dropFirst(), call.encoded().dropFirst())
        XCTAssertEqual(ptt.encoded().first, 14)
        XCTAssertEqual(call.encoded().first, 8)
    }

    // MARK: 3 — decode round-trips, plain and sealed-padded

    func testDecodeRoundTrip() throws {
        let payload = MessagePayload.callSignal(.pttRequest(callID: callID, sdp: sdp))
        let decoded = try XCTUnwrap(MessagePayload.decode(payload.encoded()))
        XCTAssertEqual(decoded, payload)
        guard case .pttRequest(let body) = decoded else {
            return XCTFail("expected .pttRequest, got \(decoded)")
        }
        let signal = try XCTUnwrap(CallSignal.parsePTTRequestBody(body))
        XCTAssertEqual(signal, .pttRequest(callID: callID, sdp: sdp))
        XCTAssertEqual(signal.callID, callID)
        XCTAssertEqual(signal.sdp, sdp)
    }

    func testSealedPlaintextRoundTrip() throws {
        let payload = MessagePayload.callSignal(.pttRequest(callID: callID, sdp: sdp))
        let decoded = try XCTUnwrap(MessagePayload.decodeSealed(payload.sealedPlaintext()))
        XCTAssertEqual(decoded, payload)
    }

    // MARK: 4 — strict parser rejections (same contract as parseRequestBody)

    func testParserRejectsMalformedBodies() {
        XCTAssertNil(CallSignal.parsePTTRequestBody(Data()), "empty")
        XCTAssertNil(CallSignal.parsePTTRequestBody(callID), "callID only, no SDP")
        XCTAssertNil(CallSignal.parsePTTRequestBody(Data(callID.prefix(15)) + Data("x".utf8)),
                     "short callID")
        XCTAssertNil(CallSignal.parsePTTRequestBody(callID + Data([0xFF, 0xFE])),
                     "non-UTF-8 SDP")
        let oversize = callID + Data(repeating: 0x61, count: CallSignal.maxSDPBytes + 1)
        XCTAssertNil(CallSignal.parsePTTRequestBody(oversize), "SDP over the ceiling")
        let atCeiling = callID + Data(repeating: 0x61, count: CallSignal.maxSDPBytes)
        XCTAssertNotNil(CallSignal.parsePTTRequestBody(atCeiling), "SDP at the ceiling parses")
        // The two parsers agree byte-for-byte on what they accept.
        for body in [Data(), callID, callID + Data([0xFF]), oversize, atCeiling] {
            XCTAssertEqual(CallSignal.parsePTTRequestBody(body) == nil,
                           CallSignal.parseRequestBody(body) == nil)
        }
    }

    // MARK: 5 — padding: same bucket as callRequest, always on the ladder

    func testPaddedSizeMatchesCallRequestForSmallAndLargeSDP() {
        let small = String(repeating: "a", count: 200)        // → 256 bucket
        let medium = String(repeating: "a", count: 2_500)     // typical SDP → 4096
        let large = String(repeating: "a", count: 12_000)     // video-heavy → 16384
        for text in [small, medium, large] {
            let ptt = MessagePayload.callSignal(.pttRequest(callID: callID, sdp: text)).sealedPlaintext()
            let call = MessagePayload.callSignal(.request(callID: callID, sdp: text)).sealedPlaintext()
            XCTAssertEqual(ptt.count, call.count, "kind 14 and kind 8 pad to the same size")
            XCTAssertTrue(PayloadBucket.sizes.contains(ptt.count),
                          "\(ptt.count) is not on the bucket ladder")
        }
    }

    // MARK: 6 — forward-compat: the NEXT tag is still unknown

    func testTagFifteenDecodesNil() {
        XCTAssertNil(MessagePayload.decode(Data([15, 1])),
                     "tag 15 is the next genuinely-unknown tag and must decode nil")
        XCTAssertNil(MessagePayload.decode(Data([0xFF, 1])))
    }

    // MARK: 7 — inert: CallController drops a .pttRequest in every state

    @MainActor
    func testCallControllerDropsPTTRequestInEveryState() async {
        let peer = Data(repeating: 0xA1, count: 32)
        let other = Data(repeating: 0xB2, count: 32)
        let ptt = CallSignal.pttRequest(callID: callID, sdp: sdp)

        // idle
        do {
            let h = InertHarness()
            await h.controller.handleInbound(ptt, from: peer)
            XCTAssertEqual(h.controller.state, .idle)
            XCTAssertEqual(h.sentCount, 0)
            XCTAssertEqual(h.sessionsMade, 0)
        }
        // incomingRinging (a real ring is up; the ptt frame must not touch it)
        do {
            let h = InertHarness()
            let ringID = Data(repeating: 0x02, count: 16)
            await h.controller.handleInbound(.request(callID: ringID, sdp: "offer"), from: other)
            let before = h.controller.state
            let sentBefore = h.sentCount
            await h.controller.handleInbound(ptt, from: peer)
            XCTAssertEqual(h.controller.state, before)
            XCTAssertEqual(h.sentCount, sentBefore, "no decline is sent for a ptt frame")
            XCTAssertEqual(h.sessionsMade, 0)
        }
        // ended
        do {
            let h = InertHarness()
            let ringID = Data(repeating: 0x02, count: 16)
            await h.controller.handleInbound(.request(callID: ringID, sdp: "offer"), from: other)
            await h.controller.decline()
            let sentBefore = h.sentCount
            await h.controller.handleInbound(ptt, from: peer)
            XCTAssertEqual(h.controller.state, .ended(.declined))
            XCTAssertEqual(h.sentCount, sentBefore)
        }
    }
}

// MARK: - Minimal doubles for the inertness pin

@MainActor
private final class InertMedia: CallMediaSession {
    var onConnected: (() -> Void)?
    var onFailed: (() -> Void)?
    var onRemoteEnded: (() -> Void)?
    func makeOffer() async throws -> String { "offer-sdp" }
    func makeAnswer(remoteOffer: String) async throws -> String { "answer-sdp" }
    func start(remoteAnswer: String) async throws {}
    func close() {}
}

@MainActor
private final class InertHarness {
    let controller: CallController
    private(set) var sentCount = 0
    private(set) var sessionsMade = 0

    init() {
        var send: ((CallSignal, Data) async throws -> Void)!
        var make: (() -> CallMediaSession)!
        controller = CallController(
            sendSignal: { signal, peer in try await send(signal, peer) },
            makeMediaSession: { make() })
        send = { [unowned self] _, _ in self.sentCount += 1 }
        make = { [unowned self] in self.sessionsMade += 1; return InertMedia() }
    }
}
