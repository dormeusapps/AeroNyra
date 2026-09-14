//
//  NostrInboxTagTests.swift
//  BeaconTests
//
//  Anchors the v59 inbox-tag primitive to external reference vectors BEFORE it
//  is trusted (project discipline). Three tiers, all from
//  docs/NOSTR_INBOX_TAG_KAT.md:
//    • Tier 1  — HMAC-SHA256 against the canonical RFC 4231 cases (proves the
//      underlying CryptoKit primitive matches the standard).
//    • Tier 1b — the CURVE-VALID predicate against fixed x values (proves the
//      predicate independently of the hash, so a predicate regression cannot
//      hide behind correct hashing).
//    • Tier 2  — our framing KATs (proves TAG ‖ epoch_be ‖ label ‖ counter, full
//      32 bytes, plus the counter search reproduce the out-of-implementation
//      (Python + libsecp256k1) vectors). N6 is load-bearing: it is the only
//      fixed row whose counter is not 0.
//  Plus the §5 properties: determinism, round-trip, direction, separation,
//  every-output-curve-valid, counter distribution, `now` injection, and decode
//  independence (the p-tag value is not load-bearing on receive).
//
//  XCTest only (not Swift Testing), per project standard.
//

import XCTest
import CryptoKit
@testable import Beacon

final class NostrInboxTagTests: XCTestCase {

    // Fixed inputs (NOSTR_INBOX_TAG_KAT.md §1) — the same S1/S2/LA/LB as the
    // beacon KAT, so the two vector sets are diffable.
    private let S1 = Data((0...31).map { UInt8($0) })
    private let S2 = Data(repeating: 0x11, count: 32)
    private let LA = Data(repeating: 0xAA, count: 32)
    private let LB = Data(repeating: 0xBB, count: 32)

    // MARK: Tier 1 — HMAC-SHA256 anchored to RFC 4231 (§2)

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

    // MARK: Tier 1b — CURVE-VALID predicate anchor (§3)

    func testCurvePredicateVectors() {
        // C1: generator G.x accepted
        XCTAssertTrue(NostrInboxTag.isCurveValidX(
            hex("79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")))
        // C2: x = 0 rejected
        XCTAssertFalse(NostrInboxTag.isCurveValidX(Data(repeating: 0, count: 32)))
        // C3–C5: small valid x
        XCTAssertTrue(NostrInboxTag.isCurveValidX(smallX(1)))
        XCTAssertTrue(NostrInboxTag.isCurveValidX(smallX(2)))
        XCTAssertTrue(NostrInboxTag.isCurveValidX(smallX(3)))
        // C6: x = p − 1 — in-field but not on the curve (a curve test)
        XCTAssertFalse(NostrInboxTag.isCurveValidX(
            hex("fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2e")))
        // C7: x = p — out of field (a range test); distinct failure from C6
        XCTAssertFalse(NostrInboxTag.isCurveValidX(
            hex("fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f")))
    }

    func testCurvePredicateRejectsWrongLength() {
        XCTAssertFalse(NostrInboxTag.isCurveValidX(Data(repeating: 1, count: 31)))
        XCTAssertFalse(NostrInboxTag.isCurveValidX(Data(repeating: 1, count: 33)))
        XCTAssertFalse(NostrInboxTag.isCurveValidX(Data()))
    }

    // MARK: Tier 2 — framing KATs, tag AND counter (§4)

    func testFramingVectors() {
        assertTag(secret: S1, epoch: 0, label: LA, counter: 0,
                  "b1c25406911c8c4c9f9b0b9c154018f81f2022ca5371eac1fb03b78849c49ba0")   // N1 baseline
        assertTag(secret: S1, epoch: 1, label: LA, counter: 0,
                  "ef4def82e2f091b1dca4a72e7d8ea43d8992dff3876e17ff518bd122fea8bdb1")   // N2 epoch
        assertTag(secret: S1, epoch: 0, label: LB, counter: 0,
                  "61bdfb6891c688d02d83ca69699b39593c38ec158d2fac36a00cae21d06d5cac")   // N3 direction/label
        assertTag(secret: S2, epoch: 0, label: LA, counter: 0,
                  "42b02b584c0fc600830e69a483f34f4d82351a5344faf643eb13e91978026989")   // N4 pair secret
        assertTag(secret: S1, epoch: 20710, label: LA, counter: 0,
                  "e2040b8422ba4aa5e05e44d9bad5d1e5c8182a1101c612c6bf75e023cec8882a")   // N5 realistic epoch
        assertTag(secret: S1, epoch: 2, label: LA, counter: 3,
                  "98ed9f9f76f47b942929bfdd09472120f5fe72cad42559c5eb32d2dbfd970904")   // N6 search loop
    }

    /// N6 is the load-bearing vector: N1–N5 all land on counter 0 and would pass
    /// against an implementation that never increments. N6 must reject exactly
    /// three candidates before accepting the fourth.
    func testN6ExercisesTheSearchLoop() {
        let n6 = NostrInboxTag.tag(secret: S1, epoch: 2, label: LA)
        XCTAssertEqual(n6.counter, 3, "N6 must be reached on counter 3")
        for rejected: UInt8 in 0...2 {
            let candidate = NostrInboxTag.candidate(secret: S1, epoch: 2, label: LA, counter: rejected)
            XCTAssertFalse(NostrInboxTag.isCurveValidX(candidate),
                           "candidate \(rejected) must be curve-invalid, else the search landed early")
            XCTAssertNotEqual(candidate, n6.value)
        }
        XCTAssertEqual(NostrInboxTag.candidate(secret: S1, epoch: 2, label: LA, counter: 3), n6.value,
                       "the accepted tag must be candidate 3 verbatim — no truncation, no rehash")
    }

    // MARK: Cross-checks (§4)

    func testEpochLabelSecretChangeTag() {
        let n1 = NostrInboxTag.tag(secret: S1, epoch: 0, label: LA).value
        let n2 = NostrInboxTag.tag(secret: S1, epoch: 1, label: LA).value
        let n6 = NostrInboxTag.tag(secret: S1, epoch: 2, label: LA).value
        let n3 = NostrInboxTag.tag(secret: S1, epoch: 0, label: LB).value
        let n4 = NostrInboxTag.tag(secret: S2, epoch: 0, label: LA).value
        XCTAssertEqual(Set([n1, n2, n6]).count, 3, "epoch must change the tag")
        XCTAssertNotEqual(n1, n3, "directional label must change the tag")
        XCTAssertNotEqual(n1, n4, "pair-secret separation must hold")
    }

    func testEveryFixedVectorIsCurveValidAndWireShaped() {
        let rows: [(Data, UInt64, Data)] = [(S1, 0, LA), (S1, 1, LA), (S1, 0, LB),
                                            (S2, 0, LA), (S1, 20710, LA), (S1, 2, LA)]
        for (s, e, l) in rows {
            let t = NostrInboxTag.tag(secret: s, epoch: e, label: l)
            XCTAssertEqual(t.value.count, NostrInboxTag.tagLength)
            XCTAssertTrue(NostrInboxTag.isCurveValidX(t.value), "every N must parse as an x-only key")
            XCTAssertEqual(t.hex.count, 64)
            XCTAssertEqual(t.hex, t.hex.lowercased(), "wire form is lowercase hex")
            XCTAssertEqual(t.hex, t.value.hexString)
        }
    }

    /// Same S1 / epoch 0 / LA under the beacon domain gives beacon V1
    /// (RECONNECT_BEACON_KAT.md §3, `6a332966a02fb42e762af3f14bf50a6a`). The
    /// inbox tag must not share a prefix with it: same inputs, different domain,
    /// different output. Asserted against the literal so this file never calls
    /// the beacon.
    func testDomainSeparationFromReconnectBeacon() {
        let n1 = NostrInboxTag.tag(secret: S1, epoch: 0, label: LA).value
        XCTAssertNotEqual(Data(n1.prefix(16)).hexString, "6a332966a02fb42e762af3f14bf50a6a")
        XCTAssertEqual(NostrInboxTag.domainTag, Data("AeroNyra/nostr-inbox-tag/v1".utf8))
        XCTAssertEqual(NostrInboxTag.domainTag.hexString,
                       "4165726f4e7972612f6e6f7374722d696e626f782d7461672f7631")
    }

    // MARK: §5 — Determinism

    func testDeterminism() {
        let a = NostrInboxTag.tag(secret: S1, epoch: 7, label: LA)
        let b = NostrInboxTag.tag(secret: S1, epoch: 7, label: LA)
        XCTAssertEqual(a, b, "same inputs → same tag and same counter")
        XCTAssertEqual(a.value, b.value)
        XCTAssertEqual(a.counter, b.counter)
    }

    // MARK: §5 — Round-trip (the labelling convention)

    func testPublisherSubscriberRoundTrip() {
        // Publisher A publishes the tag labelled with A's own identity; a
        // subscriber predicting the same (secret, epoch, A-label) reproduces it.
        let published = NostrInboxTag.tag(secret: S1, epoch: 7, label: LA)
        let predicted = NostrInboxTag.tag(secret: S1, epoch: 7, label: LA)
        XCTAssertEqual(published.value, predicted.value)
        // A stranger holding a different pair secret cannot reproduce it.
        XCTAssertNotEqual(NostrInboxTag.tag(secret: S2, epoch: 7, label: LA).value, published.value)
    }

    // MARK: §5 — Direction over fresh random pairs

    func testDirectionOverRandomPairs() {
        var rng = SeededRNG(seed: 3)
        for _ in 0..<200 {
            let s = randomBytes(32, &rng)
            let la = randomBytes(32, &rng)
            let lb = randomBytes(32, &rng)
            let e = UInt64.random(in: 0...40_000, using: &rng)
            XCTAssertNotEqual(NostrInboxTag.tag(secret: s, epoch: e, label: la).value,
                              NostrInboxTag.tag(secret: s, epoch: e, label: lb).value,
                              "tag(A→B) must differ from tag(B→A)")
        }
    }

    // MARK: §5 — Separation over fresh pairs (probabilistic)

    func testSeparationOverFreshPairs() {
        var rng = SeededRNG(seed: 4)
        var seen = Set<Data>()
        let trials = 2_000
        for _ in 0..<trials {
            let t = NostrInboxTag.tag(secret: randomBytes(32, &rng),
                                      epoch: UInt64.random(in: 0...40_000, using: &rng),
                                      label: randomBytes(32, &rng))
            seen.insert(t.value)
        }
        XCTAssertEqual(seen.count, trials, "independent (S, epoch, label) must produce distinct tags")
    }

    // MARK: §5 — Every output is curve-valid, and the counter distribution is sane

    func testEveryOutputIsCurveValidOverRandomInputs() {
        var rng = SeededRNG(seed: 5)
        for _ in 0..<1_000 {
            let t = NostrInboxTag.tag(secret: randomBytes(32, &rng),
                                      epoch: UInt64.random(in: 0...40_000, using: &rng),
                                      label: randomBytes(32, &rng))
            XCTAssertTrue(NostrInboxTag.isCurveValidX(t.value))
            XCTAssertEqual(t.value.count, NostrInboxTag.tagLength)
        }
    }

    /// A mean near 0 means the predicate accepts everything; a mean near 255
    /// means it accepts nothing. Both are silent failures that fixed vectors
    /// alone would catch only by luck. Expected: mean ≈ 1.0 (geometric, p ≈ ½),
    /// max well under the 255 cap.
    func testCounterDistributionSanity() {
        var rng = SeededRNG(seed: 6)
        let trials = 1_500
        var sum = 0
        var maxCounter: UInt8 = 0
        var incremented = 0
        for _ in 0..<trials {
            let t = NostrInboxTag.tag(secret: randomBytes(32, &rng),
                                      epoch: UInt64.random(in: 0...40_000, using: &rng),
                                      label: randomBytes(32, &rng))
            sum += Int(t.counter)
            maxCounter = max(maxCounter, t.counter)
            if t.counter > 0 { incremented += 1 }
        }
        let mean = Double(sum) / Double(trials)
        XCTAssertGreaterThan(mean, 0.6, "mean counter \(mean): predicate appears to accept everything")
        XCTAssertLessThan(mean, 1.6, "mean counter \(mean): predicate appears to reject too much")
        XCTAssertLessThan(maxCounter, 64, "max counter \(maxCounter) is far above the measured max of ~14")
        XCTAssertGreaterThan(incremented, trials / 3,
                             "an implementation that never increments would land every tag on counter 0")
    }

    // MARK: §5 — `now` injection: epoch bucketing at 86,400 s

    func testEpochBucketing() {
        XCTAssertEqual(NostrInboxTag.epochLength, 86_400)
        XCTAssertEqual(NostrInboxTag.epoch(at: 0), 0)
        XCTAssertEqual(NostrInboxTag.epoch(at: 86_399), 0)
        XCTAssertEqual(NostrInboxTag.epoch(at: 86_400), 1)
        XCTAssertEqual(NostrInboxTag.epoch(at: 172_799), 1)
        XCTAssertEqual(NostrInboxTag.epoch(at: 1_789_344_000), 20_710)   // N5's epoch, 2026-09-14
        XCTAssertEqual(NostrInboxTag.epoch(at: 1_789_430_399), 20_710)
        XCTAssertEqual(NostrInboxTag.epoch(at: 1_789_430_400), 20_711)
        // Two calls with the same injected instant agree; the clock is never read.
        XCTAssertEqual(NostrInboxTag.epoch(at: 1_789_344_000), NostrInboxTag.epoch(at: 1_789_344_000))
    }

    // MARK: §5 — Decode independence: the p-tag value is not load-bearing on receive

    /// `NostrGiftWrap.unwrap` checks kind, signatures, and the two NIP-44 layers
    /// only (NostrGiftWrap.swift:126-158). A wrap whose `p` value is an inbox
    /// tag — or anything else — must still open, so a later change cannot
    /// quietly make the tag load-bearing on receive. The wrap is built by hand
    /// here because `NostrGiftWrap.wrap` fixes the p-tag to the recipient npub.
    func testUnwrapIgnoresPTagValue() throws {
        let sender = hex("b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef")
        let recipient = hex("c90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b14e5c9")
        let ephemeral = hex("0000000000000000000000000000000000000000000000000000000000000007")
        guard let recipientPub = Secp256k1.xOnlyPublicKey(fromSecretKey: recipient),
              let senderPub = Secp256k1.xOnlyPublicKey(fromSecretKey: sender) else {
            return XCTFail("pubkey derivation failed")
        }
        let envelope = Envelope(ttl: 5,
                                id: MessageID(bytes: Array(repeating: 0xAB, count: MessageID.byteCount))!,
                                ciphertext: Data((0..<200).map { UInt8($0 & 0xff) }))

        let inboxTag = NostrInboxTag.tag(secret: S1, epoch: 20710, label: LA).hex
        for pValue in [inboxTag, String(repeating: "de", count: 32), "not-a-pubkey"] {
            let wrap = try handWrap(envelope: envelope, senderSecret: sender, senderPub: senderPub,
                                    recipientPub: recipientPub, ephemeralSecret: ephemeral,
                                    pTagValue: pValue)
            XCTAssertTrue(wrap.tags.contains(["p", pValue]))
            let (recovered, authSender) = try NostrGiftWrap.unwrap(giftWrap: wrap, mySecret: recipient)
            XCTAssertEqual(recovered.wireData(), envelope.wireData(),
                           "unwrap must not depend on the p-tag value (\(pValue.prefix(12))…)")
            XCTAssertEqual(authSender, senderPub)
        }
    }

    // MARK: Helpers

    private func assertTag(secret: Data, epoch: UInt64, label: Data, counter: UInt8,
                           _ expectedHex: String, file: StaticString = #filePath, line: UInt = #line) {
        let t = NostrInboxTag.tag(secret: secret, epoch: epoch, label: label)
        XCTAssertEqual(t.value.hexString, expectedHex, file: file, line: line)
        XCTAssertEqual(t.counter, counter, "counter diverged", file: file, line: line)
    }

    /// The NIP-59 construction of `NostrGiftWrap.wrap` (NostrGiftWrap.swift:55-116)
    /// with the outer p-tag chosen by the caller and a caller-supplied ephemeral
    /// key, so the outer event is validly signed over the substituted tag.
    private func handWrap(envelope: Envelope, senderSecret: Data, senderPub: Data,
                          recipientPub: Data, ephemeralSecret: Data,
                          pTagValue: String) throws -> NostrEvent {
        let now = Int64(1_789_344_000)
        let senderPubHex = senderPub.hexString
        let rumorContent = envelope.wireData().base64EncodedString()
        let rumorID = NostrEvent.computeID(pubkey: senderPubHex, createdAt: now,
                                           kind: NostrGiftWrap.rumorKind, tags: [], content: rumorContent)
        let rumor = NostrEvent(id: rumorID, pubkey: senderPubHex, createdAt: now,
                               kind: NostrGiftWrap.rumorKind, tags: [], content: rumorContent, sig: "")
        let rumorJSON = try XCTUnwrap(rumor.jsonData().flatMap { String(data: $0, encoding: .utf8) })

        let sealKey = try NIP44.conversationKey(mySecret: senderSecret, peerPublicKey: recipientPub)
        let sealContent = try NIP44.encrypt(plaintext: rumorJSON, conversationKey: sealKey)
        let seal = try XCTUnwrap(NostrEvent.signed(kind: NostrGiftWrap.sealKind, content: sealContent,
                                                   tags: [], createdAt: now, secretKey: senderSecret))
        let sealJSON = try XCTUnwrap(seal.jsonData().flatMap { String(data: $0, encoding: .utf8) })

        let wrapKey = try NIP44.conversationKey(mySecret: ephemeralSecret, peerPublicKey: recipientPub)
        let wrapContent = try NIP44.encrypt(plaintext: sealJSON, conversationKey: wrapKey)
        return try XCTUnwrap(NostrEvent.signed(kind: NostrGiftWrap.wrapKind, content: wrapContent,
                                               tags: [["p", pTagValue]], createdAt: now,
                                               secretKey: ephemeralSecret))
    }

    private func smallX(_ v: UInt8) -> Data {
        var d = Data(repeating: 0, count: 32)
        d[31] = v
        return d
    }

    private func randomBytes<R: RandomNumberGenerator>(_ n: Int, _ rng: inout R) -> Data {
        var d = Data(count: n)
        for i in 0..<n { d[i] = UInt8.random(in: UInt8.min...UInt8.max, using: &rng) }
        return d
    }

    private func hex(_ string: String) -> Data {
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
