//
//  NostrSecretStore.swift
//  Core/Nostr
//
//  Keychain persistence for the Nostr identity's secret key (Phase 8a).
//
//  The Nostr pillar needs a long-lived secp256k1 secret: it signs the events we
//  publish and is the key we subscribe under to receive gift-wraps. Like the
//  session DEK (SessionStoreKey), it is a single 32-byte secret, load-or-created
//  in the Keychain, gated on `afterFirstUnlockThisDeviceOnly` so the internet
//  transport can publish/subscribe while the screen is locked — never
//  synchronized to iCloud, never leaving the device.
//
//  This file stores RAW BYTES only — it neither generates nor validates a
//  secp256k1 scalar (that is NostrIdentity's job, which owns the curve). Keeping
//  storage curve-free means it has no dependency on secp256k1 and can be proven
//  on its own. Mirrors SessionStoreKey deliberately, down to the secure-zero
//  scrub and the `destroy` hook for the emergency-wipe path.
//
//  WIPE NOTE: `destroy` must be called from the emergency crypto-erase path
//  alongside SessionStoreKey.destroy — a wipe that leaves the Nostr secret
//  behind would leave a recoverable identity. (Wiring into EmergencyWipe is a
//  tracked follow-up.)
//

import Foundation
import Security

enum NostrSecretStoreError: Error {
    case keychain(OSStatus)
}

enum NostrSecretStore {

    private static let account = "nostr.secret.v1"
    static let byteCount = 32   // secp256k1 scalar

    /// Load the stored 32-byte secret, or nil if none exists yet.
    /// - Parameter service: stable bundle-scoped Keychain service id (must not
    ///   change across launches, or the identity reads as absent → regenerated).
    static func load(service: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw NostrSecretStoreError.keychain(status)
        }
    }

    /// Persist `secret` (must be exactly `byteCount` bytes). Adds on first run.
    /// Caller is NostrIdentity, which has just generated a valid scalar.
    static func save(_ secret: Data, service: String) throws {
        precondition(secret.count == byteCount, "Nostr secret must be \(byteCount) bytes")
        let attributes: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String:     kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String:          secret,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw NostrSecretStoreError.keychain(status) }
    }

    /// Remove the Nostr secret — crypto-erases the internet identity. Part of
    /// the emergency-wipe path. Idempotent (a missing item is not an error).
    static func destroy(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NostrSecretStoreError.keychain(status)
        }
    }
}
