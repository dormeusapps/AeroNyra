//
//  DeviceResidueWipe.swift
//  Security/Wipe
//
//  Crypto-erase step for device-side, identity-bearing residue that the key
//  destruction steps don't touch (security-review items 9 + 10).
//
//  The core wipe destroys secret KEY material — identity, Enclave key, session
//  DEK, Nostr secret, sealed stores, the SwiftData file. But two identity
//  artifacts live OUTSIDE that key-sealed world and survived a panic wipe:
//
//   • UserDefaults `aeronyra.displayName` + `aeronyra.selfPhoto` — the user's
//     chosen name and photo bytes, written as plaintext in the defaults plist
//     by Settings/Home (`@AppStorage`). Not key material, but plainly the
//     device owner's identity.
//   • Delivered / pending LOCAL notifications — each carries a per-conversation
//     `threadIdentifier` and, grouped in Notification Center, reveals that
//     messages arrived. The app badge likewise persists an unread count.
//
//  A panic wipe should leave none of it. This rides `additionalSteps` so the
//  wipe's core key-destruction sequence is untouched, exactly like
//  `SessionKeyWipe` / `NostrIdentityWipe`.
//
//  IDEMPOTENT: removing an absent default key or clearing an empty notification
//  tray is a no-op, so a repeat wipe never throws — satisfying `Wipeable`.
//

import Foundation
import UserNotifications

/// Clears device-side identity residue (self name/photo defaults, delivered +
/// pending local notifications, app-icon badge) as part of the emergency
/// crypto-erase. See file header for why this is hygiene on top of the key
/// destruction, not secret-material erasure.
struct DeviceResidueWipe: Wipeable {

    /// UserDefaults keys written by Settings/Home via `@AppStorage`. MUST match
    /// those keys exactly (`SettingsView`/`HomeView`) or the residue survives.
    static let displayNameKey = "aeronyra.displayName"
    static let selfPhotoKey   = "aeronyra.selfPhoto"

    func wipe() async throws {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.displayNameKey)
        defaults.removeObject(forKey: Self.selfPhotoKey)

        // UNUserNotificationCenter is @MainActor-facing in our use; hop once and
        // do all three there. Clearing an empty tray / zeroing an unset badge is
        // a no-op, keeping this step idempotent.
        await MainActor.run {
            let center = UNUserNotificationCenter.current()
            center.removeAllDeliveredNotifications()
            center.removeAllPendingNotificationRequests()
            center.setBadgeCount(0)
        }
    }
}
