// SASWordPhraseTests.swift
// BeaconTests
//
// Tests the SAS phrase CODEC logic (Closed-Contact pairing, docs/CONTACT_MODEL
// §5) against a deterministic SYNTHETIC word list, so the encode/decode logic is
// proven independent of the real PGP word data (which is a separately-sourced,
// KAT-anchored asset bundled in the next step). Pure logic — no crypto engine,
// no hardware.

import XCTest
import CryptoKit
@testable import Beacon

final class SASWordPhraseTests: XCTestCase {

    // MARK: Synthetic list

    /// A deterministic 256/256 list: even words "even000"…"even255", odd words
    /// "odd000"…"odd255". Distinct across the two lists so parity is testable.
    private func makeSyntheticList() throws -> SASWordList {
        let even = (0..<256).map { String(format: "even%03d", $0) }
        let odd  = (0..<256).map { String(format: "odd%03d", $0) }
        return try SASWordList(even: even, odd: odd)
    }

    // MARK: Round-trip

    func testEveryByteRoundTripsAtBothParities() throws {
        let list = try makeSyntheticList()
        for v in 0...255 {
            let b = UInt8(v)
            let evenWord = list.word(forByte: b, position: 0)
            XCTAssertEqual(list.byte(forWord: evenWord, position: 0), b)
            let oddWord = list.word(forByte: b, position: 1)
            XCTAssertEqual(list.byte(forWord: oddWord, position: 1), b)
        }
    }

    func testFourByteRoundTrip() throws {
        let list = try makeSyntheticList()
        let bytes = Data([0x00, 0xFF, 0x10, 0x80])
        let words = SASWordPhrase.encode(bytes, using: list)
        XCTAssertEqual(words.count, 4)
        XCTAssertEqual(SASWordPhrase.decode(words, using: list), bytes)
    }

    func testEmptyRoundTrips() throws {
        let list = try makeSyntheticList()
        XCTAssertEqual(SASWordPhrase.encode(Data(), using: list), [])
        XCTAssertEqual(SASWordPhrase.decode([], using: list), Data())
    }

    // MARK: Alternation

    func testEncodeAlternatesEvenOddByPosition() throws {
        let list = try makeSyntheticList()
        let words = SASWordPhrase.encode(Data([0x00, 0xFF, 0x10, 0x80]), using: list)
        XCTAssertEqual(words[0], "even000")  // byte 0x00 at even position
        XCTAssertEqual(words[1], "odd255")   // byte 0xFF at odd position
        XCTAssertEqual(words[2], "even016")  // byte 0x10 at even position
        XCTAssertEqual(words[3], "odd128")   // byte 0x80 at odd position
    }

    // MARK: Transposition / malformed rejection

    func testAdjacentTranspositionIsDetected() throws {
        let list = try makeSyntheticList()
        let bytes = Data([0x12, 0x34, 0x56, 0x78])
        var words = SASWordPhrase.encode(bytes, using: list)
        words.swapAt(0, 1)   // swap two adjacent spoken words
        // Swapped words are now at the wrong parity → not found → decode fails.
        XCTAssertNotEqual(SASWordPhrase.decode(words, using: list), bytes)
        XCTAssertNil(SASWordPhrase.decode(words, using: list))
    }

    func testDecodeRejectsUnknownWord() throws {
        let list = try makeSyntheticList()
        XCTAssertNil(SASWordPhrase.decode(["nope", "odd000"], using: list))
    }

    func testDecodeRejectsRightWordWrongParity() throws {
        let list = try makeSyntheticList()
        // "odd000" is valid in the odd list but appears at position 0 (even).
        XCTAssertNil(SASWordPhrase.decode(["odd000"], using: list))
    }

    func testDecodeIsCaseInsensitive() throws {
        let list = try makeSyntheticList()
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        let upper = SASWordPhrase.encode(bytes, using: list).map { $0.uppercased() }
        XCTAssertEqual(SASWordPhrase.decode(upper, using: list), bytes)
    }

    // MARK: Fingerprint derivation

    func testPhraseIsDeterministic() throws {
        let list = try makeSyntheticList()
        let fp = Data("12345 67890 11111 22222 33333 44444".utf8)
        let a = SASWordPhrase.phrase(fromFingerprint: fp, using: list)
        let b = SASWordPhrase.phrase(fromFingerprint: fp, using: list)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 4)
    }

    func testDifferentFingerprintsGiveDifferentPhrases() throws {
        let list = try makeSyntheticList()
        let a = SASWordPhrase.phrase(fromFingerprint: Data("alice-bob".utf8), using: list)
        let b = SASWordPhrase.phrase(fromFingerprint: Data("alice-eve".utf8), using: list)
        XCTAssertNotEqual(a, b)
    }

    func testPhraseDerivationMatchesManualHashTruncate() throws {
        // Pin the derivation: SHA-256(fingerprint), first 4 bytes, encoded.
        let list = try makeSyntheticList()
        let fp = Data("canonical-fingerprint-bytes".utf8)
        let digest = Array(SHA256.hash(data: fp))
        let expected = SASWordPhrase.encode(Data(digest.prefix(4)), using: list)
        XCTAssertEqual(SASWordPhrase.phrase(fromFingerprint: fp, using: list), expected)
    }

    func testPhraseWordCountClampsToDigestLength() throws {
        let list = try makeSyntheticList()
        let phrase = SASWordPhrase.phrase(fromFingerprint: Data("x".utf8),
                                          wordCount: 999, using: list)
        XCTAssertEqual(phrase.count, SASWordPhrase.maxWords)   // 32
    }

    // MARK: List validation

    func testWrongSizedListThrows() {
        XCTAssertThrowsError(
            try SASWordList(even: Array(repeating: "x", count: 10),
                            odd: (0..<256).map { "o\($0)" })
        )
    }

    func testDuplicateWordThrows() throws {
        var even = (0..<256).map { "e\($0)" }
        even[1] = even[0]   // introduce a duplicate
        XCTAssertThrowsError(
            try SASWordList(even: even, odd: (0..<256).map { "o\($0)" })
        ) { error in
            XCTAssertEqual(error as? SASWordList.ListError, .duplicateWord)
        }
    }
}
