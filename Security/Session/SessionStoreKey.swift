// SessionStoreKey.swift
// Security/Session
//
// The Data Encryption Key for PersistentBeaconStore's at-rest file.
//
// A single 256-bit key, load-or-created in the Keychain. Unlike MessageVault
// (an actor whose DEK is gated on user presence and read asynchronously), this
// key is read SYNCHRONOUSLY at the composition root and is gated only on
// `afterFirstUnlockThisDeviceOnly` — deliberately, because the session store
// must be readable while the screen is locked so the mesh can receive in the
// background. It never leaves the device and is not synchronized to iCloud.
//
// Threat-model note: this protects the libsignal session FILE at rest. Message
// *content* at rest still rides MessageVault's stricter user-presence DEK; this
// is the wire-session slice, a different layer. A future hardening can wrap this
// key with the Secure Enclave (as MessageVault wraps its DEK); for now the
// Keychain item's own ThisDeviceOnly + afterFirstUnlock protection is the floor.
//

import Foundation
import CryptoKit
import Security

enum SessionStoreKeyError: Error {
    case keychain(OSStatus)
    case generationFailed
}

enum SessionStoreKey {

    private static let account = "session.dek.v1"
    private static let byteCount = 32   // 256-bit

    /// Load the existing DEK, or create + store one on first run.
    /// - Parameter service: stable bundle-scoped Keychain service id (must not
    ///   change across launches, or the store reads as wiped).
    static func loadOrCreate(service: String) throws -> SymmetricKey {
        if let existing = try load(service: service) {
            return existing
        }
        return try create(service: service)
    }

    private static func load(service: String) throws -> SymmetricKey? {
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
            guard let data = item as? Data else { return nil }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw SessionStoreKeyError.keychain(status)
        }
    }

    /// Overwrite a byte buffer with zeros via `memset_s`, which the optimizer
    /// is not permitted to elide. Best-effort scrub of transient key bytes.
    private static func secureZero(_ bytes: inout [UInt8]) {
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                _ = memset_s(base, raw.count, 0, raw.count)
            }
        }
    }

    private static func create(service: String) throws -> SymmetricKey {
        var raw = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &raw) == errSecSuccess else {
            secureZero(&raw)
            throw SessionStoreKeyError.generationFailed
        }
        defer { secureZero(&raw) }

        let attributes: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String:     kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String:          Data(raw),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw SessionStoreKeyError.keychain(status) }

        return SymmetricKey(data: Data(raw))
    }

    /// Remove the DEK — crypto-erases the persistent session store (its file
    /// becomes undecryptable). Part of the emergency-wipe path.
    static func destroy(service: String) throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SessionStoreKeyError.keychain(status)
        }
    }
}
