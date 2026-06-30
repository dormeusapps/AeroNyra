//
//  DiscoverySecret.swift
//  Security/Session
//
//  Derives the per-pairing discovery secret S_AB that keys the reconnection
//  beacon (Closed-Contact Step 5c). Specified in docs/RECONNECT_DISCOVERY_SECRET_KAT.md;
//  context in docs/RECONNECT_HANDSHAKE.md (the two-layer discovery/auth split).
//
//  This is the PRODUCER for the value that BeaconRecognizer.Contact.secret and
//  ReconnectBeacon.token(secret:) consume as an opaque input. The beacon layer is
//  deliberately independent of how S_AB is made; this file is that "how".
//
//  PURE. No clock, no I/O, no stored state, nothing to inject. A static X25519
//  Diffie-Hellman between our identity-agreement private key and a contact's
//  identity-agreement public key, conditioned through HKDF-SHA256 under a fixed
//  domain label.
//
//  WHY SECRET, WHY SYMMETRIC (KAT §0/§1):
//    • secret — the DH needs a PRIVATE key, so an outsider who scraped a public
//      bundle cannot compute it. This is the property that preserves beacon
//      unlinkability: a secret built only from the two PUBLIC keys would be
//      world-computable and would defeat the whole scheme.
//    • symmetric — X25519 DH(a_priv, B_pub) == DH(b_priv, A_pub), and because no
//      public-key material is folded into salt/info, both sides feed byte-identical
//      HKDF inputs and reach the same S_AB with zero canonicalization/tie-break.
//
//  KEY HYGIENE:
//    • A bare identity×identity static DH is NOT one of the X3DH/PQXDH DH
//      combinations (those mix ephemerals/prekeys and never combine the two static
//      identities), so this DH output is computed in no other code path. The HKDF
//      `info` label separates the derived key regardless.
//    • The agreement key is CryptoKit-native (IdentityKeypair.agreement, a
//      Curve25519.KeyAgreement.PrivateKey), so there is no libsignal bridge and no
//      Secure-Enclave round-trip on this path. The Enclave only wraps the at-rest
//      identity blob; at runtime the live private key drives the DH directly.
//    • CryptoKit's SharedSecret / SymmetricKey zeroize their own buffers on
//      release; this function holds no raw key bytes to scrub.
//

import Foundation
import CryptoKit

public enum DiscoverySecret {

    /// HKDF `info` — domain separation for the discovery secret. Bumping the
    /// "/v1" suffix is a wire-format version change and REQUIRES recomputing the
    /// KAT set in docs/RECONNECT_DISCOVERY_SECRET_KAT.md.
    static let info = Data("AeroNyra/discovery-secret/v1".utf8)

    /// Output length: a 256-bit key.
    static let length = 32

    /// Derive the per-pairing discovery secret S_AB.
    ///
    /// - Parameters:
    ///   - ourAgreementPrivate: our identity X25519 key-agreement private key
    ///     (`IdentityKeypair.agreement`).
    ///   - theirAgreementPublic: the contact's identity X25519 key-agreement public
    ///     key as 32 raw bytes — i.e. `PublicIdentity.agreementKey`, which is the
    ///     same value used as the beacon `label` and stored as
    ///     `BeaconRecognizer.Contact.identity`.
    /// - Returns: the 32-byte S_AB as a `SymmetricKey`. The wiring layer converts
    ///   it to `Data` for the `Contact.secret` slot via `rawBytes(of:)`.
    /// - Throws: `CryptoKitError` if `theirAgreementPublic` is not a valid X25519
    ///   public key (e.g. wrong length).
    public static func derive(
        ourAgreementPrivate: Curve25519.KeyAgreement.PrivateKey,
        theirAgreementPublic: Data
    ) throws -> SymmetricKey {
        let theirKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: theirAgreementPublic)
        return try derive(ourAgreementPrivate: ourAgreementPrivate, theirAgreementPublic: theirKey)
    }

    /// Typed-key overload. Identical derivation; takes an already-validated
    /// `Curve25519.KeyAgreement.PublicKey`. Still throwing: the key agreement
    /// itself can fail (e.g. a degenerate/low-order peer point), and we surface
    /// that rather than force-unwrap into a crash.
    public static func derive(
        ourAgreementPrivate: Curve25519.KeyAgreement.PrivateKey,
        theirAgreementPublic: Curve25519.KeyAgreement.PublicKey
    ) throws -> SymmetricKey {
        // ikm = the 32-byte raw X25519 shared point.
        let shared = try ourAgreementPrivate.sharedSecretFromKeyAgreement(
            with: theirAgreementPublic)
        // S_AB = HKDF-SHA256(ikm, salt = "" , info, L = 32).
        // Empty salt is the RFC 5869 "not provided" path (HashLen zeros); see the
        // empty-salt equivalence note in the KAT.
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: info,
            outputByteCount: length
        )
    }

    /// Raw bytes of a derived secret, for storing into the `Data`-typed
    /// `BeaconRecognizer.Contact.secret` / passing to `ReconnectBeacon.token`.
    public static func rawBytes(of secret: SymmetricKey) -> Data {
        secret.withUnsafeBytes { Data($0) }
    }
}
