//
//  SafetyCopyTests.swift
//  BeaconTests
//
//  Guideline 1.2 copy rules, enforced by scanning the app's sources (the
//  LogHygieneTests approach: #filePath, run on the Mac that built them).
//  Copy that would no longer be true must not come back:
//   • reports are REVIEWED within 24 hours — never "answered";
//   • a blocked or reported chat STAYS in the chat list, marked — it is
//     never "removed from your chats" or "moved to Blocked Contacts".
//

import XCTest

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
}
