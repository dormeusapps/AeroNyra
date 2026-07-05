// MediaChunkerTests.swift
// BeaconTests
//
// Hermetic, Mac/Simulator-only unit tests for the media chunker. No transport,
// no crypto, no hardware — pure Data round-tripping. Verifies that a blob
// survives split → (shuffle) → reassemble byte-for-byte, that integrity and
// missing-chunk detection actually fire, and that chunk sizing stays aligned to
// the chosen PayloadBucket so no padding tier is wasted.
//

import XCTest
@testable import Beacon

final class MediaChunkerTests: XCTestCase {

    // Deterministic id so failures are reproducible.
    private let fixedID: [UInt8] = Array(0..<16)

    /// A pseudo-random but deterministic blob of `count` bytes.
    private func blob(_ count: Int) -> Data {
        var d = Data(capacity: count)
        var x: UInt8 = 7
        for _ in 0..<count {
            x = x &* 31 &+ 17           // simple deterministic LCG-ish fill
            d.append(x)
        }
        return d
    }

    // MARK: - Round-trip

    func testRoundTripInOrder() throws {
        let chunker = try MediaChunker(targetBucket: 4096)
        let original = blob(50_000)     // ~12 chunks at 4 KB
        let (manifest, chunks) = try chunker.split(original, mime: .jpeg, mediaID: fixedID)

        XCTAssertEqual(manifest.totalBytes, original.count)
        XCTAssertEqual(manifest.chunkCount, chunks.count)

        let rebuilt = try chunker.reassemble(chunks, manifest: manifest)
        XCTAssertEqual(rebuilt, original, "in-order reassembly must be byte-identical")
    }

    func testRoundTripOutOfOrder() throws {
        let chunker = try MediaChunker(targetBucket: 4096)
        let original = blob(40_000)
        let (manifest, chunks) = try chunker.split(original, mime: .m4a, mediaID: fixedID)

        // Chunks are self-describing, so a shuffled set must still reassemble.
        let shuffled = chunks.shuffled()
        let rebuilt = try chunker.reassemble(shuffled, manifest: manifest)
        XCTAssertEqual(rebuilt, original, "out-of-order reassembly must be byte-identical")
    }

    func testSingleChunkBlob() throws {
        let chunker = try MediaChunker(targetBucket: 4096)
        let original = blob(100)        // smaller than one payload
        let (manifest, chunks) = try chunker.split(original, mime: .jpeg, mediaID: fixedID)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(manifest.chunkCount, 1)
        XCTAssertEqual(try chunker.reassemble(chunks, manifest: manifest), original)
    }

    func testExactBoundaryBlob() throws {
        // Blob exactly fills an integer number of chunks — last chunk is full,
        // no remainder. Guards the offset math at the boundary.
        let chunker = try MediaChunker(targetBucket: 4096)
        let original = blob(chunker.payloadPerChunk * 3)
        let (manifest, chunks) = try chunker.split(original, mime: .jpeg, mediaID: fixedID)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(try chunker.reassemble(chunks, manifest: manifest), original)
    }

    // MARK: - Failure detection

    func testDroppedChunkIsDetected() throws {
        let chunker = try MediaChunker(targetBucket: 4096)
        let original = blob(40_000)
        let (manifest, chunks) = try chunker.split(original, mime: .jpeg, mediaID: fixedID)

        var missing = chunks
        missing.remove(at: 3)           // lose one chunk

        XCTAssertThrowsError(try chunker.reassemble(missing, manifest: manifest)) { error in
            guard case MediaChunkerError.missingChunks(let expected, let got) = error else {
                return XCTFail("expected .missingChunks, got \(error)")
            }
            XCTAssertEqual(expected, manifest.chunkCount)
            XCTAssertEqual(got, manifest.chunkCount - 1)
        }
    }

    func testMissingIndicesReportsGaps() throws {
        let chunker = try MediaChunker(targetBucket: 4096)
        let original = blob(40_000)
        let (manifest, chunks) = try chunker.split(original, mime: .jpeg, mediaID: fixedID)

        var partial = chunks
        partial.remove(at: 5)
        partial.remove(at: 1)           // remove 1 after 5 so indices are 1 and 5

        let missing = chunker.missingIndices(have: partial, manifest: manifest)
        XCTAssertEqual(missing, [1, 5])
    }

    func testIntegrityFailureOnTamper() throws {
        let chunker = try MediaChunker(targetBucket: 4096)
        let original = blob(20_000)
        let (manifest, chunks) = try chunker.split(original, mime: .jpeg, mediaID: fixedID)

        // Flip a payload byte in one chunk (past the 24-byte header).
        var tampered = chunks
        var bytes = [UInt8](tampered[2])
        bytes[MediaChunker.headerSize] ^= 0xFF
        tampered[2] = Data(bytes)

        XCTAssertThrowsError(try chunker.reassemble(tampered, manifest: manifest)) { error in
            XCTAssertEqual(error as? MediaChunkerError, .integrityFailure)
        }
    }

    func testInconsistentMediaIDRejected() throws {
        let chunker = try MediaChunker(targetBucket: 4096)
        let a = blob(20_000)
        let (manifestA, chunksA) = try chunker.split(a, mime: .jpeg, mediaID: fixedID)

        let otherID = Array(16..<32).map { UInt8($0) }
        let (_, chunksB) = try chunker.split(blob(20_000), mime: .jpeg, mediaID: otherID)

        // Splice a chunk from a different transfer into A's set.
        var mixed = chunksA
        mixed[1] = chunksB[1]

        XCTAssertThrowsError(try chunker.reassemble(mixed, manifest: manifestA)) { error in
            XCTAssertEqual(error as? MediaChunkerError, .inconsistentChunks)
        }
    }

    // MARK: - Bucket alignment

    func testChunkFitsTargetBucket() throws {
        // Every chunk (header + payload) must fit within the targeted bucket,
        // so that after the Security layer pads to a PayloadBucket it lands in
        // THAT bucket and not the next one up (no wasted padding tier).
        for bucket in [1024, 4096, 16384] {
            let chunker = try MediaChunker(targetBucket: bucket)
            let (_, chunks) = try chunker.split(blob(bucket * 5 + 123),
                                                mime: .jpeg, mediaID: fixedID)
            for (i, c) in chunks.enumerated() {
                XCTAssertLessThanOrEqual(
                    c.count, bucket,
                    "chunk \(i) of \(c.count)B must fit bucket \(bucket)")
                // Every chunk except possibly the last should be exactly full.
                if i < chunks.count - 1 {
                    XCTAssertEqual(c.count, bucket,
                                   "non-final chunk should fill the bucket exactly")
                }
            }
        }
    }

    func testInvalidBucketRejected() {
        XCTAssertThrowsError(try MediaChunker(targetBucket: 3000)) { error in
            XCTAssertEqual(error as? MediaChunkerError, .invalidBucket(3000))
        }
    }

    func testEmptyBlobRejected() throws {
        let chunker = try MediaChunker(targetBucket: 4096)
        XCTAssertThrowsError(try chunker.split(Data(), mime: .jpeg, mediaID: fixedID)) { error in
            XCTAssertEqual(error as? MediaChunkerError, .emptyBlob)
        }
    }

    // MARK: - Manifest bounds (SEC-10b)
    //
    // A manifest arrives from a verified peer but is still untrusted data: its
    // chunkCount drives an O(chunkCount) sweep on EVERY subsequent ingest and
    // sizes the reassembly slot array; totalBytes sizes the blob allocation.
    // These pins hold the defensive bounds in place and — via the consistency
    // pin — stop a future window/bucket change from silently making legitimate
    // media rejectable.

    /// A copy of a manifest with doctored geometry (id/mime/hash preserved).
    private func doctored(_ m: MediaManifest,
                          chunkCount: Int? = nil,
                          totalBytes: Int? = nil) -> MediaManifest {
        MediaManifest(mediaID: m.mediaID,
                      mime: m.mime,
                      totalBytes: totalBytes ?? m.totalBytes,
                      chunkCount: chunkCount ?? m.chunkCount,
                      sha256: m.sha256)
    }

    func testManifestBoundsTruthTable() {
        let ok = MediaManifest(mediaID: "00ff", mime: .jpeg,
                               totalBytes: 1_000, chunkCount: 2, sha256: "irrelevant")
        XCTAssertTrue(MediaChunker.manifestWithinBounds(ok))

        // chunkCount: zero rejected, 1 and the max accepted (boundary inclusive),
        // max+1 rejected.
        XCTAssertFalse(MediaChunker.manifestWithinBounds(doctored(ok, chunkCount: 0)))
        XCTAssertTrue(MediaChunker.manifestWithinBounds(doctored(ok, chunkCount: 1)))
        XCTAssertTrue(MediaChunker.manifestWithinBounds(
            doctored(ok, chunkCount: MediaChunker.maxChunkCount,
                     totalBytes: MediaChunker.maxTotalBytes)))
        XCTAssertFalse(MediaChunker.manifestWithinBounds(
            doctored(ok, chunkCount: MediaChunker.maxChunkCount + 1,
                     totalBytes: MediaChunker.maxTotalBytes)))

        // totalBytes: zero rejected, the max accepted (boundary inclusive),
        // max+1 rejected.
        XCTAssertFalse(MediaChunker.manifestWithinBounds(
            doctored(ok, chunkCount: 1, totalBytes: 0)))
        XCTAssertTrue(MediaChunker.manifestWithinBounds(
            doctored(ok, chunkCount: 1, totalBytes: MediaChunker.maxTotalBytes)))
        XCTAssertFalse(MediaChunker.manifestWithinBounds(
            doctored(ok, chunkCount: 1, totalBytes: MediaChunker.maxTotalBytes + 1)))

        // Consistency: more chunks than bytes is impossible (every chunk
        // carries at least one media byte).
        XCTAssertFalse(MediaChunker.manifestWithinBounds(
            doctored(ok, chunkCount: 10, totalBytes: 5)))
    }

    func testReassembleRejectsOutOfBoundsManifest() throws {
        let chunker = try MediaChunker(targetBucket: 4096)
        let (manifest, chunks) = try chunker.split(blob(20_000), mime: .jpeg, mediaID: fixedID)
        let evil = doctored(manifest,
                            chunkCount: MediaChunker.maxChunkCount + 1,
                            totalBytes: MediaChunker.maxTotalBytes + 1)
        XCTAssertThrowsError(try chunker.reassemble(chunks, manifest: evil)) { error in
            XCTAssertEqual(error as? MediaChunkerError,
                           .manifestOutOfBounds(chunkCount: MediaChunker.maxChunkCount + 1,
                                                totalBytes: MediaChunker.maxTotalBytes + 1))
        }
    }

    func testMissingIndicesGuardsOutOfBoundsManifest() throws {
        // Without the guard, an Int.max chunkCount would materialize the range
        // 0..<Int.max — this test hanging IS the failure signature.
        let chunker = try MediaChunker(targetBucket: 4096)
        let (manifest, chunks) = try chunker.split(blob(20_000), mime: .jpeg, mediaID: fixedID)
        let evil = doctored(manifest, chunkCount: Int.max, totalBytes: Int.max)
        XCTAssertEqual(chunker.missingIndices(have: chunks, manifest: evil), [],
                       "out-of-bounds manifest must not materialize an attacker-sized range")
    }

    func testReassemblerIgnoresOutOfBoundsManifest() throws {
        let chunker = try MediaChunker(targetBucket: 4096)
        var reassembler = MediaReassembler(chunker: chunker)
        let original = blob(20_000)
        let (manifest, chunks) = try chunker.split(original, mime: .jpeg, mediaID: fixedID)

        // The oversized manifest is ignored like an unparseable chunk: nil
        // result AND stored nowhere.
        let evil = doctored(manifest, chunkCount: MediaChunker.maxChunkCount + 1)
        XCTAssertNil(reassembler.ingest(manifest: evil))
        XCTAssertFalse(reassembler.isInFlight(mediaID: evil.mediaID),
                       "a rejected manifest must be stored NOWHERE")

        // The legitimate transfer — SAME mediaID — still completes end-to-end,
        // proving the rejection left no residue behind.
        for chunk in chunks {
            XCTAssertNil(reassembler.ingest(chunk: chunk))   // buffered, awaiting manifest
        }
        let done = reassembler.ingest(manifest: manifest)
        XCTAssertEqual(done?.data, original)
    }

    func testBoundsAdmitLargestLegitimateTransfer() throws {
        // Mutual-consistency pin: a maxTotalBytes blob chunked at every
        // media-realistic bucket (with the coordinator's 1 reserved tag byte)
        // must need <= maxChunkCount chunks, and such a manifest must pass the
        // gate — so a future bound/bucket change can't strand legitimate media.
        for bucket in [1024, 4096, 16384] {
            let chunker = try MediaChunker(targetBucket: bucket, reservedBytes: 1)
            let count = Int((Double(MediaChunker.maxTotalBytes)
                             / Double(chunker.payloadPerChunk)).rounded(.up))
            XCTAssertLessThanOrEqual(
                count, MediaChunker.maxChunkCount,
                "a \(MediaChunker.maxTotalBytes)B transfer at bucket \(bucket) needs \(count) chunks — exceeds maxChunkCount")
            let manifest = MediaManifest(mediaID: "00", mime: .jpeg,
                                         totalBytes: MediaChunker.maxTotalBytes,
                                         chunkCount: count, sha256: "x")
            XCTAssertTrue(MediaChunker.manifestWithinBounds(manifest))
        }
    }
}
