//
//  NostrInboxDecoyTests.swift
//  BeaconTests
//
//  v59 connection-leak fix · Stage 3 — decoy padding for the subscribe set.
//
//  Anchors the decoy construction to vectors computed OUT of implementation
//  (Python: HKDF + SHA-256 + the Stage 1 tag search with a Legendre curve test)
//  before any Swift, then proves the properties the padding exists for:
//    • every decoy is curve-valid and built by the SAME construction as a real
//      tag (no property but traffic separates them);
//    • the padded set is byte-identical for a whole epoch and across the
//      sliding window — same inputs → same bytes, and a one-day slide changes
//      exactly one epoch's worth of values, real and decoy alike;
//    • the decoy secret has S_AB's lifetime: it is keyed on the identity
//      agreement key, so it is invariant under an npub rotation and moves
//      with the whole set when the identity regenerates;
//    • past one page the set is bucket-padded, never bare.
//  Plus: the frame budget confirmed against a REAL serialized REQ, the
//  displacement rule, and the secret derivation.
//
//  XCTest only (not Swift Testing), per project standard.
//

import XCTest
import CryptoKit
@testable import Beacon

final class NostrInboxDecoyTests: XCTestCase {

    // Fixed inputs (NOSTR_INBOX_TAG_KAT.md §1): S1 doubles as the raw X25519
    // private key for the decoy-secret vector so the two sets stay diffable.
    // CryptoKit returns a Curve25519 private key's raw bytes unchanged, so the
    // HKDF input is exactly S1.
    private let S1 = Data((0...31).map { UInt8($0) })
    private let LA = Data(repeating: 0xAA, count: 32)
    private let LB = Data(repeating: 0xBB, count: 32)

    /// DS1 = HKDF-SHA256(ikm = S1, salt = "", info = secretInfo, 32).
    private let DS1 = "bc39b77742faad18675be99cbf48cdfd15dad6f352aaf94ca9c58801af9cb910"

    /// A realistic injected instant: 2026-09-14, epoch 20710 (KAT N5).
    private let realisticNow: UInt64 = 1_789_344_000

    // MARK: Tier 1 — HKDF-SHA256 anchored to RFC 5869 (the empty-salt path we use)

    func testHKDF_RFC5869_TC3_emptySalt() {
        let ikm = Data(repeating: 0x0b, count: 22)
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm),
                                         salt: Data(), info: Data(), outputByteCount: 42)
        XCTAssertEqual(okm.withUnsafeBytes { Data($0) }.hexString,
            "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")
    }

    // MARK: Tier 1b — decoy secret + slot labels

    func testDecoySecretVector() throws {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: S1)
        XCTAssertEqual(key.rawRepresentation, S1, "CryptoKit must hand the raw scalar back unchanged for the vector to apply")
        let ds = NostrInboxDecoy.secret(fromAgreementPrivate: key)
        XCTAssertEqual(ds.hexString, DS1)
        XCTAssertEqual(ds.count, NostrInboxDecoy.secretLength)
        XCTAssertNotEqual(ds, S1, "the decoy secret must not be the identity key itself")
        XCTAssertEqual(NostrInboxDecoy.secretInfo, Data("AeroNyra/nostr-inbox-decoy-secret/v1".utf8))
    }

    func testDecoySecretIsDeterministicAndKeyedOnTheIdentity() throws {
        let a = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: S1)
        let b = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
        XCTAssertEqual(NostrInboxDecoy.secret(fromAgreementPrivate: a),
                       NostrInboxDecoy.secret(fromAgreementPrivate: a))
        XCTAssertNotEqual(NostrInboxDecoy.secret(fromAgreementPrivate: a),
                          NostrInboxDecoy.secret(fromAgreementPrivate: b))
    }

    func testSlotLabelVectors() {
        XCTAssertEqual(NostrInboxDecoy.labelDomain, Data("AeroNyra/nostr-inbox-decoy-label/v1".utf8))
        XCTAssertEqual(NostrInboxDecoy.slotLabel(0).hexString,
                       "d6e6e6ca4f69c9e98e6842ad92a543005f3a8269e1987e97135ef94ceb3c9f64")
        XCTAssertEqual(NostrInboxDecoy.slotLabel(1).hexString,
                       "a8deea43a4c079549f7ff744a854e9c8ca7ec86a777a07be7aaac6f834ec9a4b")
        XCTAssertEqual(NostrInboxDecoy.slotLabel(59).hexString,
                       "c38aa27e6817347dda1288fff53aa796554a1f2b42872fe32461e017d6d4e630")
        XCTAssertEqual(NostrInboxDecoy.slotLabel(0).count, NostrInboxTag.labelLength)
    }

    // MARK: Tier 2 — decoy vectors, tag AND counter

    func testDecoyVectors() {
        let ds = hex(DS1)
        assertDecoy(ds, epoch: 0, slot: 0, counter: 1,
                    "41f85d602fa6766c451fb536cd29f1a9883ed102f3c74aac093c4316cb4d37e9")   // D1 baseline
        assertDecoy(ds, epoch: 1, slot: 0, counter: 0,
                    "5028904242bd803aa76e8ddf9d230c48c445c13d850649e87a4a2db07a9069d0")   // D2 epoch changes decoy
        assertDecoy(ds, epoch: 0, slot: 1, counter: 1,
                    "186815261cf5e985e33cdb5308a94e160a667fbdd76f1832eadc0f9618124e68")   // D3 slot changes decoy
        assertDecoy(ds, epoch: 20710, slot: 0, counter: 1,
                    "4e3a5a8424dd97baf71b9739cc9ad251378cc565accf6fd4b980756e71001fcd")   // D4 realistic epoch
        assertDecoy(ds, epoch: 0, slot: 5, counter: 2,
                    "12f8e2135fab72348f7094ac9d658fc2747904517fcd3c5f5dcb510ca1e2a919")   // D5 search loop (2 rejections)
    }

    /// A decoy IS a real-tag computation under a synthetic label: same domain,
    /// same HMAC, same search. This is the "no property but traffic" claim.
    func testDecoyIsTheRealTagConstructionUnderASyntheticLabel() {
        let ds = hex(DS1)
        for (e, s): (UInt64, UInt32) in [(0, 0), (1, 0), (0, 1), (20710, 0), (0, 5)] {
            XCTAssertEqual(NostrInboxDecoy.decoy(secret: ds, epoch: e, slot: s),
                           NostrInboxTag.tag(secret: ds, epoch: e, label: NostrInboxDecoy.slotLabel(s)))
        }
    }

    // MARK: Padded-set KAT (page of 4, one real row, epoch 0)

    func testPaddedSetVector() {
        // Our identity LB; one contact whose identity is LA with secret S1, so
        // the real subscribe tag for epoch 0 is N1. Slots 1, 2, 3 are decoys.
        let table = NostrInboxTagTable(ourIdentity: LB,
                                       rows: [.init(identity: LA, secret: S1, nostrPubkey: nil)])
        let padded = NostrInboxDecoy.paddedSubscribeTags(table: table, epochs: 0...0,
                                                         decoySecret: hex(DS1), pageSlots: 4)
        XCTAssertEqual(padded.tags, [
            "186815261cf5e985e33cdb5308a94e160a667fbdd76f1832eadc0f9618124e68",   // decoy slot 1 (D3)
            "24579417e80262f64dfd7e43710f25ede1fe055f5a476da914f016126bf412d5",   // decoy slot 3
            "b1c25406911c8c4c9f9b0b9c154018f81f2022ca5371eac1fb03b78849c49ba0",   // N1 (real)
            "ddf66ed4b2dd80009a04fae20d0b08a993eed8f490ea8866d24c548fad23997e",   // decoy slot 2
        ])
        XCTAssertEqual(padded.realSlots, 1)
        XCTAssertEqual(padded.decoySlots, 3)
        XCTAssertEqual(padded.slots, 4)
        XCTAssertEqual(padded.pages, 1)
        XCTAssertEqual(padded.valuesPerPage, 4)
        XCTAssertFalse(padded.spilled)
        XCTAssertEqual(padded.paged, [padded.tags])
    }

    // MARK: Property 1 — every padded value is curve-valid; size is S × |epochs|

    func testEveryPaddedValueIsCurveValidAndSizeIsFixed() throws {
        let me = freshParty()
        let contacts = (0..<5).map { _ in freshParty() }
        let table = try NostrInboxTagTable.build(ourAgreementPrivate: me.priv, ourIdentity: me.id,
                                                 contacts: contacts.map { ($0.id, $0.npub) })
        let window = NostrInboxTagTable.epochWindow(atSeconds: realisticNow)
        let padded = NostrInboxDecoy.paddedSubscribeTags(table: table, epochs: window,
                                                         decoySecret: NostrInboxDecoy.secret(fromAgreementPrivate: me.priv))
        XCTAssertEqual(padded.tags.count, NostrInboxDecoy.pageSlotCount * 32)
        XCTAssertEqual(padded.realSlots, 5)
        XCTAssertEqual(padded.decoySlots, 55)
        XCTAssertEqual(padded.pages, 1)
        for t in padded.tags {
            XCTAssertEqual(t.count, 64)
            XCTAssertEqual(t, t.lowercased())
            XCTAssertTrue(NostrInboxTag.isCurveValidX(hex(t)), "every padded value must parse as an x-only key")
        }
        XCTAssertEqual(padded.tags, padded.tags.sorted())
        XCTAssertEqual(Set(padded.tags).count, padded.tags.count)
        // A contactless device still presents a full page (cover traffic).
        let empty = NostrInboxDecoy.paddedSubscribeTags(table: NostrInboxTagTable(ourIdentity: me.id, rows: []),
                                                        epochs: window, decoySecret: hex(DS1))
        XCTAssertEqual(empty.tags.count, NostrInboxDecoy.pageSlotCount * 32)
        XCTAssertEqual(empty.realSlots, 0)
        XCTAssertEqual(empty.pages, 1)
    }

    // MARK: Property 2 — byte-stable within an epoch and across the sliding window

    func testPaddedSetIsByteIdenticalForSameInputs() throws {
        let me = freshParty()
        let contacts = (0..<3).map { _ in freshParty() }
        let forward = try NostrInboxTagTable.build(ourAgreementPrivate: me.priv, ourIdentity: me.id,
                                                   contacts: contacts.map { ($0.id, $0.npub) })
        let reversed = try NostrInboxTagTable.build(ourAgreementPrivate: me.priv, ourIdentity: me.id,
                                                    contacts: contacts.reversed().map { ($0.id, $0.npub) })
        let window = NostrInboxTagTable.epochWindow(atSeconds: realisticNow)
        let ds = NostrInboxDecoy.secret(fromAgreementPrivate: me.priv)
        let a = NostrInboxDecoy.paddedSubscribeTags(table: forward, epochs: window, decoySecret: ds, pageSlots: 8)
        let b = NostrInboxDecoy.paddedSubscribeTags(table: reversed, epochs: window, decoySecret: ds, pageSlots: 8)
        XCTAssertEqual(a, b, "every re-REQ inside an epoch must present byte-identical padding")
        // A different device (different identity) pads differently.
        let other = freshParty()
        let otherSet = NostrInboxDecoy.paddedSubscribeTags(table: forward, epochs: window,
                                                           decoySecret: NostrInboxDecoy.secret(fromAgreementPrivate: other.priv),
                                                           pageSlots: 8)
        XCTAssertNotEqual(a.tags, otherSet.tags)
    }

    func testWindowSlideChangesExactlyOneEpochOfValuesRealAndDecoyAlike() throws {
        let me = freshParty()
        let contacts = (0..<3).map { _ in freshParty() }
        let table = try NostrInboxTagTable.build(ourAgreementPrivate: me.priv, ourIdentity: me.id,
                                                 contacts: contacts.map { ($0.id, $0.npub) })
        let ds = NostrInboxDecoy.secret(fromAgreementPrivate: me.priv)
        let slots = 8
        let today = NostrInboxDecoy.paddedSubscribeTags(
            table: table, epochs: NostrInboxTagTable.epochWindow(atSeconds: realisticNow),
            decoySecret: ds, pageSlots: slots)
        let tomorrow = NostrInboxDecoy.paddedSubscribeTags(
            table: table, epochs: NostrInboxTagTable.epochWindow(atSeconds: realisticNow + 86_400),
            decoySecret: ds, pageSlots: slots)
        let t = Set(today.tags), n = Set(tomorrow.tags)
        // 31 overlapping epochs × S slots persist; one epoch × S leaves, one arrives.
        XCTAssertEqual(t.intersection(n).count, slots * 31)
        XCTAssertEqual(t.subtracting(n).count, slots)
        XCTAssertEqual(n.subtracting(t).count, slots)
        // The values that left are exactly epoch 20680's (real + decoy), the ones
        // that arrived exactly epoch 20712's — uniform churn, nothing to diff on.
        let left = Set(NostrInboxDecoy.paddedSubscribeTags(table: table, epochs: 20680...20680,
                                                           decoySecret: ds, pageSlots: slots).tags)
        let arrived = Set(NostrInboxDecoy.paddedSubscribeTags(table: table, epochs: 20712...20712,
                                                              decoySecret: ds, pageSlots: slots).tags)
        XCTAssertEqual(t.subtracting(n), left)
        XCTAssertEqual(n.subtracting(t), arrived)
    }

    func testDecoysChangeAcrossEpochsAndSlots() {
        let ds = hex(DS1)
        var seen = Set<Data>()
        for e: UInt64 in 0..<20 {
            for s: UInt32 in 0..<20 {
                seen.insert(NostrInboxDecoy.decoy(secret: ds, epoch: e, slot: s).value)
            }
        }
        XCTAssertEqual(seen.count, 400, "no slot may repeat a value across epochs — that would fingerprint the device")
    }

    // MARK: Lifetime — invariant under npub rotation, whole-set under identity regeneration

    /// The decoy secret takes no Nostr input at all, so an npub rotation (A2)
    /// cannot move a single decoy while the real tags stay. Asserted the only
    /// way it can be: rebuilding with different npubs on every row yields a
    /// byte-identical padded set.
    func testPaddedSetIsInvariantUnderNpubRotation() throws {
        let me = freshParty()
        let contacts = (0..<4).map { _ in freshParty() }
        let before = try NostrInboxTagTable.build(ourAgreementPrivate: me.priv, ourIdentity: me.id,
                                                  contacts: contacts.map { ($0.id, $0.npub) })
        let rotated = try NostrInboxTagTable.build(ourAgreementPrivate: me.priv, ourIdentity: me.id,
                                                   contacts: contacts.map { ($0.id, freshParty().npub) })
        let ds = NostrInboxDecoy.secret(fromAgreementPrivate: me.priv)
        let window = NostrInboxTagTable.epochWindow(atSeconds: realisticNow)
        XCTAssertEqual(NostrInboxDecoy.paddedSubscribeTags(table: before, epochs: window, decoySecret: ds, pageSlots: 8),
                       NostrInboxDecoy.paddedSubscribeTags(table: rotated, epochs: window, decoySecret: ds, pageSlots: 8))
    }

    /// When the identity regenerates, S_AB changes for every contact AND the
    /// decoy secret changes with it: the old and new padded sets share nothing.
    /// A relay diffing across that moment sees one uniform discontinuity, not
    /// a real half and a decoy half.
    func testIdentityRegenerationMovesTheWholeSetAtOnce() throws {
        let contacts = (0..<4).map { _ in freshParty() }
        let oldMe = freshParty(), newMe = freshParty()
        let oldTable = try NostrInboxTagTable.build(ourAgreementPrivate: oldMe.priv, ourIdentity: oldMe.id,
                                                    contacts: contacts.map { ($0.id, $0.npub) })
        let newTable = try NostrInboxTagTable.build(ourAgreementPrivate: newMe.priv, ourIdentity: newMe.id,
                                                    contacts: contacts.map { ($0.id, $0.npub) })
        let window = NostrInboxTagTable.epochWindow(atSeconds: realisticNow)
        let old = Set(NostrInboxDecoy.paddedSubscribeTags(table: oldTable, epochs: window,
                                                          decoySecret: NostrInboxDecoy.secret(fromAgreementPrivate: oldMe.priv),
                                                          pageSlots: 8).tags)
        let new = Set(NostrInboxDecoy.paddedSubscribeTags(table: newTable, epochs: window,
                                                          decoySecret: NostrInboxDecoy.secret(fromAgreementPrivate: newMe.priv),
                                                          pageSlots: 8).tags)
        XCTAssertEqual(old.count, 8 * 32)
        XCTAssertEqual(new.count, 8 * 32)
        XCTAssertTrue(old.isDisjoint(with: new), "real and decoy must both move — nothing may persist across an identity change")
    }

    // MARK: Bucket padding past one page — never bare

    func testPastOnePageThePaddingRoundsUpToWholePages() throws {
        let me = freshParty()
        let contacts = (0..<5).map { _ in freshParty() }
        let table = try NostrInboxTagTable.build(ourAgreementPrivate: me.priv, ourIdentity: me.id,
                                                 contacts: contacts.map { ($0.id, $0.npub) })
        let ds = NostrInboxDecoy.secret(fromAgreementPrivate: me.priv)
        let epochs: ClosedRange<UInt64> = 0...31
        // 5 real contacts on pages of 4 → 2 pages, 8 slots, 3 decoys. Never bare.
        let padded = NostrInboxDecoy.paddedSubscribeTags(table: table, epochs: epochs, decoySecret: ds, pageSlots: 4)
        XCTAssertTrue(padded.spilled)
        XCTAssertEqual(padded.pages, 2)
        XCTAssertEqual(padded.slots, 8)
        XCTAssertEqual(padded.realSlots, 5)
        XCTAssertEqual(padded.decoySlots, 3)
        XCTAssertEqual(padded.tags.count, 8 * 32, "a relay learns the count only to page granularity")
        XCTAssertNotEqual(padded.tags.count, table.subscribeTags(epochs: epochs).count, "must not drop to the bare real set")
        XCTAssertEqual(padded.valuesPerPage, 4 * 32)
        let pages = padded.paged
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages.map(\.count), [128, 128])
        XCTAssertEqual(pages.flatMap { $0 }, padded.tags, "pages are consecutive chunks of the sorted set")
        for t in padded.tags { XCTAssertTrue(NostrInboxTag.isCurveValidX(hex(t))) }
        // Exactly one full page is not a spill and has no decoys.
        let exact = NostrInboxDecoy.paddedSubscribeTags(table: table, epochs: epochs, decoySecret: ds, pageSlots: 5)
        XCTAssertFalse(exact.spilled)
        XCTAssertEqual(exact.pages, 1)
        XCTAssertEqual(exact.decoySlots, 0)
        // Pages are byte-stable on their own: same inputs → same page contents.
        let again = NostrInboxDecoy.paddedSubscribeTags(table: table, epochs: epochs, decoySecret: ds, pageSlots: 4)
        XCTAssertEqual(again.paged, pages)
    }

    // MARK: Displacement (the recorded residual, pinned so it cannot change silently)

    func testAddingAContactDisplacesExactlyOneDecoySlot() throws {
        let me = freshParty()
        let contacts = (0..<4).map { _ in freshParty() }
        let newcomer = freshParty()
        let before = try NostrInboxTagTable.build(ourAgreementPrivate: me.priv, ourIdentity: me.id,
                                                  contacts: contacts.map { ($0.id, $0.npub) })
        let after = try NostrInboxTagTable.build(ourAgreementPrivate: me.priv, ourIdentity: me.id,
                                                 contacts: (contacts + [newcomer]).map { ($0.id, $0.npub) })
        let ds = NostrInboxDecoy.secret(fromAgreementPrivate: me.priv)
        let e: UInt64 = 20710
        let b = Set(NostrInboxDecoy.paddedSubscribeTags(table: before, epochs: e...e, decoySecret: ds, pageSlots: 8).tags)
        let a = Set(NostrInboxDecoy.paddedSubscribeTags(table: after, epochs: e...e, decoySecret: ds, pageSlots: 8).tags)
        XCTAssertEqual(a.count, b.count, "the set size must not move")
        XCTAssertEqual(b.subtracting(a).count, 1, "one decoy leaves")
        XCTAssertEqual(a.subtracting(b).count, 1, "one real tag arrives")
        XCTAssertEqual(b.subtracting(a), [NostrInboxDecoy.decoy(secret: ds, epoch: e, slot: 4).hex],
                       "the displaced slot is the lowest free one, slot 4")
        // A duplicated row does not consume a second slot.
        let dup = try NostrInboxTagTable.build(ourAgreementPrivate: me.priv, ourIdentity: me.id,
                                               contacts: (contacts + [contacts[0]]).map { ($0.id, $0.npub) })
        XCTAssertEqual(NostrInboxDecoy.paddedSubscribeTags(table: dup, epochs: e...e, decoySecret: ds, pageSlots: 8).realSlots, 4)
    }

    // MARK: Indistinguishability — counter distribution matches real tags

    func testDecoyCounterDistributionMatchesRealTags() {
        let ds = hex(DS1)
        var sum = 0, incremented = 0
        let trials = 1_200
        var i = 0
        for e: UInt64 in 0..<40 {
            for s: UInt32 in 0..<30 {
                let c = NostrInboxDecoy.decoy(secret: ds, epoch: e, slot: s).counter
                sum += Int(c); if c > 0 { incremented += 1 }; i += 1
            }
        }
        XCTAssertEqual(i, trials)
        let mean = Double(sum) / Double(trials)
        XCTAssertGreaterThan(mean, 0.6, "mean \(mean): the search appears to accept everything")
        XCTAssertLessThan(mean, 1.6, "mean \(mean): the search appears to reject too much")
        XCTAssertGreaterThan(incremented, trials / 3)
    }

    // MARK: Capacity — a REAL serialized frame at 60 slots fits nos.lol's 131,072-byte cap

    func testOnePageAtSixtySlotsFitsTheSmallestRelayFrame() throws {
        let me = freshParty()
        let contacts = (0..<12).map { _ in freshParty() }
        let table = try NostrInboxTagTable.build(ourAgreementPrivate: me.priv, ourIdentity: me.id,
                                                 contacts: contacts.map { ($0.id, $0.npub) })
        let window = NostrInboxTagTable.epochWindow(atSeconds: realisticNow)
        let padded = NostrInboxDecoy.paddedSubscribeTags(table: table, epochs: window,
                                                         decoySecret: NostrInboxDecoy.secret(fromAgreementPrivate: me.priv))
        XCTAssertEqual(padded.pages, 1)
        XCTAssertEqual(padded.tags.count, 1_920)
        XCTAssertEqual(padded.paged.count, 1)
        // The exact shape NostrTransport.subscriptionFrame builds, with one page
        // in the `#p` slot and a production-shaped subscription id.
        let filter: [String: Any] = ["kinds": [NostrGiftWrap.wrapKind], "#p": padded.paged[0]]
        let req: [Any] = ["REQ", "aeronyra-\(UUID().uuidString.prefix(8))", filter]
        let frame = try JSONSerialization.data(withJSONObject: req)
        XCTAssertLessThanOrEqual(frame.count, 131_072, "nos.lol frame cap")
        XCTAssertGreaterThan(frame.count, 128_000, "sanity: ~67 bytes per value")
        XCTAssertLessThanOrEqual(padded.valuesPerPage, 2_047, "strfry per-filter value cap")
        XCTAssertLessThanOrEqual(padded.valuesPerPage * 32, 65_535, "strfry per-filter decoded byte budget")
    }

    // MARK: Helpers

    private func assertDecoy(_ secret: Data, epoch: UInt64, slot: UInt32, counter: UInt8,
                             _ expectedHex: String, file: StaticString = #filePath, line: UInt = #line) {
        let d = NostrInboxDecoy.decoy(secret: secret, epoch: epoch, slot: slot)
        XCTAssertEqual(d.value.hexString, expectedHex, file: file, line: line)
        XCTAssertEqual(d.counter, counter, "counter diverged", file: file, line: line)
        XCTAssertTrue(NostrInboxTag.isCurveValidX(d.value), file: file, line: line)
    }

    private func freshParty() -> (priv: Curve25519.KeyAgreement.PrivateKey, id: Data, npub: Data) {
        let p = Curve25519.KeyAgreement.PrivateKey()
        var npub = Data(count: 32)
        for i in 0..<32 { npub[i] = UInt8.random(in: UInt8.min...UInt8.max) }
        return (p, p.publicKey.rawRepresentation, npub)
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

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
