// PendingInvitesCodec.swift
// Security/Session
//
// The at-rest wire format for the initiator's `PendingInvites` burn ledger
// (STEP 7c-2). PURE and deterministic — it turns the {id → expiresAt} ledger
// into a canonical byte blob and back, with no crypto and no I/O. Sealing that
// blob to disk (ChaChaPoly + a dedicated DEK) is `PendingInvitesStore`'s job, a
// later sub-step; this layer only defines the bytes. Mirrors
// `ContactAllowlistCodec` field-for-field where the shapes align.
//
// The store persists ONLY this ledger — never the Invite / PairingPayload. The
// initiator doesn't need the payload after minting; it only needs to recognize
// and burn an echoed id, which is decided from {id, expiresAt} alone. So the
// sealed file is just random nonces + timestamps — nothing key-bearing.
//
// FORMAT v1 (fixed-width, self-describing, KAT-anchored):
//
//     byte 0        version (0x01)
//     bytes 1..<3   count   (UInt16, big-endian) — number of entries
//     then `count` records, each 24 bytes:
//         [id:16] [expiresAt:8  Int64 big-endian]
//
// CANONICAL ORDER: entries are emitted sorted ASCENDING by id bytes
// (lexicographic). `PendingInvites` stores entries in a dictionary whose
// iteration order is non-deterministic, so without this sort the same ledger
// could serialize to different bytes across launches — which would defeat any
// byte-level equality check and any KAT. The sort makes the encoding a function
// of the SET, not of insertion order.
//
// STRICT DECODE: a persisted single-use ledger must never silently mutate — a
// dropped or duplicated id would break the single-use guarantee. Unknown
// version, a length that doesn't match the declared count, or a duplicate id all
// THROW rather than being guessed past — the store surfaces the failure rather
// than restoring a corrupted ledger.
//
// This format is anchored to `PendingInvitesCodecTests` KAT vectors computed OUT
// of this implementation (docs/PENDING_INVITES_CODEC_KAT.md). Do not change a
// field width or the sort without recomputing the whole vector set.
//

import Foundation

public enum PendingInvitesCodec {

    /// Wire-format version. Bump on any breaking layout change (and add a
    /// migration path in `decode`).
    public static let version: UInt8 = 0x01

    /// Id width — must match `Invite.idByteCount` (16). Validated on encode.
    static let idSize = 16

    /// Fixed per-entry size: id(16) + expiresAt(8).
    static let entrySize = 16 + 8

    /// Fixed header size: version(1) + count(2).
    static let headerSize = 1 + 2

    public enum CodecError: Error, Equatable {
        /// More than 0xFFFF pending invites — the 2-byte count can't represent it.
        case tooManyEntries(Int)
        /// An in-RAM id whose length isn't the expected 16 bytes (corruption).
        case nonStandardID(Int)
        /// Fewer than the 3 header bytes.
        case shortBuffer
        /// Version byte isn't one this codec understands.
        case unknownVersion(UInt8)
        /// Declared count and actual buffer length disagree.
        case lengthMismatch(expected: Int, actual: Int)
        /// The same id appears twice in one blob.
        case duplicateID
    }

    // MARK: - Encode

    /// Serialize a ledger to the canonical v1 blob. Uses only the type's public
    /// `entries` view, so `PendingInvites` itself stays otherwise unchanged.
    public static func encode(_ ledger: PendingInvites) throws -> Data {
        // Sort the (id, expiresAt) pairs ascending by id — no re-lookup, no
        // force-unwrap on a security path.
        let sorted = ledger.entries.sorted { $0.key.lexicographicallyPrecedes($1.key) }
        guard sorted.count <= 0xFFFF else { throw CodecError.tooManyEntries(sorted.count) }

        var out = Data()
        out.reserveCapacity(headerSize + sorted.count * entrySize)
        out.append(version)
        out.append(UInt8((sorted.count >> 8) & 0xFF))
        out.append(UInt8(sorted.count & 0xFF))

        for (id, expiresAt) in sorted {
            guard id.count == idSize else { throw CodecError.nonStandardID(id.count) }
            out.append(id)
            var be = UInt64(bitPattern: expiresAt).bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        }
        return out
    }

    // MARK: - Decode

    /// Parse a v1 blob back into a ledger. Strict: any structural surprise throws
    /// rather than producing a silently-altered single-use ledger.
    public static func decode(_ data: Data) throws -> PendingInvites {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize else { throw CodecError.shortBuffer }
        guard bytes[0] == version else { throw CodecError.unknownVersion(bytes[0]) }

        let count = (Int(bytes[1]) << 8) | Int(bytes[2])
        let expected = headerSize + count * entrySize
        guard bytes.count == expected else {
            throw CodecError.lengthMismatch(expected: expected, actual: bytes.count)
        }

        var map = [Data: Int64]()
        var i = headerSize

        for _ in 0..<count {
            let id = Data(bytes[i ..< i + idSize]); i += idSize

            var expU: UInt64 = 0
            for _ in 0..<8 { expU = (expU << 8) | UInt64(bytes[i]); i += 1 }

            guard map[id] == nil else { throw CodecError.duplicateID }
            map[id] = Int64(bitPattern: expU)
        }
        return PendingInvites(entries: map)
    }
}
