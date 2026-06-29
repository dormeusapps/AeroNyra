//
//  NostrEventTests.swift
//  BeaconTests
//
//  Phase 8c-ii-0 — NIP-01 event tests for Core/Nostr/NostrEvent.swift.
//
//  Known-answer vector generated with an independent libsecp256k1 binding
//  (coincurve) and cross-checked: the hand-rolled canonical serialization here
//  matches an independent JSON serializer, and the signature verifies against
//  the id. The content deliberately exercises every NIP-01 escape case
//  (" \ \n \t) plus multibyte unicode (em-dash, ☂, 🍕) emitted verbatim.
//

import XCTest
@testable import Beacon

final class NostrEventTests: XCTestCase {

    // BIP-340 vector 1 secret -> this x-only pubkey.
    private let secretKey = "b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef"
    private let pubkey = "dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659"
    private let createdAt: Int64 = 1700000000
    private let kind = 1
    private let tags = [
        ["e", "5c83da77af1dec6d7289834998ad7aafbd9e2191396d75ec3cc27f5a77226f36"],
        ["p", "f7234bd4c1394dda46d09f35bd384dd30cc552ad5541990f98844fb06676e9ca"],
    ]
    // Actual content string (real newline/tab/quote/backslash + unicode).
    private let content = "Hello, Nostr! \"quotes\" \\backslash\\ \n newline \t tab — unicode ☂ 🍕"

    private let knownID = "3d3be3a056d706928f52e9f1d094b3cdc74b663fb159084d96a55191c505a8bb"
    private let knownSig = "167a56a986099b664306e69d802924290f266debc984646c1322524d6e1d94926a058fd4e7701ca8a044fece1411020a3341831d50f106b13467cc3925e8f2b4"

    // Canonical serialization (raw string: backslashes are literal here).
    private let knownSerialization = #"[0,"dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659",1700000000,1,[["e","5c83da77af1dec6d7289834998ad7aafbd9e2191396d75ec3cc27f5a77226f36"],["p","f7234bd4c1394dda46d09f35bd384dd30cc552ad5541990f98844fb06676e9ca"]],"Hello, Nostr! \"quotes\" \\backslash\\ \n newline \t tab — unicode ☂ 🍕"]"#

    // MARK: Canonical serialization + id

    func testCanonicalSerializationMatchesKAT() {
        let s = NostrEvent.serializeForID(pubkey: pubkey,
                                          createdAt: createdAt,
                                          kind: kind,
                                          tags: tags,
                                          content: content)
        XCTAssertEqual(s, knownSerialization)
    }

    func testComputeIDMatchesKAT() {
        let id = NostrEvent.computeID(pubkey: pubkey,
                                      createdAt: createdAt,
                                      kind: kind,
                                      tags: tags,
                                      content: content)
        XCTAssertEqual(id, knownID)
    }

    // MARK: Signature verification (against an independent sig)

    func testKnownSignatureValidates() {
        let event = NostrEvent(id: knownID,
                               pubkey: pubkey,
                               createdAt: createdAt,
                               kind: kind,
                               tags: tags,
                               content: content,
                               sig: knownSig)
        XCTAssertTrue(event.isValid(), "coincurve-produced signature must verify")
    }

    // MARK: Sign

    func testSignedEventHasCorrectIDAndValidates() throws {
        guard let event = NostrEvent.signed(kind: kind,
                                            content: content,
                                            tags: tags,
                                            createdAt: createdAt,
                                            secretKey: hexData(secretKey)) else {
            return XCTFail("signed returned nil")
        }
        // id and pubkey are deterministic; the signature is not (aux randomness).
        XCTAssertEqual(event.id, knownID)
        XCTAssertEqual(event.pubkey, pubkey)
        XCTAssertEqual(event.sig.count, 128, "64-byte sig as hex")
        XCTAssertTrue(event.isValid())
    }

    // MARK: Tamper

    func testTamperedContentFailsValidation() {
        let event = NostrEvent(id: knownID,
                               pubkey: pubkey,
                               createdAt: createdAt,
                               kind: kind,
                               tags: tags,
                               content: content + "!",   // any change breaks the id
                               sig: knownSig)
        XCTAssertFalse(event.isValid(), "altered content must fail id/signature check")
    }

    // MARK: Wire JSON round-trip

    func testWireJSONRoundTrip() throws {
        guard let original = NostrEvent.signed(kind: kind,
                                               content: content,
                                               tags: tags,
                                               createdAt: createdAt,
                                               secretKey: hexData(secretKey)),
              let data = original.jsonData(),
              let parsed = NostrEvent(jsonData: data) else {
            return XCTFail("encode/parse failed")
        }
        XCTAssertEqual(parsed, original)
        XCTAssertTrue(parsed.isValid())
    }

    // MARK: Timestamp randomization

    func testRandomizedTimestampInRange() {
        let now: Int64 = 1_700_000_000
        let maxBack: Int64 = 2 * 24 * 60 * 60
        for _ in 0..<200 {
            let t = NostrEvent.randomizedTimestamp(now: now, maxBackdateSeconds: maxBack)
            XCTAssertLessThanOrEqual(t, now)
            XCTAssertGreaterThanOrEqual(t, now - maxBack)
        }
    }

    // MARK: Helpers

    private func hexData(_ string: String) -> Data {
        var bytes = [UInt8]()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            bytes.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }
}
