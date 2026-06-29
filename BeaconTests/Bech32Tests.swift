//
//  Bech32Tests.swift
//  BeaconTests
//
//  Proves the NIP-19 codec (Phase 8a) against the canonical Nostr vectors and
//  round-trips, so the encoding is trustworthy before any secp256k1 key exists.
//  XCTest (project convention), no app launch, no dependencies.
//

import XCTest
@testable import Beacon

final class Bech32Tests: XCTestCase {

    // The canonical NIP-19 examples.
    private let pubHex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
    private let pubNpub = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
    private let secHex = "67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa"
    private let secNsec = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"

    // MARK: - NIP-19 vectors

    func testNpubEncodeMatchesVector() {
        let npub = NIP19.npub(fromPublicKey: hex(pubHex))
        XCTAssertEqual(npub, pubNpub)
    }

    func testNsecEncodeMatchesVector() {
        let nsec = NIP19.nsec(fromSecretKey: hex(secHex))
        XCTAssertEqual(nsec, secNsec)
    }

    func testNpubDecodeMatchesVector() {
        let key = NIP19.publicKey(fromNpub: pubNpub)
        XCTAssertEqual(key, hex(pubHex))
    }

    func testNsecDecodeMatchesVector() {
        let key = NIP19.secretKey(fromNsec: secNsec)
        XCTAssertEqual(key, hex(secHex))
    }

    // MARK: - Round-trips

    func testNpubRoundTrip() {
        let raw = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        guard let npub = NIP19.npub(fromPublicKey: raw) else { return XCTFail("encode") }
        XCTAssertEqual(NIP19.publicKey(fromNpub: npub), raw)
    }

    func testNsecRoundTrip() {
        let raw = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        guard let nsec = NIP19.nsec(fromSecretKey: raw) else { return XCTFail("encode") }
        XCTAssertEqual(NIP19.secretKey(fromNsec: nsec), raw)
    }

    func testUppercaseDecodesSameAsLowercase() {
        // bech32 is case-insensitive (but never mixed); an all-caps npub decodes
        // to the same key.
        XCTAssertEqual(NIP19.publicKey(fromNpub: pubNpub.uppercased()), hex(pubHex))
    }

    // MARK: - Rejections

    func testWrongHRPRejected() {
        // A valid nsec is not a valid npub.
        XCTAssertNil(NIP19.publicKey(fromNpub: secNsec))
    }

    func testBadChecksumRejected() {
        // Flip the last data character → checksum must fail.
        var bad = Array(pubNpub)
        bad[bad.count - 1] = bad.last == "6" ? "7" : "6"
        XCTAssertNil(NIP19.publicKey(fromNpub: String(bad)))
    }

    func testMixedCaseRejected() {
        XCTAssertNil(Bech32.decode("npub1ABC"))   // structurally mixed-case
    }

    func testWrongLengthPayloadRejected() {
        XCTAssertNil(NIP19.npub(fromPublicKey: Data(repeating: 0, count: 31)))
        XCTAssertNil(NIP19.npub(fromPublicKey: Data(repeating: 0, count: 33)))
    }

    // MARK: - convertBits

    func testConvertBitsRoundTrips() {
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF, 0x42]
        guard let five = Bech32.convertBits(bytes, from: 8, to: 5, pad: true),
              let back = Bech32.convertBits(five, from: 5, to: 8, pad: false)
        else { return XCTFail("convertBits") }
        XCTAssertEqual(back, bytes)
    }

    // MARK: - Helpers

    private func hex(_ s: String) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return Data(out)
    }
}
