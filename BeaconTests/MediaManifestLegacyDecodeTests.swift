// MediaManifestLegacyDecodeTests.swift
// BeaconTests
//
// Known-answer tests for the STORIES wire-compat contract (SEC-6 stories):
// a LEGACY manifest — the exact JSON shape every pre-stories build emits,
// carrying neither `sentAt` nor `isStory` — MUST still decode, and MUST come
// out as ordinary NON-story media. A synthesized decoder would throw on the
// missing non-optional `isStory` key and the receive path would drop the
// whole transfer as a "bad manifest"; the hand-written init(from:) in
// MediaManifest is what these tests pin down.
//

import XCTest
@testable import Beacon

final class MediaManifestLegacyDecodeTests: XCTestCase {

    /// The canned legacy wire shape: ONLY the five original keys, byte-for-byte
    /// what a pre-stories sender's JSONEncoder produces. Kept as a literal so a
    /// future codec change that breaks old peers fails HERE, not in the field.
    private let legacyJSON = Data("""
        {"mediaID":"00112233445566778899aabbccddeeff","mime":"jpeg","totalBytes":5,"chunkCount":1,"sha256":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"}
        """.utf8)

    func testLegacyManifestDecodesAsNonStory() throws {
        let manifest = try JSONDecoder().decode(MediaManifest.self, from: legacyJSON)
        // The original five fields survive intact…
        XCTAssertEqual(manifest.mediaID, "00112233445566778899aabbccddeeff")
        XCTAssertEqual(manifest.mime, .jpeg)
        XCTAssertEqual(manifest.totalBytes, 5)
        XCTAssertEqual(manifest.chunkCount, 1)
        // …and the story fields default to the non-story shape.
        XCTAssertNil(manifest.sentAt, "legacy manifest must carry no send stamp")
        XCTAssertFalse(manifest.isStory, "legacy manifest must never decode as a story")
    }

    /// A legacy manifest fed through the reassembler yields a non-story
    /// Completed — the exact values the persistence layer receives, so the
    /// row it writes is a plain photo (24h receipt-anchored window, outbound
    /// never expires), not a story.
    func testLegacyManifestYieldsNonStoryCompleted() throws {
        let blob = Data("hello".utf8)   // sha256 above is SHA-256("hello")
        let chunker = try MediaChunker(targetBucket: 4096, reservedBytes: 32)
        // Re-chunk the same blob under the same mediaID so the chunk matches
        // the canned manifest's geometry (1 chunk, 5 bytes).
        let id: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                           0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]
        let (_, chunks) = try chunker.split(blob, mime: .jpeg, mediaID: id)

        var reassembler = MediaReassembler(chunker: chunker)
        let legacy = try JSONDecoder().decode(MediaManifest.self, from: legacyJSON)
        XCTAssertNil(reassembler.ingest(manifest: legacy), "one chunk still missing")
        let done = try XCTUnwrap(reassembler.ingest(chunk: chunks[0]))

        XCTAssertEqual(done.data, blob)
        XCTAssertNil(done.sentAt)
        XCTAssertFalse(done.isStory)
    }

    /// Inverse direction: a STORY manifest round-trips its new fields, so the
    /// stamp a sender writes is the stamp a (new-build) receiver reads.
    func testStoryManifestRoundTripsNewFields() throws {
        let sent = Date(timeIntervalSince1970: 1_720_000_000)
        let original = MediaManifest(mediaID: "ffeeddccbbaa99887766554433221100",
                                     mime: .jpeg,
                                     totalBytes: 5,
                                     chunkCount: 1,
                                     sha256: MediaManifest.hashHex(Data("hello".utf8)),
                                     sentAt: sent,
                                     isStory: true)
        let decoded = try JSONDecoder().decode(MediaManifest.self,
                                               from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.sentAt, sent)
        XCTAssertTrue(decoded.isStory)
    }
}
