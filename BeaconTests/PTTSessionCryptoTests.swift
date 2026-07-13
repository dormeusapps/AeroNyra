//
//  PTTSessionCryptoTests.swift
//  BeaconTests
//
//  KAT-anchored tests for the PTT session crypto. The expected bytes come ONLY
//  from the committed fixture (BeaconTests/Fixtures/ptt_kat_vectors.json,
//  produced externally by tools/ptt_kat_gen.py via pyca/cryptography). This test
//  NEVER computes its own expected values — it asserts CryptoKit reproduces the
//  external bytes exactly, including the RFC 8439 / RFC 5869 ground-truth vectors
//  carried in the JSON. Plus two invariant pin-tests (nonce; anti-replay).
//

import XCTest
import CryptoKit
@testable import Beacon

final class PTTSessionCryptoTests: XCTestCase {

    // MARK: Fixture model (mirrors ptt_kat_vectors.json)

    private struct Fixture: Decodable {
        let rfc8439_aead: RFCAEAD
        let rfc5869_hkdf: RFCHKDF
        let hkdf: HKDFVectors
        let aead_frames: [FrameVector]
    }
    private struct RFCAEAD: Decodable { let key, nonce, aad, plaintext, ciphertext, tag: String }
    private struct RFCHKDF: Decodable { let ikm, salt, info: String; let length: Int; let okm: String }
    private struct HKDFVectors: Decodable { let session_secret, salt: String; let k_send, k_recv: DirKey }
    private struct DirKey: Decodable { let info_ascii, info_hex, derived_key: String }
    private struct FrameVector: Decodable {
        let name, direction, key: String
        let counter: UInt64
        let nonce, aad, plaintext, ciphertext, tag: String
    }

    private func loadFixture() throws -> Fixture {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: "ptt_kat_vectors", withExtension: "json"),
                                "ptt_kat_vectors.json not in the test bundle's resources")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func hex(_ s: String) throws -> Data {
        try XCTUnwrap(Data(hexString: s), "bad hex: \(s)")
    }

    // MARK: 1 — RFC 8439 §2.8.2: CryptoKit ChaChaPoly vs RFC ground truth

    func testRFC8439AEADMatchesCryptoKit() throws {
        let v = try loadFixture().rfc8439_aead
        let key = SymmetricKey(data: try hex(v.key))
        let nonce = try ChaChaPoly.Nonce(data: try hex(v.nonce))
        let aad = try hex(v.aad), pt = try hex(v.plaintext)

        let box = try ChaChaPoly.seal(pt, using: key, nonce: nonce, authenticating: aad)
        XCTAssertEqual(box.ciphertext, try hex(v.ciphertext))
        XCTAssertEqual(box.tag, try hex(v.tag))
        // And it opens back to the RFC plaintext.
        XCTAssertEqual(try ChaChaPoly.open(box, using: key, authenticating: aad), pt)
    }

    // MARK: 2 — RFC 5869 TC1: CryptoKit HKDF vs RFC ground truth

    func testRFC5869HKDFMatchesCryptoKit() throws {
        let v = try loadFixture().rfc5869_hkdf
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: try hex(v.ikm)),
                                         salt: try hex(v.salt), info: try hex(v.info),
                                         outputByteCount: v.length)
        XCTAssertEqual(okm.bytes, try hex(v.okm))
    }

    // MARK: 3 — directional HKDF keys reproduce the external vectors

    func testDirectionalKeysMatchVectors() throws {
        let v = try loadFixture().hkdf
        // The module's info labels must be the exact bytes the vectors pinned.
        XCTAssertEqual(PTTSessionCrypto.infoInitiatorToResponder, try hex(v.k_send.info_hex))
        XCTAssertEqual(PTTSessionCrypto.infoResponderToInitiator, try hex(v.k_recv.info_hex))

        let keys = PTTSessionCrypto.directionalKeys(secret: SymmetricKey(data: try hex(v.session_secret)))
        XCTAssertEqual(keys.initiatorToResponder.bytes, try hex(v.k_send.derived_key))
        XCTAssertEqual(keys.responderToInitiator.bytes, try hex(v.k_recv.derived_key))
    }

    // MARK: 4 — per-frame seal/open reproduces every external vector

    func testAEADFramesMatchVectors() throws {
        for v in try loadFixture().aead_frames {
            let key = SymmetricKey(data: try hex(v.key))
            let aad = try hex(v.aad), pt = try hex(v.plaintext)

            // Nonce encoding is the pinned 0x00000000 ‖ BE64(counter).
            XCTAssertEqual(Data(PTTSessionCrypto.nonce(counter: v.counter)), try hex(v.nonce),
                           "nonce mismatch for \(v.name)")

            // The sealer (at this counter) must produce the exact vector bytes.
            let sealer = PTTFrameSealer(key: key, counter: v.counter)
            let sealed = try sealer.seal(pt, aad: aad)
            XCTAssertEqual(sealed.counter, v.counter, v.name)
            XCTAssertEqual(sealed.ciphertext, try hex(v.ciphertext), v.name)
            XCTAssertEqual(sealed.tag, try hex(v.tag), v.name)

            // And the opener round-trips it back to the plaintext.
            let opener = PTTFrameOpener(key: key)
            let out = try opener.open(counter: v.counter,
                                      ciphertext: try hex(v.ciphertext),
                                      tag: try hex(v.tag), aad: aad)
            XCTAssertEqual(out, pt, v.name)
        }
    }

    // MARK: 5 — invariant (a): nonce distinct / monotonic / ceiling throws

    func testNonceDistinctMonotonicAndCeilingThrows() throws {
        let key = SymmetricKey(size: .bits256)
        let sealer = PTTFrameSealer(key: key)
        var counters = [UInt64](), nonces = Set<Data>()
        for _ in 0..<1_000 {
            let s = try sealer.seal(Data("x".utf8))
            counters.append(s.counter)
            nonces.insert(Data(PTTSessionCrypto.nonce(counter: s.counter)))
        }
        XCTAssertEqual(counters, Array(0..<1_000), "counter must be strictly monotonic from 0")
        XCTAssertEqual(nonces.count, 1_000, "every frame's nonce must be distinct")

        // At the ceiling the sealer must refuse rather than wrap the nonce.
        let atCeiling = PTTFrameSealer(key: key, counter: .max)
        XCTAssertThrowsError(try atCeiling.seal(Data("x".utf8))) {
            XCTAssertEqual($0 as? PTTSessionCryptoError, .counterCeiling)
        }
    }

    // MARK: 6 — invariant (b): anti-replay window

    func testReplayWindow() throws {
        let key = SymmetricKey(size: .bits256)
        // Authentic frame at an arbitrary counter (fresh sealer per counter).
        func frame(_ c: UInt64) throws -> (Data, Data) {
            let s = try PTTFrameSealer(key: key, counter: c).seal(Data("f".utf8))
            return (s.ciphertext, s.tag)
        }
        let opener = PTTFrameOpener(key: key)
        func open(_ c: UInt64) throws { let (ct, tag) = try frame(c); _ = try opener.open(counter: c, ciphertext: ct, tag: tag) }
        func expectReplayed(_ c: UInt64) throws {
            let (ct, tag) = try frame(c)
            XCTAssertThrowsError(try opener.open(counter: c, ciphertext: ct, tag: tag)) {
                XCTAssertEqual($0 as? PTTSessionCryptoError, .replayed)
            }
        }

        try open(100)              // first frame → accepted, highest = 100
        try expectReplayed(100)    // duplicate → rejected
        try open(99)               // in-window reorder (diff 1, unseen) → accepted
        try expectReplayed(99)     // now a duplicate → rejected
        try expectReplayed(36)     // diff = 64 = window → TOO OLD → rejected
        try open(37)               // diff = 63, unseen → accepted
        try open(101)              // forward → accepted, highest = 101
        try expectReplayed(37)     // diff now 64 → too old → rejected

        // A tampered tag is an auth failure, not accepted.
        var (ct, tag) = try frame(200)
        tag[tag.startIndex] ^= 0x01
        XCTAssertThrowsError(try opener.open(counter: 200, ciphertext: ct, tag: tag)) {
            XCTAssertEqual($0 as? PTTSessionCryptoError, .authenticationFailed)
        }
        // …and the forgery must NOT have advanced the window: a real 200 still opens.
        let (ct2, tag2) = try frame(200)
        XCTAssertNoThrow(try opener.open(counter: 200, ciphertext: ct2, tag: tag2))
    }
}

// MARK: - Local hex decode (test-only)

private extension SymmetricKey {
    /// Raw key bytes for byte-exact comparison against the KAT vectors.
    var bytes: Data { withUnsafeBytes { Data($0) } }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var d = Data(capacity: hexString.count / 2)
        var i = hexString.startIndex
        while i < hexString.endIndex {
            let j = hexString.index(i, offsetBy: 2)
            guard let b = UInt8(hexString[i..<j], radix: 16) else { return nil }
            d.append(b); i = j
        }
        self = d
    }
}
