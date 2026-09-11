//
//  WalkieSettingsTests.swift
//  BeaconTests
//
//  Pins the kill switch's read: default-on when the key is absent (the trap
//  is `bool(forKey:)` reading false for an absent key), off when stored
//  false, on when stored true. Isolated suite so nothing touches `.standard`.
//

import XCTest
@testable import Beacon

final class WalkieSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "WalkieSettingsTests.isolated"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testAbsentKeyReadsAllowed() {
        XCTAssertTrue(WalkieSettings.allowsInbound(defaults), "default ON — never inverted by an absent key")
    }

    func testStoredFalseReadsRefused() {
        defaults.set(false, forKey: WalkieSettings.allowInboundKey)
        XCTAssertFalse(WalkieSettings.allowsInbound(defaults))
    }

    func testStoredTrueReadsAllowed() {
        defaults.set(true, forKey: WalkieSettings.allowInboundKey)
        XCTAssertTrue(WalkieSettings.allowsInbound(defaults))
    }

    func testKeyMatchesTheWipeList() {
        XCTAssertEqual(WalkieSettings.allowInboundKey, DeviceResidueWipe.walkieAllowInboundKey,
                       "the residue wipe must clear the same key the toggle writes")
    }
}
