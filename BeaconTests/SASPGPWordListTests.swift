// SASPGPWordListTests.swift
// BeaconTests
//
// Known-answer tests for the embedded canonical PGP word list
// (SASPGPWordList.swift), anchored to PUBLISHED reference vectors — the external
// reference the project's crypto discipline requires. These are what would have
// caught the corrupted-gist copy (which drops odd[0x02]="aftermath" and shifts
// the rest). If any of these fail, the embedded data is wrong; do not "fix" the
// test to match — fix the data.

import XCTest
@testable import Beacon

final class SASPGPWordListTests: XCTestCase {

    private let list = SASWordList.pgp   // force-built; proves 256/256 + no dups

    // MARK: Published byte → word anchors

    func testSingleByteEvenAnchors() {
        // Even list (two-syllable), phrase position 0.
        XCTAssertEqual(SASWordPhrase.encode(Data([0x00]), using: list), ["aardvark"])
        XCTAssertEqual(SASWordPhrase.encode(Data([0x17]), using: list), ["banjo"])
        XCTAssertEqual(SASWordPhrase.encode(Data([0x33]), using: list), ["chisel"])
        XCTAssertEqual(SASWordPhrase.encode(Data([0x82]), using: list), ["miser"])
        XCTAssertEqual(SASWordPhrase.encode(Data([0xE5]), using: list), ["topmost"])
        XCTAssertEqual(SASWordPhrase.encode(Data([0xFE]), using: list), ["woodlark"])
        XCTAssertEqual(SASWordPhrase.encode(Data([0xFF]), using: list), ["Zulu"])
    }

    func testOddAnchorsAtOddPosition() {
        // Odd list (three-syllable) is used at odd positions; pair each with a
        // leading even byte so the second word exercises the odd list.
        XCTAssertEqual(SASWordPhrase.encode(Data([0x00, 0x00]), using: list),
                       ["aardvark", "adroitness"])
        XCTAssertEqual(SASWordPhrase.encode(Data([0x00, 0x02]), using: list),
                       ["aardvark", "aftermath"])   // the entry the gist dropped
        XCTAssertEqual(SASWordPhrase.encode(Data([0x00, 0x0D]), using: list),
                       ["aardvark", "asteroid"])
        XCTAssertEqual(SASWordPhrase.encode(Data([0x00, 0xFF]), using: list),
                       ["aardvark", "Yucatan"])
    }

    // MARK: Published two-byte vectors (from a tested reference implementation)

    func testTwoByteReferenceVectors() {
        XCTAssertEqual(SASWordPhrase.encode(Data([0xE5, 0x82]), using: list),
                       ["topmost", "Istanbul"])
        XCTAssertEqual(SASWordPhrase.encode(Data([0x82, 0xE5]), using: list),
                       ["miser", "travesty"])
        // And they decode back.
        XCTAssertEqual(SASWordPhrase.decode(["topmost", "Istanbul"], using: list),
                       Data([0xE5, 0x82]))
        XCTAssertEqual(SASWordPhrase.decode(["miser", "travesty"], using: list),
                       Data([0x82, 0xE5]))
    }

    // MARK: Exhaustive round-trip over the real list

    func testEveryByteRoundTripsAtBothParities() {
        for v in 0...255 {
            let b = UInt8(v)
            let evenWord = list.word(forByte: b, position: 0)
            XCTAssertEqual(list.byte(forWord: evenWord, position: 0), b)
            let oddWord = list.word(forByte: b, position: 1)
            XCTAssertEqual(list.byte(forWord: oddWord, position: 1), b)
        }
    }

    func testFullSequenceRoundTrip() {
        let bytes = Data((0...255).map { UInt8($0) })
        let words = SASWordPhrase.encode(bytes, using: list)
        XCTAssertEqual(words.count, 256)
        XCTAssertEqual(SASWordPhrase.decode(words, using: list), bytes)
    }

    // MARK: End-to-end 4-word phrase from a fingerprint

    func testFourWordPhraseFromFingerprintIsStableAndReal() {
        let fp = Data("safety-number-canonical-bytes".utf8)
        let phrase = SASWordPhrase.phrase(fromFingerprint: fp, using: list)
        XCTAssertEqual(phrase.count, 4)
        // Deterministic and decodes back to the 4 derived digest bytes.
        XCTAssertEqual(SASWordPhrase.phrase(fromFingerprint: fp, using: list), phrase)
        XCTAssertNotNil(SASWordPhrase.decode(phrase, using: list))
        // Every word is a real PGP word (alternating even/odd).
        for (i, word) in phrase.enumerated() {
            XCTAssertNotNil(list.byte(forWord: word, position: i))
        }
    }
}
