//
//  PairRefusalCopyTests.swift
//  BeaconTests
//
//  Pins the pairing screen's refusal lines (Guideline 1.2, v68 §5b): a
//  REPORTED identity is refused with its own line — it can never be
//  unblocked, so it must never be told to unblock — and a plain-blocked one
//  keeps the unblock line. Source scans (the SafetyCopyTests approach) pin
//  that all three refusal sites (tapped invite, scan, paste) use the shared
//  copy and that neither line is written inline anywhere else.
//

import XCTest
@testable import Beacon

final class PairRefusalCopyTests: XCTestCase {

    /// App source folders (tests excluded: they quote the phrases).
    static let roots = ["Beacon", "Screens", "Core", "Security", "Stories", "DesignSystem"]

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// "path" for every source line containing `phrase` (exact case).
    private func files(containing phrase: String) throws -> [String] {
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
                for line in lines where line.contains(phrase) {
                    found.append(url.path.replacingOccurrences(of: repoRoot.path + "/", with: ""))
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "precondition: the sources were actually scanned")
        return found.sorted()
    }

    func testTheReportedLineIsExact() {
        XCTAssertEqual(PairRefusalCopy.reported,
                       "you reported this contact — they can never pair with you again")
    }

    func testTheBlockedLineIsUnchanged() {
        XCTAssertEqual(PairRefusalCopy.blocked,
                       "this contact is blocked — unblock them in Settings to pair again")
    }

    func testTheReportedLineNeverSaysUnblock() {
        XCTAssertNil(PairRefusalCopy.reported.range(of: "unblock", options: .caseInsensitive))
    }

    func testEveryRefusalSiteUsesTheSharedCopy() throws {
        let sites = ["Beacon/ContentView.swift", "Screens/PairingView.swift", "Screens/PairingView.swift"]
        XCTAssertEqual(try files(containing: "catch PairingService.PairError.reported"), sites)
        XCTAssertEqual(try files(containing: "= PairRefusalCopy.reported"), sites)
        XCTAssertEqual(try files(containing: "= PairRefusalCopy.blocked"), sites)
    }

    func testNeitherLineIsWrittenInlineElsewhere() throws {
        XCTAssertEqual(try files(containing: "this contact is blocked — unblock"),
                       ["Beacon/PairRefusalCopy.swift"])
        XCTAssertEqual(try files(containing: "you reported this contact — they"),
                       ["Beacon/PairRefusalCopy.swift"])
    }
}
