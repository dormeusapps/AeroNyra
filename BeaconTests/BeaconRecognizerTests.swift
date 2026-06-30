//
//  BeaconRecognizerTests.swift
//  BeaconTests
//
//  Receiver-side recognition over the ReconnectBeacon primitive. These tests
//  compose real beacon tokens (so they stay consistent with the committed KAT)
//  and assert recognition, epoch-skew tolerance, stranger/decoy rejection,
//  multi-contact resolution, and UInt64 underflow safety at epoch 0.
//
//  XCTest only (not Swift Testing), per project standard.
//

import XCTest
@testable import Beacon

final class BeaconRecognizerTests: XCTestCase {

    // Reuse the KAT fixtures so recognition is anchored to the same framing.
    private let S1 = Data((0...31).map { UInt8($0) })
    private let S2 = Data(repeating: 0x11, count: 32)
    private let LA = Data(repeating: 0xAA, count: 32)   // contact A identity + label
    private let LB = Data(repeating: 0xBB, count: 32)   // contact B identity + label

    private func emit(secret: Data, epoch: UInt64, label: Data) -> Data {
        ReconnectBeacon.token(secret: secret, epoch: epoch, label: label)
    }

    private func decoys(_ n: Int, seed: UInt64) -> [Data] {
        var rng = SeededRNG(seed: seed)
        return (0..<n).map { _ in
            var d = Data(count: ReconnectBeacon.tokenLength)
            for i in 0..<d.count { d[i] = UInt8.random(in: UInt8.min...UInt8.max, using: &rng) }
            return d
        }
    }

    // MARK: Recognition

    func testRecognizesPresentContactAmongDecoys() {
        let a = BeaconRecognizer.Contact(identity: LA, secret: S1)
        let emission = decoys(60, seed: 7) + [emit(secret: S1, epoch: 100, label: LA)]
        let present = BeaconRecognizer.recognize(emissionSet: emission.shuffled(),
                                                 contacts: [a], epoch: 100)
        XCTAssertEqual(present, [LA])
    }

    func testMultipleContactsResolvedIndependently() {
        let a = BeaconRecognizer.Contact(identity: LA, secret: S1)
        let b = BeaconRecognizer.Contact(identity: LB, secret: S2)
        let emission = [
            emit(secret: S1, epoch: 5, label: LA),
            emit(secret: S2, epoch: 5, label: LB),
        ] + decoys(40, seed: 3)
        let present = BeaconRecognizer.recognize(emissionSet: emission,
                                                 contacts: [a, b], epoch: 5)
        XCTAssertEqual(present, [LA, LB])
    }

    // MARK: Skew window

    func testRecognizesAdjacentEpochsWithinSkew() {
        let a = BeaconRecognizer.Contact(identity: LA, secret: S1)
        // Emitter is one epoch behind us (E=9), we are at E=10, skew=1 → still seen.
        let behind = BeaconRecognizer.recognize(emissionSet: [emit(secret: S1, epoch: 9, label: LA)],
                                                contacts: [a], epoch: 10)
        XCTAssertEqual(behind, [LA])
        // Emitter one epoch ahead (E=11) → still seen.
        let ahead = BeaconRecognizer.recognize(emissionSet: [emit(secret: S1, epoch: 11, label: LA)],
                                               contacts: [a], epoch: 10)
        XCTAssertEqual(ahead, [LA])
        // Two epochs off (E=12) with skew=1 → NOT seen.
        let tooFar = BeaconRecognizer.recognize(emissionSet: [emit(secret: S1, epoch: 12, label: LA)],
                                                contacts: [a], epoch: 10)
        XCTAssertTrue(tooFar.isEmpty)
    }

    func testEpochWindowContents() {
        XCTAssertEqual(BeaconRecognizer.epochWindow(epoch: 10, skew: 1), [9, 10, 11])
        XCTAssertEqual(BeaconRecognizer.epochWindow(epoch: 10, skew: 2), [8, 9, 10, 11, 12])
    }

    // MARK: UInt64 underflow safety at epoch 0

    func testEpochZeroDoesNotUnderflow() {
        XCTAssertEqual(BeaconRecognizer.epochWindow(epoch: 0, skew: 1), [0, 1])
        let a = BeaconRecognizer.Contact(identity: LA, secret: S1)
        let present = BeaconRecognizer.recognize(emissionSet: [emit(secret: S1, epoch: 0, label: LA)],
                                                 contacts: [a], epoch: 0)
        XCTAssertEqual(present, [LA])
    }

    // MARK: Strangers & decoys reject

    func testStrangerSecretNotRecognized() {
        // Contact A is known under S1; an emission token built under S2 (a secret
        // we don't share) for A's label must NOT be recognized.
        let a = BeaconRecognizer.Contact(identity: LA, secret: S1)
        let present = BeaconRecognizer.recognize(emissionSet: [emit(secret: S2, epoch: 0, label: LA)],
                                                 contacts: [a], epoch: 0)
        XCTAssertTrue(present.isEmpty)
    }

    func testPureDecoysRecognizeNothing() {
        let a = BeaconRecognizer.Contact(identity: LA, secret: S1)
        let present = BeaconRecognizer.recognize(emissionSet: decoys(64, seed: 99),
                                                 contacts: [a], epoch: 0)
        XCTAssertTrue(present.isEmpty)
    }

    func testNoContactsRecognizesNothing() {
        let present = BeaconRecognizer.recognize(emissionSet: [emit(secret: S1, epoch: 0, label: LA)],
                                                 contacts: [], epoch: 0)
        XCTAssertTrue(present.isEmpty)
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
