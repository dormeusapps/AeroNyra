//
//  PTTReceiverTests.swift
//  BeaconTests
//
//  The PTT receive pipeline, exercised DIRECTLY — no BLE transport (the win of
//  moving open/replay/decode out of the carrier layer). Keys come from a fixed
//  SymmetricKey; frames are packed with PTTAudioWire exactly as the wire carries
//  them. Covers the gap/replay behavior and the per-link teardown (no leaked
//  opener after a link drops).
//

import XCTest
import CryptoKit
@testable import Beacon

final class PTTReceiverTests: XCTestCase {

    private func fixedKey(_ b: UInt8) -> SymmetricKey { SymmetricKey(data: Data(repeating: b, count: 32)) }

    /// A sealer + Opus encoder paired to `key`; each call encodes a REAL Opus
    /// frame (so the receiver's decode succeeds) and returns the sealed wire
    /// payload for the next seq.
    private func makePacker(_ key: SymmetricKey) throws -> () throws -> Data {
        let sealer = PTTFrameSealer(key: key)
        let enc = try OpusVoiceCodec.Encoder()
        let pcm = [Int16](repeating: 0, count: OpusVoiceCodec.samplesPerFrame)   // one 20 ms frame
        return {
            let opus = try enc.encode(pcm)
            let seq = sealer.nextCounter
            let s = try sealer.seal(opus, aad: PTTAudioWire.aad(forSeq: seq))
            return PTTAudioWire.pack(seq: s.counter, ciphertext: s.ciphertext, tag: s.tag)
        }
    }

    // MARK: dropped frame → gap tolerated; replay rejected (moved from transport tests)

    func testDroppedFrameLeavesGap() throws {
        let key = fixedKey(0x5b)
        let link = UUID()
        let rx = PTTReceiver()
        try rx.openSession(link: link, recvKey: key)
        let pack = try makePacker(key)

        let f0 = try pack()   // seq 0
        let f1 = try pack()   // seq 1 — DROPPED (never delivered)
        let f2 = try pack()   // seq 2
        _ = f1

        // Assert the emitted samples (seq + full 20 ms frame), not just the status.
        if case .decoded(let seq, let pcm) = rx.receive(link: link, sealed: f0) {
            XCTAssertEqual(seq, 0)
            XCTAssertEqual(pcm.count, OpusVoiceCodec.samplesPerFrame)   // 960
        } else {
            XCTFail("expected .decoded for seq 0")
        }
        if case .decoded(let seq, let pcm) = rx.receive(link: link, sealed: f2) {   // gap at 1 tolerated
            XCTAssertEqual(seq, 2)
            XCTAssertEqual(pcm.count, OpusVoiceCodec.samplesPerFrame)   // 960
        } else {
            XCTFail("expected .decoded for seq 2 (gap at 1 tolerated)")
        }
        XCTAssertEqual(rx.receive(link: link, sealed: f2), .replayed)  // replay of 2 rejected
    }

    // MARK: outcome branches

    func testNoSessionForUnknownLink() {
        let rx = PTTReceiver()
        // Well-formed length, but no context for this link → noSession (never opens).
        XCTAssertEqual(rx.receive(link: UUID(), sealed: Data(repeating: 0, count: 24)), .noSession)
    }

    func testMalformedRejectedBeforeSessionLookup() throws {
        let rx = PTTReceiver()
        let link = UUID()
        try rx.openSession(link: link, recvKey: fixedKey(0x11))
        // Shorter than seq+tag → malformed, even with a live session.
        XCTAssertEqual(rx.receive(link: link, sealed: Data(repeating: 0, count: 23)), .malformed)
    }

    func testAuthFailureOnTamperedTag() throws {
        let key = fixedKey(0x22)
        let link = UUID()
        let rx = PTTReceiver()
        try rx.openSession(link: link, recvKey: key)
        var frame = try makePacker(key)()
        frame[frame.index(before: frame.endIndex)] ^= 0x01   // flip a tag byte
        XCTAssertEqual(rx.receive(link: link, sealed: frame), .authFailed)
    }

    // MARK: per-link teardown — no leaked opener after a link drops

    func testDropLinkEvictsContext() throws {
        let rx = PTTReceiver()
        let link = UUID()
        try rx.openSession(link: link, recvKey: fixedKey(0x33))
        XCTAssertEqual(rx.sessionCount, 1)

        rx.dropLink(link)
        XCTAssertEqual(rx.sessionCount, 0)
        // A frame for the evicted link no longer finds an opener → noSession.
        XCTAssertEqual(rx.receive(link: link, sealed: Data(repeating: 0, count: 24)), .noSession)
    }

    // MARK: closePTTInitiator slot arithmetic (pttID-keyed close)
    // The coordinator itself is not unit-constructible (heavyweight init), so
    // these pin the extracted pure verdict `slotAfterClose` — the piece whose
    // failure mode is "a stale hold's close killed the live session."

    func testCloseByOwningIDEvictsSlot() {
        let id = Data(repeating: 0xAA, count: 16)
        XCTAssertNil(FirstContactCoordinator.slotAfterClose(current: id, closing: id),
            "closing the id that owns the slot must evict it")
    }

    func testStaleCloseNeverEvictsNewerSession() {
        let stale = Data(repeating: 0x01, count: 16)
        let live = Data(repeating: 0x02, count: 16)
        XCTAssertEqual(FirstContactCoordinator.slotAfterClose(current: live, closing: stale), live,
            "a stale hold's close must never evict a newer session's record — the wrong-victim kill")
    }

    func testCloseWithEmptySlotStaysEmpty() {
        let id = Data(repeating: 0xAA, count: 16)
        XCTAssertNil(FirstContactCoordinator.slotAfterClose(current: nil, closing: id),
            "closing with nothing open records nothing (the send still goes out — heal path)")
    }

    func testDoubleCloseIsIdempotent() {
        let id = Data(repeating: 0xAA, count: 16)
        let afterFirst = FirstContactCoordinator.slotAfterClose(current: id, closing: id)
        XCTAssertNil(afterFirst)
        XCTAssertNil(FirstContactCoordinator.slotAfterClose(current: afterFirst, closing: id),
            "a duplicate close of the same id must be a no-op, not a crash or resurrection")
    }
}
