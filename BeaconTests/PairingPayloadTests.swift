// PairingPayloadTests.swift
// BeaconTests
//
// Tests the pairing-payload container codec (Closed-Contact step 2,
// docs/CONTACT_MODEL §6). Pure Data logic — no crypto, no hardware. Covers
// round-trip with/without the optional Nostr key, an exact-bytes KAT that pins
// the wire layout, and strict rejection of malformed input.

import XCTest
@testable import Beacon

final class PairingPayloadTests: XCTestCase {

    private func key(_ b: UInt8) -> Data { Data(repeating: b, count: PairingPayload.nostrKeyByteCount) }

    // MARK: Round-trip

    func testRoundTripWithNostrKey() {
        let payload = PairingPayload(bundle: PrekeyBundle(data: Data([0xDE, 0xAD, 0xBE, 0xEF])),
                                     nostrPublicKey: key(0x01))
        let decoded = PairingPayload(wire: payload.wireData())
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded?.nostrPublicKey, key(0x01))
    }

    func testRoundTripWithoutNostrKey() {
        let payload = PairingPayload(bundle: PrekeyBundle(data: Data([0x01, 0x02, 0x03])),
                                     nostrPublicKey: nil)
        let decoded = PairingPayload(wire: payload.wireData())
        XCTAssertEqual(decoded, payload)
        XCTAssertNil(decoded?.nostrPublicKey)
    }

    func testRoundTripWithLargeRealisticBundle() {
        // ~1.8 KB stand-in for a Kyber-bearing bundle.
        let big = Data((0..<1800).map { UInt8($0 % 256) })
        let payload = PairingPayload(bundle: PrekeyBundle(data: big), nostrPublicKey: key(0x7F))
        XCTAssertEqual(PairingPayload(wire: payload.wireData()), payload)
    }

    func testEmptyBundleRoundTrips() {
        // The container is dumb about bundle contents; an empty bundle is
        // BundleWire's problem, not the container's — it still frames cleanly.
        let payload = PairingPayload(bundle: PrekeyBundle(data: Data()), nostrPublicKey: nil)
        XCTAssertEqual(PairingPayload(wire: payload.wireData()), payload)
    }

    // MARK: Exact-bytes KAT (pins the wire layout)

    func testExactWireLayout() {
        let payload = PairingPayload(bundle: PrekeyBundle(data: Data([0xAA, 0xBB])),
                                     nostrPublicKey: key(0x01))
        var expected = Data()
        expected.append(0x01)                              // version
        expected.append(contentsOf: [0x00, 0x00, 0x00, 0x02])  // bundle len = 2
        expected.append(contentsOf: [0xAA, 0xBB])              // bundle
        expected.append(contentsOf: [0x00, 0x00, 0x00, 0x20])  // nostr len = 32
        expected.append(key(0x01))                             // nostr key
        XCTAssertEqual(payload.wireData(), expected)
    }

    func testExactWireLayoutNoKey() {
        let payload = PairingPayload(bundle: PrekeyBundle(data: Data([0xAA])),
                                     nostrPublicKey: nil)
        var expected = Data()
        expected.append(0x01)                              // version
        expected.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // bundle len = 1
        expected.append(0xAA)                                  // bundle
        expected.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // nostr len = 0 (absent)
        XCTAssertEqual(payload.wireData(), expected)
    }

    func testEncodingIsDeterministic() {
        let p = PairingPayload(bundle: PrekeyBundle(data: Data([1, 2, 3, 4, 5])),
                               nostrPublicKey: key(0x42))
        XCTAssertEqual(p.wireData(), p.wireData())
    }

    // MARK: Rejection

    func testRejectsWrongVersion() {
        var wire = PairingPayload(bundle: PrekeyBundle(data: Data([0xAA])),
                                  nostrPublicKey: nil).wireData()
        wire[wire.startIndex] = 0x02   // bump version
        XCTAssertNil(PairingPayload(wire: wire))
    }

    func testRejectsEmptyBuffer() {
        XCTAssertNil(PairingPayload(wire: Data()))
    }

    func testRejectsTruncation() {
        let full = PairingPayload(bundle: PrekeyBundle(data: Data([0xAA, 0xBB, 0xCC])),
                                  nostrPublicKey: key(0x01)).wireData()
        // Every strict prefix shorter than the whole must fail to parse.
        for cut in 1..<full.count {
            XCTAssertNil(PairingPayload(wire: full.prefix(cut)),
                         "prefix of length \(cut) should not parse")
        }
    }

    func testRejectsTrailingJunk() {
        var wire = PairingPayload(bundle: PrekeyBundle(data: Data([0xAA])),
                                  nostrPublicKey: key(0x01)).wireData()
        wire.append(0x99)
        XCTAssertNil(PairingPayload(wire: wire))
    }

    func testRejectsWrongLengthNostrKey() {
        // Hand-build a wire with a 31-byte nostr blob (present but wrong length).
        var wire = Data()
        wire.append(0x01)
        wire.append(contentsOf: [0x00, 0x00, 0x00, 0x01])  // bundle len 1
        wire.append(0xAA)
        wire.append(contentsOf: [0x00, 0x00, 0x00, 0x1F])  // nostr len 31
        wire.append(Data(repeating: 0x01, count: 31))
        XCTAssertNil(PairingPayload(wire: wire))
    }

    func testRejectsBundleLengthOverrunningBuffer() {
        var wire = Data()
        wire.append(0x01)
        wire.append(contentsOf: [0x00, 0x00, 0x10, 0x00])  // claims 4096-byte bundle
        wire.append(contentsOf: [0xAA, 0xBB])              // but only 2 bytes follow
        XCTAssertNil(PairingPayload(wire: wire))
    }
}
