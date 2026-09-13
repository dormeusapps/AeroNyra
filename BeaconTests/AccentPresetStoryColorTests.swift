//
//  AccentPresetStoryColorTests.swift
//  BeaconTests
//
//  Every accent preset must be reachable from the story text palette by name.
//  `StoryTextColor` looks presets up by string and falls back to biolume
//  SILENTLY when a name drifts — this pins that no preset is orphaned: for
//  each preset there is a case whose rendered colour is exactly that hex.
//

import XCTest
import UIKit
@testable import Beacon

final class AccentPresetStoryColorTests: XCTestCase {

    private func hex(_ c: UIColor) -> UInt {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(c.getRed(&r, green: &g, blue: &b, alpha: &a))
        return UInt((r * 255).rounded()) << 16 | UInt((g * 255).rounded()) << 8 | UInt((b * 255).rounded())
    }

    func testEveryAccentPresetResolvesToAStoryTextColorCase() {
        // Park the accent on a value no preset uses, so a case that silently
        // fell back to biolume could not masquerade as a preset.
        let key = Stillwater.Accent.key
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(0x123456, forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let rendered = Set(StoryTextColor.allCases.map { hex($0.uiColor) })
        // The DEFAULT preset (teal) has no named case by design: `.biolume`
        // is the story palette's teal, because biolume IS teal until the user
        // picks otherwise. Pinned separately below. Every other preset must
        // have its own case.
        for preset in Stillwater.Accent.presets where preset.hex != Stillwater.Accent.defaultHex {
            XCTAssertTrue(rendered.contains(preset.hex),
                          "accent preset '\(preset.name)' (\(String(preset.hex, radix: 16))) has no StoryTextColor case — it would fall back to biolume silently")
        }
    }

    func testDefaultPresetIsCoveredByTheBiolumeCase() {
        let key = Stillwater.Accent.key
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } }
        XCTAssertEqual(hex(StoryTextColor.biolume.uiColor), Stillwater.Accent.defaultHex,
                       "with no accent chosen, the story palette's biolume must be the default preset (teal)")
    }

    func testNoStoryTextColorCaseFallsBackToBiolume() {
        let key = Stillwater.Accent.key
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(0x123456, forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        for c in StoryTextColor.allCases where c != .biolume {
            XCTAssertNotEqual(hex(c.uiColor), 0x123456, "\(c) renders as biolume — its preset name lookup failed")
        }
    }
}
