// ProcessedEventLedgerStore.swift
// Security/Session
//
// At-rest home for the ISSUE-5 Nostr backlog-replay ledger. Seals a
// `ProcessedEventLedger` (Codable) to a single file with `ChaChaPoly` + a vault
// DEK, mirroring `ContactAllowlistStore` / `MessageVault` (combined-form
// ChaChaPoly, AAD-bound, atomic write). The pure dedup logic is the ledger
// struct's; this is only the persistence half. Because the ledger is `Codable`,
// it serialises via JSON directly here — no separate codec type is needed.
//
// AT-REST PROTECTION: written with
// `.completeFileProtectionUntilFirstUserAuthentication` — deliberately the SAME
// posture as `ContactAllowlistStore` and the session DEK, because the Nostr
// inbound path runs backgrounded / with the screen locked (relays deliver
// anytime), so the replay guard must be readable while locked. The blob is also
// sealed under the DEK, so file-protection is defense-in-depth, not the only guard.
//
// FAILURE POSTURE: a MISSING file is the normal first-launch case → an empty
// ledger. A PRESENT-but-undecryptable/undecodable file THROWS (faithful to the
// store pattern); the composition root decides how to degrade. UNLIKE the
// allowlist, a corrupt ledger is NOT security-critical — the worst case is one
// replay storm — so the caller boots an empty ledger on load failure (a logged
// warning, not a hard stop), exactly like the invite ledger.
//
// WIPE: conforms to `Wipeable`, so it slots into `EmergencyWipe.additionalSteps`
// without touching that coordinator's core sequence. `wipe()` deletes the sealed
// file AND destroys its DEK (crypto-erase), idempotently — so a wiped identity
// starts from a fresh empty ledger, which is correct (a rotated Nostr identity
// receives new gift wraps under new outer ids anyway).
//
// TOMBSTONE: once `wipe()` has run, THIS instance refuses every later `save()`
// (throws `.wiped`). Erase can leave the old Nostr transport alive long enough
// to flush a debounced or stop-time save; without the tombstone that write
// recreates the file under the DEK the wipe just destroyed. The check-and-write
// in `save()` and the flag-set in `wipe()` share one lock, so a save already in
// flight finishes BEFORE the wipe deletes, and none lands after. Per instance,
// not on disk: a new identity's stack builds a fresh store and saves normally.
//

import Foundation
import CryptoKit
import os

public final class ProcessedEventLedgerStore: Wipeable, Sendable {

    public enum StoreError: Error, Equatable {
        /// `save()` after `wipe()` on this instance — refused, nothing written.
        case wiped
    }

    /// Default Keychain service id for this store's DEK. Distinct from the
    /// session / allowlist / invite DEK services, so the ledger key is an
    /// independent secret. Injectable so tests use a throwaway.
    public static let defaultKeychainService = "com.aeronyra.nostreventledger.v1"

    /// Sealed-file name inside the provided directory.
    private static let fileName = "nostr-event-ledger.v1.seal"

    /// Associated data binding the ciphertext to this purpose + version, so a
    /// blob can't be lifted and opened in another context.
    private static let aad = Data("aeronyra.nostr-event-ledger.v1".utf8)

    private let fileURL: URL
    private let dek: SymmetricKey
    private let keychainService: String
    /// True once `wipe()` has begun. Guards `save()`'s check-and-write.
    private let wiped = OSAllocatedUnfairLock(initialState: false)

    /// - Parameters:
    ///   - directory: where the sealed file lives (created if absent). May be
    ///     shared with the session / allowlist stores — the file name is distinct.
    ///   - dek: the Data Encryption Key sealing the file (from
    ///     `SessionStoreKey.loadOrCreate(service:)` at the composition root).
    ///   - keychainService: the DEK's Keychain service, used by `wipe()` to
    ///     destroy it. Defaults to the production service; tests pass a unique one.
    public init(directory: URL,
                dek: SymmetricKey,
                keychainService: String = ProcessedEventLedgerStore.defaultKeychainService) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        self.dek = dek
        self.keychainService = keychainService
    }

    // MARK: - Load / Save

    /// Read and decrypt the ledger. A missing file → empty ledger (first launch).
    /// A present file that fails to open or decode THROWS.
    public func load() throws -> ProcessedEventLedger {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ProcessedEventLedger()
        }
        let sealed = try Data(contentsOf: fileURL)
        let box = try ChaChaPoly.SealedBox(combined: sealed)
        let plaintext = try ChaChaPoly.open(box, using: dek, authenticating: Self.aad)
        return try JSONDecoder().decode(ProcessedEventLedger.self, from: plaintext)
    }

    /// Encode, seal, and write the ledger atomically (temp file + rename via
    /// `.atomic`), so a crash mid-write can't leave a truncated, undecryptable
    /// blob. Called OFF the transport's serial queue (the transport dispatches
    /// persistence to a utility queue), so this file write never blocks inbound
    /// processing.
    /// Throws `.wiped` (writing nothing) once `wipe()` has run on this instance.
    public func save(_ ledger: ProcessedEventLedger) throws {
        let plaintext = try JSONEncoder().encode(ledger)
        let sealed = try ChaChaPoly.seal(plaintext, using: dek, authenticating: Self.aad).combined
        let fileURL = self.fileURL
        // The write happens UNDER the lock, so a concurrent wipe cannot delete
        // between check and write — the only design with no window in which a
        // file exists after wipe() returns. Holding an unfair lock across I/O is
        // safe HERE because: wipe() is non-isolated async, so it runs on the
        // cooperative pool, never the main actor (which only suspends on it);
        // os_unfair_lock donates the waiter's priority to the owner; and
        // contention happens at most once per erase (saves are debounced, so an
        // uncontended save costs nothing extra). Worst case: one pool thread
        // waits for one write — the ledger is ≤ 8,192 ids, ~550 KB sealed
        // (duration unmeasured).
        try wiped.withLock { isWiped in
            guard !isWiped else { throw StoreError.wiped }
            try sealed.write(to: fileURL,
                             options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    // MARK: - Wipeable

    /// Crypto-erase: destroy the DEK, then remove the sealed file. Idempotent — a
    /// missing file and an already-absent key are both no-ops, per `Wipeable`.
    public func wipe() async throws {
        // Tombstone FIRST, under the save lock: waits out an in-flight save,
        // then no later save can write.
        wiped.withLock { $0 = true }
        // KEY FIRST, then the file: if the removal then fails, what survives is
        // a sealed file under a destroyed key — unreadable, never loadable by a
        // later identity (a `loadOrCreate` mints a NEW key that cannot open it).
        try SessionStoreKey.destroy(service: keychainService)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
