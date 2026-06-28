// MediaWiringTests.swift
// BeaconTests
//
// Hermetic, Mac-only tests for the 6b.1 pure logic: the payload-framing tag
// (MessagePayload) and the receive-side collector (MediaReassembler), plus the
// chunker's reserved-byte headroom that lets a framed chunk still fit one
// PayloadBucket tier. No transport, crypto, SwiftData, or hardware.
//

import XCTest
@testable import Beacon

final class MediaWiringTests: XCTestCase {

    private let fixedID: [UInt8] = Array(0..<16)

    private func blob(_ count: Int) -> Data {
        var d = Data(capacity: count)
        var x: UInt8 = 7
        for _ in 0..<count { x = x &* 31 &+ 17; d.append(x) }
        return d
    }

    // MARK: - MessagePayload framing

    func testPayloadRoundTripEachKind() {
        let bodies: [(MessagePayload, WirePayloadKind)] = [
            (.text(Data("hello".utf8)), .text),
            (.mediaManifest(Data("{json}".utf8)), .mediaManifest),
            (.mediaChunk(blob(4000)), .mediaChunk),
        ]
        for (payload, kind) in bodies {
            let encoded = payload.encoded()
            XCTAssertEqual(encoded.first, kind.rawValue, "leading byte is the tag")
            let decoded = MessagePayload.decode(encoded)
            XCTAssertEqual(decoded, payload, "round-trip must preserve kind + body")
        }
    }

    func testPayloadDecodeRejectsEmptyAndUnknown() {
        XCTAssertNil(MessagePayload.decode(Data()), "empty buffer → nil")
        XCTAssertNil(MessagePayload.decode(Data([0xFF])), "unknown tag → nil (forward-compat)")
    }

    func testPayloadEmptyBodyIsValid() {
        let decoded = MessagePayload.decode(Data([WirePayloadKind.text.rawValue]))
        XCTAssertEqual(decoded, .text(Data()), "a tag with no body is an empty text payload")
    }

    // MARK: - Reassembler happy paths

    func testReassembleManifestThenChunks() throws {
        let chunker = try MediaChunker(targetBucket: 4096)
        let original = blob(40_000)
        let (manifest, chunks) = try chunker.split(original, mime: .jpeg, mediaID: fixedID)

        var reasm = MediaReassembler(chunker: chunker)
        XCTAssertNil(reasm.ingest(manifest: manifest), "manifest alone doesn't complete")

        var completed: MediaReassembler.Completed?
        for (i, c) in chunks.enumerated() {
            let result = reasm.ingest(chunk: c)
            if i < chunks.count - 1 {
                XCTAssertNil(result, "incomplete set must not complete early")
            } else {
                completed = result
            }
        }
        XCTAssertEqual(completed?.data, original)
        XCTAssertEqual(completed?.mime, .jpeg)
        XCTAssertEqual(completed?.mediaID, manifest.mediaID)
    }

    func testReassembleChunksBeforeManifest() throws {
        // Mesh reality: chunks can arrive before the manifest. They must buffer,
        // and the manifest completes the transfer.
        let chunker = try MediaChunker(targetBucket: 4096)
        let original = blob(30_000)
        let (manifest, chunks) = try chunker.split(original, mime: .m4a, mediaID: fixedID)

        var reasm = MediaReassembler(chunker: chunker)
        for c in chunks {
            XCTAssertNil(reasm.ingest(chunk: c), "no manifest yet → cannot complete")
        }
        let completed = reasm.ingest(manifest: manifest)
        XCTAssertEqual(completed?.data, original)
        XCTAssertEqual(completed?.mime, .m4a)
    }

    func testReassembleOutOfOrderAndDuplicates() throws {
        let chunker = try MediaChunker(targetBucket: 4096)
        let original = blob(45_000)
        let (manifest, chunks) = try chunker.split(original, mime: .jpeg, mediaID: fixedID)

        var reasm = MediaReassembler(chunker: chunker)
        _ = reasm.ingest(manifest: manifest)

        // Shuffle, and relay a few chunks twice — a duplicate must not break or
        // double-count; completion happens once all indices are present.
        var feed = chunks.shuffled()
        feed.insert(chunks[0], at: 0)
        feed.append(chunks[chunks.count - 1])

        var completed: MediaReassembler.Completed?
        for c in feed {
            if let done = reasm.ingest(chunk: c) { completed = done }
        }
        XCTAssertEqual(completed?.data, original, "duplicates + shuffle still reassemble")
    }

    func testMissingIndicesTracksProgress() throws {
        let chunker = try MediaChunker(targetBucket: 4096)
        let (manifest, chunks) = try chunker.split(blob(20_000), mime: .jpeg, mediaID: fixedID)

        var reasm = MediaReassembler(chunker: chunker)
        XCTAssertNil(reasm.missingIndices(mediaID: manifest.mediaID),
                     "before the manifest, progress is unknown (nil)")
        _ = reasm.ingest(manifest: manifest)
        XCTAssertEqual(reasm.missingIndices(mediaID: manifest.mediaID)?.count, manifest.chunkCount)

        _ = reasm.ingest(chunk: chunks[2])
        let missing = reasm.missingIndices(mediaID: manifest.mediaID)
        XCTAssertFalse(missing?.contains(2) ?? true, "index 2 should no longer be missing")
    }

    func testInterleavedTransfersDoNotCrossContaminate() throws {
        // Two transfers in flight at once must stay separate (keyed by mediaID).
        let chunker = try MediaChunker(targetBucket: 4096)
        let idA = Array(0..<16).map { UInt8($0) }
        let idB = Array(16..<32).map { UInt8($0) }
        let blobA = blob(20_000), blobB = blob(25_000)
        let (manA, chunksA) = try chunker.split(blobA, mime: .jpeg, mediaID: idA)
        let (manB, chunksB) = try chunker.split(blobB, mime: .m4a, mediaID: idB)

        var reasm = MediaReassembler(chunker: chunker)
        _ = reasm.ingest(manifest: manA)
        _ = reasm.ingest(manifest: manB)

        // Interleave the two chunk streams.
        var doneA: Data?, doneB: Data?
        let maxCount = max(chunksA.count, chunksB.count)
        for i in 0..<maxCount {
            if i < chunksA.count, let d = reasm.ingest(chunk: chunksA[i]) { doneA = d.data }
            if i < chunksB.count, let d = reasm.ingest(chunk: chunksB[i]) { doneB = d.data }
        }
        XCTAssertEqual(doneA, blobA)
        XCTAssertEqual(doneB, blobB)
    }

    // MARK: - Framed-chunk bucket alignment

    func testFramedChunkStillFitsBucket() throws {
        // With one reserved byte for the payload tag, [tag ‖ chunk] must still
        // fit the bucket exactly — never spilling into the next padding tier.
        for bucket in [1024, 4096, 16384] {
            let chunker = try MediaChunker(targetBucket: bucket, reservedBytes: 1)
            let (_, chunks) = try chunker.split(blob(bucket * 4 + 50),
                                                mime: .jpeg, mediaID: fixedID)
            for (i, c) in chunks.enumerated() {
                // Simulate the real wire unit: tag byte + chunk.
                let framed = MessagePayload.mediaChunk(c).encoded()
                XCTAssertLessThanOrEqual(framed.count, bucket,
                    "framed chunk \(i) (\(framed.count)B) must fit bucket \(bucket)")
                if i < chunks.count - 1 {
                    XCTAssertEqual(framed.count, bucket,
                        "non-final framed chunk should fill the bucket exactly")
                }
            }
        }
    }
}
