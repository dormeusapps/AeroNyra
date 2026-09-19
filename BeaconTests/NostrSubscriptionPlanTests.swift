//
//  NostrSubscriptionPlanTests.swift
//  BeaconTests
//
//  v59 connection-leak fix · Stage 5 — the pure subscription planner.
//
//  Pins what the REQ carries: contact pages (padded, cut at 1,920 values,
//  one full decoy page for a contactless device, NO pages without a table or
//  a decoy secret), the invite-echo tags across the skew window as their own
//  set (pruned at expiry), byte-stability, and the rollover arithmetic.
//
//  XCTest only (not Swift Testing), per project standard.
//

import XCTest
import CryptoKit
@testable import Beacon

final class NostrSubscriptionPlanTests: XCTestCase {

    private let S1 = Data((0...31).map { UInt8($0) })
    private let LA = Data(repeating: 0xAA, count: 32)
    private let LB = Data(repeating: 0xBB, count: 32)
    private let I1 = Data((0...15).map { UInt8($0) })
    /// 2026-09-14, epoch 20710 (KAT N5), 1,000 s into the day.
    private let now: UInt64 = 1_789_344_000 + 1_000
    private var decoy: Data { NostrInboxDecoy.secret(fromAgreementPrivate: try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: S1)) }

    private func table(rows: Int) -> NostrInboxTagTable {
        NostrInboxTagTable(ourIdentity: LB, rows: (0..<rows).map { i in
            .init(identity: Data(repeating: UInt8(0x10 + i), count: 32), secret: S1, nostrPubkey: nil)
        })
    }

    // MARK: Pages

    func testOnePaddedPageForFewContactsAndForNoContacts() {
        let plan = NostrSubscriptionPlan.make(table: table(rows: 3), decoySecret: decoy,
                                              inviteEchoes: [], nowSeconds: now)
        XCTAssertEqual(plan.pages.count, 1)
        XCTAssertEqual(plan.pages[0].count, 60 * 32)
        XCTAssertEqual(plan.pages[0], plan.pages[0].sorted())
        XCTAssertTrue(plan.inviteEchoTags.isEmpty)
        let empty = NostrSubscriptionPlan.make(table: table(rows: 0), decoySecret: decoy,
                                               inviteEchoes: [], nowSeconds: now)
        XCTAssertEqual(empty.pages.count, 1, "a contactless device still holds a full decoy page")
        XCTAssertEqual(empty.pages[0].count, 60 * 32)
    }

    func testPagesPastSixtyContacts() {
        let plan = NostrSubscriptionPlan.make(table: table(rows: 61), decoySecret: decoy,
                                              inviteEchoes: [], nowSeconds: now)
        XCTAssertEqual(plan.pages.count, 2)
        XCTAssertEqual(plan.pages.map(\.count), [1_920, 1_920])
    }

    func testNoPagesWithoutTableOrDecoySecret() {
        XCTAssertTrue(NostrSubscriptionPlan.make(table: nil, decoySecret: decoy,
                                                 inviteEchoes: [], nowSeconds: now).pages.isEmpty)
        XCTAssertTrue(NostrSubscriptionPlan.make(table: table(rows: 3), decoySecret: nil,
                                                 inviteEchoes: [], nowSeconds: now).pages.isEmpty,
                      "never subscribe to a bare, unpadded set")
    }

    func testPagesAreByteStableWithinAnEpochAndCarryTheRealTags() {
        let t = table(rows: 2)
        let a = NostrSubscriptionPlan.make(table: t, decoySecret: decoy, inviteEchoes: [], nowSeconds: now)
        let b = NostrSubscriptionPlan.make(table: t, decoySecret: decoy, inviteEchoes: [], nowSeconds: now + 3_600)
        XCTAssertEqual(a, b, "same epoch → byte-identical plan on every re-REQ")
        let window = NostrInboxTagTable.epochWindow(atSeconds: now)
        for real in t.subscribeTags(epochs: window) {
            XCTAssertTrue(a.pages[0].contains(real), "every real subscribe tag is on the page")
        }
    }

    // MARK: Invite echoes

    func testLiveInviteYieldsThreeEchoTagsAcrossSkewWindowAsItsOwnSet() {
        let expires = Int64(now) * 1000 + 5 * 60 * 1000
        let plan = NostrSubscriptionPlan.make(table: table(rows: 1), decoySecret: decoy,
                                              inviteEchoes: [.init(inviteID: I1, expiresAtMillis: expires)],
                                              nowSeconds: now)
        XCTAssertEqual(plan.inviteEchoTags.count, 3)
        XCTAssertEqual(plan.inviteEchoTags, NostrInviteEchoTag.subscribeTags(inviteID: I1, epochs: 20709...20711))
        XCTAssertEqual(plan.pages[0].count, 1_920, "echo tags never move a contact page")
        XCTAssertTrue(Set(plan.inviteEchoTags).isDisjoint(with: Set(plan.pages[0])))
    }

    func testExpiredInviteIsPrunedWithSkewLeniency() {
        let nowMillis = Int64(now) * 1000
        let justExpired = NostrSubscriptionPlan.InviteEcho(inviteID: I1, expiresAtMillis: nowMillis - 60_000)   // 1 min ago: within 2 min skew
        let longExpired = NostrSubscriptionPlan.InviteEcho(inviteID: Data(repeating: 0x22, count: 16),
                                                           expiresAtMillis: nowMillis - 5 * 60_000)             // 5 min ago
        let live = NostrSubscriptionPlan.liveEchoes([justExpired, longExpired], nowSeconds: now)
        XCTAssertEqual(live, [justExpired])
        let plan = NostrSubscriptionPlan.make(table: table(rows: 1), decoySecret: decoy,
                                              inviteEchoes: [justExpired, longExpired], nowSeconds: now)
        XCTAssertEqual(plan.inviteEchoTags.count, 3, "only the skew-live invite contributes")
        let later = NostrSubscriptionPlan.make(table: table(rows: 1), decoySecret: decoy,
                                               inviteEchoes: [justExpired, longExpired], nowSeconds: now + 3 * 60)
        XCTAssertTrue(later.inviteEchoTags.isEmpty, "past skew, the echo subscription goes away")
    }

    // MARK: Rollover

    func testSecondsUntilNextEpoch() {
        XCTAssertEqual(NostrSubscriptionPlan.secondsUntilNextEpoch(nowSeconds: 0), 86_400)
        XCTAssertEqual(NostrSubscriptionPlan.secondsUntilNextEpoch(nowSeconds: 1), 86_399)
        XCTAssertEqual(NostrSubscriptionPlan.secondsUntilNextEpoch(nowSeconds: 86_399), 1)
        XCTAssertEqual(NostrSubscriptionPlan.secondsUntilNextEpoch(nowSeconds: 86_400), 86_400)
        XCTAssertEqual(NostrSubscriptionPlan.secondsUntilNextEpoch(nowSeconds: now), 86_400 - 1_000)
        // Crossing the boundary changes exactly one epoch's worth per page.
        let t = table(rows: 2)
        let before = NostrSubscriptionPlan.make(table: t, decoySecret: decoy, inviteEchoes: [], nowSeconds: now)
        let after = NostrSubscriptionPlan.make(table: t, decoySecret: decoy, inviteEchoes: [],
                                               nowSeconds: now + NostrSubscriptionPlan.secondsUntilNextEpoch(nowSeconds: now))
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(Set(before.pages[0]).intersection(Set(after.pages[0])).count, 60 * 31)
    }
}
