//
//  DeviceResidueWipe.swift
//  Security/Wipe
//
//  Crypto-erase step for device-side, identity-bearing residue that the key
//  destruction steps don't touch (security-review items 9 + 10).
//
//  The core wipe destroys secret KEY material — identity, Enclave key, session
//  DEK, Nostr secret, sealed stores, the SwiftData file. But identity
//  artifacts living OUTSIDE that key-sealed world survived a panic wipe:
//
//   • UserDefaults `aeronyra.displayName` + `aeronyra.selfPhoto` — the user's
//     chosen name and photo bytes, written as plaintext in the defaults plist
//     by Settings/Home (`@AppStorage`). Not key material, but plainly the
//     device owner's identity.
//   • Delivered / pending LOCAL notifications — each carries a per-conversation
//     `threadIdentifier` and, grouped in Notification Center, reveals that
//     messages arrived. The app badge likewise persists an unread count.
//   • The A2 Nostr identity-change breadcrumb (`lastLocalNostrPubkeyKey`) —
//     the last local Nostr PUBLIC key, linking the install to its wiped
//     identity. Clearing it is safe for A2 (see the constant's doc).
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

    /// A2 (NOSTR_KEY_PROPAGATION): the last local Nostr PUBLIC key this install
    /// saw — the identity-change breadcrumb ContentView.bootstrap() compares
    /// against `NostrIdentity.loadOrCreate`. Public material, but it links the
    /// install to its (wiped) Nostr identity, so a panic wipe clears it too.
    /// Clearing does not break A2: on the post-wipe launch the stored value is
    /// absent, `nil != newPub` still fires the re-announce (a harmless no-op
    /// with zero contacts after a full erase). Defined HERE, beside the other
    /// defaults keys, as the single source of truth — ContentView references
    /// this constant.
    static let lastLocalNostrPubkeyKey = "nostr.lastKnownLocalPubkey.v1"

    func wipe() async throws {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.displayNameKey)
        defaults.removeObject(forKey: Self.selfPhotoKey)
        defaults.removeObject(forKey: Self.lastLocalNostrPubkeyKey)

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
