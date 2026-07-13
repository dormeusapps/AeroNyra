//
//  BLEReassemblyRekeyTests.swift
//  BeaconTests
//
//  Pin tests for step 4a: reassembly re-keyed to per-(link, characteristic)
//  (`[UUID: [CBUUID: ReassemblyState]]`). Pure logic, desk-provable — drives the
//  reassembly via the transport's `#if DEBUG` test hooks (`_testIngestNotify`
//  etc.); the shipping surface stays private. Test 2 is the one that bites: it
//  goes RED against link-only keying (the old single-buffer-per-link behavior)
//  and GREEN once the inner map is keyed by characteristic.
//

import XCTest
import CoreBluetooth
@testable import Beacon

final class BLEReassemblyRekeyTests: XCTestCase {

    /// Build a wire frame: [type][4-byte big-endian length][payload].
    private func frame(_ type: UInt8, _ payload: Data) -> Data {
        var d = Data([type])
        var len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &len) { d.append(contentsOf: $0) }
        d.append(payload)
        return d
    }

    private let envelope: UInt8 = 0x01   // FrameType.envelope.rawValue

    // MARK: 1 — nesting preserves single-char chunked reassembly, byte-exact

    func testLegacyChunkedReassemblyByteIdentical() {
        let t = BLEMeshTransport()
        let link = UUID(), charA = CBUUID(string: "AAAA")
        let payload = Data((0..<300).map { UInt8($0 & 0xFF) })
        let wire = frame(envelope, payload)

        var completed: (UInt8, Data)?
        var offset = 0
        while offset < wire.count {
            let end = min(offset + 90, wire.count)          // several notify packets
            completed = t._testIngestNotify(link: link, char: charA, wire.subdata(in: offset..<end))
            offset = end
            if offset < wire.count { XCTAssertNil(completed, "a partial frame must not complete") }
        }
        XCTAssertEqual(completed?.0, envelope)
        XCTAssertEqual(completed?.1, payload, "single-char chunked reassembly must stay byte-exact")
    }

    // MARK: 2 — interleaved frames on DISTINCT chars, one link, do not corrupt
    //          (RED against link-only keying; GREEN after the re-key)

    func testInterleavedFramesOnDistinctCharsDoNotCorrupt() {
        let t = BLEMeshTransport()
        let link = UUID()
        let charA = CBUUID(string: "AAAA"), charB = CBUUID(string: "BBBB")
        let payloadA = Data((0..<200).map { _ in UInt8(0xA5) })
        let payloadB = Data((0..<120).map { _ in UInt8(0x5B) })
        let wireA = frame(envelope, payloadA), wireB = frame(envelope, payloadB)

        // Begin A on charA (partial — header + part of payload).
        let a1 = wireA.subdata(in: 0..<50)
        let a2 = wireA.subdata(in: 50..<wireA.count)
        XCTAssertNil(t._testIngestNotify(link: link, char: charA, a1), "A is mid-reassembly")

        // A COMPLETE frame arrives on charB, same link, mid-A.
        let bDone = t._testIngestNotify(link: link, char: charB, wireB)
        XCTAssertEqual(bDone?.0, envelope)
        XCTAssertEqual(bDone?.1, payloadB, "B must reassemble byte-exact despite A mid-flight")

        // Finish A — it must be uncorrupted by B's bytes.
        let aDone = t._testIngestNotify(link: link, char: charA, a2)
        XCTAssertEqual(aDone?.0, envelope)
        XCTAssertEqual(aDone?.1, payloadA, "A must complete byte-exact, never merged with B")
    }

    // MARK: 3 — disconnect cleanup drops ALL char buffers for the link (no leak)

    func testDisconnectDropsAllCharBuffersForLink() {
        let t = BLEMeshTransport()
        let link = UUID()
        let charA = CBUUID(string: "AAAA"), charB = CBUUID(string: "BBBB")

        // Two chars mid-reassembly → two live inner entries under one link.
        _ = t._testIngestNotify(link: link, char: charA, Data(frame(envelope, Data(count: 100)).prefix(20)))
        _ = t._testIngestNotify(link: link, char: charB, Data(frame(envelope, Data(count: 100)).prefix(20)))
        XCTAssertEqual(t._testNotifyCharCount(link), 2)

        // The per-link disconnect cleanup, UNCHANGED by 4a: notifyReassembly[id] = nil.
        t._testDropNotifyLink(link)
        XCTAssertEqual(t._testNotifyCharCount(link), 0, "the whole inner map must drop — no per-char leak")
    }
}
