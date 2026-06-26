//
//  Security/Session
//
//  IDENTITY BRIDGE (PASS 2, Option A) — one true identity.
//
//  Beacon's long-term identity (Security/Identity/IdentityKeypair.swift) is a
//  CryptoKit Curve25519 keypair whose private half is Enclave-wrapped and never
//  written to disk unwrapped (HANDOFF §3.2). libsignal manages its OWN
//  `IdentityKeyPair`. Before this bridge there were TWO identities; this makes
//  the libsignal session identity BE the app identity.
//
//  Which key: the app holds two keys — `agreement` (X25519, the canonical user
//  ID per `PublicIdentity.userID`) and `signing` (Ed25519). libsignal uses ONE
//  Curve25519 key for both ECDH and XEdDSA signing, so we map the `agreement`
//  key in. The app's separate Ed25519 `signing` key is therefore unused by the
//  session layer — the honest consequence of libsignal's one-key model.
//
//  Security note (Option A, chosen deliberately): bridging requires the
//  identity PRIVATE key in memory to construct libsignal's keypair. This does
//  NOT weaken the at-rest model — the key is still Enclave-wrapped on disk and
//  only ever materializes while the app is unlocked and actively messaging,
//  which is exactly the state §3.8 already declares outside crypto's reach
//  (a compromised, unlocked endpoint). This mirrors how Signal itself operates.
//

import Foundation
import CryptoKit
import LibSignalClient

extension IdentityKeypair {

    /// Derive libsignal's `IdentityKeyPair` from this app identity's X25519
    /// agreement key. The resulting libsignal identity is deterministically tied
    /// to the app's permanent user ID — same app identity in, same session
    /// identity out, every launch.
    ///
    /// Throws if the raw key bytes are not a valid Curve25519 private scalar —
    /// which, for a CryptoKit-generated key, does not happen in practice.
    func libsignalIdentityKeyPair() throws -> LibSignalClient.IdentityKeyPair {
        let priv = try LibSignalClient.PrivateKey(agreement.rawRepresentation)
        return LibSignalClient.IdentityKeyPair(publicKey: priv.publicKey,
                                               privateKey: priv)
    }
}
