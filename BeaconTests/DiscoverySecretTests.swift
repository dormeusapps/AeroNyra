//
//  DiscoverySecretTests.swift
//  BeaconTests
//
//  Known-answer + property tests for DiscoverySecret (Step 5c), written FROM
//  docs/RECONNECT_DISCOVERY_SECRET_KAT.md. Vectors there were computed out-of-impl
//  (Python) before this Swift existed; this file asserts CryptoKit reproduces them.
//
//  Tier 1a — X25519 DH anchored to RFC 7748 §6.1
//  Tier 1b — HKDF-SHA256 anchored to RFC 5869 (TC1 + TC3 empty-salt)
//  Tier 2  — S_AB framing (DV1 baseline+symmetry, DV2 info-sep, DV3 pair-sep)
//  §5      — determinism, symmetry/separation over fresh pairs, public-input
//            rejection guard-rail, and round-trip into the beacon layer.
//

import XCTest
import CryptoKit
@testable import Beacon

final class DiscoverySecretTests: XCTestCase {

    // MARK: RFC 7748 §6.1 fixtures
    private let aPriv = Data(hex: "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
    private let aPub  = Data(hex: "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
    private let bPriv = Data(hex: "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
    private let bPub  = Data(hex: "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
    private let kAB   = Data(hex: "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")

    // DV3 second peer C (priv = 0x01 × 32)
    private let cPriv = Data(hex: "0101010101010101010101010101010101010101010101010101010101010101")
    private let cPub  = Data(hex: "a4e09292b651c278b9772c569f5fa9bb13d906b46ab68c9df9dc2b4409f8a209")

    // Tier 2 expected S_AB values
    private let dv1 = Data(hex: "e3c109ab7b8841085689cae5bed1def3bd37ce8390f35cf73187a6a40d4bf380")
    private let dv2 = Data(hex: "bd97aa67435dd37517b16cf4a9766e2b2b02968bf63d07dc9742b35fe885e417")
    private let dv3 = Data(hex: "cf6d70dbeaeaf9aa713cf8f41cdb27af535c890c2250784162efd4b447833fe7")

    // MARK: - Tier 1a — X25519 DH (RFC 7748 §6.1)

    func testX25519_RFC7748_publicKeysDeriveFromPrivate() throws {
        let a = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: aPriv)
        let b = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bPriv)
        XCTAssertEqual(a.publicKey.rawRepresentation, aPub, "A = X25519(a,9)")
        XCTAssertEqual(b.publicKey.rawRepresentation, bPub, "B = X25519(b,9)")
    }

    func testX25519_RFC7748_sharedSecretAndSymmetry() throws {
        let a = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: aPriv)
        let b = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bPriv)
        let aPubKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: aPub)
        let bPubKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: bPub)

        let ssAB = try a.sharedSecretFromKeyAgreement(with: bPubKey)
        let ssBA = try b.sharedSecretFromKeyAgreement(with: aPubKey)

        XCTAssertEqual(Self.bytes(ssAB), kAB, "DH(a,B) == RFC 7748 K")
        XCTAssertEqual(Self.bytes(ssBA), kAB, "DH(b,A) == RFC 7748 K (symmetry)")
    }

    // MARK: - Tier 1b — HKDF-SHA256 (RFC 5869)

    func testHKDF_RFC5869_TC1() {
        let ikm  = Data(repeating: 0x0b, count: 22)
        let salt = Data((0x00...0x0c).map { UInt8($0) })
        let info = Data((0xf0...0xf9).map { UInt8($0) })
        let okm  = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt, info: info, outputByteCount: 42)
        XCTAssertEqual(
            Self.bytes(okm),
            Data(hex: "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"))
    }

    func testHKDF_RFC5869_TC3_emptySalt() {
        // The empty-salt path — the one our framing actually uses.
        let ikm = Data(repeating: 0x0b, count: 22)
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data(), info: Data(), outputByteCount: 42)
        XCTAssertEqual(
            Self.bytes(okm),
            Data(hex: "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"))
    }

    // MARK: - Tier 2 — S_AB framing

    func testSAB_DV1_baselineAndSymmetry() throws {
        let a = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: aPriv)
        let b = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bPriv)

        // Alice derives against Bob's public key, and vice versa.
        let fromA = try DiscoverySecret.derive(ourAgreementPrivate: a, theirAgreementPublic: bPub)
        let fromB = try DiscoverySecret.derive(ourAgreementPrivate: b, theirAgreementPublic: aPub)

        XCTAssertEqual(DiscoverySecret.rawBytes(of: fromA), dv1, "DV1 baseline (full DH→HKDF chain)")
        XCTAssertEqual(DiscoverySecret.rawBytes(of: fromB), dv1, "DV1 symmetry — both sides reach S_AB")
    }

    func testSAB_DV2_infoDomainSeparation() {
        // Bump info to v2 over the SAME ikm (RFC 7748 K) and confirm the key
        // changes — i.e. info is doing real domain separation.
        let v2 = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: kAB),
            salt: Data(),
            info: Data("AeroNyra/discovery-secret/v2".utf8),
            outputByteCount: 32)
        XCTAssertEqual(Self.bytes(v2), dv2, "DV2 vector")
        XCTAssertNotEqual(dv2, dv1, "info bump ⇒ different key")
    }

    func testSAB_DV3_pairSeparation() throws {
        let a = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: aPriv)
        let sAC = try DiscoverySecret.derive(ourAgreementPrivate: a, theirAgreementPublic: cPub)
        XCTAssertEqual(DiscoverySecret.rawBytes(of: sAC), dv3, "DV3 vector — DH(a,C)")
        XCTAssertNotEqual(dv3, dv1, "different peer ⇒ different key")
    }

    func testDV3_secondPeerPublicDerivesFromItsPrivate() throws {
        let c = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: cPriv)
        XCTAssertEqual(c.publicKey.rawRepresentation, cPub, "C = X25519(C_priv, 9)")
    }

    // MARK: - §5 properties

    func testDeterminism() throws {
        let a = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: aPriv)
        let s1 = try DiscoverySecret.derive(ourAgreementPrivate: a, theirAgreementPublic: bPub)
        let s2 = try DiscoverySecret.derive(ourAgreementPrivate: a, theirAgreementPublic: bPub)
        XCTAssertEqual(DiscoverySecret.rawBytes(of: s1), DiscoverySecret.rawBytes(of: s2))
    }

    func testSymmetryOverFreshPairs() throws {
        for _ in 0..<64 {
            let a = Curve25519.KeyAgreement.PrivateKey()
            let b = Curve25519.KeyAgreement.PrivateKey()
            let fromA = try DiscoverySecret.derive(
                ourAgreementPrivate: a, theirAgreementPublic: b.publicKey.rawRepresentation)
            let fromB = try DiscoverySecret.derive(
                ourAgreementPrivate: b, theirAgreementPublic: a.publicKey.rawRepresentation)
            XCTAssertEqual(DiscoverySecret.rawBytes(of: fromA), DiscoverySecret.rawBytes(of: fromB))
        }
    }

    func testSeparationOverFreshPairs() throws {
        var seen = Set<Data>()
        for _ in 0..<64 {
            let a = Curve25519.KeyAgreement.PrivateKey()
            let b = Curve25519.KeyAgreement.PrivateKey()
            let s = try DiscoverySecret.derive(
                ourAgreementPrivate: a, theirAgreementPublic: b.publicKey.rawRepresentation)
            let bytes = DiscoverySecret.rawBytes(of: s)
            XCTAssertFalse(seen.contains(bytes), "independent pairs must not collide")
            seen.insert(bytes)
        }
    }

    /// Guard-rail: a secret built from PUBLIC keys alone must NOT equal S_AB.
    /// A regression that made the secret public-derivable would collapse beacon
    /// unlinkability; this pins the difference.
    func testPublicInputRejection() throws {
        let a = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: aPriv)
        let real = DiscoverySecret.rawBytes(
            of: try DiscoverySecret.derive(ourAgreementPrivate: a, theirAgreementPublic: bPub))

        // Any public-only construction over the two identity public keys.
        var publicOnly = Data()
        for d in [aPub, bPub].sorted(by: { $0.lexicographicallyPrecedes($1) }) { publicOnly.append(d) }
        let publicDigest = Data(SHA256.hash(data: publicOnly))

        XCTAssertNotEqual(real, publicDigest, "S_AB must not be computable from public keys")
    }

    /// The derived secret round-trips through the real beacon layer: a token
    /// emitted under S_AB is recognized, and a stranger secret is not.
    func testDerivedSecretFeedsBeacon() throws {
        let a = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: aPriv)
        let sAB = DiscoverySecret.rawBytes(
            of: try DiscoverySecret.derive(ourAgreementPrivate: a, theirAgreementPublic: bPub))

        let epoch: UInt64 = 1_900_000
        // Alice emits her beacon labelled with her OWN identity (aPub).
        let token = ReconnectBeacon.token(secret: sAB, epoch: epoch, label: aPub)

        let contact = BeaconRecognizer.Contact(identity: aPub, secret: sAB)
        let present = BeaconRecognizer.recognize(
            emissionSet: [token], contacts: [contact], epoch: epoch, skew: 1)
        XCTAssertTrue(present.contains(aPub), "derived S_AB ⇒ recognizable beacon")

        let stranger = BeaconRecognizer.Contact(
            identity: aPub, secret: Data(repeating: 0x99, count: 32))
        let none = BeaconRecognizer.recognize(
            emissionSet: [token], contacts: [stranger], epoch: epoch, skew: 1)
        XCTAssertFalse(none.contains(aPub), "wrong secret ⇒ no recognition")
    }

    // MARK: - Negative

    func testInvalidPeerKeyThrows() {
        let a = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(
            try DiscoverySecret.derive(
                ourAgreementPrivate: a,
                theirAgreementPublic: Data(repeating: 0x00, count: 31)),  // wrong length
            "a malformed peer public key must throw, not silently derive")
    }

    // MARK: - Helpers

    private static func bytes<T: ContiguousBytes>(_ value: T) -> Data {
        value.withUnsafeBytes { Data($0) }
    }
}

// MARK: - Hex helper

private extension Data {
    init(hex: String) {
        precondition(hex.count % 2 == 0, "odd-length hex")
        var out = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<j], radix: 16) else {
                preconditionFailure("bad hex byte \(hex[i..<j])")
            }
            out.append(byte)
            i = j
        }
        self = out
    }
}
