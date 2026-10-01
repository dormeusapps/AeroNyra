//
//  ReportComposerTests.swift
//  BeaconTests
//
//  Pins how a report is sent (ReportComposer.swift): only a SENT report
//  applies report + block + never pair (cancelled, saved, failed change
//  nothing); the email is text only — no attachment and no image data in
//  any form — and the share-sheet fallback carries the same text.
//

import XCTest
import MessageUI
@testable import Beacon

final class ReportComposerTests: XCTestCase {

    private var draft: ReportDraft {
        var d = ReportDraft(reason: .threats, contactName: "Sam",
                            contactCode: ReportDraft.contactCode(forRawKey: Data(repeating: 4, count: 32)),
                            reportedMessageText: "a message",
                            appVersion: "1.0 (14)", reportedAt: Date(timeIntervalSince1970: 0))
        d.identity.name = "Sam Smith"
        d.whatHappened = "Threats."
        return d
    }

    // MARK: - result → actions

    func testOnlyASentReportAppliesTheReport() {
        XCTAssertTrue(ReportSendResult.sent.appliesReport)
        XCTAssertFalse(ReportSendResult.cancelled.appliesReport)
        XCTAssertFalse(ReportSendResult.saved.appliesReport, "a draft saved in Mail was not sent")
        XCTAssertFalse(ReportSendResult.failed.appliesReport)
    }

    func testMailResultsMap() {
        XCTAssertEqual(ReportSendResult(mail: .sent), .sent)
        XCTAssertEqual(ReportSendResult(mail: .saved), .saved)
        XCTAssertEqual(ReportSendResult(mail: .cancelled), .cancelled)
        XCTAssertEqual(ReportSendResult(mail: .failed), .failed)
    }

    func testShareResultsMap() {
        struct E: Error {}
        XCTAssertEqual(ReportSendResult(shareCompleted: true, error: nil), .sent)
        XCTAssertEqual(ReportSendResult(shareCompleted: false, error: nil), .cancelled)
        XCTAssertEqual(ReportSendResult(shareCompleted: true, error: E()), .failed)
    }

    // MARK: - text only

    func testTheEmailIsTheDraftAndGoesToSupport() {
        let email = ReportEmail(draft: draft)
        XCTAssertEqual(email.recipient, "support@dormeusapps.com")
        XCTAssertEqual(email.subject, draft.subject)
        XCTAssertEqual(email.body, draft.body)
    }

    func testAReportHasNoAttachmentAndNoImageDataInAnyForm() {
        let email = ReportEmail(draft: draft)
        // Every stored property is a String: there is nowhere to put an attachment.
        let children = Mirror(reflecting: email).children
        XCTAssertFalse(children.isEmpty)
        for child in children {
            XCTAssertTrue(child.value is String, "\(child.label ?? "?") is not text")
        }
        // The share sheet gets exactly one item, and it is text.
        let items = ReportShareSheet.activityItems(for: email)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items.allSatisfy { $0 is String })
        XCTAssertFalse(items.contains { $0 is Data || $0 is UIImage || $0 is URL })
        // No image smuggled in as text: data URIs or base64 PNG / JPEG / GIF / HEIC.
        for text in [email.body, email.subject, email.shareText] {
            for marker in ["data:image", "iVBORw0KGgo", "/9j/", "R0lGOD", "AAAAGGZ0eXBoZWlj"] {
                XCTAssertFalse(text.contains(marker), marker)
            }
        }
    }

    func testTheShareTextCarriesTheSameReport() {
        let email = ReportEmail(draft: draft)
        XCTAssertTrue(email.shareText.hasPrefix("To: support@dormeusapps.com\nSubject: \(email.subject)\n\n"))
        XCTAssertTrue(email.shareText.hasSuffix(email.body))
    }
}
