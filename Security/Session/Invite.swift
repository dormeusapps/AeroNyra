// Invite.swift
// Security/Session
//
// The short-lived, single-use wrapper around a PairingPayload for REMOTE pairing
// (docs/CONTACT_MODEL.md §7). When two people aren't together, the initiator
// mints an Invite, sends it over any channel, and the peer redeems it. The
// Invite adds the two guarantees the bare payload lacks:
//
//   • EXPIRY — an absolute expiry timestamp; a stale (e.g. screenshotted) invite
//     is refused. Expiry is a blast-radius control, not the security boundary —
//     the 4-word SAS confirmation remains the actual MITM defense.
//   • SINGLE-USE — enforced by the INITIATOR via PendingInvites (below), because
//     in a serverless model the only party who can burn an invite is the one who
//     completes the pairing. There is no server to invalidate a token centrally.
//
// Both halves are PURE and take `now` as a parameter (never read the clock
// internally), so the lifecycle is deterministic under test. No UI, no
// networking, no persistence — those are later wiring concerns. Mirrors
// PairingPayload / Envelope's `wireData()` / `init?(wire:)` idiom.
//
// WIRE LAYOUT:
//
//     byte 0          version (UInt8) = 1
//     bytes 1..17     invite id      (16 random bytes — the nonce)
//     bytes 17..25    mintedAt       (Int64 ms, big-endian)
//     bytes 25..33    expiresAt      (Int64 ms, big-endian)
//     bytes 33..37    payload length (UInt32, big-endian)
//     bytes 37..      PairingPayload.wireData()
//

import Foundation
import Security   // SecRandomCopyBytes (CSPRNG)

public struct Invite: Equatable, Sendable {

    /// Wire-format version. Bump on any breaking layout change.
    public static let currentVersion: UInt8 = 1

    /// Invite id (nonce) length — 128-bit, same size as MessageID.
    public static let idByteCount = 16

    /// Default time-to-live for a freshly minted invite (~10 minutes).
    public static let defaultTTLMillis: Int64 = 10 * 60 * 1000

    /// Clock-skew tolerance applied when checking expiry, so two phones with
    /// slightly different clocks don't reject a legitimately-live invite. Lenient
    /// toward acceptance; single-use + SAS carry the real security.
    public static let defaultSkewMillis: Int64 = 2 * 60 * 1000

    /// The pairing material this invite carries.
    public let payload: PairingPayload

    /// Random nonce identifying this invite; the redeemer echoes it back so the
    /// initiator can match and burn it (PendingInvites).
    public let id: Data

    /// When the invite was minted (Unix ms).
    public let mintedAt: Int64

    /// Absolute expiry (Unix ms).
    public let expiresAt: Int64

    public init(payload: PairingPayload, id: Data, mintedAt: Int64, expiresAt: Int64) {
        self.payload = payload
        self.id = id
        self.mintedAt = mintedAt
        self.expiresAt = expiresAt
    }

    // MARK: - Mint

    /// Mint a fresh invite for `payload`, expiring `ttlMillis` after `now`. `id`
    /// defaults to a fresh CSPRNG nonce; pass one only for deterministic tests.
    public static func mint(payload: PairingPayload,
                            now: Int64,
                            ttlMillis: Int64 = defaultTTLMillis,
                            id: Data = randomID()) -> Invite {
        Invite(payload: payload, id: id, mintedAt: now, expiresAt: now + ttlMillis)
    }

    /// A fresh 16-byte CSPRNG nonce.
    public static func randomID() -> Data {
        var b = [UInt8](repeating: 0, count: idByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, idByteCount, &b)
        precondition(status == errSecSuccess, "CSPRNG (SecRandomCopyBytes) failed")
        return Data(b)
    }

    // MARK: - Expiry

    /// Whether this invite is still live at `now` (within `skew` past expiry).
    public func isLive(at now: Int64, skewMillis: Int64 = defaultSkewMillis) -> Bool {
        now <= expiresAt + skewMillis
    }
}

// MARK: - Wire format

public extension Invite {

    func wireData() -> Data {
        var d = Data()
        d.append(Self.currentVersion)
        d.append(id)                       // fixed 16 bytes
        Self.appendI64(&d, mintedAt)
        Self.appendI64(&d, expiresAt)
        let payloadBytes = payload.wireData()
        Self.appendU32(&d, UInt32(payloadBytes.count))
        d.append(payloadBytes)
        return d
    }

    /// Parse from the binary layout. Returns nil on wrong version, truncation,
    /// trailing junk, or a malformed nested PairingPayload.
    init?(wire data: Data) {
        let bytes = [UInt8](data)
        var i = 0

        guard bytes.count >= 1, bytes[0] == Self.currentVersion else { return nil }
        i = 1

        guard i + Self.idByteCount <= bytes.count else { return nil }
        let id = Data(bytes[i ..< i + Self.idByteCount])
        i += Self.idByteCount

        guard let mintedRaw = Self.readU64(bytes, &i),
              let expiresRaw = Self.readU64(bytes, &i),
              let payloadLen = Self.readU32(bytes, &i) else { return nil }

        let len = Int(payloadLen)
        guard i + len <= bytes.count else { return nil }
        let payloadBytes = Data(bytes[i ..< i + len])
        i += len
        guard i == bytes.count else { return nil }      // reject trailing junk

        guard let payload = PairingPayload(wire: payloadBytes) else { return nil }

        self.init(payload: payload,
                  id: id,
                  mintedAt: Int64(bitPattern: mintedRaw),
                  expiresAt: Int64(bitPattern: expiresRaw))
    }

    // MARK: Encode/parse helpers

    private static func appendU32(_ d: inout Data, _ v: UInt32) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
    }

    private static func appendI64(_ d: inout Data, _ v: Int64) {
        var be = UInt64(bitPattern: v).bigEndian
        withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
    }

    private static func readU32(_ bytes: [UInt8], _ i: inout Int) -> UInt32? {
        guard i + 4 <= bytes.count else { return nil }
        let v = (UInt32(bytes[i]) << 24) | (UInt32(bytes[i + 1]) << 16)
              | (UInt32(bytes[i + 2]) << 8) | UInt32(bytes[i + 3])
        i += 4
        return v
    }

    private static func readU64(_ bytes: [UInt8], _ i: inout Int) -> UInt64? {
        guard i + 8 <= bytes.count else { return nil }
        var v: UInt64 = 0
        for k in 0..<8 { v = (v << 8) | UInt64(bytes[i + k]) }
        i += 8
        return v
    }
}

// MARK: - PendingInvites (initiator-side single-use accounting)

/// The initiator's burn ledger: the set of invite ids it has minted and not yet
/// consumed. SINGLE-USE lives here because the initiator is the only party that
/// completes a pairing in a serverless model — when a reply echoes an invite id,
/// the initiator consumes it exactly once; a replayed id finds nothing pending.
///
/// Pure in-memory value type, `now` injected. Bounded by pruning expired ids;
/// no remote party can grow it (only the local user mints). Persistence /
/// actor-confinement are later wiring concerns.
public struct PendingInvites: Equatable, Sendable {

    /// id → absolute expiry (Unix ms).
    private var pending: [Data: Int64] = [:]

    public init() {}

    /// Number of currently-tracked (registered, unconsumed) ids.
    public var count: Int { pending.count }

    /// Record a freshly-minted invite as pending.
    public mutating func register(id: Data, expiresAt: Int64) {
        pending[id] = expiresAt
    }

    /// Convenience: register straight from a minted Invite.
    public mutating func register(_ invite: Invite) {
        register(id: invite.id, expiresAt: invite.expiresAt)
    }

    /// Attempt to burn `id`. Returns true EXACTLY ONCE — for an id that is
    /// pending and still live at `now` — and removes it. Returns false for an
    /// unknown id, an already-consumed id (replay), or an expired one (which is
    /// also dropped). This is the single-use guarantee.
    public mutating func consume(id: Data,
                                 at now: Int64,
                                 skewMillis: Int64 = Invite.defaultSkewMillis) -> Bool {
        guard let expiresAt = pending[id] else { return false }   // unknown / already consumed
        guard now <= expiresAt + skewMillis else {                // expired
            pending[id] = nil
            return false
        }
        pending[id] = nil                                         // burn
        return true
    }

    /// Whether `id` is currently pending (and not expired) at `now`.
    public func isPending(id: Data,
                          at now: Int64,
                          skewMillis: Int64 = Invite.defaultSkewMillis) -> Bool {
        guard let expiresAt = pending[id] else { return false }
        return now <= expiresAt + skewMillis
    }

    /// Drop every expired id so the ledger stays bounded.
    public mutating func prune(at now: Int64,
                               skewMillis: Int64 = Invite.defaultSkewMillis) {
        pending = pending.filter { now <= $0.value + skewMillis }
    }
}
