//
//  TermsPagerTests.swift
//  BeaconTests
//
//  Pins the Terms of Use pages: the gate cannot be accepted without agreeing
//  to every page in order, the Accept fires once, going back keeps pages
//  agreed, the read-only (Settings) mode never offers an agreement, and no
//  page ships pending copy.
//

import XCTest
@testable import Beacon

final class TermsPagerTests: XCTestCase {

    func testSixPagesAgeFirstAcceptLast() {
        let pages = TermsContent.pages
        XCTAssertEqual(pages.count, 6)
        XCTAssertEqual(pages.first?.agreeLabel, "I am 18 or older")
        XCTAssertEqual(pages.last?.agreeLabel, "Accept & Continue")
    }

    /// Copy for unbuilt features lives in PENDING comments, never in strings.
    func testNoPendingCopyShips() {
        for page in TermsContent.pages {
            for text in [page.title, page.agreeLabel] + page.paragraphs {
                XCTAssertFalse(text.contains("PENDING"), text)
                XCTAssertFalse(text.contains("["), text)
            }
        }
    }

    /// Page 5 describes the built filter (drop, no reveal, sender block,
    /// where the switch is); page 6 points to Safety & Support.
    func testFilterAndSupportPagesMatchTheBuild() {
        let filter = TermsContent.pages[4].paragraphs.joined(separator: " ")
        XCTAssertFalse(filter.localizedCaseInsensitiveContains("tap"), filter)
        XCTAssertTrue(filter.contains("never shown, stored or notified"))
        XCTAssertTrue(filter.contains("isn't sent"))
        XCTAssertTrue(filter.contains("Settings › Safety & Support › Content filter"))
        let support = TermsContent.pages[5].paragraphs.joined(separator: " ")
        XCTAssertTrue(support.contains("under Safety & Support"))
    }

    func testGateAgreesEachPageThenAcceptsOnce() {
        var pager = TermsPager(mode: .gate)
        let pages = TermsContent.pages
        for i in 0..<(pages.count - 1) {
            XCTAssertEqual(pager.index, i)
            XCTAssertEqual(pager.primary, .agree(pages[i].agreeLabel))
            XCTAssertEqual(pager.tapPrimary(), .stay)
        }
        XCTAssertTrue(pager.isLast)
        XCTAssertEqual(pager.primary, .agree("Accept & Continue"))
        XCTAssertEqual(pager.tapPrimary(), .accepted)
        XCTAssertEqual(pager.agreed, Set(0..<pages.count))
        // A second tap (double tap) must not accept again.
        XCTAssertEqual(pager.tapPrimary(), .stay)
    }

    func testGateNeverAcceptsBeforeLastPage() {
        var pager = TermsPager(mode: .gate)
        for _ in 0..<(pager.pages.count - 1) {
            XCTAssertNotEqual(pager.tapPrimary(), .accepted)
        }
    }

    func testBackKeepsAgreedPagesAgreed() {
        var pager = TermsPager(mode: .gate)
        XCTAssertFalse(pager.canGoBack)
        _ = pager.tapPrimary()          // agree page 1
        _ = pager.tapPrimary()          // agree page 2
        XCTAssertEqual(pager.index, 2)
        pager.back()
        XCTAssertEqual(pager.index, 1)
        XCTAssertTrue(pager.isAgreed)
        XCTAssertEqual(pager.primary, .proceed)
        pager.back()
        XCTAssertEqual(pager.primary, .proceed)
        pager.back()                    // already at page 1: stays
        XCTAssertEqual(pager.index, 0)
        _ = pager.tapPrimary()
        _ = pager.tapPrimary()
        XCTAssertEqual(pager.index, 2)
        XCTAssertEqual(pager.primary, .agree(TermsContent.pages[2].agreeLabel))
    }

    /// Settings mode: Next / Done only, never an agreement, never an accept.
    func testReadOnlyOffersNoAgreement() {
        var pager = TermsPager(mode: .readOnly)
        var seen: [TermsPager.Primary] = []
        var outcomes: [TermsPager.Outcome] = []
        for _ in 0..<pager.pages.count {
            seen.append(pager.primary)
            outcomes.append(pager.tapPrimary())
        }
        XCTAssertEqual(seen, Array(repeating: .next, count: pager.pages.count - 1) + [.done])
        XCTAssertEqual(outcomes.last, .dismissed)
        XCTAssertFalse(outcomes.contains(.accepted))
        XCTAssertTrue(pager.agreed.isEmpty)
    }
}
