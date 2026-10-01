//
//  ReportFlowCopyTests.swift
//  BeaconTests
//
//  Pins the report flow's approved copy (ReportFlowView.swift): the first
//  screen asks who the person is, word for word, and the preview carries the
//  safety line.
//

import XCTest
@testable import Beacon

final class ReportFlowCopyTests: XCTestCase {

    func testTheFirstScreenAsksWhoThePersonIs() {
        XCTAssertEqual(ReportFlowCopy.whoTitle, "Who is this person?")
        XCTAssertEqual(ReportFlowCopy.whoBody,
                       "AeroNyra has no accounts or phone numbers, so we can't tell who this person is from the app. You paired with them, so you may know. Please include anything that helps identify them: their name, phone number, email, social media, where you met, and how you got their invite.\n\nIf a crime has happened or you're in danger, contact the police first. Reports to us help us spot patterns and improve AeroNyra's safety.")
    }

    func testThePreviewCarriesTheSafetyLine() {
        XCTAssertEqual(ReportFlowCopy.safetyLine,
                       "Don't attach photos. Keep this chat; it stays in your app as evidence.")
        XCTAssertEqual(ReportFlowCopy.previewLead,
                       "This is everything the email will contain. The developer will also see your email address.")
    }
}
