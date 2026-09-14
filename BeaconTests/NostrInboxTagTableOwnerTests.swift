//
//  NostrInboxTagTableOwnerTests.swift
//  BeaconTests
//
//  v59 connection-leak fix · Stage 4 — the table owner and its enrollment adapter.
//
//  Proves the wiring, not the bytes (those are pinned in the Stage 1–3 KATs):
//    • rebuild reads live membership + joins and pushes a table whose
//      publishTag works for a contact with an npub and is nil for one without;
//    • a malformed identity is DROPPED and counted, never allowed to throw or
//      to zero the table;
//    • rebuild is deterministic across Set iteration order;
//    • scheduleRebuild coalesces: a burst of triggers executes ONE rebuild
//      that reads the newest state, so a fast revoke-then-enroll cannot leave
//      a stale table;
//    • the adapter forwards to the coordinator FIRST and schedules a rebuild
//      only for membership changes.
//
//  XCTest only (not Swift Testing), per project standard.
//

import XCTest
import CryptoKit
import os
@testable import Beacon

@MainActor
final class NostrInboxTagTableOwnerTests: XCTestCase {

    private func freshParty() -> (priv: Curve25519.KeyAgreement.PrivateKey, id: Data, npub: Data) {
        let p = Curve25519.KeyAgreement.PrivateKey()
        var npub = Data(count: 32)
        for i in 0..<32 { npub[i] = UInt8.random(in: UInt8.min...UInt8.max) }
        return (p, p.publicKey.rawRepresentation, npub)
    }

    /// Dictionary-backed live state the owner reads through its closures.
    private final class World {
        var identities = Set<Data>()
        var npubs: [Data: Data] = [:]
        var pushed: [NostrInboxTagTable] = []
    }

    private func makeOwner(_ world: World, me: (priv: Curve25519.KeyAgreement.PrivateKey, id: Data, npub: Data)) -> NostrInboxTagTableOwner {
        NostrInboxTagTableOwner(ourAgreementPrivate: me.priv, ourIdentity: me.id,
                                identities: { world.identities },
                                nostrPubkey: { world.npubs[$0] },
                                sink: { world.pushed.append($0) })
    }

    // MARK: rebuild

    func testRebuildReadsLiveStateAndPushesAWorkingTable() {
        let me = freshParty(), a = freshParty(), b = freshParty()
        let world = World()
        world.identities = [a.id, b.id]
        world.npubs[a.id] = a.npub                       // b: subscribe-only
        let owner = makeOwner(world, me: me)

        let table = owner.rebuild()
        XCTAssertEqual(world.pushed.count, 1)
        XCTAssertEqual(world.pushed.first, table)
        XCTAssertEqual(owner.current, table)
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertNotNil(table.publishTag(to: a.npub, epoch: 20710))
        XCTAssertNil(table.publishTag(to: b.npub, epoch: 20710), "no npub → no publish tag")
        XCTAssertEqual(table.subscribeTags(epochs: 20710...20710).count, 2, "both rows subscribe")
        // Membership change shows on the next rebuild; the pushed value is whole.
        world.identities.remove(a.id)
        let after = owner.rebuild()
        XCTAssertEqual(after.rows.count, 1)
        XCTAssertNil(after.publishTag(to: a.npub, epoch: 20710))
        XCTAssertEqual(world.pushed.count, 2)
    }

    func testMalformedIdentityIsDroppedNotFatal() {
        let me = freshParty(), a = freshParty()
        let world = World()
        world.identities = [a.id, Data(count: 31)]
        world.npubs[a.id] = a.npub
        let owner = makeOwner(world, me: me)
        let table = owner.rebuild()
        XCTAssertEqual(owner.lastDroppedCount, 1)
        XCTAssertEqual(table.rows.count, 1, "the good contact survives the bad one")
        XCTAssertNotNil(table.publishTag(to: a.npub, epoch: 0))
    }

    func testRebuildIsDeterministicAcrossSetOrder() {
        let me = freshParty()
        let contacts = (0..<6).map { _ in freshParty() }
        let world = World()
        for c in contacts { world.identities.insert(c.id); world.npubs[c.id] = c.npub }
        let owner = makeOwner(world, me: me)
        let t1 = owner.rebuild()
        // Rebuild the set in a different insertion order.
        world.identities = Set(contacts.reversed().map(\.id))
        let t2 = owner.rebuild()
        XCTAssertEqual(t1, t2)
        XCTAssertEqual(t1.subscribeTags(epochs: 0...31), t2.subscribeTags(epochs: 0...31))
    }

    // MARK: scheduleRebuild — coalescing and ordering

    func testBurstOfTriggersRunsOneRebuildOnNewestState() async {
        let me = freshParty(), a = freshParty()
        let world = World()
        let owner = makeOwner(world, me: me)
        // Fast revoke-then-enroll: three triggers before any task runs.
        world.identities = [a.id]; world.npubs[a.id] = a.npub
        owner.scheduleRebuild()
        world.identities = []
        owner.scheduleRebuild()
        world.identities = [a.id]
        owner.scheduleRebuild()
        // Let the scheduled main-actor tasks drain.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(owner.rebuildCount, 1, "superseded generations must not execute")
        XCTAssertEqual(owner.current?.rows.count, 1, "the surviving rebuild reads the NEWEST state")
        XCTAssertNotNil(owner.current?.publishTag(to: a.npub, epoch: 0))
    }

    // MARK: adapter

    private final class RecordingSink: ReconnectEnrolling, @unchecked Sendable {
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        func addReconnectContact(rawIdentity: Data) async { calls.withLock { $0.append("add") } }
        func removeReconnectContact(rawIdentity: Data) async { calls.withLock { $0.append("remove") } }
        func addVerifiedContact(rawIdentity: Data) async { calls.withLock { $0.append("verify") } }
        func removeVerifiedContact(rawIdentity: Data) async { calls.withLock { $0.append("unverify") } }
    }

    func testAdapterForwardsFirstAndSchedulesOnlyForMembershipChanges() async {
        let me = freshParty(), a = freshParty()
        let world = World()
        world.identities = [a.id]; world.npubs[a.id] = a.npub
        let owner = makeOwner(world, me: me)
        let sink = RecordingSink()
        let adapter = NostrInboxTagEnrollmentAdapter(coordinator: sink)

        // Before attachment: forwards, no rebuild.
        await adapter.addReconnectContact(rawIdentity: a.id)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(sink.calls.withLock { $0 }, ["add"])
        XCTAssertEqual(owner.rebuildCount, 0)

        adapter.attach(owner)
        await adapter.addVerifiedContact(rawIdentity: a.id)
        await adapter.removeVerifiedContact(rawIdentity: a.id)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(owner.rebuildCount, 0, "verified-state changes do not change membership")

        await adapter.removeReconnectContact(rawIdentity: a.id)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(sink.calls.withLock { $0 }, ["add", "verify", "unverify", "remove"], "coordinator sees every call, in order, first")
        XCTAssertEqual(owner.rebuildCount, 1)
        XCTAssertNotNil(owner.current)
    }
}
