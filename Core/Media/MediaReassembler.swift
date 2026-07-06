// MediaReassembler.swift
// Core/Media
//
// Collects the pieces of an inbound media transfer until it is whole, then
// hands back the verified blob exactly once. This is the receive-side
// counterpart to MediaChunker.split: where the chunker turns one blob into a
// manifest + N chunks, this turns a manifest + N chunks (arriving in ANY order,
// possibly with relay duplicates, possibly with the manifest arriving after
// some chunks) back into one blob.
//
// PURE LOGIC: no transport, no crypto, no SwiftData. It buffers `Data` keyed by
// mediaID and returns a `Completed` the moment a transfer's manifest and every
// chunk are present and the whole-blob SHA-256 verifies. The owning actor
// (FirstContactCoordinator, in 6b.2) feeds it opened payloads and forwards a
// `Completed` to the persistence layer — so this stays trivially unit-testable
// on the Mac.
//
// MESH TOLERANCE: chunks can precede the manifest (buffered until it arrives),
// arrive out of order (placed by index), or be delivered twice by relay
// (dedup by index — a duplicate does not inflate the count). Verification is
// delegated to MediaChunker.reassemble, so integrity is checked in one place.
//
// MEMORY NOTE: an abandoned transfer (manifest or chunks that never complete)
// lingers in the buffers. v1 accepts this — media is size-bounded over a mesh
// and transfers are short-lived — but a future eviction policy (TTL / max
// in-flight bytes) is the natural place to bound it. Marked for Phase 9.
//

import Foundation

public struct MediaReassembler {

    /// A transfer that is now complete and verified.
    public struct Completed: Equatable {
        public let mediaID: String
        public let mime: MediaMimeType
        public let data: Data
        /// STORIES: carried VERBATIM from the manifest — still the sender's
        /// asserted clock at this layer. The persistence layer clamps it to
        /// arrival time; pure reassembly logic doesn't own a trusted clock.
        public let sentAt: Date?
        public let isStory: Bool
    }

    private let chunker: MediaChunker

    /// Manifests seen, keyed by mediaID hex.
    private var manifests: [String: MediaManifest] = [:]
    /// Raw chunk buffers, keyed by mediaID hex. Deduped by index at completion.
    private var chunks: [String: [Data]] = [:]

    /// - Parameter chunker: must parse/verify with the SAME layout the sender
    ///   used. (targetBucket/reservedBytes don't affect parsing or verification,
    ///   only splitting, so any valid chunker works on the receive side.)
    public init(chunker: MediaChunker) {
        self.chunker = chunker
    }

    /// Feed an arrived manifest. Returns a `Completed` if this was the last
    /// missing piece (its chunks were already buffered). A manifest whose
    /// declared geometry exceeds the defensive bounds (`MediaChunker.
    /// manifestWithinBounds`) is ignored like an unparseable chunk — stored
    /// nowhere, so its `chunkCount` can never drive the per-ingest completion
    /// sweep or size a reassembly allocation.
    public mutating func ingest(manifest: MediaManifest) -> Completed? {
        guard MediaChunker.manifestWithinBounds(manifest) else { return nil }
        manifests[manifest.mediaID] = manifest
        return tryComplete(manifest.mediaID)
    }

    /// Feed an arrived chunk. Returns a `Completed` if this chunk completed the
    /// transfer. Unparseable chunks are ignored (return nil).
    public mutating func ingest(chunk: Data) -> Completed? {
        guard let parsed = try? chunker.parse(chunk) else { return nil }
        let id = parsed.mediaID.map { String(format: "%02x", $0) }.joined()
        chunks[id, default: []].append(chunk)
        return tryComplete(id)
    }

    /// Whether a transfer is currently in flight (manifest or chunks buffered).
    public func isInFlight(mediaID: String) -> Bool {
        manifests[mediaID] != nil || (chunks[mediaID]?.isEmpty == false)
    }

    /// Indices still missing for an announced transfer, or nil if its manifest
    /// hasn't arrived yet. For a future re-request path.
    public func missingIndices(mediaID: String) -> [Int]? {
        guard let manifest = manifests[mediaID] else { return nil }
        return chunker.missingIndices(have: chunks[mediaID] ?? [], manifest: manifest)
    }

    // MARK: - Internals

    private mutating func tryComplete(_ id: String) -> Completed? {
        guard let manifest = manifests[id] else { return nil }     // need manifest
        let have = chunks[id] ?? []
        guard chunker.missingIndices(have: have, manifest: manifest).isEmpty else {
            return nil                                             // still gaps
        }
        guard let blob = try? chunker.reassemble(have, manifest: manifest) else {
            return nil                                             // integrity not yet satisfiable
        }
        manifests[id] = nil
        chunks[id] = nil
        return Completed(mediaID: id, mime: manifest.mime, data: blob,
                         sentAt: manifest.sentAt, isStory: manifest.isStory)
    }
}
