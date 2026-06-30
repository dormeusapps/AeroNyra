//
//  ReconnectBeaconTests.swift
//  BeaconTests
//
//  Anchors the discovery-beacon primitive to external reference vectors BEFORE
//  it is trusted (project discipline). Two tiers, both from
//  docs/RECONNECT_BEACON_KAT.md:
//    • Tier 1 — HMAC-SHA256 against the canonical RFC 4231 cases (proves the
//      underlying CryptoKit primitive matches the standard).
//    • Tier 2 — our framing KATs (proves TAG ‖ epoch_be ‖ label + 16-byte
//      truncation reproduce the out-of-implementation (Python) vectors).
//  Plus property tests for epoch/label/secret sensitivity, determinism, epoch
//  bucketing, decoy non-collision, and the recognition round-trip.
//
//  XCTest only (not Swift Testing), per project standard.
//

import XCTest
import CryptoKit
@testable import Beacon

final class ReconnectBeaconTests: XCTestCase {

    // Fixed inputs (RECONNECT_BEACON_KAT.md §1)
    private let S1 = Data((0...31).map { UInt8($0) })
    private let S2 = Data(repeating: 0x11, count: 32)
    private let LA = Data(repeating: 0xAA, count: 32)
    private let LB = Data(repeating: 0xBB, count: 32)

    // MARK: Tier 1 — HMAC-SHA256 anchored to RFC 4231

    func testRFC4231_TestCase1() {
        let key = Data(repeating: 0x0b, count: 20)
        let mac = HMAC<SHA256>.authenticationCode(for: Data("Hi There".utf8),
                                                  using: SymmetricKey(data: key))
        XCTAssertEqual(Data(mac).hexString,
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    }

    func testRFC4231_TestCase2() {
        let key = Data("Jefe".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: Data("what do ya want for nothing?".utf8),
                                                  using: SymmetricKey(data: key))
        XCTAssertEqual(Data(mac).hexString,
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }

    // MARK: Tier 2 — framing KATs (16-byte tokens)

    func testFramingVectors() {
        XCTAssertEqual(ReconnectBeacon.token(secret: S1, epoch: 0, label: LA).hexString,
                       "6a332966a02fb42e762af3f14bf50a6a")           // V1 baseline
        XCTAssertEqual(ReconnectBeacon.token(secret: S1, epoch: 1, label: LA).hexString,
                       "3afeeb02c195d9bbf287fb52a8ae54f6")           // V2 epoch+1
        XCTAssertEqual(ReconnectBeacon.token(secret: S1, epoch: 2, label: LA).hexString,
                       "bec0470d5fec95bab0f80a4cbd1b7356")           // V3 epoch+2
        XCTAssertEqual(ReconnectBeacon.token(secret: S1, epoch: 0, label: LB).hexString,
                       "4f1ff000e02fc46eb93022962142dbdb")           // V4 direction/label
        XCTAssertEqual(ReconnectBeacon.token(secret: S2, epoch: 0, label: LA).hexString,
                       "6a8f66118346ae5abe9b413dbf940c63")           // V5 pairing-secret
        XCTAssertEqual(ReconnectBeacon.token(secret: S1, epoch: 1900000, label: LA).hexString,
                       "3d8b9ac310b1f3fa908f97fbbb7d5d09")           // V6 realistic epoch
    }

    // MARK: Sensitivity — epoch, label/direction, pairing secret each change the token

    func testEpochLabelSecretChangeToken() {
        let v1 = ReconnectBeacon.token(secret: S1, epoch: 0, label: LA)
        let v2 = ReconnectBeacon.token(secret: S1, epoch: 1, label: LA)
        let v3 = ReconnectBeacon.token(secret: S1, epoch: 2, label: LA)
        let v4 = ReconnectBeacon.token(secret: S1, epoch: 0, label: LB)
        let v5 = ReconnectBeacon.token(secret: S2, epoch: 0, label: LA)
        // skew window {E0,E1,E2} yields three distinct tokens
        XCTAssertEqual(Set([v1, v2, v3]).count, 3)
        XCTAssertNotEqual(v1, v4, "directional label must change the token")
        XCTAssertNotEqual(v1, v5, "pairing-secret separation must hold")
        XCTAssertEqual(ReconnectBeacon.tokenLength, v1.count)
    }

    func testDeterminism() {
        let a = ReconnectBeacon.token(secret: S1, epoch: 7, label: LA)
        let b = ReconnectBeacon.token(secret: S1, epoch: 7, label: LA)
        XCTAssertEqual(a, b)
    }

    // MARK: Epoch bucketing (now injected)

    func testEpochBucketing() {
        XCTAssertEqual(ReconnectBeacon.epoch(at: 0,       epochLength: 900), 0)
        XCTAssertEqual(ReconnectBeacon.epoch(at: 899,     epochLength: 900), 0)
        XCTAssertEqual(ReconnectBeacon.epoch(at: 900,     epochLength: 900), 1)
        XCTAssertEqual(ReconnectBeacon.epoch(at: 1799,    epochLength: 900), 1)
        XCTAssertEqual(ReconnectBeacon.epoch(at: 1_350_000, epochLength: 900), 1500)
    }

    // MARK: Emission set — fixed size, contains all real tokens, decoys correct length

    func testEmissionSetSizeAndContents() {
        var rng = SeededRNG(seed: 1)
        let real = (0..<5).map { ReconnectBeacon.token(secret: S1, epoch: UInt64($0), label: LA) }
        let set = ReconnectBeacon.emissionSet(real: real, using: &rng)
        XCTAssertEqual(set.count, ReconnectBeacon.emissionSetSize)
        for r in real { XCTAssertTrue(set.contains(r), "real token missing from emission set") }
        for t in set { XCTAssertEqual(t.count, ReconnectBeacon.tokenLength) }
    }

    func testEmissionSetBoundaryNoDecoys() {
        var rng = SeededRNG(seed: 2)
        let real = (0..<ReconnectBeacon.emissionSetSize).map {
            ReconnectBeacon.token(secret: S1, epoch: UInt64($0), label: LA)
        }
        let set = ReconnectBeacon.emissionSet(real: real, using: &rng)
        XCTAssertEqual(Set(set), Set(real), "a full real set should be all real, just shuffled")
    }

    // MARK: Decoy non-collision (probabilistic)

    func testDecoyNonCollision() {
        var rng = SeededRNG(seed: 42)
        let table = Set((0..<64).map {
            ReconnectBeacon.token(secret: S1, epoch: UInt64($0), label: LA)
        })
        var collisions = 0
        for _ in 0..<20_000 {
            var d = Data(count: ReconnectBeacon.tokenLength)
            for i in 0..<d.count { d[i] = UInt8.random(in: UInt8.min...UInt8.max, using: &rng) }
            if table.contains(d) { collisions += 1 }
        }
        XCTAssertEqual(collisions, 0, "random decoys must not collide with the expected-token table")
    }

    // MARK: Recognition round-trip (the labelling convention)

    func testRecognitionRoundTrip() {
        // Emitter A emits its token labelled with A's own identity; a receiver
        // predicting the same (secret, epoch, A-label) reproduces it exactly.
        let emitted   = ReconnectBeacon.token(secret: S1, epoch: 7, label: LA)
        let predicted = ReconnectBeacon.token(secret: S1, epoch: 7, label: LA)
        XCTAssertEqual(emitted, predicted)
        // A stranger holding a different pairing secret cannot reproduce it.
        XCTAssertNotEqual(ReconnectBeacon.token(secret: S2, epoch: 7, label: LA), emitted)
    }
}

// MARK: - Deterministic RNG for tests (SplitMix64)

private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
