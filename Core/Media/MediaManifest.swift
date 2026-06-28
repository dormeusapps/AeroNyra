// MediaManifest.swift
// Core/Media
//
// The control header that announces a chunked media transfer (photo / voice
// note) before the chunks themselves arrive. It is sent as its own small
// message; the receiver uses it to know how many chunks to expect, how to
// reassemble them, and — via the whole-blob SHA-256 — whether the reassembled
// result is intact.
//
// WHY MEDIA IS CHUNKED AT ALL (ROADMAP D3): a photo or voice note is far larger
// than one Envelope can carry. Rather than invent a new large-message path, the
// blob is split into PayloadBucket-sized pieces, each sealed into its OWN
// Envelope with its own MessageID — so dedup, TTL relay, replay rejection, and
// the ratchet all work per-chunk for free. This manifest is the small first
// message that frames that burst.
//
// HONEST METADATA NOTE: fixed-bucket chunks hide each chunk's exact size, but
// the manifest's `chunkCount` (and `totalBytes`) still reveals the rough size
// of the media. That is a far smaller leak than raw length and is the realistic
// ceiling for media over a flooding mesh; revisit with padding work (Phase 9).
//

import Foundation
import CryptoKit

// MARK: - MediaMimeType

/// The kinds of media v1 carries. Kept tiny and explicit (no open-ended MIME
/// string) so the wire stays compact and the UI knows exactly how to render.
public enum MediaMimeType: String, Sendable, Codable, CaseIterable {
    case jpeg          // photos
    case m4a           // voice notes (AAC in an MPEG-4 container)
}

// MARK: - MediaManifest

/// Describes a complete media blob that is about to arrive as `chunkCount`
/// separate chunks. Codable so it can be serialized into a control message.
public struct MediaManifest: Equatable, Sendable, Codable {

    /// Stable id tying the manifest to its chunks (16 random bytes, hex).
    public let mediaID: String

    /// What the reassembled bytes are.
    public let mime: MediaMimeType

    /// Total size of the original blob in bytes.
    public let totalBytes: Int

    /// How many chunks the blob was split into.
    public let chunkCount: Int

    /// SHA-256 of the WHOLE original blob, hex. The receiver recomputes this
    /// over the reassembled bytes and rejects a mismatch.
    public let sha256: String

    public init(mediaID: String,
                mime: MediaMimeType,
                totalBytes: Int,
                chunkCount: Int,
                sha256: String) {
        self.mediaID = mediaID
        self.mime = mime
        self.totalBytes = totalBytes
        self.chunkCount = chunkCount
        self.sha256 = sha256
    }
}

// MARK: - Hashing helper

public extension MediaManifest {

    /// Lowercase-hex SHA-256 of a blob, matching the `sha256` field's format.
    static func hashHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
