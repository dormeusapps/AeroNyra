//
//  PTTJitterBufferTests.swift
//  BeaconTests
//
//  PTT C-2: deterministic, hardware-free tests for the playout side's
//  correctness core — the pure-DSP jitter buffer. PTTPlayer's AVAudioEngine
//  path needs real hardware and is validated at C-3's by-ear gate; here we pin
//  the reorder/drop-late/overflow semantics the clock relies on.
//

import XCTest
@testable import Beacon

final class PTTJitterBufferTests: XCTestCase {

    /// A distinguishable 960-sample frame per seq so playout ORDER and IDENTITY
    /// are asserted, not just counts.
    private func frame(_ seq: UInt64) -> [Int16] {
        [Int16](repeating: Int16(truncatingIfNeeded: seq &+ 1), count: OpusVoiceCodec.samplesPerFrame)
    }

    // MARK: In-order playout

    func testInOrderPlayoutYieldsEveryFrameOnceInSequence() {
        var jb = PTTJitterBuffer()
        for seq: UInt64 in 0..<5 {
            XCTAssertTrue(jb.push(seq: seq, pcm: frame(seq)))
        }
        XCTAssertEqual(jb.count, 5)
        for seq: UInt64 in 0..<5 {
            XCTAssertEqual(jb.pop(expectedSeq: seq), .frame(frame(seq)),
                           "seq \(seq) must play back exactly the pushed frame")
        }
        XCTAssertEqual(jb.count, 0)
        // Past the last pushed frame the buffer is a clean underrun.
        XCTAssertEqual(jb.pop(expectedSeq: 5), .empty)
    }

    // MARK: Prebuffer readiness (depth 3)

    func testReadinessTurnsTrueAtPrebufferDepth() {
        var jb = PTTJitterBuffer()
        jb.push(seq: 0, pcm: frame(0))
        XCTAssertFalse(jb.isReady)
        jb.push(seq: 1, pcm: frame(1))
        XCTAssertFalse(jb.isReady)
        jb.push(seq: 2, pcm: frame(2))
        XCTAssertTrue(jb.isReady, "3 queued frames (60 ms) is the playout depth")
        XCTAssertEqual(jb.minBufferedSeq, 0)
    }

    // MARK: Gap — a missing seq reports the hole

    func testGapReportsHoleThenLaterFramePlays() {
        var jb = PTTJitterBuffer()
        jb.push(seq: 0, pcm: frame(0))
        jb.push(seq: 2, pcm: frame(2))          // seq 1 never arrives
        XCTAssertEqual(jb.pop(expectedSeq: 0), .frame(frame(0)))
        // The hole: expected 1 is absent but 2 is buffered → .gap, NOT .empty —
        // the caller fills one frame of silence and keeps the clock running.
        XCTAssertEqual(jb.pop(expectedSeq: 1), .gap)
        XCTAssertEqual(jb.pop(expectedSeq: 2), .frame(frame(2)))
        XCTAssertEqual(jb.pop(expectedSeq: 3), .empty)
    }

    // MARK: Drop-late — seq <= lastPlayed is discarded

    func testLateArrivalAtOrBelowLastPlayedIsDropped() {
        var jb = PTTJitterBuffer()
        jb.push(seq: 0, pcm: frame(0))
        XCTAssertEqual(jb.pop(expectedSeq: 0), .frame(frame(0)))
        XCTAssertEqual(jb.lastPlayed, 0)

        // Exactly lastPlayed → dropped.
        XCTAssertFalse(jb.push(seq: 0, pcm: frame(0)))
        XCTAssertEqual(jb.count, 0)

        // A slot consumed as SILENCE is played history too: pop(1) missed,
        // then seq 1 arrives late → dropped.
        XCTAssertEqual(jb.pop(expectedSeq: 1), .empty)
        XCTAssertFalse(jb.push(seq: 1, pcm: frame(1)))
        XCTAssertEqual(jb.count, 0)

        // Beyond the gate still queues.
        XCTAssertTrue(jb.push(seq: 2, pcm: frame(2)))
        XCTAssertEqual(jb.pop(expectedSeq: 2), .frame(frame(2)))
    }

    func testPopPurgesBufferedFramesBehindTheGate() {
        var jb = PTTJitterBuffer()
        jb.push(seq: 3, pcm: frame(3))
        jb.push(seq: 7, pcm: frame(7))
        // The clock starts at 5 (say frames 3/4 were dropped upstream): the
        // buffered seq-3 frame is behind the gate and must be purged, and the
        // result is .gap because 7 is still ahead.
        XCTAssertEqual(jb.pop(expectedSeq: 5), .gap)
        XCTAssertEqual(jb.count, 1)
        XCTAssertEqual(jb.minBufferedSeq, 7)
        XCTAssertFalse(jb.push(seq: 3, pcm: frame(3)), "purged frame must not re-enter")
    }

    // MARK: Duplicate push

    func testDuplicateSeqIsNotBufferedTwice() {
        var jb = PTTJitterBuffer()
        XCTAssertTrue(jb.push(seq: 4, pcm: frame(4)))
        XCTAssertFalse(jb.push(seq: 4, pcm: frame(4)))
        XCTAssertEqual(jb.count, 1)
    }

    // MARK: Overflow — cap 8 (transport ring K), drop-OLDEST

    func testOverflowBeyondCapacityDropsOldest() {
        var jb = PTTJitterBuffer()
        for seq: UInt64 in 0..<10 {                     // 10 pushes into a cap of 8
            jb.push(seq: seq, pcm: frame(seq))
        }
        XCTAssertEqual(jb.count, PTTJitterBuffer.capacity)
        // Oldest two (0, 1) were evicted; the freshest 8 (2...9) survive.
        XCTAssertEqual(jb.minBufferedSeq, 2)
        XCTAssertEqual(jb.pop(expectedSeq: 0), .gap, "seq 0 was evicted — hole, later frames buffered")
        XCTAssertEqual(jb.pop(expectedSeq: 1), .gap)
        for seq: UInt64 in 2..<10 {
            XCTAssertEqual(jb.pop(expectedSeq: seq), .frame(frame(seq)))
        }
        XCTAssertEqual(jb.pop(expectedSeq: 10), .empty)
    }

    // MARK: Flush — queued frames go, the drop-late gate stays

    func testFlushKeepsLastPlayedGate() {
        var jb = PTTJitterBuffer()
        jb.push(seq: 0, pcm: frame(0))
        XCTAssertEqual(jb.pop(expectedSeq: 0), .frame(frame(0)))
        jb.push(seq: 5, pcm: frame(5))
        jb.flush()
        XCTAssertEqual(jb.count, 0)
        XCTAssertEqual(jb.lastPlayed, 0, "flush drops frames, not history")
        XCTAssertFalse(jb.push(seq: 0, pcm: frame(0)), "stragglers stay drop-late after flush")
        XCTAssertTrue(jb.push(seq: 6, pcm: frame(6)))
    }
}
