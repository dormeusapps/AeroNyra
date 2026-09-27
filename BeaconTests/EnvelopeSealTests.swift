//
//  EnvelopeSealTests.swift
//  BeaconTests
//
//  Pins EnvelopeSeal v1 against KNOWN-ANSWER vectors from an independent
//  pure-Python implementation (tools/gen_envelope_seal_kat.py, self-checked
//  against RFC 7748 / 5869 / 8439), plus the properties the format promises:
//  fresh ephemeral per message, only the recipient opens, any bit flip fails,
//  a weak (all-zero) shared secret is refused, and anything not v1-sealed is
//  refused (the flag day).
//

import XCTest
import CryptoKit
@testable import Beacon

final class EnvelopeSealTests: XCTestCase {

    private func hex(_ s: String) -> Data {
        var d = Data(); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            d.append(UInt8(s[i..<j], radix: 16)!); i = j
        }
        return d
    }

    // MARK: Known-answer vectors (byte for byte)

    func testSealMatchesEveryKnownAnswerVector() throws {
        XCTAssertFalse(EnvelopeSealKATVectors.all.isEmpty)
        for v in EnvelopeSealKATVectors.all {
            let eph = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(v.ephemeralPrivate))
            XCTAssertEqual(eph.publicKey.rawRepresentation, hex(v.ephemeralPublic))
            let sealed = try EnvelopeSeal.sealForTesting(hex(v.inner), to: hex(v.recipientPublic), ephemeral: eph)
            XCTAssertEqual(sealed, hex(v.sealed), "seal must match the vector byte for byte")
        }
    }

    func testOpenRecoversEveryKnownAnswerVector() throws {
        for v in EnvelopeSealKATVectors.all {
            let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(v.recipientPrivate))
            XCTAssertEqual(recipient.publicKey.rawRepresentation, hex(v.recipientPublic))
            XCTAssertEqual(try EnvelopeSeal.open(hex(v.sealed), with: recipient), hex(v.inner))
        }
    }

    // MARK: Properties

    func testFreshEphemeralPerMessage() throws {
        let r = Curve25519.KeyAgreement.PrivateKey()
        let a = try EnvelopeSeal.seal(Data("same".utf8), to: r.publicKey.rawRepresentation)
        let b = try EnvelopeSeal.seal(Data("same".utf8), to: r.publicKey.rawRepresentation)
        XCTAssertNotEqual(a.subdata(in: 1..<33), b.subdata(in: 1..<33), "a new ephemeral key every seal")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 4 + EnvelopeSeal.overhead)
    }

    func testOnlyTheRecipientCanOpen() throws {
        let r = Curve25519.KeyAgreement.PrivateKey()
        let sealed = try EnvelopeSeal.seal(Data("hi".utf8), to: r.publicKey.rawRepresentation)
        XCTAssertEqual(try EnvelopeSeal.open(sealed, with: r), Data("hi".utf8))
        XCTAssertThrowsError(try EnvelopeSeal.open(sealed, with: Curve25519.KeyAgreement.PrivateKey())) {
            XCTAssertEqual($0 as? EnvelopeSeal.SealError, .authenticationFailed)
        }
    }

    func testAnyBitFlipFails() throws {
        let r = Curve25519.KeyAgreement.PrivateKey()
        let sealed = try EnvelopeSeal.seal(Data("payload bytes".utf8), to: r.publicKey.rawRepresentation)
        for i in 1..<sealed.count {             // byte 0 is the version (its own test)
            var bad = sealed
            bad[bad.startIndex + i] ^= 0x01
            XCTAssertThrowsError(try EnvelopeSeal.open(bad, with: r), "flip at byte \(i) must fail")
        }
    }

    func testAllZeroPeerKeyIsRefused() {
        let zero = Data(repeating: 0, count: 32)
        XCTAssertThrowsError(try EnvelopeSeal.seal(Data("x".utf8), to: zero))
        var forged = Data([EnvelopeSeal.version]) + zero + Data(repeating: 0, count: 16)
        forged.append(0)
        XCTAssertThrowsError(try EnvelopeSeal.open(forged, with: Curve25519.KeyAgreement.PrivateKey()))
    }

    func testUnsealedOrWrongVersionIsRefused() throws {
        let r = Curve25519.KeyAgreement.PrivateKey()
        // A plain libsignal prekey message starts with its type byte (3), not 0x01.
        XCTAssertThrowsError(try EnvelopeSeal.open(Data([3]) + Data(repeating: 7, count: 80), with: r)) {
            XCTAssertEqual($0 as? EnvelopeSeal.SealError, .notSealed)
        }
        var sealed = try EnvelopeSeal.seal(Data("x".utf8), to: r.publicKey.rawRepresentation)
        sealed[sealed.startIndex] = 0x02
        XCTAssertThrowsError(try EnvelopeSeal.open(sealed, with: r)) {
            XCTAssertEqual($0 as? EnvelopeSeal.SealError, .notSealed)
        }
        XCTAssertThrowsError(try EnvelopeSeal.open(Data([EnvelopeSeal.version]), with: r)) {
            XCTAssertEqual($0 as? EnvelopeSeal.SealError, .notSealed)
        }
    }
}
