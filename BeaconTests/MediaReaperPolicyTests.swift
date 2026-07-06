// MediaReaperPolicyTests.swift
// BeaconTests
//
// Unit tests for MediaEphemeralityPolicy.isExpired — the pure per-row expiry
// decision the MessageInbox reaper applies. Hoisted precisely so this file
// can test the REAL rule, not a copy: v1 video messages expire like photos
// (photoWindow after arrival, non-story only), stories keep their own 8h
// send-anchored window, voice stays listen-armed. Direction exclusion
// (outbound non-story rows never reaped) lives in the reaper's fetch
// predicate, not here.
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
}
