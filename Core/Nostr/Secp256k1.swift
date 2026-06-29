//
//  Secp256k1.swift
//  Core/Nostr
//
//  Curve operations for the Nostr identity (Phase 8b/8c), backed by the vendored
//  libsecp256k1 (the `Csecp256k1` module). This is the ONE place the app does
//  secp256k1 curve math, keeping NostrIdentity itself free of any C import —
//  identity stays Swift-pure, the curve lives here.
//
//  Contents:
//   - xOnlyPublicKey (8b-i-1): BIP-340 x-only public-key derivation -> npub.
//   - sign / verify  (8b-ii):  BIP-340 schnorr signing + verification.
//   - ecdh           (8c-i-0): raw secp256k1 ECDH shared X for NIP-44.
//
//  A fresh context is created per call and randomized before any secret-key
//  operation (side-channel hardening, per libsecp256k1 guidance). These
//  operations are rare, so the per-call context cost is not a concern; if it
//  ever becomes one, a cached randomized context can replace it without
//  changing this surface.
//

import Foundation
import Security
import Csecp256k1

/// File-private ECDH hash callback: copy the shared point's 32-byte X coordinate
/// out verbatim. libsecp256k1's default ECDH hashes the compressed point with
/// SHA256; NIP-44 instead wants the RAW shared X, so we pass this passthrough.
/// Must be non-capturing to bridge to a C function pointer.
private func secp256k1RawXCopyHash(_ output: UnsafeMutablePointer<UInt8>?,
                                   _ x32: UnsafePointer<UInt8>?,
                                   _ y32: UnsafePointer<UInt8>?,
                                   _ data: UnsafeMutableRawPointer?) -> Int32 {
    guard let output = output, let x32 = x32 else { return 0 }
    output.update(from: x32, count: 32)
    return 1
}

enum Secp256k1 {

    // MARK: - Public-key derivation (8b-i-1)

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

    // MARK: - BIP-340 schnorr signing / verification (8b-ii)

    /// Produce a 64-byte BIP-340 schnorr signature over a 32-byte message hash
    /// using a 32-byte secret scalar.
    ///
    /// `messageHash32` MUST already be a 32-byte hash — for Nostr this is the
    /// NIP-01 event id (sha256 of the serialized event array). This helper does
    /// NOT hash for you; it signs the 32 bytes you pass.
    ///
    /// Auxiliary randomness (32 bytes, per BIP-340) is drawn fresh from
    /// `SecRandomCopyBytes` on every call, so signatures over the same
    /// (message, key) pair are intentionally NON-deterministic. The context is
    /// randomized before any secret-key operation.
    ///
    /// Returns nil if the inputs are the wrong length, the secret is an invalid
    /// scalar (0 or >= curve order), randomness is unavailable, or any curve
    /// operation fails.
    static func sign(messageHash32 message: Data, secretKey secret: Data) -> Data? {
        guard message.count == 32, secret.count == 32 else { return nil }
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

        // 32 bytes of auxiliary randomness, per BIP-340; zeroed on the way out.
        var aux = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, aux.count, &aux) == errSecSuccess else {
            return nil
        }
        defer { for i in aux.indices { aux[i] = 0 } }

        let messageBytes = [UInt8](message)
        var signature = [UInt8](repeating: 0, count: 64)
        guard secp256k1_schnorrsig_sign32(ctx, &signature, messageBytes, &keypair, aux) == 1 else {
            return nil
        }

        return Data(signature)
    }

    /// Verify a 64-byte BIP-340 schnorr signature over a 32-byte message hash
    /// against a 32-byte x-only public key.
    ///
    /// Returns true only on a valid signature. Any malformed input (wrong
    /// length, a public key that is not a valid x-coordinate on the curve) or a
    /// failed curve operation returns false. No secret is involved, so the
    /// context is not randomized here.
    static func verify(signature64 signature: Data,
                       messageHash32 message: Data,
                       xOnlyPublicKey publicKey: Data) -> Bool {
        guard signature.count == 64, message.count == 32, publicKey.count == 32 else {
            return false
        }
        guard let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE)) else {
            return false
        }
        defer { secp256k1_context_destroy(ctx) }

        var xonly = secp256k1_xonly_pubkey()
        let publicKeyBytes = [UInt8](publicKey)
        guard secp256k1_xonly_pubkey_parse(ctx, &xonly, publicKeyBytes) == 1 else {
            return false   // not a valid x-only public key
        }

        let signatureBytes = [UInt8](signature)
        let messageBytes = [UInt8](message)
        let result = secp256k1_schnorrsig_verify(ctx,
                                                 signatureBytes,
                                                 messageBytes,
                                                 messageBytes.count,
                                                 &xonly)
        return result == 1
    }

    // MARK: - ECDH (8c-i-0)

    /// Compute the raw secp256k1 ECDH shared X coordinate between our 32-byte
    /// secret scalar and a peer's 32-byte x-only public key.
    ///
    /// This returns the BARE 32-byte X of the shared point (no SHA256), which is
    /// the input NIP-44 v2 feeds into HKDF to form the conversation key. The
    /// per-conversation HKDF/salt step is NIP-44's concern and lives there, not
    /// here — this helper stays a pure curve op.
    ///
    /// The peer key is x-only, so it is lifted to the even-Y point (0x02 prefix)
    /// before the multiply. The shared X is parity-independent (negating a point
    /// preserves its X), so the result matches regardless of either key's Y
    /// parity — which is exactly why the NIP-44 conversation key is symmetric.
    ///
    /// Returns nil on wrong-length inputs, an invalid secret scalar, a peer key
    /// that is not a valid curve x-coordinate, or any curve failure.
    static func ecdh(secretKey secret: Data, peerXOnlyPublicKey peerKey: Data) -> Data? {
        guard secret.count == 32, peerKey.count == 32 else { return nil }
        guard let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE)) else {
            return nil
        }
        defer { secp256k1_context_destroy(ctx) }

        // Randomize before the secret-key multiply (DPA hardening).
        var seed = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, seed.count, &seed) == errSecSuccess,
              secp256k1_context_randomize(ctx, seed) == 1 else {
            return nil
        }

        // Lift the peer x-only key to a full point as the even-Y candidate by
        // prefixing 0x02, then parse it as a compressed public key.
        var compressed = [UInt8](repeating: 0, count: 33)
        compressed[0] = 0x02
        let peerBytes = [UInt8](peerKey)
        for i in 0..<32 { compressed[1 + i] = peerBytes[i] }

        var pubkey = secp256k1_pubkey()
        guard secp256k1_ec_pubkey_parse(ctx, &pubkey, compressed, 33) == 1 else {
            return nil   // peer key not a valid curve x-coordinate
        }

        // Local copy of the secret; zeroed on the way out for hygiene.
        var secretBytes = [UInt8](secret)
        defer { for i in secretBytes.indices { secretBytes[i] = 0 } }

        var output = [UInt8](repeating: 0, count: 32)
        guard secp256k1_ecdh(ctx,
                             &output,
                             &pubkey,
                             secretBytes,
                             secp256k1RawXCopyHash,
                             nil) == 1 else {
            return nil   // invalid scalar, or shared point at infinity
        }

        return Data(output)
    }
}
