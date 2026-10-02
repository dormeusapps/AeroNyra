//
//  FirstUnlockAssumptionTests.swift
//  BeaconTests
//
//  TRIPWIRE for `BlockHistoryStore` (v68 §5a). The store loads once at init
//  and treats an unreadable file as damaged for the life of the process. That
//  is safe only because nothing can launch Beacon before the device's first
//  unlock: the only background modes are Bluetooth, with no state
//  restoration, no background tasks, no push, no VoIP. If any of that
//  changes, a launch before first unlock would see the file as unreadable and
//  refuse Unblock until relaunch — so the store needs a retryable "locked"
//  state first. These tests fail the moment that assumption changes.
//

import XCTest

final class FirstUnlockAssumptionTests: XCTestCase {

    private static let message =
        "BlockHistoryStore assumes no launch before first unlock — add the retryable locked state first."

    /// App source folders (tests excluded).
    private static let roots = ["Beacon", "Screens", "Core", "Security", "Stories", "DesignSystem"]

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    func testTheOnlyBackgroundModesAreBluetooth() throws {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Beacon/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil)
                                    as? [String: Any])
        let modes = plist["UIBackgroundModes"] as? [String] ?? []
        XCTAssertEqual(modes.sorted(), ["bluetooth-central", "bluetooth-peripheral"], Self.message)
    }

    func testNoBackgroundRelaunchPathExistsInTheSource() throws {
        let forbidden = ["CBCentralManagerOptionRestoreIdentifierKey",
                         "CBPeripheralManagerOptionRestoreIdentifierKey",
                         "willRestoreState",
                         "BGTaskScheduler",
                         "PushKit",
                         "registerForRemoteNotifications",
                         "CXProvider"]
        var scanned = 0
        for root in Self.roots {
            let dir = repoRoot.appendingPathComponent(root)
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
                XCTFail("source folder not found: \(dir.path)")
                return
            }
            for case let url as URL in e where url.pathExtension == "swift" {
                scanned += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                for token in forbidden where text.contains(token) {
                    XCTFail("\(token) in \(url.lastPathComponent): \(Self.message)")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "precondition: the sources were actually scanned")
    }
}
