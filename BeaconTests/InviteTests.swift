// InviteTests.swift
// BeaconTests
//
// Tests the invite lifecycle (Closed-Contact step 3, docs/CONTACT_MODEL §7):
// the Invite codec, expiry with skew tolerance, and the PendingInvites
// single-use guarantee. Pure logic, `now` injected — fully deterministic.

import XCTest
@testable import Beacon

final class InviteTests: XCTestCase {

    // MARK: Fixtures

    private func samplePayload() -> PairingPayload {
        PairingPayload(bundle: PrekeyBundle(data: Data([0xDE, 0xAD, 0xBE, 0xEF])),
                       nostrPublicKey: Data(repeating: 0x01, count: 32))
    }

    private func fixedID(_ b: UInt8) -> Data { Data(repeating: b, count: Invite.idByteCount) }

    // MARK: Mint

    func testMintSetsExpiryAndId() {
        let now: Int64 = 1_000_000
        let invite = Invite.mint(payload: samplePayload(), now: now,
                                 ttlMillis: 600_000, id: fixedID(0xAB))
        XCTAssertEqual(invite.mintedAt, now)
        XCTAssertEqual(invite.expiresAt, now + 600_000)
        XCTAssertEqual(invite.id, fixedID(0xAB))
    }

    func testRandomIDIsCorrectLengthAndFresh() {
        let a = Invite.randomID()
        let b = Invite.randomID()
        XCTAssertEqual(a.count, Invite.idByteCount)
        XCTAssertNotEqual(a, b)   // overwhelmingly likely
    }

    // MARK: Round-trip

    func testWireRoundTrip() {
        let invite = Invite(payload: samplePayload(), id: fixedID(0x11),
                            mintedAt: 1_700_000_000_000, expiresAt: 1_700_000_600_000)
        let decoded = Invite(wire: invite.wireData())
        XCTAssertEqual(decoded, invite)
    }

    func testRoundTripWithoutNostrKey() {
        let payload = PairingPayload(bundle: PrekeyBundle(data: Data([0x01])), nostrPublicKey: nil)
        let invite = Invite(payload: payload, id: fixedID(0x22), mintedAt: 5, expiresAt: 600_005)
        XCTAssertEqual(Invite(wire: invite.wireData()), invite)
    }

    func testExactHeaderLayout() {
        // Minimal payload so we can pin the full header bytes.
        let payload = PairingPayload(bundle: PrekeyBundle(data: Data([0xAA])), nostrPublicKey: nil)
        let invite = Invite(payload: payload, id: fixedID(0x00),
                            mintedAt: 1, expiresAt: 2)
        let wire = invite.wireData()
        let payloadBytes = payload.wireData()

        var expected = Data()
        expected.append(0x01)                                  // version
        expected.append(fixedID(0x00))                         // 16-byte id
        expected.append(contentsOf: [0,0,0,0,0,0,0,1])         // mintedAt = 1
        expected.append(contentsOf: [0,0,0,0,0,0,0,2])         // expiresAt = 2
        let len = UInt32(payloadBytes.count).bigEndian
        withUnsafeBytes(of: len) { expected.append(contentsOf: $0) }   // payload length
        expected.append(payloadBytes)                          // nested payload
        XCTAssertEqual(wire, expected)
    }

    // MARK: Rejection

    func testRejectsWrongVersion() {
        var wire = Invite(payload: samplePayload(), id: fixedID(0x33),
                          mintedAt: 1, expiresAt: 2).wireData()
        wire[wire.startIndex] = 0x02
        XCTAssertNil(Invite(wire: wire))
    }

    func testRejectsTruncation() {
        let full = Invite(payload: samplePayload(), id: fixedID(0x44),
                          mintedAt: 1, expiresAt: 2).wireData()
        for cut in 1..<full.count {
            XCTAssertNil(Invite(wire: full.prefix(cut)), "prefix \(cut) should not parse")
        }
    }

    func testRejectsTrailingJunk() {
        var wire = Invite(payload: samplePayload(), id: fixedID(0x55),
                          mintedAt: 1, expiresAt: 2).wireData()
        wire.append(0x99)
        XCTAssertNil(Invite(wire: wire))
    }

    func testRejectsCorruptNestedPayload() {
        // Valid invite header but the payload bytes carry a bad version.
        var wire = Invite(payload: samplePayload(), id: fixedID(0x66),
                          mintedAt: 1, expiresAt: 2).wireData()
        // The nested payload's version byte sits right after the 4-byte length,
        // at offset 1 + 16 + 8 + 8 + 4 = 37.
        let payloadVersionOffset = wire.index(wire.startIndex, offsetBy: 37)
        wire[payloadVersionOffset] = 0x7F
        XCTAssertNil(Invite(wire: wire))
    }

    // MARK: Expiry

    func testIsLiveWithinWindow() {
        let invite = Invite(payload: samplePayload(), id: fixedID(0x77),
                            mintedAt: 0, expiresAt: 1000)
        XCTAssertTrue(invite.isLive(at: 500, skewMillis: 0))
        XCTAssertTrue(invite.isLive(at: 1000, skewMillis: 0))   // boundary inclusive
        XCTAssertFalse(invite.isLive(at: 1001, skewMillis: 0))
    }

    func testIsLiveSkewTolerance() {
        let invite = Invite(payload: samplePayload(), id: fixedID(0x88),
                            mintedAt: 0, expiresAt: 1000)
        XCTAssertTrue(invite.isLive(at: 1100, skewMillis: 200))   // within skew past expiry
        XCTAssertFalse(invite.isLive(at: 1300, skewMillis: 200))  // beyond skew
    }

    // MARK: PendingInvites — the single-use guarantee

    func testConsumeSucceedsExactlyOnce() {
        var pending = PendingInvites()
        let id = fixedID(0xA1)
        pending.register(id: id, expiresAt: 1000)
        XCTAssertTrue(pending.consume(id: id, at: 500, skewMillis: 0))   // first: burn
        XCTAssertFalse(pending.consume(id: id, at: 500, skewMillis: 0))  // replay: rejected
        XCTAssertEqual(pending.count, 0)
    }

    func testConsumeUnknownIdFails() {
        var pending = PendingInvites()
        XCTAssertFalse(pending.consume(id: fixedID(0xA2), at: 0, skewMillis: 0))
    }

    func testConsumeExpiredFailsAndDrops() {
        var pending = PendingInvites()
        let id = fixedID(0xA3)
        pending.register(id: id, expiresAt: 1000)
        XCTAssertFalse(pending.consume(id: id, at: 2000, skewMillis: 0))  // expired
        XCTAssertEqual(pending.count, 0)                                  // dropped
    }

    func testConsumeWithinSkewSucceeds() {
        var pending = PendingInvites()
        let id = fixedID(0xA4)
        pending.register(id: id, expiresAt: 1000)
        XCTAssertTrue(pending.consume(id: id, at: 1100, skewMillis: 200))
    }

    func testRegisterFromInvite() {
        var pending = PendingInvites()
        let invite = Invite.mint(payload: samplePayload(), now: 0,
                                 ttlMillis: 1000, id: fixedID(0xA5))
        pending.register(invite)
        XCTAssertTrue(pending.isPending(id: invite.id, at: 500, skewMillis: 0))
        XCTAssertTrue(pending.consume(id: invite.id, at: 500, skewMillis: 0))
    }

    func testPruneRemovesOnlyExpired() {
        var pending = PendingInvites()
        pending.register(id: fixedID(0xB1), expiresAt: 1000)   // expires early
        pending.register(id: fixedID(0xB2), expiresAt: 5000)   // still live
        pending.prune(at: 2000, skewMillis: 0)
        XCTAssertEqual(pending.count, 1)
        XCTAssertFalse(pending.isPending(id: fixedID(0xB1), at: 2000, skewMillis: 0))
        XCTAssertTrue(pending.isPending(id: fixedID(0xB2), at: 2000, skewMillis: 0))
    }

    func testTwoDistinctInvitesAreIndependent() {
        var pending = PendingInvites()
        let id1 = fixedID(0xC1), id2 = fixedID(0xC2)
        pending.register(id: id1, expiresAt: 1000)
        pending.register(id: id2, expiresAt: 1000)
        XCTAssertTrue(pending.consume(id: id1, at: 100, skewMillis: 0))
        XCTAssertTrue(pending.isPending(id: id2, at: 100, skewMillis: 0))   // id2 untouched
        XCTAssertTrue(pending.consume(id: id2, at: 100, skewMillis: 0))
    }
}
