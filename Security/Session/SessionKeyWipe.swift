//
//  SessionKeyWipe.swift
//  Security/Session
//
//  Crypto-erase step for the persistent session store's Data Encryption Key
//  (STEP 7b-3 · GROUND_TRUTH §3.8 completeness).
//
//  The DEK (`SessionStoreKey`, Keychain account `session.dek.v1`) seals
//  PersistentBeaconStore's at-rest file (`signalstore.dat`). The emergency wipe's
//  step 2 — `SecureSessionStore.deleteAllSessions()` →
//  `PersistentBeaconStore.wipe()` — already DELETES that sealed file, so the
//  session state is erased even if this key survived (a key with no ciphertext
//  left to open is inert). This step exists for HYGIENE, matching the "no ghost"
//  standard the rest of the wipe already holds: the identity item, the Nostr
//  secret, and the contact-allowlist DEK are all destroyed on a panic wipe, so
//  leaving the session DEK behind would be the one orphaned AeroNyra secret in
//  the Keychain. Destroying it makes the post-wipe property uniform and
//  audit-clean: after an emergency wipe, NO AeroNyra secret remains in the
//  Keychain.
//
//  Ordering note: because step 2 deletes the file regardless, this step is order-
//  independent with respect to the file delete — running before or after leaves
//  the same end state (no file, no key). It rides `additionalSteps` so the wipe's
//  core sequence is untouched, exactly like `NostrIdentityWipe`.
//
//  IDEMPOTENT: `SessionStoreKey.destroy` treats a missing item as success
//  (errSecItemNotFound is not an error), so wiping an already-wiped (or
//  never-created) key does not throw — satisfying the `Wipeable` contract.
//

import Foundation

/// Erases the persistent session store's DEK as part of the emergency
/// crypto-erase. See file header for why this is hygiene on top of the file
/// delete, not the primary session-state erasure.
struct SessionKeyWipe: Wipeable {

    /// The Keychain service id the session DEK is stored under — MUST match the
    /// id passed to `SessionStoreKey.loadOrCreate` at the composition root
    /// (`sessionKeyService`, `"com.aeronyra.sessionkey.v1"`), or this deletes
    /// nothing.
    let service: String

    func wipe() async throws {
        try SessionStoreKey.destroy(service: service)
    }
}
