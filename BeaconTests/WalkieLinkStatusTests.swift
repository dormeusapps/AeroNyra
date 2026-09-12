//
//  WalkieLinkStatusTests.swift
//  BeaconTests
//
//  Pins `WalkieLinkStatus.derive` (live PTT-over-IP, step 5): the pure map
//  from the link engine's state to what ONE peer's walkie cover shows and
//  which press path it takes. The load-bearing bits: a link to ANOTHER peer
//  reads as `.notes` (the cover closes it, never adopts it), `isLink` is true
//  for every state in which PTTCaptureEngine must not run (opening OR open,
//  not only open), and a non-visible close reason reads as the shipped path.
//

import XCTest
@testable import Beacon

final class WalkieLinkStatusTests: XCTestCase {

    private let me   = Data(repeating: 0xA1, count: 32)
    private let them = Data(repeating: 0xB2, count: 32)
    private let id   = Data(repeating: 0x01, count: 16)

    func testNoEngineIsNotes() {
        XCTAssertEqual(WalkieLinkStatus.derive(from: nil, for: me), .notes)
        XCTAssertFalse(WalkieLinkStatus.notes.isLink)
    }

    func testIdleIsNotes() {
        XCTAssertEqual(WalkieLinkStatus.derive(from: .idle, for: me), .notes)
    }

    func testOpeningPhasesForThisPeer() {
        let reaching = WalkieLinkStatus.derive(
            from: .opening(linkID: id, peerKey: me, role: .initiator, phase: .awaitingAnswer), for: me)
        let connecting = WalkieLinkStatus.derive(
            from: .opening(linkID: id, peerKey: me, role: .initiator, phase: .connecting), for: me)
        XCTAssertEqual(reaching, .reaching)
        XCTAssertEqual(connecting, .connecting)
        XCTAssertTrue(reaching.isLink, "capture must not run while reaching")
        XCTAssertTrue(connecting.isLink, "capture must not run while connecting")
    }

    func testOpenForThisPeerIsLiveRegardlessOfRole() {
        XCTAssertEqual(WalkieLinkStatus.derive(from: .open(linkID: id, peerKey: me, role: .initiator), for: me), .live)
        XCTAssertEqual(WalkieLinkStatus.derive(from: .open(linkID: id, peerKey: me, role: .responder), for: me), .live,
                       "a responder link adopted through the chat is live in the cover")
        XCTAssertTrue(WalkieLinkStatus.live.isLink)
    }

    func testLinkToAnotherPeerReadsAsNotes() {
        XCTAssertEqual(WalkieLinkStatus.derive(
            from: .opening(linkID: id, peerKey: them, role: .responder, phase: .connecting), for: me), .notes)
        XCTAssertEqual(WalkieLinkStatus.derive(
            from: .open(linkID: id, peerKey: them, role: .responder), for: me), .notes)
    }

    func testVisibleCloseReasonsAreEndedAndNotLink() {
        for reason: PTTLinkController.CloseReason in
            [.unreachable, .remoteDeclined, .connectFailed, .remoteEnded, .interrupted, .failed] {
            let status = WalkieLinkStatus.derive(from: .closed(reason), for: me)
            XCTAssertEqual(status, .ended(reason))
            XCTAssertFalse(status.isLink, "\(reason): the shipped note path again")
            XCTAssertTrue(status.modeLabel(peerName: "Maya", near: false).hasSuffix("notes"), "\(reason) label names the fallback when FAR")
            XCTAssertEqual(status.modeLabel(peerName: "Maya", near: true), "walkie · near",
                           "\(reason): near, the failed attempt is irrelevant — a hold goes BLE-live")
        }
    }

    func testSilentCloseReasonsAreNotes() {
        XCTAssertEqual(WalkieLinkStatus.derive(from: .closed(.localClosed), for: me), .notes)
        XCTAssertEqual(WalkieLinkStatus.derive(from: .closed(.preempted), for: me), .notes)
    }

    func testLabelsFar() {
        XCTAssertEqual(WalkieLinkStatus.notes.modeLabel(peerName: "Maya", near: false), "walkie")
        XCTAssertEqual(WalkieLinkStatus.reaching.modeLabel(peerName: "Maya", near: false), "reaching Maya…")
        XCTAssertEqual(WalkieLinkStatus.live.modeLabel(peerName: "Maya", near: false), "walkie · live")
        XCTAssertEqual(WalkieLinkStatus.ended(.unreachable).modeLabel(peerName: "Maya", near: false),
                       "couldn't reach Maya · notes")
    }

    // MARK: Loop 7 (2026-09-12): the tier is the label's second input

    func testLabelsNear() {
        XCTAssertEqual(WalkieLinkStatus.notes.modeLabel(peerName: "Maya", near: true), "walkie · near")
        XCTAssertEqual(WalkieLinkStatus.ended(.connectFailed).modeLabel(peerName: "Maya", near: true),
                       "walkie · near", "the field symptom: 'couldn't connect · notes' while BLE audio flowed")
        // A link that EXISTS is still a link, near or not.
        XCTAssertEqual(WalkieLinkStatus.reaching.modeLabel(peerName: "Maya", near: true), "reaching Maya…")
        XCTAssertEqual(WalkieLinkStatus.connecting.modeLabel(peerName: "Maya", near: true), "connecting…")
        XCTAssertEqual(WalkieLinkStatus.live.modeLabel(peerName: "Maya", near: true), "walkie · live")
    }

    // MARK: Loop 7: the hold hint's second input is WHICH hold this is

    func testHintIdleAndMicOff() {
        XCTAssertEqual(WalkieLinkStatus.notes.hint(holding: false, holdIsLinkHold: false, micDenied: false), .holdToTalk)
        XCTAssertEqual(WalkieLinkStatus.live.hint(holding: true, holdIsLinkHold: false, micDenied: true), .micOff,
                       "mic denied wins over everything")
    }

    func testHintWhileOpeningIsKeepHolding() {
        for status in [WalkieLinkStatus.reaching, .connecting] {
            XCTAssertEqual(status.hint(holding: true, holdIsLinkHold: true, micDenied: false), .keepHolding)
        }
    }

    func testHintTransmittingOnLiveAndNotePaths() {
        XCTAssertEqual(WalkieLinkStatus.live.hint(holding: true, holdIsLinkHold: true, micDenied: false), .transmitting)
        XCTAssertEqual(WalkieLinkStatus.notes.hint(holding: true, holdIsLinkHold: false, micDenied: false), .transmitting)
    }

    func testHintAfterFailureDependsOnWhichHold() {
        let ended = WalkieLinkStatus.ended(.connectFailed)
        XCTAssertEqual(ended.hint(holding: true, holdIsLinkHold: true, micDenied: false), .nothingSent,
                       "the hold that began during opening and was refused: it sent nothing")
        XCTAssertEqual(ended.hint(holding: true, holdIsLinkHold: false, micDenied: false), .transmitting,
                       "a FRESH hold after the failure is on the note path and IS sending — the inverted-honesty bug")
        XCTAssertEqual(ended.hint(holding: false, holdIsLinkHold: false, micDenied: false), .holdToTalk)
    }
}
