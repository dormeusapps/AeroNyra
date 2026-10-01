//
//  ChatSafetyStateTests.swift
//  BeaconTests
//
//  Pins the blocked/reported tables the views read (ChatSafetyState.swift):
//  Home keeps blocked and reported chats with the right label; a blocked or
//  reported chat is read-only (no composer, no verify-gate, no call or
//  walkie); Report is offered on a blocked chat but not a reported one; a
//  reported row has no swipe actions.
//

import XCTest
@testable import Beacon

final class ChatSafetyStateTests: XCTestCase {

    private let a = Data(repeating: 1, count: 32)
    private let b = Data(repeating: 2, count: 32)
    private let c = Data(repeating: 3, count: 32)

    private var denylist: [BlockedContact] {
        [BlockedContact(rawKey: b, blockedAt: 1, petname: nil, wasVerified: false),
         BlockedContact(rawKey: c, blockedAt: 2, petname: nil, wasVerified: true, reported: true)]
    }

    // MARK: - ChatSafety

    func testSafetyComesFromTheDenylist() {
        XCTAssertEqual(ChatSafety.of(a, in: denylist), .normal)
        XCTAssertEqual(ChatSafety.of(b, in: denylist), .blocked)
        XCTAssertEqual(ChatSafety.of(c, in: denylist), .reported)
        XCTAssertNil(ChatSafety.normal.label)
        XCTAssertEqual(ChatSafety.blocked.label, "blocked")
        XCTAssertEqual(ChatSafety.reported.label, "reported")
    }

    // MARK: - ChatRoster

    func testTheRosterKeepsBlockedAndReportedChatsLabelledAndSortedByName() {
        let items: [(key: Data, name: String)] = [(c, "Cara"), (a, "alex"), (b, "Ben")]
        let rows = ChatRoster.rows(items, key: \.key, name: \.name, blocked: denylist)
        XCTAssertEqual(rows.map(\.item.name), ["alex", "Ben", "Cara"], "everyone stays, sorted by name")
        XCTAssertEqual(rows.map(\.safety), [.normal, .blocked, .reported])
    }

    // MARK: - ChatMode

    func testABlockedOrReportedChatIsReadOnly() {
        for safety in [ChatSafety.blocked, .reported] {
            for verified in [true, false] {
                let mode = ChatMode.of(safety: safety, verified: verified)
                XCTAssertEqual(mode, .readOnly(safety))
                XCTAssertFalse(mode.showsComposer, "no composer")
                XCTAssertFalse(mode.showsVerifyGate, "no verify-gate")
                XCTAssertFalse(mode.showsCallButtons, "no call, video or walkie")
            }
        }
    }

    func testANormalChatIsUnchanged() {
        let verified = ChatMode.of(safety: .normal, verified: true)
        XCTAssertEqual(verified, .composer)
        XCTAssertTrue(verified.showsComposer)
        XCTAssertTrue(verified.showsCallButtons)
        let unverified = ChatMode.of(safety: .normal, verified: false)
        XCTAssertEqual(unverified, .verifyGate)
        XCTAssertTrue(unverified.showsVerifyGate)
        XCTAssertTrue(unverified.showsCallButtons)
    }

    // MARK: - ChatActions

    func testRowActions() {
        XCTAssertEqual(ChatActions.row(.normal), [.block, .report])
        XCTAssertEqual(ChatActions.row(.blocked), [.unblock, .report])
        XCTAssertEqual(ChatActions.row(.reported), [], "no actions on a reported row")
    }

    func testReportIsOfferedOnABlockedChatButNotAReportedOne() {
        XCTAssertTrue(ChatActions.offersReport(.normal))
        XCTAssertTrue(ChatActions.offersReport(.blocked))
        XCTAssertFalse(ChatActions.offersReport(.reported))
    }

    func testDeletingFromAReportedChatWarnsFirst() {
        XCTAssertFalse(ChatActions.warnsBeforeDeleting(.normal))
        XCTAssertFalse(ChatActions.warnsBeforeDeleting(.blocked))
        XCTAssertTrue(ChatActions.warnsBeforeDeleting(.reported))
        XCTAssertEqual(ChatActions.evidenceWarning(name: "Sam"),
                       "This deletes your evidence. Sam still can't pair with you again.")
    }
}
