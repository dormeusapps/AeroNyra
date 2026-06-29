//
//  NostrIdentity.swift
//  Core/Nostr
//
//  The device's Nostr identity for the internet pillar (Phase 8).
//
//  A secp256k1 secret scalar — SEPARATE from the app's Enclave-bound Curve25519
//  identity, because Nostr is a different curve and the Enclave key is
//  non-extractable (so it can't seed this). Generated once and persisted via
//  NostrSecretStore (Keychain, ThisDeviceOnly). The public half is an x-only
//  32-byte key, shown/shared as `npub…` (NIP-19, see Bech32).
//
//  DEPENDENCY POSTURE: identity generation/persistence is dependency-free (8a) —
//  choosing a valid 32-byte scalar with the platform CSPRNG. The curve math that
//  derives the x-only PUBLIC key from the secret lives in `Secp256k1` (8b-i-1),
//  backed by the vendored libsecp256k1. This file imports no C: it stays Swift-
//  pure and delegates the one curve operation to the helper. Schnorr event
//  signing (8b-ii) will live alongside the derivation in that same helper.
//
//  SECRET VALIDITY: a secp256k1 private key must be in [1, n-1] where n is the
//  curve order. A uniform random 32-byte value is overwhelmingly valid; we still
//  reject the two degenerate cases (zero, or ≥ n) and re-draw, so a stored
//  secret is always a usable scalar for derivation.
//

import Foundation
import Security

enum NostrIdentityError: Error {
    case randomGenerationFailed
}

/// The persistent Nostr identity: the secret scalar, its `nsec` encoding, and —
/// as of 8b — the derived x-only public key and its `npub` encoding.
struct NostrIdentity {

    /// The 32-byte secret scalar. Never leaves the device; persisted in the
    /// Keychain via NostrSecretStore.
    let secretKeyBytes: Data

    /// The 32-byte x-only public key, derived from the secret via libsecp256k1
    /// (see `Secp256k1.xOnlyPublicKey`). nil only if derivation fails (which, for
    /// a stored scalar that passed `isValidScalar`, should not happen).
    ///
    /// Derivation runs on each access; callers that read it repeatedly (e.g. UI)
    /// may cache. Kept computed here to leave identity construction non-throwing.
    var publicKeyBytes: Data? {
        Secp256k1.xOnlyPublicKey(fromSecretKey: secretKeyBytes)
    }

    /// `npub1…` form of the public key (NIP-19). Non-nil once the pubkey derives.
    var npub: String? { publicKeyBytes.flatMap(NIP19.npub(fromPublicKey:)) }

    /// `nsec1…` form of the secret key (NIP-19). Pure encoding.
    /// Handle with care: this is the private key in shareable form.
    var nsec: String? { NIP19.nsec(fromSecretKey: secretKeyBytes) }

    // MARK: - Construction

    /// Wrap an existing 32-byte secret (e.g. loaded from the Keychain).
    /// Precondition: exactly 32 bytes. Validity is assumed for a value this code
    /// previously generated; reconstruction does not re-validate.
    init(secretKeyBytes: Data) {
        precondition(secretKeyBytes.count == 32, "Nostr secret must be 32 bytes")
        self.secretKeyBytes = secretKeyBytes
    }

    /// Generate a fresh identity: a uniformly random, curve-valid 32-byte scalar.
    init() throws {
        self.secretKeyBytes = try Self.generateValidScalar()
    }

    /// Load the persisted identity, or generate + persist one on first run —
    /// the same load-or-create shape as the session DEK.
    /// - Parameter service: stable bundle-scoped Keychain service id.
    static func loadOrCreate(service: String) throws -> NostrIdentity {
        if let bytes = try NostrSecretStore.load(service: service) {
            return NostrIdentity(secretKeyBytes: bytes)
        }
        let identity = try NostrIdentity()
        try NostrSecretStore.save(identity.secretKeyBytes, service: service)
        return identity
    }

    // MARK: - Scalar generation

    /// secp256k1 group order n. A valid private key d satisfies 1 ≤ d ≤ n-1.
    private static let curveOrder: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
        0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
        0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41,
    ]

    /// Draw a uniform 32-byte value and accept it iff it's a valid scalar
    /// (non-zero and < n). Rejection-sampling: the reject region is astronomically
    /// small (~2^-128 for ≥ n; 2^-256 for zero), so this effectively never loops.
    private static func generateValidScalar() throws -> Data {
        for _ in 0..<8 {
            var raw = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, 32, &raw) == errSecSuccess else {
                throw NostrIdentityError.randomGenerationFailed
            }
            if isValidScalar(raw) { return Data(raw) }
        }
        // 8 consecutive rejections is impossible in practice; treat as RNG fault.
        throw NostrIdentityError.randomGenerationFailed
    }

    /// True iff `bytes` (big-endian) is in [1, n-1].
    static func isValidScalar(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 32 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }      // d == 0
        // Reject d >= n via big-endian lexicographic compare against the order.
        for i in 0..<32 {
            if bytes[i] < curveOrder[i] { return true }        // strictly below n
            if bytes[i] > curveOrder[i] { return false }       // at or above n
        }
        return false                                           // exactly == n
    }
}
