//
//  NostrInboxTagTableTests.swift
//  BeaconTests
//
//  v59 connection-leak fix · Stage 2 — the contact tag table.
//
//  NostrInboxTagTable layers over two already-KAT-anchored primitives
//  (DiscoverySecret 5c, NostrInboxTag Stage 1), so this suite is mostly a
//  PROPERTY / round-trip suite: the fixed bytes are pinned in those primitives'
//  own KAT tests. What we prove here is the wiring, per
//  STAGE2_CONTACT_TAG_TABLE_SPEC.md §7:
//
//    1. KAT tie-in — the table reproduces N1 and N5 under the locked framing
//       (it CALLS the Stage 1 primitive rather than re-deriving one);
//    2. two-device round trip — A's publish tag for B is in B's subscribe set
//       and vice-versa; a stranger's table contains neither;
//    3. direction — the tag A publishes to B differs from the tag A subscribes
//       to for B;
//    4. subscribe-only row — a nil npub still contributes its tags, publish
//       returns nil;
//    5. unknown npub — publishTag returns nil, NEVER the npub hex;
//    6. determinism / byte-stability — contact order does not change the set;
//    7. ordering — sorted ascending, no duplicates;
//    8. count — rows × 32 over the locked window;
//    9. window — exactly 32 epochs from an INJECTED instant; no underflow at 0;
//   10. separation — fresh random pairs never share a tag in one epoch;
//   11. throwing contract — an invalid contact key makes build throw.
//
//  XCTest only (not Swift Testing), per project standard.
//

import XCTest
import CryptoKit
@testable import Beacon

final class NostrInboxTagTableTests: XCTestCase {

    // Fixed inputs (NOSTR_INBOX_TAG_KAT.md §1 / §4)
    private let S1 = Data((0...31).map { UInt8($0) })
    private let LA = Data(repeating: 0xAA, count: 32)
    private let LB = Data(repeating: 0xBB, count: 32)
    private let someNpub = Data(repeating: 0x42, count: 32)

    /// A realistic injected instant: 2026-09-14, epoch 20710 (KAT N5).
    private let realisticNow: UInt64 = 1_789_344_000

    // MARK: Helpers

    /// A fresh X25519 agreement keypair and its raw 32-byte identity (the value
    /// the store hands back as `rawPublicKey(of:)`), plus a fresh random npub —
    /// the table never inspects the npub, so any 32 bytes stand in for one.
    private func freshParty() -> (priv: Curve25519.KeyAgreement.PrivateKey, id: Data, npub: Data) {
        let p = Curve25519.KeyAgreement.PrivateKey()
        var npub = Data(count: 32)
        for i in 0..<32 { npub[i] = UInt8.random(in: UInt8.min...UInt8.max) }
        return (p, p.publicKey.rawRepresentation, npub)
    }

    // MARK: 1. KAT tie-in (load-bearing)

    func testTableReproducesKATVectorsN1AndN5() {
        // Publish side: label = OUR identity. With ourIdentity = LA and the
        // row's secret = S1, publishing yields tag(S1, e, LA) — N1 / N5.
        let publisher = NostrInboxTagTable(
            ourIdentity: LA,
            rows: [.init(identity: LB, secret: S1, nostrPubkey: someNpub)])
        let n1 = publisher.publishTag(to: someNpub, epoch: 0)
        let n5 = publisher.publishTag(to: someNpub, epoch: 20710)
        XCTAssertEqual(n1?.value.hexString, "b1c25406911c8c4c9f9b0b9c154018f81f2022ca5371eac1fb03b78849c49ba0")
        XCTAssertEqual(n1?.counter, 0)
        XCTAssertEqual(n5?.value.hexString, "e2040b8422ba4aa5e05e44d9bad5d1e5c8182a1101c612c6bf75e023cec8882a")
        XCTAssertEqual(n5?.counter, 0)

        // Subscribe side: label = the CONTACT's identity. With a contact whose
        // identity is LA and secret S1, our subscribe set contains the same N1.
        let subscriber = NostrInboxTagTable(
            ourIdentity: LB,
            rows: [.init(identity: LA, secret: S1, nostrPubkey: nil)])
        XCTAssertEqual(subscriber.subscribeTags(epochs: 0...0),
                       ["b1c25406911c8c4c9f9b0b9c154018f81f2022ca5371eac1fb03b78849c49ba0"])
        XCTAssertEqual(subscriber.subscribeTags(epochs: 20710...20710),
                       ["e2040b8422ba4aa5e05e44d9bad5d1e5c8182a1101c612c6bf75e023cec8882a"])
    }

    // MARK: 2. Two-device round trip

    func testTwoDeviceRoundTripBothDirections() throws {
        let a = freshParty(), b = freshParty(), stranger = freshParty()
        let tableA = try NostrInboxTagTable.build(ourAgreementPrivate: a.priv, ourIdentity: a.id,
                                                  contacts: [(b.id, b.npub)])
        let tableB = try NostrInboxTagTable.build(ourAgreementPrivate: b.priv, ourIdentity: b.id,
                                                  contacts: [(a.id, a.npub)])
        // A stranger who paired with neither: a table over an unrelated secret.
        let tableX = try NostrInboxTagTable.build(ourAgreementPrivate: stranger.priv,
                                                  ourIdentity: stranger.id,
                                                  contacts: [(a.id, a.npub), (b.id, b.npub)])
        let e: UInt64 = 20710

        let aToB = try XCTUnwrap(tableA.publishTag(to: b.npub, epoch: e))
        XCTAssertTrue(tableB.subscribeTags(epochs: e...e).contains(aToB.hex),
                      "what A publishes to B must be a tag B subscribes to")
        let bToA = try XCTUnwrap(tableB.publishTag(to: a.npub, epoch: e))
        XCTAssertTrue(tableA.subscribeTags(epochs: e...e).contains(bToA.hex),
                      "what B publishes to A must be a tag A subscribes to")

        let strangerSet = Set(tableX.subscribeTags(epochs: e...e))
        XCTAssertFalse(strangerSet.contains(aToB.hex), "a stranger's table must not predict A→B")
        XCTAssertFalse(strangerSet.contains(bToA.hex), "a stranger's table must not predict B→A")
    }

    // MARK: 3. Direction

    func testPublishTagDiffersFromOwnSubscribeTagForSameContact() throws {
        let a = freshParty(), b = freshParty()
        let tableA = try NostrInboxTagTable.build(ourAgreementPrivate: a.priv, ourIdentity: a.id,
                                                  contacts: [(b.id, b.npub)])
        let e: UInt64 = 20710
        let aToB = try XCTUnwrap(tableA.publishTag(to: b.npub, epoch: e))
        XCTAssertFalse(tableA.subscribeTags(epochs: e...e).contains(aToB.hex),
                       "tag(A→B) must not equal tag(B→A): the subscribe set is labelled with B, the publish tag with A")
    }

    // MARK: 4. Subscribe-only row

    func testSubscribeOnlyRowContributesTagsButNeverPublishes() throws {
        let a = freshParty(), b = freshParty()
        let table = try NostrInboxTagTable.build(ourAgreementPrivate: a.priv, ourIdentity: a.id,
                                                 contacts: [(b.id, nil)])
        let window = NostrInboxTagTable.epochWindow(atSeconds: realisticNow)
        XCTAssertEqual(table.subscribeTags(epochs: window).count, 32,
                       "a nil-npub row still contributes one tag per epoch")
        XCTAssertNil(table.publishTag(to: b.npub, epoch: 20710))
        XCTAssertNil(table.publishTag(to: someNpub, epoch: 20710))
    }

    // MARK: 5. Unknown npub — nil, never the npub

    func testUnknownNpubReturnsNilNotTheNpub() throws {
        let a = freshParty(), b = freshParty()
        let table = try NostrInboxTagTable.build(ourAgreementPrivate: a.priv, ourIdentity: a.id,
                                                 contacts: [(b.id, b.npub)])
        let unknown = someNpub
        let result = table.publishTag(to: unknown, epoch: 20710)
        XCTAssertNil(result)
        XCTAssertNotEqual(result?.hex, unknown.hexString,
                          "a silent fallback to the npub is the defect this fix removes")
        // And the empty table.
        let empty = NostrInboxTagTable(ourIdentity: a.id, rows: [])
        XCTAssertNil(empty.publishTag(to: b.npub, epoch: 20710))
        XCTAssertEqual(empty.subscribeTags(epochs: 0...31), [])
    }

    // MARK: 6. Determinism / byte-stability across contact order

    func testSubscribeSetIsIdenticalRegardlessOfContactOrder() throws {
        let me = freshParty()
        let contacts = (0..<6).map { _ in freshParty() }
        let forward = try NostrInboxTagTable.build(
            ourAgreementPrivate: me.priv, ourIdentity: me.id,
            contacts: contacts.map { ($0.id, $0.npub) })
        let reversed = try NostrInboxTagTable.build(
            ourAgreementPrivate: me.priv, ourIdentity: me.id,
            contacts: contacts.reversed().map { ($0.id, $0.npub) })
        let window = NostrInboxTagTable.epochWindow(atSeconds: realisticNow)
        XCTAssertEqual(forward.subscribeTags(epochs: window), reversed.subscribeTags(epochs: window),
                       "element-wise identical: the REQ must be byte-stable regardless of Set iteration order")
        // Same inputs twice → same table.
        let again = try NostrInboxTagTable.build(
            ourAgreementPrivate: me.priv, ourIdentity: me.id,
            contacts: contacts.map { ($0.id, $0.npub) })
        XCTAssertEqual(forward, again)
    }

    // MARK: 7. Ordering — sorted ascending, no duplicates

    func testSubscribeTagsSortedAscendingAndDeduplicated() throws {
        let me = freshParty()
        let b = freshParty()
        let contacts = (0..<5).map { _ in freshParty() }
        // A duplicated ROW from a caller must collapse, not double the set.
        let table = try NostrInboxTagTable.build(
            ourAgreementPrivate: me.priv, ourIdentity: me.id,
            contacts: contacts.map { ($0.id, $0.npub) } + [(b.id, b.npub), (b.id, b.npub)])
        let window = NostrInboxTagTable.epochWindow(atSeconds: realisticNow)
        let tags = table.subscribeTags(epochs: window)
        XCTAssertEqual(tags, tags.sorted(), "must be sorted ascending")
        XCTAssertEqual(Set(tags).count, tags.count, "must contain no duplicates")
        XCTAssertEqual(tags.count, 6 * 32, "the duplicated row contributes once")
        for t in tags {
            XCTAssertEqual(t.count, 64)
            XCTAssertEqual(t, t.lowercased())
        }
    }

    // MARK: 8. Count

    func testSubscribeCountIsRowsTimesWindow() throws {
        let me = freshParty()
        let contacts = (0..<7).map { _ in freshParty() }
        let table = try NostrInboxTagTable.build(
            ourAgreementPrivate: me.priv, ourIdentity: me.id,
            contacts: contacts.map { ($0.id, $0.npub) })
        let window = NostrInboxTagTable.epochWindow(atSeconds: realisticNow)
        XCTAssertEqual(table.rows.count, 7)
        XCTAssertEqual(table.subscribeTags(epochs: window).count, table.rows.count * 32)
    }

    // MARK: 9. Window — 32 epochs from an injected instant, no underflow

    func testEpochWindowSpansThirtyTwoEpochsFromInjectedInstant() {
        XCTAssertEqual(NostrInboxTagTable.epochsBack, 30)
        XCTAssertEqual(NostrInboxTagTable.epochsAhead, 1)
        let window = NostrInboxTagTable.epochWindow(atSeconds: realisticNow)
        XCTAssertEqual(window, 20_680...20_711)
        XCTAssertEqual(window.count, 32)
        // Computed from the INJECTED value, not the clock: shift by one day.
        XCTAssertEqual(NostrInboxTagTable.epochWindow(atSeconds: realisticNow + 86_400), 20_681...20_712)
        XCTAssertEqual(NostrInboxTagTable.epochWindow(atSeconds: realisticNow - 1), 20_679...20_710)
    }

    func testEpochWindowDoesNotUnderflowNearZero() {
        XCTAssertEqual(NostrInboxTagTable.epochWindow(atSeconds: 0), 0...1)
        XCTAssertEqual(NostrInboxTagTable.epochWindow(atSeconds: 29 * 86_400), 0...30)
        XCTAssertEqual(NostrInboxTagTable.epochWindow(atSeconds: 30 * 86_400), 0...31)
        XCTAssertEqual(NostrInboxTagTable.epochWindow(atSeconds: 31 * 86_400), 1...32)
    }

    // MARK: 10. Separation over fresh random pairs

    func testNoTwoContactsShareATagInOneEpoch() throws {
        let me = freshParty()
        let contacts = (0..<40).map { _ in freshParty() }
        let table = try NostrInboxTagTable.build(
            ourAgreementPrivate: me.priv, ourIdentity: me.id,
            contacts: contacts.map { ($0.id, $0.npub) })
        let e: UInt64 = 20710
        let subscribe = table.subscribeTags(epochs: e...e)
        XCTAssertEqual(subscribe.count, 40, "40 contacts → 40 distinct subscribe tags in one epoch")
        let publish = Set(contacts.compactMap { table.publishTag(to: $0.npub, epoch: e)?.hex })
        XCTAssertEqual(publish.count, 40, "40 contacts → 40 distinct publish tags in one epoch")
        XCTAssertTrue(publish.isDisjoint(with: subscribe),
                      "our publish tags (our label) never collide with our subscribe tags (their labels)")
    }

    // MARK: 11. Throwing contract

    func testBuildThrowsOnInvalidContactKey() {
        let a = freshParty(), b = freshParty()
        // 31 bytes is not a valid X25519 public key — derive() throws, and the
        // builder surfaces it rather than returning a short table.
        XCTAssertThrowsError(
            try NostrInboxTagTable.build(ourAgreementPrivate: a.priv, ourIdentity: a.id,
                                         contacts: [(b.id, b.npub), (Data(count: 31), nil)]))
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
