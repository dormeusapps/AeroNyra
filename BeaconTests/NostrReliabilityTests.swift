//
//  NostrReliabilityTests.swift
//  BeaconTests
//
//  Pins for the internet-delivery reliability fixes (F1/F2/F3):
//
//  F1 — acceptance ladder: a publish round with >= 1 relay accept settles; a
//  zero-accept round retries until the attempt cap, then gives up (surfaces the
//  failure upward so a `.cast` row can demote). The decision core is pure
//  (`NostrTransport.acceptanceOutcome`) precisely so this ladder is pinned
//  without sockets.
//
//  F2 — ledger policy: `contains` never mutates, `containsOrInsert` records —
//  the call-site revision (record only on successful unwrap) leans on this
//  read-only probe existing and staying read-only.
//
//  F3 — re-echo heal, end-to-end through the REAL seams: the redeemer's
//  `resendInviteEcho` seals a fresh V2 echo over the EXISTING session and
//  routes it addressed (Tier-2); the minter opens it through the REAL
//  `receive` → openInbound → burn-gate path and creates its Peer/Conversation
//  row — the exact minter-blank field failure, healed. The negative pins the
//  no-regression rule: the re-echo path emits NO events on the redeemer's own
//  coordinator (in particular no `.learnedNostrIdentity` — an unauthenticated,
//  replayable invite must never update our stored npub for the minter).
//

import XCTest
import SwiftData
import os
@testable import Beacon

@MainActor
final class NostrReliabilityTests: XCTestCase {

    // MARK: - F1: acceptance retry ladder (pure)

    func testAcceptanceOutcomeLadder() {
        // Any accept settles, regardless of attempt.
        XCTAssertEqual(NostrTransport.acceptanceOutcome(accepted: 1, attempt: 1, maxAttempts: 3), .settled)
        XCTAssertEqual(NostrTransport.acceptanceOutcome(accepted: 2, attempt: 3, maxAttempts: 3), .settled)
        // Zero accepts retries below the cap...
        XCTAssertEqual(NostrTransport.acceptanceOutcome(accepted: 0, attempt: 1, maxAttempts: 3), .retry)
        XCTAssertEqual(NostrTransport.acceptanceOutcome(accepted: 0, attempt: 2, maxAttempts: 3), .retry)
        // ...and gives up AT the cap — never silently, never early.
        XCTAssertEqual(NostrTransport.acceptanceOutcome(accepted: 0, attempt: 3, maxAttempts: 3), .giveUp)
        XCTAssertEqual(NostrTransport.acceptanceOutcome(accepted: 0, attempt: 4, maxAttempts: 3), .giveUp)
    }

    // MARK: - F2: ledger probe is read-only

    func testLedgerContainsDoesNotMutate() {
        var ledger = ProcessedEventLedger(capacity: 4)
        XCTAssertFalse(ledger.contains("a"))
        XCTAssertFalse(ledger.contains("a"))          // still absent — no insert
        XCTAssertEqual(ledger.count, 0)
        XCTAssertFalse(ledger.containsOrInsert("a"))  // first sight records
        XCTAssertTrue(ledger.contains("a"))
        XCTAssertEqual(ledger.count, 1)
    }

    // MARK: - F3: re-echo completes a blank minter, end to end

    private let inviteID = Data((0..<16).map { UInt8($0) })
    private let redeemerNpub = Data((40..<72).map { UInt8($0) })

    func testResendInviteEchoCompletesBlankMinter() async throws {
        // MINTER side: real coordinator + real inbox over an in-memory store,
        // with a burn gate that admits this invite id (fresh-invite case).
        let minterStore = SignalSessionStore()
        let minterCoord = FirstContactCoordinator(store: minterStore,
                                                  transport: BLEMeshTransport())
        let redeemer = FakeInviteRedeemer()
        await minterCoord.setInviteRedeemer(redeemer)
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Peer.self, Conversation.self, Message.self,
                                           configurations: config)
        let inbox = MessageInbox(modelContext: container.mainContext,
                                 coordinator: minterCoord,
                                 router: MessageRouter(transports: []),
                                 isVerified: { _ in true })
        let runTask = Task { await inbox.run() }
        defer { runTask.cancel() }

        // REDEEMER side: session with the minter ALREADY established (the
        // long-paired state the early-return protects), BLE failing so the
        // echo takes the addressed Tier-2 rail, captured by the fake.
        let redeemerStore = SignalSessionStore()
        let minterBundle = try minterStore.localPrekeyBundle()
        _ = try redeemerStore.establishSession(from: minterBundle)
        let redeemerCoord = FirstContactCoordinator(store: redeemerStore,
                                                    transport: BLEMeshTransport())
        await redeemerCoord.setNostrPublicKey(redeemerNpub)
        let wire = CapturingAddressedTransport()
        await redeemerCoord.setRouter(MessageRouter(transports: [FailingBLETransport(), wire]))

        try await redeemerCoord.resendInviteEcho(bundle: minterBundle,
                                                 inviteID: inviteID,
                                                 nostrRecipient: Data(repeating: 7, count: 32))

        // The echo left addressed to the minter's npub...
        let published = wire.published
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published.first?.recipient, Data(repeating: 7, count: 32))

        // ...and, fed through the minter's REAL receive path, burns the id and
        // creates the row that was blank in the field.
        await minterCoord.receive(published[0].envelope)
        let redeemerRaw = minterStore.rawPublicKey(of: redeemerStore.localIdentity)
        try await waitUntil("minter row created with redeemer npub") {
            try self.fetchPeer(redeemerRaw, in: container.mainContext)?.nostrPubkey == self.redeemerNpub
        }
        XCTAssertEqual(redeemer.redeemedIDs, [inviteID])
        let row = try XCTUnwrap(try fetchPeer(redeemerRaw, in: container.mainContext))
        XCTAssertFalse(row.conversations.isEmpty, "handleEstablished must create the conversation")
    }

    // MARK: - F3 negative: re-echo emits nothing on the redeemer's coordinator

    func testResendInviteEchoEmitsNoRedeemerSideEvents() async throws {
        let minterStore = SignalSessionStore()
        let minterBundle = try minterStore.localPrekeyBundle()
        let redeemerStore = SignalSessionStore()
        _ = try redeemerStore.establishSession(from: minterBundle)
        let redeemerCoord = FirstContactCoordinator(store: redeemerStore,
                                                    transport: BLEMeshTransport())
        await redeemerCoord.setNostrPublicKey(redeemerNpub)
        let wire = CapturingAddressedTransport()
        await redeemerCoord.setRouter(MessageRouter(transports: [FailingBLETransport(), wire]))

        let collected = OSAllocatedUnfairLock(initialState: 0)
        let collector = Task {
            for await _ in redeemerCoord.events {
                collected.withLock { $0 += 1 }
            }
        }
        defer { collector.cancel() }

        try await redeemerCoord.resendInviteEcho(bundle: minterBundle,
                                                 inviteID: inviteID,
                                                 nostrRecipient: Data(repeating: 7, count: 32))
        try await Task.sleep(nanoseconds: 300_000_000)

        // No .established, no .learnedNostrIdentity — the unauthenticated
        // invite payload must never mutate the redeemer's own rows.
        XCTAssertEqual(collected.withLock { $0 }, 0)
        XCTAssertEqual(wire.published.count, 1)   // but the echo DID go out
    }

    // MARK: - Helpers

    private func fetchPeer(_ key: Data, in context: ModelContext) throws -> Peer? {
        let descriptor = FetchDescriptor<Peer>(
            predicate: #Predicate { $0.publicKeyData == key }
        )
        return try context.fetch(descriptor).first
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 5,
                           condition: () throws -> Bool) async rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for: \(label)")
    }
}

// MARK: - Test doubles

/// Burn gate stand-in: admits every echo and records the ids it burned.
private final class FakeInviteRedeemer: InviteRedeeming, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [Data]())
    var redeemedIDs: [Data] { lock.withLock { $0 } }
    func redeemEcho(inviteID: Data, redeemerIdentity: Data) async throws -> Bool {
        lock.withLock { $0.append(inviteID) }
        return true
    }
}

/// BLE that always misses, so routeOut takes the Tier-2 addressed rail.
private final class FailingBLETransport: MeshTransport, @unchecked Sendable {
    let kind: TransportKind = .ble
    let incoming: AsyncStream<(link: UUID, envelope: Envelope)>
    private let cont: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation
    init() {
        var c: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation!
        self.incoming = AsyncStream { c = $0 }
        self.cont = c
    }
    func start() async throws {}
    func stop() { cont.finish() }
    func send(_ envelope: Envelope) async throws { throw TransportError.noReachablePeers }
    func relay(_ envelope: Envelope, excludingLinks: Set<UUID>) async {}
}

/// Addressed (Nostr-like) transport that captures every published envelope so
/// the test can replay it into the far side's real receive path.
private final class CapturingAddressedTransport: MeshTransport, AddressedTransport, @unchecked Sendable {
    let kind: TransportKind = .internet
    let incoming: AsyncStream<(link: UUID, envelope: Envelope)>
    private let cont: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation
    private let record = OSAllocatedUnfairLock(initialState: [(envelope: Envelope, recipient: Data)]())
    var published: [(envelope: Envelope, recipient: Data)] { record.withLock { $0 } }
    init() {
        var c: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation!
        self.incoming = AsyncStream { c = $0 }
        self.cont = c
    }
    func start() async throws {}
    func stop() { cont.finish() }
    func send(_ envelope: Envelope) async throws { throw NostrTransportError.sendRequiresRecipient }
    func relay(_ envelope: Envelope, excludingLinks: Set<UUID>) async {}
    func publish(_ envelope: Envelope, to recipient: Data) async throws {
        record.withLock { $0.append((envelope, recipient)) }
    }
}
