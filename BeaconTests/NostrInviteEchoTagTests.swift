//
//  NostrInviteEchoTagTests.swift
//  BeaconTests
//
//  v59 connection-leak fix · Stage 4 — the invite-echo tag.
//
//  Anchors the echo-tag construction to vectors computed OUT of implementation
//  (Python: HKDF + SHA-256 + the Stage 1 tag search with a Legendre curve test)
//  before any Swift: the invite-derived secret (ES1, ES2), the fixed label
//  (EL), and four tags with their counters — one of which (E2, counter 5)
//  exercises the search loop. Then the properties: same construction as a
//  real tag, distinct per invite id and per epoch, curve-valid, and the
//  minter's subscribe shape.
//
//  XCTest only (not Swift Testing), per project standard.
//

import XCTest
import CryptoKit
@testable import Beacon

final class NostrInviteEchoTagTests: XCTestCase {

    private let I1 = Data((0...15).map { UInt8($0) })
    private let I2 = Data(repeating: 0x22, count: 16)
    private let ES1 = "d7af90397559f1f18f2aa72c9cfccb9dd24c1cdda768006e99c93ff9980fcf44"
    private let ES2 = "f2276e34ffac542d68621b78fc78d82dd9d0fa50545198642e3c581810653598"
    private let EL  = "2cf6fe7e9cb55c1d3950a5b3a8d55afe78ceb0f155b01276b8b8726353880c28"

    // MARK: Tier 1b — secret + label vectors

    func testSecretVectors() {
        XCTAssertEqual(NostrInviteEchoTag.secret(fromInviteID: I1).hexString, ES1)
        XCTAssertEqual(NostrInviteEchoTag.secret(fromInviteID: I2).hexString, ES2)
        XCTAssertEqual(NostrInviteEchoTag.secret(fromInviteID: I1).count, NostrInviteEchoTag.secretLength)
        XCTAssertEqual(NostrInviteEchoTag.secretInfo, Data("AeroNyra/nostr-invite-echo-secret/v1".utf8))
        XCTAssertEqual(NostrInviteEchoTag.inviteIDLength, Invite.idByteCount)
    }

    func testLabelVector() {
        XCTAssertEqual(NostrInviteEchoTag.labelDomain, Data("AeroNyra/nostr-invite-echo-label/v1".utf8))
        XCTAssertEqual(NostrInviteEchoTag.label.hexString, EL)
        XCTAssertEqual(NostrInviteEchoTag.label.count, NostrInboxTag.labelLength)
    }

    // MARK: Tier 2 — tag vectors, tag AND counter

    func testTagVectors() {
        assertTag(I1, epoch: 0, counter: 0,
                  "f6250b59e377d56ec9efcff143e5e67b94fc31cccace11ea0318ad85fc98c003")   // E1 baseline
        assertTag(I1, epoch: 1, counter: 5,
                  "06f416d640355a4f5bb152e65dfdd957f5fd4ea3859d16fb0845c0f7e0458cca")   // E2 search loop (5 rejections)
        assertTag(I1, epoch: 20710, counter: 0,
                  "019a0c312921107cb34839ef8de8cfedef4bca4c1296743fae06a3959d09086b")   // E3 realistic epoch
        assertTag(I2, epoch: 0, counter: 3,
                  "06cf93d881e7e3cc72f999ad0940e7c24914881310df0f9acfb44821c5d354b3")   // E4 invite id separation
    }

    /// E2 needs five rejections; pin that candidates 0–4 are each curve-invalid
    /// so a non-incrementing search fails on its own line.
    func testE2ExercisesTheSearchLoop() {
        let secret = NostrInviteEchoTag.secret(fromInviteID: I1)
        let e2 = NostrInviteEchoTag.tag(inviteID: I1, epoch: 1)
        XCTAssertEqual(e2.counter, 5)
        for rejected: UInt8 in 0...4 {
            let candidate = NostrInboxTag.candidate(secret: secret, epoch: 1,
                                                    label: NostrInviteEchoTag.label, counter: rejected)
            XCTAssertFalse(NostrInboxTag.isCurveValidX(candidate), "candidate \(rejected) must be rejected")
        }
    }

    // MARK: Properties

    func testEchoTagIsTheRealTagConstruction() {
        for e: UInt64 in [0, 1, 20710] {
            XCTAssertEqual(NostrInviteEchoTag.tag(inviteID: I1, epoch: e),
                           NostrInboxTag.tag(secret: NostrInviteEchoTag.secret(fromInviteID: I1),
                                             epoch: e, label: NostrInviteEchoTag.label))
        }
    }

    func testDistinctPerInviteAndPerEpochAndCurveValid() {
        var seen = Set<Data>()
        for id in [I1, I2, Data(repeating: 0x33, count: 16)] {
            for e: UInt64 in 0..<20 {
                let t = NostrInviteEchoTag.tag(inviteID: id, epoch: e)
                XCTAssertTrue(NostrInboxTag.isCurveValidX(t.value))
                seen.insert(t.value)
            }
        }
        XCTAssertEqual(seen.count, 60)
    }

    func testMinterSubscribeShapeAcrossSkewWindow() {
        let tags = NostrInviteEchoTag.subscribeTags(inviteID: I1, epochs: 20709...20711)
        XCTAssertEqual(tags.count, 3)
        XCTAssertEqual(tags, tags.sorted())
        XCTAssertTrue(tags.contains("019a0c312921107cb34839ef8de8cfedef4bca4c1296743fae06a3959d09086b"))
        XCTAssertTrue(tags.contains(NostrInviteEchoTag.tag(inviteID: I1, epoch: 20709).hex))
        XCTAssertTrue(tags.contains(NostrInviteEchoTag.tag(inviteID: I1, epoch: 20711).hex))
        for t in tags { XCTAssertEqual(t.count, 64); XCTAssertEqual(t, t.lowercased()) }
    }

    // MARK: Helpers

    private func assertTag(_ inviteID: Data, epoch: UInt64, counter: UInt8, _ expectedHex: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        let t = NostrInviteEchoTag.tag(inviteID: inviteID, epoch: epoch)
        XCTAssertEqual(t.value.hexString, expectedHex, file: file, line: line)
        XCTAssertEqual(t.counter, counter, "counter diverged", file: file, line: line)
        XCTAssertTrue(NostrInboxTag.isCurveValidX(t.value), file: file, line: line)
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
