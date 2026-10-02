//
//  UnblockConfirmTests.swift
//  BeaconTests
//
//  Pins the Unblock UI (v68 §5a, commit C5): the confirm alert tells the user
//  that what the contact sent while blocked won't appear; EVERY Unblock goes
//  through that one "Unblock [name]?" confirm (BlockConfirmations) — the only
//  production call into `PairingService.unblock` lives there; the Blocked
//  contacts list names an unnamed contact the way Home and contact settings
//  do; a reported contact is offered no Unblock anywhere.
//

import XCTest
@testable import Beacon

final class UnblockConfirmTests: XCTestCase {

    /// App source folders (tests excluded).
    private static let roots = ["Beacon", "Screens", "Core", "Security", "Stories", "DesignSystem"]

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Repo-relative path and text of every production Swift file.
    private func sources() throws -> [(path: String, text: String)] {
        var out: [(String, String)] = []
        for root in Self.roots {
            let dir = repoRoot.appendingPathComponent(root)
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
                XCTFail("source folder not found: \(dir.path)")
                return []
            }
            for case let url as URL in e where url.pathExtension == "swift" {
                out.append((url.path.replacingOccurrences(of: repoRoot.path + "/", with: ""),
                            try String(contentsOf: url, encoding: .utf8)))
            }
        }
        XCTAssertGreaterThan(out.count, 100, "precondition: the sources were actually scanned")
        return out
    }

    // MARK: - Copy

    func testTheUnblockAlertSaysWhatWasSentWhileBlockedWontAppear() {
        XCTAssertEqual(BlockCopy.unblockMessage,
                       "They can message you again, and your chat goes back to normal. Messages they sent while blocked won't appear.")
        XCTAssertEqual(BlockCopy.unblockTitle("Sam"), "Unblock Sam?")
    }

    // MARK: - Every Unblock is confirmed

    func testTheOnlyProductionUnblockCallIsTheConfirmAlerts() throws {
        let callers = try sources().filter { $0.text.contains(".unblock(rawKey:") }.map(\.path)
        XCTAssertEqual(callers, ["Beacon/BlockConfirmations.swift"],
                       "every Unblock must go through the \"Unblock [name]?\" confirm")
    }

    func testEveryScreenThatOffersUnblockAppliesTheConfirm() throws {
        let screens = try sources().filter {
            $0.path != "Beacon/BlockConfirmations.swift" && $0.text.contains("\"Unblock\"")
        }
        XCTAssertEqual(Set(screens.map(\.path)),
                       ["Screens/HomeView.swift", "Screens/PeerSettingsView.swift",
                        "Screens/BlockedContactsView.swift"],
                       "precondition: the known Unblock entry points")
        for screen in screens {
            XCTAssertTrue(screen.text.contains(".blockConfirmations("),
                          "\(screen.path) offers Unblock without the confirm alert")
        }
    }

    func testTheBlockedListAsksToConfirmTheRightContact() {
        let key = Data([0x3f, 0xa2, 0xc1, 0x09, 0x77, 0x10] + Array(repeating: 0, count: 26))
        let named = BlockedContact(rawKey: key, blockedAt: 1, petname: "  Sam \n", wasVerified: true)
        let unnamed = BlockedContact(rawKey: key, blockedAt: 1, petname: nil, wasVerified: true)
        let blank = BlockedContact(rawKey: key, blockedAt: 1, petname: "  ", wasVerified: true)

        let request = BlockedContactsView.unblockRequest(for: named)
        XCTAssertEqual(request.kind, .unblock)
        XCTAssertEqual(request.rawKey, key)
        XCTAssertEqual(request.name, "Sam")
        // Home and contact settings: the first six hex of the key, uppercased.
        XCTAssertEqual(BlockedContactsView.unblockRequest(for: unnamed).name, "3FA2C1")
        XCTAssertEqual(BlockedContactsView.unblockRequest(for: blank).name, "3FA2C1")
    }

    // MARK: - Reported: no Unblock anywhere

    func testAReportedContactIsOfferedNoUnblockAnywhere() {
        let reported = BlockedContact(rawKey: Data(repeating: 1, count: 32), blockedAt: 1,
                                      petname: nil, wasVerified: true, reported: true)
        XCTAssertFalse(BlockedContactsView.offersUnblock(reported), "Blocked contacts list")
        XCTAssertFalse(ChatActions.row(.reported).contains(.unblock), "Home long-press + VoiceOver")
        XCTAssertTrue(ChatActions.row(.blocked).contains(.unblock), "precondition: a plain block offers it")
    }

    func testContactSettingsShowAFixedReportedRowAndNoUnblock() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("Screens/PeerSettingsView.swift"),
                              encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "case .reported:"))
        let end = try XCTUnwrap(text.range(of: "private var blockFooter", range: start.upperBound..<text.endIndex))
        let reportedArm = text[start.upperBound..<end.lowerBound]
        XCTAssertTrue(reportedArm.contains("Text(\"Reported\")"))
        XCTAssertFalse(reportedArm.contains("Unblock"), "a reported contact has no Unblock in contact settings")
        XCTAssertFalse(reportedArm.contains("blockButton("))
    }
}
