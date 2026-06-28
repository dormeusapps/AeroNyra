// MediaChunker.swift
// Core/Media
//
// Splits a media blob into self-describing, PayloadBucket-aligned chunks and
// reassembles them. This is the layer ABOVE sealing: each chunk this produces
// becomes the plaintext of one sealed Envelope. It is pure Data→[Data]→Data
// logic — no transport, no crypto, no hardware — so it is fully unit-testable
// on the Mac.
//
// SIZE DESIGN (grounded in Envelope.swift): the Security layer pads every
// plaintext up to the smallest `PayloadBucket` that fits before sealing. So the
// right chunk size is one where `[chunk header ‖ chunk data]` fills a chosen
// bucket EXACTLY — any larger and it spills into the next bucket and wastes a
// whole padding tier; any smaller and it wastes space in the current tier.
// The chunker therefore targets a bucket (default 4096, the balanced tier) and
// carves `bucket − headerSize` bytes of media per chunk. Result: zero padding
// waste and the minimum chunk count for that tier.
//
// CHUNK WIRE LAYOUT (the plaintext that gets sealed):
//
//     bytes 0..<16   mediaID (16 raw bytes)
//     bytes 16..<20  index  (UInt32, big-endian)
//     bytes 20..<24  total  (UInt32, big-endian)   — total chunk count
//     bytes 24..      payload (media bytes; < bucket − headerSize)
//
// Each chunk is self-describing: a receiver can reassemble from chunks arriving
// in any order, and knows when it has them all, without consulting the manifest
// first. The manifest still carries the integrity hash and mime.
//

import Foundation
import Security   // SecRandomCopyBytes

public enum MediaChunkerError: Error, Equatable {
    /// A target bucket was requested that PayloadBucket doesn't define.
    case invalidBucket(Int)
    /// The blob is empty — nothing to chunk.
    case emptyBlob
    /// A chunk buffer was too short to contain the fixed header.
    case malformedChunk
    /// Reassembly found a gap (missing index) or a duplicate/again count
    /// mismatch.
    case missingChunks(expected: Int, got: Int)
    /// Chunks disagree on mediaID or total — they are not one transfer.
    case inconsistentChunks
    /// Reassembled bytes did not match the manifest's SHA-256.
    case integrityFailure
}

public struct MediaChunker {

    /// Fixed per-chunk header: mediaID(16) + index(4) + total(4).
    public static let headerSize = 16 + 4 + 4

    /// The PayloadBucket tier each chunk (header + payload) is sized to fill.
    /// 4096 is the balanced default; 16384 sends fewer/larger chunks, 1024
    /// sends more/smaller. Must be one of `PayloadBucket.sizes`.
    public let targetBucket: Int

    /// Bytes to leave free at the front of the bucket for an OUTER frame the
    /// chunker itself doesn't write — specifically the 1-byte payload-kind tag
    /// (see MessagePayload) that classifies a sealed plaintext as text vs.
    /// manifest vs. chunk. Reserving it here keeps `[tag ‖ header ‖ payload]`
    /// inside the SAME bucket, so a framed chunk still pads to `targetBucket`
    /// exactly rather than spilling into the next tier. Default 0 (unframed).
    public let reservedBytes: Int

    /// Bytes of actual media carried per chunk.
    public var payloadPerChunk: Int { targetBucket - Self.headerSize - reservedBytes }

    public init(targetBucket: Int = 4096, reservedBytes: Int = 0) throws {
        guard PayloadBucket.sizes.contains(targetBucket) else {
            throw MediaChunkerError.invalidBucket(targetBucket)
        }
        // Leave at least one byte of media per chunk after header + reserve.
        guard reservedBytes >= 0,
              targetBucket - Self.headerSize - reservedBytes > 0 else {
            throw MediaChunkerError.invalidBucket(targetBucket)
        }
        self.targetBucket = targetBucket
        self.reservedBytes = reservedBytes
    }

    // MARK: - Split

    /// Split a blob into chunks + the manifest describing them.
    ///
    /// - Parameters:
    ///   - blob: the complete media bytes.
    ///   - mime: what the bytes are.
    ///   - mediaID: 16 raw bytes tying chunks to the manifest. Defaults to a
    ///     fresh random id; pass one only for deterministic tests.
    /// - Returns: the manifest (send first) and the ordered chunk plaintexts
    ///   (each becomes one sealed Envelope).
    public func split(_ blob: Data,
                      mime: MediaMimeType,
                      mediaID: [UInt8]? = nil) throws -> (manifest: MediaManifest, chunks: [Data]) {
        guard !blob.isEmpty else { throw MediaChunkerError.emptyBlob }

        let idBytes = try mediaID ?? Self.randomID()
        guard idBytes.count == 16 else { throw MediaChunkerError.malformedChunk }

        // Carve the blob into payloadPerChunk-sized pieces.
        var payloads: [Data] = []
        var offset = blob.startIndex
        while offset < blob.endIndex {
            let end = blob.index(offset, offsetBy: payloadPerChunk, limitedBy: blob.endIndex) ?? blob.endIndex
            payloads.append(Data(blob[offset..<end]))
            offset = end
        }

        let total = UInt32(payloads.count)
        var chunks: [Data] = []
        chunks.reserveCapacity(payloads.count)
        for (i, payload) in payloads.enumerated() {
            var chunk = Data(capacity: Self.headerSize + payload.count)
            chunk.append(contentsOf: idBytes)
            chunk.append(bigEndian: UInt32(i))
            chunk.append(bigEndian: total)
            chunk.append(payload)
            chunks.append(chunk)
        }

        let manifest = MediaManifest(
            mediaID: idBytes.map { String(format: "%02x", $0) }.joined(),
            mime: mime,
            totalBytes: blob.count,
            chunkCount: payloads.count,
            sha256: MediaManifest.hashHex(blob))

        return (manifest, chunks)
    }

    // MARK: - Reassemble

    /// A parsed chunk header + payload.
    public struct ParsedChunk: Equatable {
        public let mediaID: [UInt8]
        public let index: Int
        public let total: Int
        public let payload: Data
    }

    /// Parse one chunk's fixed header and payload.
    public func parse(_ chunk: Data) throws -> ParsedChunk {
        guard chunk.count >= Self.headerSize else { throw MediaChunkerError.malformedChunk }
        let bytes = [UInt8](chunk)
        let id = Array(bytes[0..<16])
        let index = Self.readU32(bytes, at: 16)
        let total = Self.readU32(bytes, at: 20)
        let payload = Data(bytes[Self.headerSize...])
        return ParsedChunk(mediaID: id, index: Int(index), total: Int(total), payload: payload)
    }

    /// Reassemble a complete blob from chunks (any order), verifying it against
    /// the manifest's chunk count and SHA-256. Throws on a gap, an inconsistent
    /// set, or an integrity mismatch.
    public func reassemble(_ chunks: [Data], manifest: MediaManifest) throws -> Data {
        let parsed = try chunks.map(parse)

        // All chunks must agree on mediaID and total, and match the manifest.
        guard let first = parsed.first else {
            throw MediaChunkerError.missingChunks(expected: manifest.chunkCount, got: 0)
        }
        let id = first.mediaID
        for p in parsed where p.mediaID != id || p.total != first.total {
            throw MediaChunkerError.inconsistentChunks
        }
        guard first.total == manifest.chunkCount else {
            throw MediaChunkerError.inconsistentChunks
        }

        // Place by index; detect gaps and duplicates.
        var slots = [Data?](repeating: nil, count: manifest.chunkCount)
        for p in parsed {
            guard p.index >= 0 && p.index < manifest.chunkCount else {
                throw MediaChunkerError.inconsistentChunks
            }
            slots[p.index] = p.payload
        }
        let present = slots.compactMap { $0 }.count
        guard present == manifest.chunkCount else {
            throw MediaChunkerError.missingChunks(expected: manifest.chunkCount, got: present)
        }

        var blob = Data(capacity: manifest.totalBytes)
        for slot in slots { blob.append(slot!) }

        guard MediaManifest.hashHex(blob) == manifest.sha256 else {
            throw MediaChunkerError.integrityFailure
        }
        return blob
    }

    /// Which chunk indices are still missing, for a future re-request path
    /// (Phase 5b+/7c auto-retry). Returns the sorted set of absent indices.
    public func missingIndices(have chunks: [Data], manifest: MediaManifest) -> [Int] {
        var seen = Set<Int>()
        for chunk in chunks {
            if let p = try? parse(chunk), p.index >= 0, p.index < manifest.chunkCount {
                seen.insert(p.index)
            }
        }
        return (0..<manifest.chunkCount).filter { !seen.contains($0) }
    }

    // MARK: - Internals

    private static func randomID() throws -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, 16, &b) == errSecSuccess else {
            throw MediaChunkerError.malformedChunk
        }
        return b
    }

    private static func readU32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }
}

// MARK: - Data big-endian append

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        var be = value.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
}
