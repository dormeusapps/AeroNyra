// ContactAllowlistTests.swift
// BeaconTests
//
// Tests the closed-contact admission set (step 4, docs/CONTACT_MODEL §8). Pure
// logic, deterministic. Identities are opaque Data here.

import XCTest
@testable import Beacon

final class ContactAllowlistTests: XCTestCase {

    private func identity(_ b: UInt8) -> Data { Data(repeating: b, count: 32) }

    // MARK: Enroll / admit

    func testUnknownIdentityIsNotAdmitted() {
        let list = ContactAllowlist()
        XCTAssertFalse(list.contains(identity: identity(0x01)))
        XCTAssertFalse(list.admits(identity: identity(0x01)))
    }

    func testEnrolledIdentityIsAdmitted() {
        var list = ContactAllowlist()
        list.enroll(identity: identity(0x01), at: 1000, verified: false)
        XCTAssertTrue(list.contains(identity: identity(0x01)))
        XCTAssertTrue(list.admits(identity: identity(0x01)))
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.entry(for: identity(0x01))?.pairedAt, 1000)
    }

    // MARK: Verified gating

    func testUnverifiedFailsRequireVerified() {
        var list = ContactAllowlist()
        list.enroll(identity: identity(0x02), at: 0, verified: false)
        XCTAssertFalse(list.isVerified(identity: identity(0x02)))
        XCTAssertTrue(list.admits(identity: identity(0x02)))                       // default: enrolled is enough
        XCTAssertFalse(list.admits(identity: identity(0x02), requireVerified: true)) // strict: needs verify
    }

    func testQrPairEnrollsVerified() {
        var list = ContactAllowlist()
        list.enroll(identity: identity(0x03), at: 0, verified: true)   // QR = physically authenticated
        XCTAssertTrue(list.isVerified(identity: identity(0x03)))
        XCTAssertTrue(list.admits(identity: identity(0x03), requireVerified: true))
    }

    func testMarkVerifiedPromotes() {
        var list = ContactAllowlist()
        list.enroll(identity: identity(0x04), at: 0, verified: false)
        XCTAssertFalse(list.admits(identity: identity(0x04), requireVerified: true))
        list.markVerified(identity: identity(0x04))                   // SAS confirmed
        XCTAssertTrue(list.isVerified(identity: identity(0x04)))
        XCTAssertTrue(list.admits(identity: identity(0x04), requireVerified: true))
    }

    func testMarkVerifiedOnUnknownIsNoOp() {
        var list = ContactAllowlist()
        list.markVerified(identity: identity(0x05))
        XCTAssertFalse(list.contains(identity: identity(0x05)))
        XCTAssertEqual(list.count, 0)
    }

    // MARK: Revoke

    func testRevokeRemoves() {
        var list = ContactAllowlist()
        list.enroll(identity: identity(0x06), at: 0, verified: true)
        list.revoke(identity: identity(0x06))
        XCTAssertFalse(list.contains(identity: identity(0x06)))
        XCTAssertFalse(list.admits(identity: identity(0x06)))
        XCTAssertEqual(list.count, 0)
    }

    // MARK: Re-enroll

    func testReEnrollReplacesRecord() {
        var list = ContactAllowlist()
        list.enroll(identity: identity(0x07), at: 100, verified: true)
        list.enroll(identity: identity(0x07), at: 200, verified: false)   // re-pair after key change
        XCTAssertEqual(list.entry(for: identity(0x07))?.pairedAt, 200)
        XCTAssertFalse(list.isVerified(identity: identity(0x07)))
        XCTAssertEqual(list.count, 1)
    }

    // MARK: Independence + introspection

    func testIdentitiesAreIndependent() {
        var list = ContactAllowlist()
        list.enroll(identity: identity(0x08), at: 0, verified: true)
        list.enroll(identity: identity(0x09), at: 0, verified: false)
        list.revoke(identity: identity(0x08))
        XCTAssertFalse(list.contains(identity: identity(0x08)))
        XCTAssertTrue(list.contains(identity: identity(0x09)))
    }

    func testIdentitiesSet() {
        var list = ContactAllowlist()
        list.enroll(identity: identity(0x0A), at: 0, verified: true)
        list.enroll(identity: identity(0x0B), at: 0, verified: true)
        XCTAssertEqual(list.identities, [identity(0x0A), identity(0x0B)])
    }
}
