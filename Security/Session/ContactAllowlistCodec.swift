// ContactAllowlistCodec.swift
// Security/Session
//
// The at-rest wire format for `ContactAllowlist` (STEP 7a-1). PURE and
// deterministic — it turns the paired-contact set into a canonical byte blob and
// back, with no crypto and no I/O. Sealing that blob to disk (ChaChaPoly + the
// vault DEK) is `ContactAllowlistStore`'s job, a later sub-step; this layer only
// defines the bytes.
//
// FORMAT v1 (fixed-width, self-describing, KAT-anchored):
//
//     byte 0        version (0x01)
//     bytes 1..<3   count   (UInt16, big-endian) — number of entries
//     then `count` records, each 41 bytes:
//         [identity:32] [pairedAt:8 Int64 big-endian] [verified:1  0x00|0x01]
//
// CANONICAL ORDER: entries are emitted sorted ASCENDING by identity bytes
// (lexicographic). `ContactAllowlist` stores entries in a dictionary whose
// iteration order is non-deterministic, so without this sort the same set could
// serialize to different bytes across launches — which would defeat any
// byte-level equality check and any KAT. The sort makes the encoding a function
// of the SET, not of insertion order.
//
// STRICT DECODE: a persisted admission set must never silently mutate. Unknown
// version, a length that doesn't match the declared count, a verified byte other
// than 0x00/0x01, or a duplicate identity all THROW rather than being guessed
// past — the store surfaces the failure rather than admitting a corrupted set.
//
// This format is anchored to `ContactAllowlistCodecTests` KAT vectors computed
// OUT of this implementation. Do not change a field width or the sort without
// recomputing the whole vector set.
//

import Foundation

public enum ContactAllowlistCodec {

    /// Wire-format version. Bump on any breaking layout change (and add a
    /// migration path in `decode`).
    public static let version: UInt8 = 0x01

    /// Fixed per-entry size: identity(32) + pairedAt(8) + verified(1).
    static let entrySize = 32 + 8 + 1

    /// Fixed header size: version(1) + count(2).
    static let headerSize = 1 + 2

    public enum CodecError: Error, Equatable {
        /// More than 0xFFFF contacts — the 2-byte count can't represent it.
        case tooManyEntries(Int)
        /// An in-RAM entry whose identity isn't the expected 32 bytes (corruption).
        case nonStandardIdentity(Int)
        /// Fewer than the 3 header bytes.
        case shortBuffer
        /// Version byte isn't one this codec understands.
        case unknownVersion(UInt8)
        /// Declared count and actual buffer length disagree.
        case lengthMismatch(expected: Int, actual: Int)
        /// A verified flag that is neither 0x00 nor 0x01.
        case badVerifiedByte(UInt8)
        /// The same identity appears twice in one blob.
        case duplicateIdentity
    }

    // MARK: - Encode

    /// Serialize an allowlist to the canonical v1 blob. Uses only the type's
    /// public surface (`identities`, `entry(for:)`), so `ContactAllowlist`
    /// itself stays unchanged.
    public static func encode(_ allowlist: ContactAllowlist) throws -> Data {
        let ids = allowlist.identities.sorted { $0.lexicographicallyPrecedes($1) }
        guard ids.count <= 0xFFFF else { throw CodecError.tooManyEntries(ids.count) }

        var out = Data()
        out.reserveCapacity(headerSize + ids.count * entrySize)
        out.append(version)
        out.append(UInt8((ids.count >> 8) & 0xFF))
        out.append(UInt8(ids.count & 0xFF))

        for id in ids {
            guard id.count == 32 else { throw CodecError.nonStandardIdentity(id.count) }
            // entry(for:) can't be nil here — id came from identities — but stay
            // defensive rather than force-unwrap on a security path.
            guard let entry = allowlist.entry(for: id) else {
                throw CodecError.nonStandardIdentity(id.count)
            }
            out.append(id)
            var be = UInt64(bitPattern: entry.pairedAt).bigEndian
            withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
            out.append(entry.verified ? 0x01 : 0x00)
        }
        return out
    }

    // MARK: - Decode

    /// Parse a v1 blob back into an allowlist. Strict: any structural surprise
    /// throws rather than producing a silently-altered admission set.
    public static func decode(_ data: Data) throws -> ContactAllowlist {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize else { throw CodecError.shortBuffer }
        guard bytes[0] == version else { throw CodecError.unknownVersion(bytes[0]) }

        let count = (Int(bytes[1]) << 8) | Int(bytes[2])
        let expected = headerSize + count * entrySize
        guard bytes.count == expected else {
            throw CodecError.lengthMismatch(expected: expected, actual: bytes.count)
        }

        var allowlist = ContactAllowlist()
        var seen = Set<Data>()
        var i = headerSize

        for _ in 0..<count {
            let id = Data(bytes[i ..< i + 32]); i += 32

            var pairedU: UInt64 = 0
            for _ in 0..<8 { pairedU = (pairedU << 8) | UInt64(bytes[i]); i += 1 }
            let pairedAt = Int64(bitPattern: pairedU)

            let verifiedByte = bytes[i]; i += 1
            let verified: Bool
            switch verifiedByte {
            case 0x00: verified = false
            case 0x01: verified = true
            default:   throw CodecError.badVerifiedByte(verifiedByte)
            }

            guard !seen.contains(id) else { throw CodecError.duplicateIdentity }
            seen.insert(id)
            allowlist.enroll(identity: id, at: pairedAt, verified: verified)
        }
        return allowlist
    }
}
