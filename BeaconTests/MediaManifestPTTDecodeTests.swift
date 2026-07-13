// MediaManifestPTTDecodeTests.swift
// BeaconTests
//
// Known-answer tests for the PUSH-TO-TALK wire-compat contract (walkie-talkie).
// `isPushToTalk` is an ADDITIVE manifest flag (like `isStory`): a manifest that
// predates it — carrying no `isPushToTalk` key — MUST still decode and come out
// as NON-PTT (an ordinary voice note), and a PTT manifest MUST round-trip the
// flag so a sender's PTT marker is the marker a new-build receiver reads. These
// pin the tolerant `decodeIfPresent` in MediaManifest so an old peer never
// drops a PTT note and never mis-renders it.
//

import XCTest
@testable import Beacon

final class MediaManifestPTTDecodeTests: XCTestCase {

    /// The canonical pre-PTT wire shape (an m4a voice-note manifest, no
    /// `isPushToTalk` key) — kept as a literal so a codec change that breaks
    /// old peers fails HERE, not in the field.
    private let legacyVoiceJSON = Data("""
        {"mediaID":"00112233445566778899aabbccddeeff","mime":"m4a","totalBytes":5,"chunkCount":1,"sha256":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"}
        """.utf8)

    func testLegacyVoiceManifestDecodesAsNonPTT() throws {
        let manifest = try JSONDecoder().decode(MediaManifest.self, from: legacyVoiceJSON)
        XCTAssertEqual(manifest.mime, .m4a)
        XCTAssertFalse(manifest.isPushToTalk, "a manifest with no key must never decode as PTT")
        XCTAssertFalse(manifest.isStory)
    }

    /// A PTT manifest round-trips the flag through encode→decode, and the flag
    /// is INDEPENDENT of `isStory` (they are orthogonal additive fields).
    func testPTTManifestRoundTripsFlag() throws {
        let original = MediaManifest(mediaID: "ffeeddccbbaa99887766554433221100",
                                     mime: .m4a,
                                     totalBytes: 5,
                                     chunkCount: 1,
                                     sha256: MediaManifest.hashHex(Data("hello".utf8)),
                                     isPushToTalk: true)
        let decoded = try JSONDecoder().decode(MediaManifest.self,
                                               from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.isPushToTalk)
        XCTAssertFalse(decoded.isStory, "PTT and story are orthogonal — PTT must not imply story")
    }

    /// A PTT manifest through the reassembler yields a Completed carrying the
    /// flag — the exact value the persistence layer receives, so the row it
    /// writes renders as a walkie-talkie note.
    func testPTTManifestYieldsPTTCompleted() throws {
        let blob = Data("hello".utf8)   // sha256 literal below is SHA-256("hello")
        let chunker = try MediaChunker(targetBucket: 4096, reservedBytes: 32)
        let id: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                           0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]
        let (manifest, chunks) = try chunker.split(blob, mime: .m4a, mediaID: id,
                                                   isPushToTalk: true)
        XCTAssertTrue(manifest.isPushToTalk)

        var reassembler = MediaReassembler(chunker: chunker)
        XCTAssertNil(reassembler.ingest(manifest: manifest), "one chunk still missing")
        let done = try XCTUnwrap(reassembler.ingest(chunk: chunks[0]))
        XCTAssertEqual(done.data, blob)
        XCTAssertTrue(done.isPushToTalk, "the PTT flag must survive reassembly")
    }
}
