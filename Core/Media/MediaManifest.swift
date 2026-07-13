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
    case mp4           // video stories (H.264/AAC in an MPEG-4 container)
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

    /// When the SENDER first sent this media — the anchor a story's expiry
    /// window counts from (a resend/re-drive re-stamps the ORIGINAL time, so
    /// a retry can never extend the window). nil on a legacy manifest and on
    /// non-story media. Sender-asserted: the receiver must clamp it to its
    /// own arrival time before persisting (a future-dated stamp would make a
    /// story immortal).
    public let sentAt: Date?

    /// True when this transfer is a story: ephemeral on BOTH ends,
    /// self-destructing a fixed window after `sentAt` — the stories-only
    /// reversal of the SEC-6 "outbound never expires" rule. Absent on a
    /// legacy manifest → false (see the custom decoder below).
    public let isStory: Bool

    /// True when this `.m4a` transfer is a push-to-talk utterance (walkie-
    /// talkie), so the receiver renders/auto-plays it as PTT rather than a
    /// tap-to-play voice note. Additive metadata ONLY — expiry, sealing, and
    /// routing are identical to an ordinary voice note. Absent on a legacy
    /// manifest → false; old peers decode a PTT note as an ordinary voice note.
    public let isPushToTalk: Bool

    public init(mediaID: String,
                mime: MediaMimeType,
                totalBytes: Int,
                chunkCount: Int,
                sha256: String,
                sentAt: Date? = nil,
                isStory: Bool = false,
                isPushToTalk: Bool = false) {
        self.mediaID = mediaID
        self.mime = mime
        self.totalBytes = totalBytes
        self.chunkCount = chunkCount
        self.sha256 = sha256
        self.sentAt = sentAt
        self.isStory = isStory
        self.isPushToTalk = isPushToTalk
    }

    // MARK: Wire compatibility

    /// Explicit keys + a hand-written decoder so a LEGACY manifest (neither
    /// new field present) still decodes. `sentAt` would tolerate absence even
    /// synthesized (optional → decodeIfPresent), but a synthesized decode of
    /// the non-optional `isStory` throws on a missing key — and the receive
    /// path treats a throw as a bad manifest and drops the whole transfer.
    /// Encoding stays synthesized: providing only `init(from:)` preserves the
    /// compiler's `encode(to:)`, and unknown keys are ignored by old peers'
    /// JSONDecoder, so a story manifest decodes on a legacy build as ordinary
    /// media.
    private enum CodingKeys: String, CodingKey {
        case mediaID, mime, totalBytes, chunkCount, sha256, sentAt, isStory, isPushToTalk
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaID      = try c.decode(String.self, forKey: .mediaID)
        mime         = try c.decode(MediaMimeType.self, forKey: .mime)
        totalBytes   = try c.decode(Int.self, forKey: .totalBytes)
        chunkCount   = try c.decode(Int.self, forKey: .chunkCount)
        sha256       = try c.decode(String.self, forKey: .sha256)
        sentAt       = try c.decodeIfPresent(Date.self, forKey: .sentAt)
        isStory      = try c.decodeIfPresent(Bool.self, forKey: .isStory) ?? false
        isPushToTalk = try c.decodeIfPresent(Bool.self, forKey: .isPushToTalk) ?? false
    }
}

// MARK: - Hashing helper

public extension MediaManifest {

    /// Lowercase-hex SHA-256 of a blob, matching the `sha256` field's format.
    static func hashHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
