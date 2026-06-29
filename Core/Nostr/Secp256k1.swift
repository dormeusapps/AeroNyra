//
//  Secp256k1.swift
//  Core/Nostr
//
//  Curve operations for the Nostr identity (Phase 8b), backed by the vendored
//  libsecp256k1 (the `Csecp256k1` module from 8b-i-0). This is the ONE place the
//  app does secp256k1 curve math, keeping NostrIdentity itself free of any C
//  import — identity stays Swift-pure, the curve lives here.
//
//  8b-i-1 adds x-only public-key derivation (this file). 8b-ii will add BIP-340
//  schnorr signing alongside it (same context/keypair machinery), which is why
//  this is a standalone helper rather than inlined into NostrIdentity.
//
//  A fresh context is created per call and randomized before any secret-key
//  operation (side-channel hardening, per libsecp256k1 guidance). Derivation is
//  rare (once per identity load, then cached by callers), so the per-call
//  context cost is not a concern; if it ever becomes one, a cached randomized
//  context can replace it without changing this surface.
//

import Foundation
import Security
import Csecp256k1

enum Secp256k1 {

    /// Derive the 32-byte BIP-340 x-only public key from a 32-byte secret
    /// scalar. Returns nil if the secret is not exactly 32 bytes, is not a valid
    /// scalar, or any curve operation fails.
    ///
    /// This is the `npub` byte source: NostrIdentity.publicKeyBytes calls here,
    /// and NIP19.npub(fromPublicKey:) encodes the result.
    static func xOnlyPublicKey(fromSecretKey secret: Data) -> Data? {
        guard secret.count == 32 else { return nil }
        guard let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE)) else {
            return nil
        }
        defer { secp256k1_context_destroy(ctx) }

        // Randomize the context before touching the secret key (DPA hardening).
        var seed = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, seed.count, &seed) == errSecSuccess,
              secp256k1_context_randomize(ctx, seed) == 1 else {
            return nil
        }

        // Local copy of the secret; zeroed on the way out for hygiene.
        var secretBytes = [UInt8](secret)
        defer { for i in secretBytes.indices { secretBytes[i] = 0 } }

        var keypair = secp256k1_keypair()
        guard secp256k1_keypair_create(ctx, &keypair, secretBytes) == 1 else {
            return nil   // invalid scalar (0 or >= n)
        }

        var xonly = secp256k1_xonly_pubkey()
        guard secp256k1_keypair_xonly_pub(ctx, &xonly, nil, &keypair) == 1 else {
            return nil
        }

        var out = [UInt8](repeating: 0, count: 32)
        guard secp256k1_xonly_pubkey_serialize(ctx, &out, &xonly) == 1 else {
            return nil
        }

        return Data(out)
    }
}
