// PendingInvitesStore.swift
// Security/Session
//
// The at-rest home for the initiator's single-use invite ledger (STEP 7c-2).
// Seals the `PendingInvitesCodec` blob to a single file with `ChaChaPoly` + a
// dedicated vault DEK, mirroring `ContactAllowlistStore` exactly — same seal
// idiom, same file-protection posture, same failure/wipe contract. The pure
// bytes are the codec's; the mint/consume lifecycle is the `EnrollmentService`
// seam's (step 7c-2b); this layer only persists.
//
// WHAT IT PERSISTS: ONLY the {id → expiresAt} ledger — never the Invite or its
// PairingPayload. The initiator doesn't need the payload after minting; it only
// needs to recognize and burn an echoed id. So the sealed file holds nothing
// key-bearing — just random nonces + expiry timestamps. It is nonetheless
// secret-adjacent (in-flight-pairing metadata), which is why it gets its own DEK,
// conforms to `Wipeable`, and is registered in `EmergencyWipe` at the root.
//
// AT-REST PROTECTION: `.completeFileProtectionUntilFirstUserAuthentication` — the
// same posture as `ContactAllowlistStore` and the session DEK, so an echo that
// arrives while the screen is locked can still be consumed. The blob is sealed
// under the DEK regardless, so file-protection is defense-in-depth.
//
// FAILURE POSTURE (LOCKED, mirrors the allowlist): a MISSING file is the normal
// first-launch case → empty ledger. A PRESENT-but-undecryptable/undecodable file
// THROWS — a single-use ledger must surface corruption loudly, never silently
// empty itself (which would silently forget in-flight invites).
//
// PURITY NOTE: this layer does NOT prune expired ids on load — it has no clock and
// round-trips bytes faithfully, exactly like the codec. Pruning belongs to the
// `EnrollmentService` seam (step 7c-2b), which already owns `nowMillis` and calls
// `prune(at:)` after loading.
//
// WIPE: conforms to `Wipeable`, so it registers in `EmergencyWipe` without
// touching that coordinator's core sequence. `wipe()` deletes the sealed file AND
// destroys its DEK (crypto-erase), idempotently.
//

import Foundation
import CryptoKit

public final class PendingInvitesStore: Wipeable, Sendable {

    /// Keychain service id for this store's DEK. Distinct from the allowlist and
    /// session DEKs, so the invite ledger is an independent secret with its own
    /// destruction. Injectable so tests use a throwaway.
    public static let defaultKeychainService = "com.aeronyra.pendinginvites.v1"

    /// Sealed-file name inside the provided directory.
    private static let fileName = "pending-invites.v1.seal"

    /// Associated data binding the ciphertext to this purpose + version, so a
    /// blob can't be lifted and opened in another context.
    private static let aad = Data("aeronyra.pending-invites.v1".utf8)

    private let fileURL: URL
    private let dek: SymmetricKey
    private let keychainService: String

    /// - Parameters:
    ///   - directory: where the sealed file lives (created if absent). May be
    ///     shared with the other stores — the file name is distinct.
    ///   - dek: the Data Encryption Key sealing the file (from
    ///     `SessionStoreKey.loadOrCreate(service:)` at the composition root).
    ///   - keychainService: the DEK's Keychain service, used by `wipe()` to
    ///     destroy it. Defaults to the production service; tests pass a unique one.
    public init(directory: URL,
                dek: SymmetricKey,
                keychainService: String = PendingInvitesStore.defaultKeychainService) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        self.dek = dek
        self.keychainService = keychainService
    }

    // MARK: - Load / Save

    /// Read and decrypt the ledger. A missing file → empty ledger (first launch).
    /// A present file that fails to open or decode THROWS. Does not prune — the
    /// seam prunes with a clock after loading.
    public func load() throws -> PendingInvites {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return PendingInvites()
        }
        let sealed = try Data(contentsOf: fileURL)
        let box = try ChaChaPoly.SealedBox(combined: sealed)
        let plaintext = try ChaChaPoly.open(box, using: dek, authenticating: Self.aad)
        return try PendingInvitesCodec.decode(plaintext)
    }

    /// Encode, seal, and write the ledger atomically (temp file + rename via
    /// `.atomic`), so a crash mid-write can't leave a truncated, undecryptable
    /// ledger.
    public func save(_ ledger: PendingInvites) throws {
        let plaintext = try PendingInvitesCodec.encode(ledger)
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
