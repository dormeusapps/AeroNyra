// ContactAllowlistStore.swift
// Security/Session
//
// The at-rest home for the closed-contact allowlist (STEP 7a-2). Seals the
// `ContactAllowlistCodec` blob to a single file with `ChaChaPoly` + a vault DEK,
// mirroring the existing at-rest pattern (`MessageVault`, `PersistentBeaconStore`
// — combined-form ChaChaPoly, AAD-bound). This is the persistence half; the pure
// bytes are the codec's, the pairing/enrollment logic is the allowlist struct's,
// and wiring it into startup is a later sub-step.
//
// AT-REST PROTECTION: the file is written with
// `.completeFileProtectionUntilFirstUserAuthentication` — deliberately the same
// posture as the session DEK (`SessionStoreKey`, `afterFirstUnlockThisDeviceOnly`)
// rather than `.complete`, because the mesh must be able to read the paired set to
// admit a reconnecting contact while the screen is locked in the background. The
// blob is also sealed under the DEK, so file-protection is defense-in-depth, not
// the only guard.
//
// FAILURE POSTURE (LOCKED): a MISSING file is the normal first-launch case and
// yields an empty allowlist. A PRESENT-but-undecryptable/undecodable file THROWS
// — a security admission set must surface corruption loudly, never silently empty
// itself (which would drop every real contact and darken the mesh with no signal).
//
// WIPE: conforms to `Wipeable`, so it registers in `EmergencyWipe.additionalSteps`
// without touching that coordinator's core sequence. `wipe()` deletes the sealed
// file AND destroys its DEK (crypto-erase), idempotently.
//

import Foundation
import CryptoKit

public final class ContactAllowlistStore: Wipeable, Sendable {

    /// Default Keychain service id for this store's DEK. Distinct from the
    /// session DEK's service, so the allowlist key is an independent secret
    /// (its own rotation / destruction). Injectable so tests use a throwaway.
    public static let defaultKeychainService = "com.aeronyra.contactallowlist.v1"

    /// Sealed-file name inside the provided directory.
    private static let fileName = "contact-allowlist.v1.seal"

    /// Associated data binding the ciphertext to this purpose + version, so a
    /// blob can't be lifted and opened in another context.
    private static let aad = Data("aeronyra.contact-allowlist.v1".utf8)

    private let fileURL: URL
    private let dek: SymmetricKey
    private let keychainService: String

    /// - Parameters:
    ///   - directory: where the sealed file lives (created if absent). May be
    ///     shared with the session store — the file name is distinct.
    ///   - dek: the Data Encryption Key sealing the file (from
    ///     `SessionStoreKey.loadOrCreate(service:)` at the composition root).
    ///   - keychainService: the DEK's Keychain service, used by `wipe()` to
    ///     destroy it. Defaults to the production service; tests pass a unique one.
    public init(directory: URL,
                dek: SymmetricKey,
                keychainService: String = ContactAllowlistStore.defaultKeychainService) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        self.dek = dek
        self.keychainService = keychainService
    }

    // MARK: - Load / Save

    /// Read and decrypt the paired set. A missing file → empty allowlist (first
    /// launch). A present file that fails to open or decode THROWS.
    public func load() throws -> ContactAllowlist {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ContactAllowlist()
        }
        let sealed = try Data(contentsOf: fileURL)
        let box = try ChaChaPoly.SealedBox(combined: sealed)
        let plaintext = try ChaChaPoly.open(box, using: dek, authenticating: Self.aad)
        return try ContactAllowlistCodec.decode(plaintext)
    }

    /// Encode, seal, and write the paired set atomically (temp file + rename via
    /// `.atomic`), so a crash mid-write can't leave a truncated, undecryptable set.
    public func save(_ allowlist: ContactAllowlist) throws {
        let plaintext = try ContactAllowlistCodec.encode(allowlist)
        let sealed = try ChaChaPoly.seal(plaintext, using: dek, authenticating: Self.aad).combined
        try sealed.write(to: fileURL,
                         options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: - Wipeable

    /// Crypto-erase: remove the sealed file and destroy its DEK. Idempotent — a
    /// missing file and an already-absent key are both no-ops, per `Wipeable`.
    public func wipe() async throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try SessionStoreKey.destroy(service: keychainService)
    }
}
