// PayloadPadding.swift
// Core/Media
//
// Reversible fixed-size padding for sealed plaintexts (Phase 9b — metadata
// hardening, fixed-size text padding).
//
// WHY: a sealed Envelope's ciphertext length tracks its plaintext length, so a
// passive observer on EITHER transport (BLE sniffer, Nostr relay) can read the
// approximate size of every message even though it cannot read the contents.
// THREAT_MODEL.md §7 tracks this as the 9b item. Padding plaintext up to a small
// set of fixed bucket sizes before sealing collapses observed lengths to that
// set, so a short text, a delivery ack, and a Nostr-identity announcement all
// look identical on the wire.
//
// SCOPE (Option B, LOCKED): this pads the SMALL sealed payloads — text, ack,
// nostrIdentity. MEDIA is intentionally NOT padded here: `MediaChunker` already
// shapes each chunk's plaintext to fill a `PayloadBucket` tier EXACTLY (via its
// `reservedBytes`), so running a media chunk through this layer would only add a
// length header and spill it into the next tier (4096 → 16384), quadrupling
// every chunk. The wiring step exempts media by kind; this primitive stays pure
// and kind-agnostic.
//
// FORMAT:
//
//     bytes 0..<4    originalLength (UInt32, big-endian)
//     bytes 4..<4+n  the original payload (n = originalLength)
//     bytes 4+n..    zero padding up to the chosen bucket size
//
// The pad bytes are zero: the whole padded buffer is encrypted by `seal`, so an
// observer never sees the padding, and its content is irrelevant to the size
// goal. Zero is chosen for determinism (clean known-answer tests).
//
// BUCKET LADDER: reuses `PayloadBucket.sizes` (Envelope.swift) as the single
// source of truth — [256, 1024, 4096, 16384]. A payload whose header+body
// exceeds the largest bucket is rounded up to the next MULTIPLE of the largest
// bucket, so even an oversize message collapses to a coarse grid rather than
// leaking its exact length.
//
// This is the layer BELOW MessagePayload tagging and ABOVE sealing: the input
// is `MessagePayload.encoded()` ([kind] ‖ body); the output is what gets sealed.
// Pure Data→Data — no transport, no crypto, no hardware — fully unit-testable.
//

import Foundation

public enum PayloadPadding {

    /// Big-endian UInt32 length header prepended before padding.
    public static let lengthHeaderSize = 4

    /// The padded size for a buffer of `contentLength` bytes (header INCLUDED).
    /// Smallest `PayloadBucket` that fits; if it exceeds the largest bucket,
    /// the next multiple of the largest bucket. Always ≥ `contentLength`.
    static func paddedSize(forContentLength contentLength: Int) -> Int {
        if let bucket = PayloadBucket.bucket(forContentLength: contentLength) {
            return bucket
        }
        // Larger than the largest defined bucket: round up to a multiple of it
        // so oversize payloads still collapse onto a coarse grid.
        guard let largest = PayloadBucket.sizes.last, largest > 0 else {
            return contentLength
        }
        return ((contentLength + largest - 1) / largest) * largest
    }

    /// Pad `payload` to a fixed bucket size with a recoverable length header.
    /// The result is always one of `PayloadBucket.sizes` (or a multiple of the
    /// largest bucket for oversize input), so distinct short payloads become
    /// indistinguishable by length.
    public static func pad(_ payload: Data) -> Data {
        let needed = lengthHeaderSize + payload.count
        let target = paddedSize(forContentLength: needed)

        var out = Data(capacity: target)
        var lengthBE = UInt32(truncatingIfNeeded: payload.count).bigEndian
        withUnsafeBytes(of: &lengthBE) { out.append(contentsOf: $0) }
        out.append(payload)
        if out.count < target {
            out.append(Data(repeating: 0, count: target - out.count))
        }
        return out
    }

    /// Reverse `pad`: read the length header and slice the original payload back
    /// out, discarding the trailing zero padding. Returns nil on a buffer too
    /// short to hold the header or a declared length that runs past the buffer
    /// (a malformed or non-padded input).
    public static func unpad(_ padded: Data) -> Data? {
        let bytes = [UInt8](padded)
        guard bytes.count >= lengthHeaderSize else { return nil }

        let originalLength =
            (Int(bytes[0]) << 24) |
            (Int(bytes[1]) << 16) |
            (Int(bytes[2]) << 8) |
             Int(bytes[3])

        guard originalLength >= 0,
              bytes.count >= lengthHeaderSize + originalLength else { return nil }

        return Data(bytes[lengthHeaderSize ..< lengthHeaderSize + originalLength])
    }
}
