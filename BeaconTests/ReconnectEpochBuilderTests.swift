//
//  ReconnectEpochBuilderTests.swift
//  BeaconTests
//
//  Closed-Contact Step 5d-2 — the per-epoch reconnect builder.
//
//  ReconnectEpochBuilder layers over three already-KAT-anchored primitives
//  (DiscoverySecret 5c, ReconnectBeacon 5a, BeaconRecognizer 5b), so this suite
//  is a PROPERTY / round-trip suite, not a fixed-vector one: the fixed bytes are
//  pinned in those primitives' own KAT tests. What we prove here is the wiring —
//  that the builder composes them so two paired devices recognise each other:
//
//    • round-trip BOTH directions — A's recognizer finds B in B's emission set
//      and vice-versa (the end-to-end proof, which implicitly re-proves S_AC
//      symmetry through the whole emit→recognize pipeline);
//    • directionality — our real token is labelled with OUR id, and that exact
//      token is what the peer predicts for us;
//    • derive-once correctness — each recognizer secret equals a direct
//      DiscoverySecret.derive for that contact;
//    • non-recognition — a stranger and an all-decoy set match nothing;
//    • skew — a peer one epoch ahead is still recognised ({E-1,E,E+1} window);
//    • cover traffic — a contactless device still emits a full decoy set;
//    • determinism — same seed → identical Plan; recognizer table is
//      rng-independent;
//    • fault surfacing — an invalid contact key throws rather than being skipped.
//
//  XCTest only. Randomness is injected: SystemRandomNumberGenerator where order
//  is irrelevant (recognition scans the whole set), and a local seeded SplitMix64
//  only for the determinism assertion.

import XCTest
import CryptoKit
@testable import Beacon

final class ReconnectEpochBuilderTests: XCTestCase {

    // MARK: Helpers

    /// A fresh X25519 agreement keypair and its raw 32-byte identity (the value
    /// the store would hand back as `rawPublicKey(of:)` and the peer stores as the
    /// beacon label — equal by the bridge-consistency guarantee).
    private func freshParty() -> (priv: Curve25519.KeyAgreement.PrivateKey, id: Data) {
        let p = Curve25519.KeyAgreement.PrivateKey()
        return (p, p.publicKey.rawRepresentation)
    }

    /// Deterministic generator for the determinism test only. SplitMix64 — a
    /// standard, well-distributed seedable PRNG. Distinctly named so it cannot
    /// collide with any other test helper in the target.
    private struct SplitMix64RNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func plan(
        _ priv: Curve25519.KeyAgreement.PrivateKey,
        id: Data,
        contacts: [Data],
        epoch: UInt64
    ) throws -> ReconnectEpochBuilder.Plan {
        var rng = SystemRandomNumberGenerator()
        return try ReconnectEpochBuilder.plan(
            ourAgreementPrivate: priv, ourIdentity: id,
            contacts: contacts, epoch: epoch, using: &rng)
    }

    // MARK: Round-trip (the headline property)

    func testRecognitionRoundTripBothDirections() throws {
        let a = freshParty(), b = freshParty()
        let epoch: UInt64 = 1_900_000

        let aPlan = try plan(a.priv, id: a.id, contacts: [b.id], epoch: epoch)
        let bPlan = try plan(b.priv, id: b.id, contacts: [a.id], epoch: epoch)

        // A recognises B inside B's emission set, and B recognises A inside A's.
        XCTAssertEqual(
            BeaconRecognizer.recognize(emissionSet: bPlan.emissionSet,
                                       contacts: aPlan.recognizerContacts, epoch: epoch),
            [b.id])
        XCTAssertEqual(
            BeaconRecognizer.recognize(emissionSet: aPlan.emissionSet,
                                       contacts: bPlan.recognizerContacts, epoch: epoch),
            [a.id])
    }

    /// With several contacts, the present one (and only it) is recognised.
    func testRecognizesOnlyThePresentContactAmongMany() throws {
        let a = freshParty(), b = freshParty()
        let other1 = freshParty(), other2 = freshParty()
        let epoch: UInt64 = 42

        // A is paired with B + two others; only B is actually on the link.
        let aPlan = try plan(a.priv, id: a.id,
                             contacts: [b.id, other1.id, other2.id], epoch: epoch)
        let bPlan = try plan(b.priv, id: b.id, contacts: [a.id], epoch: epoch)

        XCTAssertEqual(
            BeaconRecognizer.recognize(emissionSet: bPlan.emissionSet,
                                       contacts: aPlan.recognizerContacts, epoch: epoch),
            [b.id])
    }

    // MARK: Directionality (our token carries OUR label; peer predicts it)

    func testEmittedRealTokenIsLabelledWithOurIdentityAndPredictedByPeer() throws {
        let a = freshParty(), b = freshParty()
        let epoch: UInt64 = 7

        let aPlan = try plan(a.priv, id: a.id, contacts: [b.id], epoch: epoch)

        // Independently recompute the token A should emit for the A–B pairing:
        // secret S_AB, A's epoch, labelled with A's identity.
        let sAB = DiscoverySecret.rawBytes(of:
            try DiscoverySecret.derive(ourAgreementPrivate: a.priv, theirAgreementPublic: b.id))
        let expectedAReal = ReconnectBeacon.token(secret: sAB, epoch: epoch, label: a.id)

        XCTAssertTrue(aPlan.emissionSet.contains(expectedAReal),
                      "A's emission set must contain its real token labelled with A's id")

        // And that exact token is what B's recognizer predicts for contact A.
        let bPlan = try plan(b.priv, id: b.id, contacts: [a.id], epoch: epoch)
        let bTable = BeaconRecognizer.expectedTable(contacts: bPlan.recognizerContacts, epoch: epoch)
        XCTAssertEqual(bTable[expectedAReal], a.id,
                       "B must predict A's real token → A's identity")
    }

    // MARK: Derive-once correctness

    func testRecognizerSecretMatchesDirectDerive() throws {
        let a = freshParty(), b = freshParty()
        let aPlan = try plan(a.priv, id: a.id, contacts: [b.id], epoch: 0)

        let direct = DiscoverySecret.rawBytes(of:
            try DiscoverySecret.derive(ourAgreementPrivate: a.priv, theirAgreementPublic: b.id))
        XCTAssertEqual(aPlan.recognizerContacts.first?.secret, direct)
        XCTAssertEqual(aPlan.recognizerContacts.first?.identity, b.id)
    }

    // MARK: Non-recognition

    func testStrangerIsNotRecognised() throws {
        let a = freshParty(), b = freshParty(), stranger = freshParty()
        let epoch: UInt64 = 100

        // A is paired with B only; the stranger (unpaired) emits its own set.
        let aPlan = try plan(a.priv, id: a.id, contacts: [b.id], epoch: epoch)
        let strangerPlan = try plan(stranger.priv, id: stranger.id,
                                    contacts: [b.id], epoch: epoch) // stranger paired w/ B, not A

        XCTAssertTrue(
            BeaconRecognizer.recognize(emissionSet: strangerPlan.emissionSet,
                                       contacts: aPlan.recognizerContacts, epoch: epoch).isEmpty,
            "A must not recognise a device it is not paired with")
    }

    func testAllDecoySetMatchesNothing() throws {
        let a = freshParty(), b = freshParty()
        let epoch: UInt64 = 5

        // A contactless device's plan is pure decoys; A's recognizer finds nothing.
        let decoyOnly = try plan(b.priv, id: b.id, contacts: [], epoch: epoch)
        let aPlan = try plan(a.priv, id: a.id, contacts: [b.id], epoch: epoch)

        XCTAssertEqual(decoyOnly.emissionSet.count, ReconnectBeacon.emissionSetSize)
        XCTAssertTrue(decoyOnly.recognizerContacts.isEmpty)
        XCTAssertTrue(
            BeaconRecognizer.recognize(emissionSet: decoyOnly.emissionSet,
                                       contacts: aPlan.recognizerContacts, epoch: epoch).isEmpty)
    }

    // MARK: Epoch skew

    func testRecognisedAcrossOneEpochSkew() throws {
        let a = freshParty(), b = freshParty()
        let aEpoch: UInt64 = 1000

        // B emits one epoch ahead of A's clock; the {E-1,E,E+1} window absorbs it.
        let aPlan = try plan(a.priv, id: a.id, contacts: [b.id], epoch: aEpoch)
        let bPlan = try plan(b.priv, id: b.id, contacts: [a.id], epoch: aEpoch + 1)

        XCTAssertEqual(
            BeaconRecognizer.recognize(emissionSet: bPlan.emissionSet,
                                       contacts: aPlan.recognizerContacts,
                                       epoch: aEpoch, skew: 1),
            [b.id],
            "a peer one epoch ahead must still be recognised within the skew window")
    }

    func testNotRecognisedBeyondSkewWindow() throws {
        let a = freshParty(), b = freshParty()
        let aEpoch: UInt64 = 1000

        // Two epochs ahead is outside the default ±1 window → no match.
        let aPlan = try plan(a.priv, id: a.id, contacts: [b.id], epoch: aEpoch)
        let bPlan = try plan(b.priv, id: b.id, contacts: [a.id], epoch: aEpoch + 2)

        XCTAssertTrue(
            BeaconRecognizer.recognize(emissionSet: bPlan.emissionSet,
                                       contacts: aPlan.recognizerContacts,
                                       epoch: aEpoch, skew: 1).isEmpty)
    }

    // MARK: Emission-set shape

    func testEmissionSetIsFixedSizeAndTokenSized() throws {
        let a = freshParty(), b = freshParty()
        let aPlan = try plan(a.priv, id: a.id, contacts: [b.id], epoch: 3)

        XCTAssertEqual(aPlan.emissionSet.count, ReconnectBeacon.emissionSetSize,
                       "the emission set is always padded to the fixed size, hiding N")
        for token in aPlan.emissionSet {
            XCTAssertEqual(token.count, ReconnectBeacon.tokenLength,
                           "real tokens and decoys are the same length (indistinguishable)")
        }
    }

    // MARK: Determinism (seeded rng → identical Plan)

    func testDeterministicUnderSameSeed() throws {
        let a = freshParty(), b = freshParty()
        let epoch: UInt64 = 999

        var rng1 = SplitMix64RNG(seed: 0xA11CE)
        var rng2 = SplitMix64RNG(seed: 0xA11CE)
        let p1 = try ReconnectEpochBuilder.plan(
            ourAgreementPrivate: a.priv, ourIdentity: a.id,
            contacts: [b.id], epoch: epoch, using: &rng1)
        let p2 = try ReconnectEpochBuilder.plan(
            ourAgreementPrivate: a.priv, ourIdentity: a.id,
            contacts: [b.id], epoch: epoch, using: &rng2)

        XCTAssertEqual(p1, p2, "same seed + same inputs must yield a byte-identical Plan")
    }

    func testRecognizerTableIsRngIndependentAcrossSeeds() throws {
        let a = freshParty(), b = freshParty()
        let epoch: UInt64 = 999

        var rng1 = SplitMix64RNG(seed: 1)
        var rng2 = SplitMix64RNG(seed: 2)
        let p1 = try ReconnectEpochBuilder.plan(
            ourAgreementPrivate: a.priv, ourIdentity: a.id,
            contacts: [b.id], epoch: epoch, using: &rng1)
        let p2 = try ReconnectEpochBuilder.plan(
            ourAgreementPrivate: a.priv, ourIdentity: a.id,
            contacts: [b.id], epoch: epoch, using: &rng2)

        // Decoys differ across seeds; the derived recognizer table does not.
        XCTAssertEqual(p1.recognizerContacts, p2.recognizerContacts)
    }

    // MARK: Fault surfacing

    func testThrowsOnInvalidContactKey() throws {
        let a = freshParty()
        var rng = SystemRandomNumberGenerator()
        // 31 bytes is not a valid X25519 public key — derive() throws, and the
        // builder surfaces it rather than skipping the contact.
        XCTAssertThrowsError(
            try ReconnectEpochBuilder.plan(
                ourAgreementPrivate: a.priv, ourIdentity: a.id,
                contacts: [Data(count: 31)], epoch: 0, using: &rng))
    }
}
