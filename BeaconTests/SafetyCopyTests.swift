//
//  SafetyCopyTests.swift
//  BeaconTests
//
//  Guideline 1.2 copy rules, enforced by scanning the app's sources (the
//  LogHygieneTests approach: #filePath, run on the Mac that built them).
//  Copy that would no longer be true must not come back:
//   • reports are REVIEWED within 24 hours — never "answered";
//   • a blocked or reported chat STAYS in the chat list, marked — it is
//     never "removed from your chats" or "moved to Blocked Contacts";
//   • a report is never described as carrying no content or keys only
//     (it carries what the user sees in the preview);
//   • no unbuilt-feature notes left in the Terms (`// PENDING` comments).
//

import XCTest
@testable import Beacon

final class SafetyCopyTests: XCTestCase {

    /// App source folders (tests excluded: they quote the phrases).
    static let roots = ["Beacon", "Screens", "Core", "Security", "Stories", "DesignSystem"]

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// "path:line" for every source line containing `phrase` (case-insensitive).
    private func occurrences(of phrase: String) throws -> [String] {
        var found: [String] = []
        var scanned = 0
        for root in Self.roots {
            let dir = repoRoot.appendingPathComponent(root)
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
                XCTFail("source folder not found: \(dir.path)")
                return []
            }
            for case let url as URL in e where url.pathExtension == "swift" {
                scanned += 1
                let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                for (i, line) in lines.enumerated() where line.range(of: phrase, options: .caseInsensitive) != nil {
                    found.append("\(url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")):\(i + 1)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "precondition: the sources were actually scanned")
        return found
    }

    func testReportsAreNeverSaidToBeAnswered() throws {
        XCTAssertEqual(try occurrences(of: "answered within 24 hours"), [])
        XCTAssertEqual(try occurrences(of: "reviewed and answered"), [])
    }

    func testABlockedChatIsNeverSaidToLeaveTheChatList() throws {
        for phrase in ["removed from your chats", "moves to Blocked Contacts",
                       "restores the conversation to your main list",
                       "stays readable under Settings", "preserved here, unread by the water"] {
            XCTAssertEqual(try occurrences(of: phrase), [], phrase)
        }
    }

    func testReportCopyMatchesTheReport() throws {
        for phrase in ["never message content or keys", "fills in only"] {
            XCTAssertEqual(try occurrences(of: phrase), [], phrase)
        }
    }

    func testTheTermsHaveNoPendingNotes() throws {
        let url = repoRoot.appendingPathComponent("Beacon/TermsContent.swift")
        let pending = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("// PENDING") }
        XCTAssertEqual(pending, [])
    }

    /// Terms pages 3 and 4 describe the built block and report.
    func testTheTermsDescribeTheBuiltBlockAndReport() {
        let block = TermsContent.pages[2].paragraphs.joined(separator: " ")
        XCTAssertTrue(block.contains("swipe left on their chat"))
        XCTAssertTrue(block.contains("If you report them, they can never pair with you again."))
        XCTAssertTrue(block.contains("stays in your chats, marked as blocked or reported"))
        let report = TermsContent.pages[3].paragraphs.joined(separator: " ")
        XCTAssertTrue(report.contains("You can include what you know about the person"))
        XCTAssertTrue(report.contains("Photos, videos and voice notes are never included."))
        XCTAssertTrue(report.contains("can never pair with you again"))
        XCTAssertTrue(report.contains("contact the police first"))
        XCTAssertFalse(report.contains("picture"), "no screenshot in a report")
        XCTAssertFalse(report.contains("screenshot"))
    }
}
