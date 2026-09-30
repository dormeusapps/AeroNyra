//
//  ContentFilterIntroTests.swift
//  BeaconTests
//
//  Pins the Content filter screen's first-time explanation: shown once per
//  install, and Erase (DeviceResidueWipe) shows it again. Also pins that the
//  wipe's key constants match the ones the app writes.
//

import XCTest
@testable import Beacon

@MainActor
final class ContentFilterIntroTests: XCTestCase {

    func testShownOnceThenNotAgain() {
        let name = "content-filter-intro.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(ContentFilterIntro.takeFirstShow(defaults))
        XCTAssertFalse(ContentFilterIntro.takeFirstShow(defaults))
        XCTAssertFalse(ContentFilterIntro.takeFirstShow(defaults))
    }

    func testKeysMatchTheWipe() {
        XCTAssertEqual(DeviceResidueWipe.contentFilterIntroShownKey, ContentFilterIntro.shownKey)
        XCTAssertEqual(DeviceResidueWipe.contentFilterEnabledKey, ContentFilter.enabledKey)
        XCTAssertEqual(DeviceResidueWipe.contentFilterWordsKey, ContentFilter.wordsKey)
    }

    /// Erase: the residue wipe clears the flag, so the explanation shows again.
    func testEraseShowsItAgain() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: ContentFilterIntro.shownKey)
        addTeardownBlock { defaults.set(saved, forKey: ContentFilterIntro.shownKey) }

        defaults.set(true, forKey: ContentFilterIntro.shownKey)
        XCTAssertFalse(ContentFilterIntro.takeFirstShow(defaults))
        try await DeviceResidueWipe().wipe()
        XCTAssertNil(defaults.object(forKey: ContentFilterIntro.shownKey))
        XCTAssertTrue(ContentFilterIntro.takeFirstShow(defaults))
    }
}
