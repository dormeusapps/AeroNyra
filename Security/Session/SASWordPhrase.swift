// SASWordPhrase.swift
// Security/Session
//
// The human-checkable Short Authentication String for closed-contact pairing
// (docs/CONTACT_MODEL.md §5). During the apart-pairing flow both devices compute
// the SAME short phrase from the SAME safety-number fingerprint and the two
// people read it to each other over a live call. Because the fingerprint is a
// function of BOTH identity keys (see SignalSession.safetyNumber /
// SecureSession.SafetyNumber), a man-in-the-middle who swapped a key in transit
// cannot make both phrases match without also defeating the live voice channel.
//
// THIS FILE IS THE CODEC ONLY — pure, reversible bytes ↔ words. It is the
// "alphabet-independent" half: the actual word data (the PGP word list) is
// injected as a `SASWordList`, so this logic is unit-testable against a synthetic
// list and the real list is a separately-sourced, KAT-anchored data asset. No
// libsignal dependency; the only crypto here is SHA-256, used to fold an
// arbitrary-length fingerprint down to a fixed handful of bytes.
//
// WORDLIST SHAPE (PGP word list): TWO lists of 256 words — `even` and `odd`.
// A byte is rendered using `even` when it sits at an even position in the phrase
// and `odd` when it sits at an odd position. Alternating the list by position is
// what makes a TRANSPOSITION (two adjacent spoken words swapped) detectable: a
// word decoded at the wrong parity simply isn't in the list it's looked up
// against, so the decode fails rather than silently returning different bytes.
//
// PHRASE LENGTH: 4 words = 4 bytes = 32 bits of interactive SAS strength. The
// attacker gets exactly one live attempt and must commit before learning the
// value, so 32 bits is comfortably strong (well above ZRTP's classic ~16-bit
// two-word SAS).
//

import Foundation
import CryptoKit

// MARK: - SASWordList

/// The injected word data: two 256-entry lists (`even` / `odd`). Construction
/// validates the shape so a malformed list fails loudly at load, not silently at
/// compare time. Lookup is case-insensitive (people may type/transcribe casing
/// inconsistently); the canonical rendered form is whatever the list holds.
public struct SASWordList: Sendable {

    public enum ListError: Error, Equatable {
        /// One or both lists were not exactly 256 words.
        case wrongCount(even: Int, odd: Int)
        /// A list contained a duplicate word (case-insensitive), which would
        /// make decode ambiguous.
        case duplicateWord
    }

    public static let listSize = 256

    public let even: [String]
    public let odd: [String]
    private let evenIndex: [String: Int]
    private let oddIndex: [String: Int]

    public init(even: [String], odd: [String]) throws {
        guard even.count == Self.listSize, odd.count == Self.listSize else {
            throw ListError.wrongCount(even: even.count, odd: odd.count)
        }
        var ei = [String: Int](minimumCapacity: Self.listSize)
        for (i, w) in even.enumerated() { ei[w.lowercased()] = i }
        var oi = [String: Int](minimumCapacity: Self.listSize)
        for (i, w) in odd.enumerated() { oi[w.lowercased()] = i }
        guard ei.count == Self.listSize, oi.count == Self.listSize else {
            throw ListError.duplicateWord
        }
        self.even = even
        self.odd = odd
        self.evenIndex = ei
        self.oddIndex = oi
    }

    /// The word for a byte at a given phrase position (even position → `even`
    /// list, odd position → `odd` list).
    func word(forByte b: UInt8, position: Int) -> String {
        (position % 2 == 0 ? even : odd)[Int(b)]
    }

    /// The byte a word decodes to at a given position, or nil if the word isn't
    /// in the list for that position's parity (an unknown word, or one read at
    /// the wrong position — i.e. a transposition).
    func byte(forWord word: String, position: Int) -> UInt8? {
        let table = position % 2 == 0 ? evenIndex : oddIndex
        guard let i = table[word.lowercased()] else { return nil }
        return UInt8(i)
    }
}

// MARK: - SASWordPhrase

/// The reversible codec: bytes ↔ a spoken-word phrase, plus the convenience that
/// derives a phrase from a full fingerprint.
public enum SASWordPhrase {

    /// Maximum words a single derived phrase can carry (SHA-256 digest length).
    public static let maxWords = 32

    /// Render `bytes` as a word phrase, alternating `even`/`odd` by position.
    public static func encode(_ bytes: Data, using list: SASWordList) -> [String] {
        bytes.enumerated().map { offset, byte in
            list.word(forByte: byte, position: offset)
        }
    }

    /// Inverse of `encode`. Returns nil if any word is unknown for its position
    /// (unknown word, or a transposition caught by the parity mismatch).
    public static func decode(_ words: [String], using list: SASWordList) -> Data? {
        var out = Data(capacity: words.count)
        for (offset, word) in words.enumerated() {
            guard let byte = list.byte(forWord: word, position: offset) else { return nil }
            out.append(byte)
        }
        return out
    }

    /// Derive the comparison phrase from a fingerprint. Both devices feed the
    /// SAME canonical fingerprint bytes (e.g. `safetyNumber().qrPayload`, which
    /// is symmetric across the two peers by construction), so both compute the
    /// same words. The fingerprint is hashed and truncated to `wordCount` bytes
    /// so the phrase depends uniformly on the entire fingerprint (hence on both
    /// identity keys), not on a slice of it.
    ///
    /// `wordCount` is clamped to `maxWords`; the default of 4 gives 32 bits.
    public static func phrase(fromFingerprint fingerprint: Data,
                              wordCount: Int = 4,
                              using list: SASWordList) -> [String] {
        let n = max(0, min(wordCount, maxWords))
        let digest = SHA256.hash(data: fingerprint)
        let bytes = Data(Array(digest).prefix(n))
        return encode(bytes, using: list)
    }
}
