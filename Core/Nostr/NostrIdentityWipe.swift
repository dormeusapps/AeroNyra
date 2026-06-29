//
//  NostrIdentityWipe.swift
//  Core/Nostr
//
//  Crypto-erase step for the Nostr identity (Phase 8a-iv).
//
//  The internet identity is a long-lived secret in the Keychain (NostrSecretStore),
//  so a panic wipe that left it behind would strand a recoverable identity — the
//  same "no ghost" reasoning EmergencyWipe applies to the libsignal identity. This
//  is the smallest possible hook: a `Wipeable` that deletes the Nostr secret,
//  passed to EmergencyWipe via `additionalSteps` so the wipe's core sequence is
//  untouched (the file's stated extension point).
//
//  IDEMPOTENT: NostrSecretStore.destroy treats a missing item as success, so
//  wiping an already-wiped (or never-created) identity does not throw — exactly
//  what the `Wipeable` contract requires.
//

import Foundation

/// Erases the persistent Nostr secret as part of the emergency crypto-erase.
struct NostrIdentityWipe: Wipeable {

    /// The Keychain service id the Nostr secret is stored under — must match the
    /// id used by `NostrIdentity.loadOrCreate` at the composition root.
    let service: String

    func wipe() async throws {
        try NostrSecretStore.destroy(service: service)
    }
}
