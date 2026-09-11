// WalkieSettings.swift
// Core/Calls
//
// The walkie KILL SWITCH (live PTT-over-IP, Rubins' ruling 2026-09-11): a
// user can refuse inbound walkie links entirely. Consulted by the link
// engine's `autoAnswerPolicy` at the composition root, BEFORE any media is
// built — so when the switch is off an inbound `.pttRequest` is declined and
// this device's mic hardware is never touched. Outbound is unaffected (the
// user chose it); glare while WE are initiating is answered by design (we
// wanted that link at that moment). Blocked contacts never reach this gate.
//
// Why it exists beyond preference: "any verified contact can remotely
// activate your microphone, with no way to refuse" sits in the same
// Guideline 1.2 territory the app just cleared four rejection cycles on. A
// switch is a stronger answer than a rationale.
//
// DEFAULT ON. `UserDefaults.bool(forKey:)` reads FALSE for an absent key,
// which would silently invert the default — hence the explicit absent check
// in `allowsInbound`. Key mirrored in `DeviceResidueWipe` (dies on
// crypto-erase; the post-wipe install is back to default-on).
//

import Foundation

enum WalkieSettings {
    /// The `@AppStorage` key `SettingsView` binds its toggle to. MUST match
    /// `DeviceResidueWipe.walkieAllowInboundKey` exactly.
    static let allowInboundKey = "aeronyra.walkie.allowInbound.v1"

    /// True unless the user has switched inbound walkies off. Absent → true.
    static func allowsInbound(_ defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: allowInboundKey) != nil else { return true }
        return defaults.bool(forKey: allowInboundKey)
    }
}
