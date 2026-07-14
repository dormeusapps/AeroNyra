//
//  BLEAudioTransportTests.swift
//  BeaconTests
//
//  Desk pins for the FROZEN PTT audio wire layout (PTTAudioWire) end to end
//  through the real seal/open crypto — no hardware, no handshake object (keys are
//  built directly from a fixed SymmetricKey). If the [seq][ct][tag] layout drifts,
//  testAudioWireLayoutRoundTrips fails. The open→replay→decode pipeline is tested
//  in PTTReceiverTests (which exercises PTTReceiver directly — no transport).
//

import XCTest
import CryptoKit
@testable import Beacon

final class BLEAudioTransportTests: XCTestCase {

    private func fixedKey(_ b: UInt8) -> SymmetricKey { SymmetricKey(data: Data(repeating: b, count: 32)) }

    // MARK: 1 — wire layout round-trips through real seal/open (the format pin)

    func testAudioWireLayoutRoundTrips() throws {
        let key = fixedKey(0x2b)
        let sealer = PTTFrameSealer(key: key)
        let opener = PTTFrameOpener(key: key)
        let plaintext = Data("the quick brown opus frame".utf8)

        let seq = sealer.nextCounter                                   // the counter this seal will use
        let sealed = try sealer.seal(plaintext, aad: PTTAudioWire.aad(forSeq: seq))
        XCTAssertEqual(sealed.counter, seq)

        // Pack → the wire payload → parse back.
        let payload = PTTAudioWire.pack(seq: sealed.counter, ciphertext: sealed.ciphertext, tag: sealed.tag)
        let parsed = try XCTUnwrap(PTTAudioWire.unpack(payload))
        XCTAssertEqual(parsed.seq, seq)
        XCTAssertEqual(parsed.ciphertext, sealed.ciphertext)
        XCTAssertEqual(parsed.tag, sealed.tag)

        // Open from the parsed fields → byte-identical plaintext.
        let opened = try opener.open(counter: parsed.seq, ciphertext: parsed.ciphertext,
                                     tag: parsed.tag, aad: PTTAudioWire.aad(forSeq: parsed.seq))
        XCTAssertEqual(opened, plaintext)
    }

    // MARK: 2 — a short payload is rejected safely (no OOB read / crash)

    func testAudioFrameParseRejectsShort() {
        XCTAssertNil(PTTAudioWire.unpack(Data()))                          // empty
        XCTAssertNil(PTTAudioWire.unpack(Data(repeating: 0, count: 23)))   // < seq+tag (24)
        // Exactly seq+tag with a zero-length ciphertext is still valid framing.
        let parsed = PTTAudioWire.unpack(Data(repeating: 0, count: 24))
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.ciphertext.count, 0)
    }
}
