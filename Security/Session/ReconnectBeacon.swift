//
//  ReconnectBeacon.swift
//  Security/Session
//
//  Pure discovery-beacon primitive for the closed-contact reconnection handshake
//  (Step 5, see docs/RECONNECT_HANDSHAKE.md). Produces the per-pairing presence
//  TOKEN that lets an already-paired peer be recognised over BLE without
//  re-leaking identity to a passive sniffer.
//
//  THIS IS THE EMIT SIDE + the shared token core only. Receiver-side recognition
//  (building the per-epoch {token → contact} table over ContactAllowlist and the
//  {E-1, E, E+1} skew window) lives in BeaconRecognizer, so this type stays
//  contact-independent and KAT-anchored in isolation — the same way
//  SASWordPhrase keeps its wordlist injected.
//
//  ⚠️ A TOKEN MATCH IS A HINT ONLY (Invariant #2, RECONNECT_HANDSHAKE §7). It
//  selects which session to *attempt*. Admission of a BLE link and any presence
//  flip MUST gate on the sealed "it's-me" opening under that session — NEVER on a
//  token match here. The token layer is replayable by design and is not trusted
//  to authenticate.
//
//  FRAMING (LOCKED v1, vectors in docs/RECONNECT_BEACON_KAT.md):
//      message = TAG ‖ epoch(UInt64 big-endian) ‖ label(32-byte raw identity key)
//      token   = HMAC-SHA256(key: S_AB, message)[0 ..< 16]
//  `label` is always the EMITTER's identity, which is what makes A's and B's
//  tokens differ on the wire (no visible pairing edge). `now` is INJECTED; this
//  type never reads the wall clock, so lifecycle tests are deterministic.
//

import Foundation
import CryptoKit

public enum ReconnectBeacon {

    // MARK: Locked constants (v1)

    /// Domain-separation tag. Bumping it is a new wire version — old tokens can
    /// never be confused with new framing. LOCKED for v1.
    public static let domainTag = Data("AeroNyra/reconnect-beacon/v1".utf8)

    /// Bytes of HMAC output kept per token. 128 bits: the false-match floor
    /// against any realistic decoy field is astronomically small, and forgery is
    /// moot — admission gates on the sealed it's-me, not on a token match.
    public static let tokenLength = 16

    /// Fixed emission-set size. Real tokens + random decoys padded to this count,
    /// so a passive sniffer cannot read the contact count N. 64 is chosen so a
    /// realistic closed-contact list never spills; spillover would be a
    /// *recognition miss* (a correctness bug), so it is designed out, not handled.
    public static let emissionSetSize = 64

    /// The 32-byte raw identity-key length the `label` must be.
    public static let labelLength = 32

    // MARK: Token core (KAT-anchored — see RECONNECT_BEACON_KAT.md §3)

    /// The per-pairing presence token for one epoch.
    ///
    /// - Parameters:
    ///   - secret: the pairing discovery secret `S_AB`. Opaque here; its
    ///     derivation from pairing material is a SEPARATE primitive with its own
    ///     KAT (kept out so this stays pure and list-independent).
    ///   - epoch: the time-bucket index (see `epoch(at:epochLength:)`).
    ///   - label: the EMITTER's raw 32-byte identity key (`Peer.publicKeyData`
    ///     representation). Used only as a PRF input — never appears on the wire.
    public static func token(secret: Data, epoch: UInt64, label: Data) -> Data {
        precondition(label.count == labelLength,
                     "label must be \(labelLength)-byte raw identity key, got \(label.count)")
        var message = Data()
        message.append(domainTag)
        var be = epoch.bigEndian
        withUnsafeBytes(of: &be) { message.append(contentsOf: $0) }
        message.append(label)

        let mac = HMAC<SHA256>.authenticationCode(for: message,
                                                  using: SymmetricKey(data: secret))
        return Data(Data(mac).prefix(tokenLength))
    }

    // MARK: Epoch bucketing (now INJECTED)

    /// Bucket an injected Unix time into an epoch index. `secondsSinceEpoch` is
    /// passed in (never read here) so lifecycle tests are deterministic.
    ///
    /// - Parameters:
    ///   - secondsSinceEpoch: Unix time in seconds, INJECTED by the caller.
    ///   - epochLength: bucket width in seconds (e.g. 900 = 15 min). Must be > 0.
    public static func epoch(at secondsSinceEpoch: UInt64, epochLength: UInt64) -> UInt64 {
        precondition(epochLength > 0, "epochLength must be positive")
        return secondsSinceEpoch / epochLength
    }

    // MARK: Emission set (decoy-padded, fixed size)

    /// Build the fixed-size emission set: the device's real per-pairing tokens
    /// for this epoch, padded with random `tokenLength`-byte decoys up to `size`,
    /// then shuffled so position carries no information. Randomness is INJECTED
    /// via `rng` (pass `SystemRandomNumberGenerator` in production for CSPRNG
    /// decoys; a seeded generator in tests for determinism).
    ///
    /// - Precondition: `real.count <= size`. A larger contact set would require a
    ///   spillover rule we deliberately don't have (see `emissionSetSize`).
    public static func emissionSet<R: RandomNumberGenerator>(
        real: [Data],
        size: Int = emissionSetSize,
        decoyLength: Int = tokenLength,
        using rng: inout R
    ) -> [Data] {
        precondition(real.count <= size,
                     "real token count \(real.count) exceeds emission set size \(size)")
        var set = real
        while set.count < size {
            var decoy = Data(count: decoyLength)
            for i in 0..<decoyLength {
                decoy[i] = UInt8.random(in: UInt8.min...UInt8.max, using: &rng)
            }
            set.append(decoy)
        }
        set.shuffle(using: &rng)
        return set
    }
}
