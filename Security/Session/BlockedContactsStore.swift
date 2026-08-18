// BlockedContactsStore.swift
// Security/Session
//
// The at-rest home for the BLOCKED-contact denylist (Guideline 1.2 Block).
// Mirrors `ContactAllowlistStore` exactly: seals the entry list to a single
// file with ChaChaPoly + its own DEK (own Keychain service), AAD-bound so a
// blob can't be lifted into another context, `Wipeable` so it registers in
// `EmergencyWipe.additionalSteps` untouched.
//
// WHAT AN ENTRY MEANS. Block is PROHIBITION, not absence: the allowlist's
// revoke makes a contact unknown; an entry HERE makes them refused — inbound
// dropped at the coordinator's early guard, and re-pairing (QR / invite /
// invite echo) denied until the user unblocks. The entry carries a petname
// SNAPSHOT (the Peer row's local nickname at block time, for the Blocked
// Contacts list) and the prior verified flag so unblock can restore the
// relationship exactly.
//
// FAILURE POSTURE: mirrors the allowlist — a MISSING file is the normal case
// (empty denylist); a PRESENT-but-unopenable file THROWS, and the composition
// root decides the degrade (it logs loudly and boots empty; a blocked-but-
// lost identity is also revoked from the allowlist, so they still cannot
// message — the loss is only the re-pair refusal and the Blocked list row).
//
// WIPE: `wipe()` deletes the sealed file AND destroys its DEK, idempotently.
//

import Foundation
import CryptoKit

/// One blocked identity. `petname` and `wasVerified` are snapshots taken at
/// block time so the Blocked Contacts UI and unblock-restore work even though
/// the identity is simultaneously revoked from the allowlist.
public struct BlockedContact: Codable, Sendable, Identifiable, Equatable {
    /// The raw 32-byte identity key — the permanent user ID.
    public let rawKey: Data
    /// Unix milliseconds at block time (matches the allowlist's `pairedAt`).
    public let blockedAt: Int64
    /// The LOCAL nickname the user had assigned, frozen at block time.
    public let petname: String?
    /// Whether the contact was SAS/QR-verified when blocked; unblock restores it.
    public let wasVerified: Bool

    public var id: Data { rawKey }

    public init(rawKey: Data, blockedAt: Int64, petname: String?, wasVerified: Bool) {
        self.rawKey = rawKey
        self.blockedAt = blockedAt
        self.petname = petname
        self.wasVerified = wasVerified
    }
}

public final class BlockedContactsStore: Wipeable, Sendable {

    /// This store's DEK service — distinct from every other store's, so the
    /// denylist key is an independent secret with its own destruction.
    public static let defaultKeychainService = "com.aeronyra.blockedcontacts.v1"

    private static let fileName = "blocked-contacts.v1.seal"

    /// Associated data binding the ciphertext to this purpose + version.
    private static let aad = Data("aeronyra.blocked-contacts.v1".utf8)

    private let fileURL: URL
    private let dek: SymmetricKey
    private let keychainService: String

    public init(directory: URL,
                dek: SymmetricKey,
                keychainService: String = BlockedContactsStore.defaultKeychainService) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        self.dek = dek
        self.keychainService = keychainService
    }

    // MARK: - Load / Save

    /// Missing file → empty denylist. A present file that fails to open or
    /// decode THROWS (loud, never silently empty — see header).
    public func load() throws -> [BlockedContact] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let sealed = try Data(contentsOf: fileURL)
        let box = try ChaChaPoly.SealedBox(combined: sealed)
        let plaintext = try ChaChaPoly.open(box, using: dek, authenticating: Self.aad)
        return try JSONDecoder().decode([BlockedContact].self, from: plaintext)
    }

    /// Encode, seal, and write atomically — same posture as the allowlist
    /// (`.completeFileProtectionUntilFirstUserAuthentication`, defense-in-depth
    /// under the DEK).
    public func save(_ contacts: [BlockedContact]) throws {
        let plaintext = try JSONEncoder().encode(contacts)
        let sealed = try ChaChaPoly.seal(plaintext, using: dek, authenticating: Self.aad).combined
        try sealed.write(to: fileURL,
                         options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: - Wipeable

    /// Crypto-erase: remove the sealed file and destroy its DEK. Idempotent.
    public func wipe() async throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try SessionStoreKey.destroy(service: keychainService)
    }
}
