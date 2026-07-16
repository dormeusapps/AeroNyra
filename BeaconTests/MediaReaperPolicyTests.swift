// MediaReaperPolicyTests.swift
// BeaconTests
//
// Unit tests for MediaEphemeralityPolicy.isExpired — the pure per-row expiry
// decision the MessageInbox reaper applies. Hoisted precisely so this file
// can test the REAL rule, not a copy: v1 video messages expire like photos
// (photoWindow after arrival, non-story only), stories keep their own 8h
// send-anchored window, voice stays listen-armed inbound and delivery-armed
// outbound. Direction lives in two places OUTSIDE this pure function: the
// reaper's fetch predicate (which outbound rows are even fetched) and the
// `deliveryState` bridge's outbound-only `deliveredAt` stamp (inbound rows
// are created `.delivered` as a display state, so a direction-blind stamp
// would expire unlistened inbound notes) — the bridge gate is pinned below.
//

import XCTest
@testable import Beacon

final class MediaReaperPolicyTests: XCTestCase {

    /// Fixed clock so the window edges are exact.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // v1 VIDEO MESSAGES: a non-story video expires exactly like a photo.
    func testNonStoryVideoExpiresAtPhotoWindow() {
        XCTAssertTrue(MediaEphemeralityPolicy.isExpired(
            isStory: false, mime: .mp4,
            timestamp: now.addingTimeInterval(-(MediaEphemeralityPolicy.photoWindow + 1)),
            sentAt: nil, listenedAt: nil, now: now),
            "a non-story video older than photoWindow must expire")
        XCTAssertFalse(MediaEphemeralityPolicy.isExpired(
            isStory: false, mime: .mp4,
            timestamp: now.addingTimeInterval(-(MediaEphemeralityPolicy.photoWindow - 60)),
            sentAt: nil, listenedAt: nil, now: now),
            "a non-story video inside photoWindow must survive")
    }

    // The new video rule must NOT leak into stories: a story video is governed
    // by storyWindow-from-sent alone, whatever its arrival age.
    func testStoryVideoIgnoresPhotoWindow() {
        XCTAssertFalse(MediaEphemeralityPolicy.isExpired(
            isStory: true, mime: .mp4,
            timestamp: now.addingTimeInterval(-(MediaEphemeralityPolicy.photoWindow * 2)),
            sentAt: now.addingTimeInterval(-60),
            listenedAt: nil, now: now),
            "a freshly-sent story video must not expire on the photo rule")
        XCTAssertTrue(MediaEphemeralityPolicy.isExpired(
            isStory: true, mime: .mp4,
            timestamp: now,
            sentAt: now.addingTimeInterval(-(MediaEphemeralityPolicy.storyWindow + 1)),
            listenedAt: nil, now: now),
            "a story video past storyWindow-from-sent must expire")
    }

    // Pre-existing kinds are byte-identical in behavior.
    func testPhotoVoiceAndUnknownRegression() {
        // Photo: expires at photoWindow from arrival.
        XCTAssertTrue(MediaEphemeralityPolicy.isExpired(
            isStory: false, mime: .jpeg,
            timestamp: now.addingTimeInterval(-(MediaEphemeralityPolicy.photoWindow + 1)),
            sentAt: nil, listenedAt: nil, now: now))
        XCTAssertFalse(MediaEphemeralityPolicy.isExpired(
            isStory: false, mime: .jpeg,
            timestamp: now.addingTimeInterval(-(MediaEphemeralityPolicy.photoWindow - 60)),
            sentAt: nil, listenedAt: nil, now: now))
        // Voice: unlistened never expires — even ancient.
        XCTAssertFalse(MediaEphemeralityPolicy.isExpired(
            isStory: false, mime: .m4a,
            timestamp: now.addingTimeInterval(-(MediaEphemeralityPolicy.photoWindow * 30)),
            sentAt: nil, listenedAt: nil, now: now),
            "an unlistened voice note never expires — listen-armed by design")
        // Voice: expires voiceListenWindow after listening.
        XCTAssertTrue(MediaEphemeralityPolicy.isExpired(
            isStory: false, mime: .m4a,
            timestamp: now,
            sentAt: nil,
            listenedAt: now.addingTimeInterval(-(MediaEphemeralityPolicy.voiceListenWindow + 1)),
            now: now))
        // Unknown kind: left alone.
        XCTAssertFalse(MediaEphemeralityPolicy.isExpired(
            isStory: false, mime: nil,
            timestamp: now.addingTimeInterval(-(MediaEphemeralityPolicy.photoWindow * 30)),
            sentAt: nil, listenedAt: nil, now: now))
    }

    // SENDER-SIDE VOICE WIPE: an outbound note expires voiceListenWindow after
    // first confirmed receipt (`deliveredAt`), and not a moment before.
    func testOutboundVoiceExpiresAfterDeliveredWindow() {
        XCTAssertTrue(MediaEphemeralityPolicy.isExpired(
            isStory: false, mime: .m4a,
            timestamp: now, sentAt: nil, listenedAt: nil,
            deliveredAt: now.addingTimeInterval(-(MediaEphemeralityPolicy.voiceListenWindow + 1)),
            now: now),
            "an outbound voice note past voiceListenWindow-from-delivery must expire")
        XCTAssertFalse(MediaEphemeralityPolicy.isExpired(
            isStory: false, mime: .m4a,
            timestamp: now, sentAt: nil, listenedAt: nil,
            deliveredAt: now.addingTimeInterval(-(MediaEphemeralityPolicy.voiceListenWindow - 1)),
            now: now),
            "an outbound voice note inside the delivery window must survive")
    }

    // An unconfirmed outbound note never expires — its blob is the resend
    // source (`.notDelivered` forever, or `.cast` awaiting a real receipt).
    func testOutboundVoiceWithoutDeliveryNeverExpires() {
        XCTAssertFalse(MediaEphemeralityPolicy.isExpired(
            isStory: false, mime: .m4a,
            timestamp: now.addingTimeInterval(-(MediaEphemeralityPolicy.photoWindow * 30)),
            sentAt: nil, listenedAt: nil, deliveredAt: nil, now: now),
            "an outbound voice note with no delivery confirmation never expires — even ancient")
    }

    // ANCHOR PRECEDENCE: when both anchors are somehow set, the listen anchor
    // governs — a freshly-listened note survives even under an ancient
    // delivery stamp.
    func testListenAnchorTakesPrecedenceOverDelivered() {
        XCTAssertFalse(MediaEphemeralityPolicy.isExpired(
            isStory: false, mime: .m4a,
            timestamp: now, sentAt: nil,
            listenedAt: now.addingTimeInterval(-(MediaEphemeralityPolicy.voiceListenWindow - 30)),
            deliveredAt: now.addingTimeInterval(-(MediaEphemeralityPolicy.voiceListenWindow * 100)),
            now: now),
            "listenedAt must govern when both anchors exist — deliveredAt never overrides it")
    }

    // THE BRIDGE GATE: every persisted inbound row is created `.delivered`
    // (its display state). The `deliveryState` bridge must refuse to turn that
    // into a wipe anchor, or an UNLISTENED inbound note would expire 120s
    // after arrival. Composed end-to-end: model stamp → policy verdict.
    func testInboundRowNeverGainsDeliveredAnchor() {
        let inbound = Message(content: "", isOutbound: false,
                              deliveryState: .delivered,
                              mediaData: Data([0x01]), mediaMimeRaw: "m4a")
        XCTAssertNil(inbound.deliveredAt,
            "the bridge must never stamp deliveredAt on an inbound row — not at init")
        inbound.deliveryState = .relayed(hops: 2)
        XCTAssertNil(inbound.deliveredAt,
            "…and not via a later assignment either")
        XCTAssertFalse(MediaEphemeralityPolicy.isExpired(
            isStory: false, mime: .m4a,
            timestamp: now.addingTimeInterval(-(MediaEphemeralityPolicy.photoWindow * 30)),
            sentAt: nil, listenedAt: nil, deliveredAt: inbound.deliveredAt, now: now),
            "an unlistened inbound note stays listen-armed forever, whatever its delivery state")

        // The outbound twin DOES stamp — once, on first confirmation only.
        let outbound = Message(content: "", isOutbound: true, deliveryState: .sent)
        XCTAssertNil(outbound.deliveredAt, "no anchor before confirmation")
        outbound.deliveryState = .delivered
        let first = outbound.deliveredAt
        XCTAssertNotNil(first, "first confirmation stamps the anchor")
        outbound.deliveryState = .relayed(hops: 1)
        XCTAssertEqual(outbound.deliveredAt, first,
            "a repeat/upgraded confirmation must never slide the wipe window")
    }
}
