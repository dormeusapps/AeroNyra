// EnrollmentReRedeemTests.swift
// KATs for the read-compare-decide guard on the enrollment seam (Finding B).
// Expected outcomes were fixed in this decision table BEFORE implementation:
//
//   K1 enrolled + verified   + same-identity redeem  → no-op: verified stays true
//   K2 enrolled + unverified + same-identity redeem  → no-op: record untouched
//   K3 not enrolled          + redeem                → enrolls unverified (unchanged path)
//   K4 different identity    + redeem                → new record; existing record untouched
//   K5 hazard pin: ContactAllowlist.enroll REPLACES — verified true → false
//
// K5 and the guard's read (`contains`) are pure and pinned here. K1–K4 through
// the full redeemInvite path require the concrete FirstContactCoordinator +
// session stack and belong to the integration/field checklist.

import XCTest
@testable import Beacon

final class EnrollmentReRedeemTests: XCTestCase {

    private let id  = Data(repeating: 0xA1, count: 32)
    private let id2 = Data(repeating: 0xB2, count: 32)

    // K5 — the replace/downgrade semantics the guard exists to avoid. If this
    // ever becomes a merge instead of a replace, the guard is still correct
    // but no longer load-bearing; if it stays a replace, removing the guard
    // reintroduces Finding B.
    func testAllowlistEnrollReplacesAndDowngrades() {
        var list = ContactAllowlist()
        list.enroll(identity: id, at: 1_000, verified: true)
        XCTAssertTrue(list.isVerified(identity: id))

        list.enroll(identity: id, at: 2_000, verified: false)   // the Finding B write
        XCTAssertFalse(list.isVerified(identity: id),
                       "enroll replaces the record — this is the silent downgrade")
        XCTAssertTrue(list.contains(identity: id), "still enrolled, just demoted")
    }

    // The guard's read: contains() must reflect enrollment regardless of
    // verification state (K1 and K2 take the same branch), and a different
    // key must NOT match (K4's premise — contact identity IS the key).
    func testContainsReflectsEnrollmentIndependentOfVerification() {
        var list = ContactAllowlist()
        XCTAssertFalse(list.contains(identity: id))

        list.enroll(identity: id, at: 1_000, verified: false)
        XCTAssertTrue(list.contains(identity: id))

        list.markVerified(identity: id)
        XCTAssertTrue(list.contains(identity: id))
        XCTAssertTrue(list.isVerified(identity: id))

        XCTAssertFalse(list.contains(identity: id2),
                       "different key = different contact; a changed key arrives as unenrolled")
    }

    // K4 at the allowlist layer: enrolling a second identity leaves the first
    // record byte-for-byte intact.
    func testEnrollingDifferentIdentityLeavesExistingRecordUntouched() {
        var list = ContactAllowlist()
        list.enroll(identity: id, at: 1_000, verified: true)

        list.enroll(identity: id2, at: 2_000, verified: false)

        XCTAssertTrue(list.isVerified(identity: id), "existing verified record untouched")
        XCTAssertTrue(list.contains(identity: id2))
        XCTAssertFalse(list.isVerified(identity: id2), "new pairing starts unverified")
    }
}
