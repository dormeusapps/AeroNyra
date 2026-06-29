//
//  Secp256k1LinkTests.swift
//  BeaconTests
//
//  Phase 8b-i-0 smoke test: proves the vendored libsecp256k1 is compiled into
//  the app and its symbols link — exercised THROUGH the app target via
//  `@testable import Beacon` (Secp256k1Probe), so the test target needs no view
//  of the C module itself. A green run means the C library and the
//  ENABLE_MODULE_EXTRAKEYS flag are wired correctly, clearing the §4 secp256k1
//  trap before NostrIdentity (8b-i-1) derives a public key on top.
//
//  XCTest (project convention). Device-free.
//

import XCTest
@testable import Beacon

final class Secp256k1LinkTests: XCTestCase {

    /// The vendored libsecp256k1 links, and its core + extrakeys symbols are
    /// callable from the app target.
    func testSecp256k1LinksAndContextLifecycleSucceeds() {
        XCTAssertTrue(
            Secp256k1Probe.contextLifecycleOK(),
            "secp256k1 context create/randomize should succeed — library not linked or extrakeys flag missing"
        )
    }
}
