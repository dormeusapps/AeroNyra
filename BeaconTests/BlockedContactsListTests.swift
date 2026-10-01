//
//  BlockedContactsListTests.swift
//  BeaconTests
//
//  Pins Settings › Blocked contacts for reported entries
//  (BlockedContactsView.swift): a reported contact is labelled "reported"
//  and offered no Unblock; a plain block keeps its Unblock.
//

import XCTest
@testable import Beacon

final class BlockedContactsListTests: XCTestCase {

    private let key = Data(repeating: 5, count: 32)

    func testAReportedContactIsLabelledAndCannotBeUnblocked() {
        let entry = BlockedContact(rawKey: key, blockedAt: 0, petname: "Sam", wasVerified: false, reported: true)
        XCTAssertFalse(BlockedContactsView.offersUnblock(entry))
        XCTAssertTrue(BlockedContactsView.subtitle(for: entry).hasPrefix("reported · blocked "))
    }

    func testAPlainBlockKeepsItsUnblock() {
        let entry = BlockedContact(rawKey: key, blockedAt: 0, petname: "Sam", wasVerified: false)
        XCTAssertTrue(BlockedContactsView.offersUnblock(entry))
        XCTAssertTrue(BlockedContactsView.subtitle(for: entry).hasPrefix("blocked "))
        XCTAssertFalse(BlockedContactsView.subtitle(for: entry).contains("reported"))
    }
}
