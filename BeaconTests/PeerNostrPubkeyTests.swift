// PeerNostrPubkeyTests.swift
// BeaconTests
//
// Phase 8d-0b — the npub-bootstrap storage field on the Peer @Model.
//
// Proves Peer.nostrPubkey genuinely round-trips through SwiftData (insert →
// save → fetch), defaults to nil for a peer that never announced one, and can
// be set after creation (the handleLearnedNostrIdentity path: learn it later,
// over the established channel). Uses an in-memory ModelContainer so nothing
// touches disk.
//
// NOTE: the actor→inbox wiring itself (coordinator yields .learnedNostrIdentity
// → MessageInbox persists) is exercised on-device when bootstrap fires; the
// inbox handler is a 3-line fetch-or-create-and-assign mirroring already-proven
// patterns. What deserves a unit test is the SCHEMA — that the new field
// survives a real SwiftData round-trip — which is what this covers.
//

import XCTest
import SwiftData
@testable import Beacon

final class PeerNostrPubkeyTests: XCTestCase {

    /// A fresh in-memory store each test. Includes all three related models so
    /// the Peer↔Conversation↔Message relationships resolve in the schema.
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Peer.self, Conversation.self, Message.self,
            configurations: config
        )
        return ModelContext(container)
    }

    private let idKey    = Data((0..<32).map { UInt8($0) })          // X25519 identity
    private let nostrKey = Data((100..<132).map { UInt8($0) })       // x-only secp256k1

    // MARK: - Default

    func testNostrPubkeyDefaultsToNil() throws {
        let context = try makeContext()
        context.insert(Peer(publicKeyData: idKey))
        try context.save()

        let fetched = try fetchPeer(idKey, in: context)
        XCTAssertNil(fetched.nostrPubkey)
    }

    // MARK: - Round-trip

    func testNostrPubkeyPersistsRoundTrip() throws {
        let context = try makeContext()
        context.insert(Peer(publicKeyData: idKey, nostrPubkey: nostrKey))
        try context.save()

        let fetched = try fetchPeer(idKey, in: context)
        XCTAssertEqual(fetched.nostrPubkey, nostrKey)
        XCTAssertEqual(fetched.nostrPubkey?.count, 32)
        // It is a DISTINCT key from the libsignal identity, not a copy of it.
        XCTAssertNotEqual(fetched.nostrPubkey, fetched.publicKeyData)
    }

    // MARK: - Set after creation (the learn-it-later path)

    func testNostrPubkeyCanBeSetAfterCreation() throws {
        let context = try makeContext()
        context.insert(Peer(publicKeyData: idKey))   // met first, no nostr key yet
        try context.save()

        let peer = try fetchPeer(idKey, in: context)
        XCTAssertNil(peer.nostrPubkey)
        peer.nostrPubkey = nostrKey                  // announcement arrives later
        try context.save()

        let refetched = try fetchPeer(idKey, in: context)
        XCTAssertEqual(refetched.nostrPubkey, nostrKey)
    }

    // MARK: - Helper

    private func fetchPeer(_ key: Data, in context: ModelContext) throws -> Peer {
        let descriptor = FetchDescriptor<Peer>(
            predicate: #Predicate { $0.publicKeyData == key }
        )
        return try XCTUnwrap(try context.fetch(descriptor).first)
    }
}
