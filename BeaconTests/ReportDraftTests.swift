//
//  ReportDraftTests.swift
//  BeaconTests
//
//  Pins what a report's email contains (ReportMail.swift header rules):
//  fixed fields always; identity fields and "What happened" only when
//  filled; the reported message verbatim and only when switched on; the
//  content filter never consulted; a contact code instead of the key; no
//  local reference numbers.
//

import XCTest
import CryptoKit
@testable import Beacon

final class ReportDraftTests: XCTestCase {

    private let rawKey = Data((0..<32).map { UInt8($0) })

    private func draft(message: String? = nil) -> ReportDraft {
        ReportDraft(reason: .harassment,
                    contactName: "Sam",
                    contactCode: ReportDraft.contactCode(forRawKey: rawKey),
                    reportedMessageText: message,
                    appVersion: "1.0 (14)",
                    reportedAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - fixed fields

    func testAnEmptyReportCarriesOnlyTheFixedFields() {
        let body = draft().body
        XCTAssertEqual(body, """
        Reason: Harassment or bullying
        Contact (your name for them): Sam
        Contact code: \(ReportDraft.contactCode(forRawKey: rawKey))

        App version: 1.0 (14)
        Reported at: 1970-01-01T00:00:00Z
        """)
        XCTAssertFalse(body.contains("What you know"))
        XCTAssertFalse(body.contains("What happened"))
        XCTAssertFalse(body.contains("Reported message"))
    }

    func testTheSubjectNamesTheReason() {
        XCTAssertEqual(draft().subject, "AeroNyra report — Harassment or bullying")
    }

    // MARK: - identity fields

    func testOnlyFilledIdentityFieldsAppearUnderTheirHeadings() {
        var d = draft()
        d.identity.name = "Sam Smith"
        d.identity.howYouGotTheInvite = "  "      // whitespace only = empty
        d.identity.phone = " +1 555 0100 "
        let body = d.body
        XCTAssertTrue(body.contains("What you know about this person\nName: Sam Smith\nPhone: +1 555 0100"))
        XCTAssertFalse(body.contains("How you got their invite"))
        XCTAssertFalse(body.contains("Email or social media"))
        XCTAssertFalse(body.contains("How you know them"))
    }

    func testEveryIdentityFieldHasItsOwnHeading() {
        var d = draft()
        d.identity = ReportIdentityInfo(name: "a", phone: "b", emailOrSocial: "c",
                                        howYouKnowThem: "d", howYouGotTheInvite: "e")
        XCTAssertTrue(d.body.contains("""
        What you know about this person
        Name: a
        Phone: b
        Email or social media: c
        How you know them / where you met: d
        How you got their invite: e
        """))
    }

    func testWhatHappenedAppearsOnlyWhenFilled() {
        var d = draft()
        d.whatHappened = "\n  "
        XCTAssertFalse(d.body.contains("What happened"))
        d.whatHappened = "They kept messaging after I said stop."
        XCTAssertTrue(d.body.contains("What happened\nThey kept messaging after I said stop."))
    }

    // MARK: - reported message

    func testTheReportedMessageIsVerbatimAndSwitchable() {
        let text = "  exact text, spacing kept  "
        var d = draft(message: text)
        XCTAssertTrue(d.body.contains("Reported message\n\(text)\n"))
        d.includesReportedMessage = false
        XCTAssertFalse(d.body.contains("Reported message"))
        XCTAssertFalse(d.body.contains(text))
    }

    func testMediaMessagesAreOnlyPlaceholders() {
        XCTAssertEqual(ReportDraft.messageText(content: "", mediaMimeRaw: MediaMimeType.jpeg.rawValue), "[photo]")
        XCTAssertEqual(ReportDraft.messageText(content: "", mediaMimeRaw: MediaMimeType.mp4.rawValue), "[video]")
        XCTAssertEqual(ReportDraft.messageText(content: "", mediaMimeRaw: MediaMimeType.m4a.rawValue), "[voice note]")
        XCTAssertEqual(ReportDraft.messageText(content: "", mediaMimeRaw: "image/heic"), "[media]")
        XCTAssertEqual(ReportDraft.messageText(content: " hi ", mediaMimeRaw: nil), " hi ", "text is verbatim")
    }

    func testAContactReportCarriesNoMessageContent() {
        XCTAssertNil(draft().reportedMessageText)
        XCTAssertFalse(draft().body.contains("Reported message"))
    }

    @MainActor
    func testTheContentFilterIsNeverApplied() {
        // A text the filter blocks goes into the report verbatim, filter ON.
        let filtered = "you are a fucking idiot"
        XCTAssertTrue(ContentFilter.matches(filtered, userWords: ""), "precondition: the filter matches it")
        XCTAssertTrue(draft(message: filtered).body.contains(filtered))
    }

    // MARK: - contact code

    func testTheContactCodeIsDeterministicDomainSeparatedAndNotTheKey() {
        let code = ReportDraft.contactCode(forRawKey: rawKey)
        XCTAssertEqual(code, ReportDraft.contactCode(forRawKey: rawKey))
        XCTAssertNotEqual(code, ReportDraft.contactCode(forRawKey: Data(repeating: 1, count: 32)))
        // Domain-separated: not a plain hash of the key.
        let plain = SHA256.hash(data: rawKey).prefix(16).map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(code.replacingOccurrences(of: " ", with: ""), plain)
        // Not the key itself, spaced or not.
        let keyHex = rawKey.map { String(format: "%02x", $0) }.joined()
        XCTAssertFalse(code.replacingOccurrences(of: " ", with: "").contains(String(keyHex.prefix(8))))
        // 16 bytes, hex, eight groups of four.
        XCTAssertEqual(code.split(separator: " ").count, 8)
        XCTAssertTrue(code.split(separator: " ").allSatisfy { $0.count == 4 })
    }

    func testTheBodyNeverCarriesTheKeyOrReferenceNumbers() {
        var d = draft(message: "hi")
        d.identity.name = "x"
        d.whatHappened = "y"
        let body = d.body.lowercased()
        let hex = rawKey.map { String(format: "%02x", $0) }.joined()
        XCTAssertFalse(body.contains(hex), "no raw key in hex")
        XCTAssertFalse(body.contains(String(hex.prefix(12))), "no key prefix either")
        XCTAssertFalse(body.contains(rawKey.base64EncodedString().lowercased()))
        XCTAssertFalse(body.contains("ref"), "no conversation or message reference numbers")
        XCTAssertNil(body.range(of: #"[0-9a-f]{8}-[0-9a-f]{4}-"#, options: .regularExpression), "no UUIDs")
    }
}

/// The plain "Report a problem" email (ReportMail.url): version and time, the
/// nickname only when given, no reference numbers.
final class ReportMailTests: XCTestCase {

    func testAProblemReportCarriesOnlyTheVersionAndTime() {
        let body = ReportMail.body(contactNickname: nil, at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(body.contains("App version: "))
        XCTAssertTrue(body.contains("Reported at: 1970-01-01T00:00:00Z"))
        XCTAssertFalse(body.contains("Contact"))
        XCTAssertFalse(body.contains("ref"))
    }

    func testTheNicknameIsAddedOnlyWhenGiven() {
        XCTAssertTrue(ReportMail.body(contactNickname: "Sam").contains("Contact (your local nickname): Sam"))
        XCTAssertFalse(ReportMail.body(contactNickname: "  ").contains("Contact"))
    }
}
