// PayloadPaddingTests.swift
// BeaconTests
//
// Unit tests for PayloadPadding (Phase 9b step 1). Pure Data logic — no
// hardware, no crypto. Covers: round-trip recovery, the size-collapse privacy
// property, bucket boundaries, oversize coarse-grid rounding, and malformed
// input rejection.

import XCTest
@testable import Beacon

final class PayloadPaddingTests: XCTestCase {

    // MARK: Helpers

    private func bytes(_ n: Int, fill: UInt8 = 0xAB) -> Data {
        Data(repeating: fill, count: n)
    }

    private let buckets = PayloadBucket.sizes   // [256, 1024, 4096, 16384]

    // MARK: Round-trip

    func testRoundTripRecoversOriginalAcrossSizes() {
        let sizes = [0, 1, 17, 32, 100, 200, 251, 252, 253, 255, 256,
                     1000, 1019, 1020, 4000, 16000, 16380, 16381, 40000]
        for n in sizes {
            let original = bytes(n)
            let padded = PayloadPadding.pad(original)
            let recovered = PayloadPadding.unpad(padded)
            XCTAssertEqual(recovered, original, "round-trip failed for n=\(n)")
        }
    }

    func testRoundTripPreservesContentNotJustLength() {
        var original = Data()
        for i in 0..<200 { original.append(UInt8(i % 256)) }
        let recovered = PayloadPadding.unpad(PayloadPadding.pad(original))
        XCTAssertEqual(recovered, original)
    }

    func testEmptyPayloadRoundTrips() {
        let padded = PayloadPadding.pad(Data())
        XCTAssertEqual(padded.count, 256)            // smallest bucket
        XCTAssertEqual(PayloadPadding.unpad(padded), Data())
    }

    // MARK: Size-collapse privacy property

    func testDistinctSmallPayloadsCollapseToSameSize() {
        // The whole point of 9b: an ack (17B), a nostrIdentity (32B), and a
        // short text must be indistinguishable by padded length.
        let ackSized   = PayloadPadding.pad(bytes(17))
        let nostrSized = PayloadPadding.pad(bytes(32))
        let shortText  = PayloadPadding.pad(bytes(3))
        XCTAssertEqual(ackSized.count, 256)
        XCTAssertEqual(nostrSized.count, 256)
        XCTAssertEqual(shortText.count, 256)
        XCTAssertEqual(ackSized.count, nostrSized.count)
        XCTAssertEqual(nostrSized.count, shortText.count)
    }

    func testPaddedSizeIsAlwaysABucketOrMultipleOfLargest() {
        let largest = buckets.last!
        for n in stride(from: 0, through: 20000, by: 37) {
            let size = PayloadPadding.pad(bytes(n)).count
            let isBucket = buckets.contains(size)
            let isMultipleOfLargest = size % largest == 0
            XCTAssertTrue(isBucket || isMultipleOfLargest,
                          "padded size \(size) for n=\(n) is neither a bucket nor a multiple of \(largest)")
            XCTAssertGreaterThanOrEqual(size, PayloadPadding.lengthHeaderSize + n)
        }
    }

    // MARK: Bucket boundaries

    func testBoundaryAtSmallestBucket() {
        // header(4) + 252 = 256 → exactly fills the 256 bucket.
        XCTAssertEqual(PayloadPadding.pad(bytes(252)).count, 256)
        // header(4) + 253 = 257 → spills into the 1024 bucket.
        XCTAssertEqual(PayloadPadding.pad(bytes(253)).count, 1024)
    }

    func testBoundaryAtMiddleBuckets() {
        XCTAssertEqual(PayloadPadding.pad(bytes(1020)).count, 1024)   // 4 + 1020 = 1024
        XCTAssertEqual(PayloadPadding.pad(bytes(1021)).count, 4096)   // 4 + 1021 = 1025
        XCTAssertEqual(PayloadPadding.pad(bytes(4092)).count, 4096)   // 4 + 4092 = 4096
        XCTAssertEqual(PayloadPadding.pad(bytes(4093)).count, 16384)  // spills
    }

    func testBoundaryAtLargestBucket() {
        XCTAssertEqual(PayloadPadding.pad(bytes(16380)).count, 16384) // 4 + 16380 = 16384
        XCTAssertEqual(PayloadPadding.pad(bytes(16381)).count, 32768) // spills to 2× largest
    }

    // MARK: Oversize coarse-grid rounding

    func testOversizeRoundsToMultipleOfLargest() {
        let largest = buckets.last!                  // 16384
        XCTAssertEqual(PayloadPadding.pad(bytes(largest)).count, 2 * largest)
        XCTAssertEqual(PayloadPadding.pad(bytes(3 * largest)).count, 4 * largest)
    }

    // MARK: Malformed input

    func testUnpadRejectsTooShortBuffer() {
        XCTAssertNil(PayloadPadding.unpad(Data()))
        XCTAssertNil(PayloadPadding.unpad(Data([0x00])))
        XCTAssertNil(PayloadPadding.unpad(Data([0x00, 0x00, 0x00])))  // < header
    }

    func testUnpadRejectsLengthRunningPastBuffer() {
        // Header claims 1000 bytes but the buffer only has a few.
        var malformed = Data()
        var lenBE = UInt32(1000).bigEndian
        withUnsafeBytes(of: &lenBE) { malformed.append(contentsOf: $0) }
        malformed.append(bytes(10))
        XCTAssertNil(PayloadPadding.unpad(malformed))
    }

    func testUnpadAcceptsZeroLengthHeader() {
        // Header = 0, rest is padding → recovers empty.
        var buf = Data([0x00, 0x00, 0x00, 0x00])
        buf.append(bytes(252))
        XCTAssertEqual(PayloadPadding.unpad(buf), Data())
    }

    // MARK: Padding content is zero (defensive — format guarantee)

    func testPadBytesAreZero() {
        let padded = PayloadPadding.pad(bytes(10, fill: 0xFF))
        let tail = padded.suffix(padded.count - (PayloadPadding.lengthHeaderSize + 10))
        XCTAssertTrue(tail.allSatisfy { $0 == 0 }, "padding region must be zero-filled")
    }
}
