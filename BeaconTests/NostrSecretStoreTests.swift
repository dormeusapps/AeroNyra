//
//  NostrSecretStoreTests.swift
//  BeaconTests
//
//  Proves the Keychain round-trip for the Nostr secret (Phase 8a) with arbitrary
//  bytes — no secp256k1 needed, so this is green before the pod lands. Uses a
//  per-test unique service id so runs don't collide and always cleans up.
//  XCTest (project convention).
//

import XCTest
@testable import Beacon

final class NostrSecretStoreTests: XCTestCase {

    private var service: String!

    override func setUp() {
        super.setUp()
        service = "test.nostr.\(UUID().uuidString)"
    }

    override func tearDown() {
        try? NostrSecretStore.destroy(service: service)
        super.tearDown()
    }

    func testLoadReturnsNilWhenAbsent() throws {
        XCTAssertNil(try NostrSecretStore.load(service: service))
    }

    func testSaveThenLoadRoundTrips() throws {
        let secret = Data((0..<NostrSecretStore.byteCount).map { _ in UInt8.random(in: 0...255) })
        try NostrSecretStore.save(secret, service: service)
        XCTAssertEqual(try NostrSecretStore.load(service: service), secret)
    }

    func testDestroyRemovesSecret() throws {
        let secret = Data(repeating: 0xAB, count: NostrSecretStore.byteCount)
        try NostrSecretStore.save(secret, service: service)
        XCTAssertNotNil(try NostrSecretStore.load(service: service))
        try NostrSecretStore.destroy(service: service)
        XCTAssertNil(try NostrSecretStore.load(service: service))
    }

    func testDestroyIsIdempotent() throws {
        // Destroying a non-existent item must not throw.
        XCTAssertNoThrow(try NostrSecretStore.destroy(service: service))
    }
}
