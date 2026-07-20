//
//  NostrAnnounceInvariantTests.swift
//  BeaconTests
//
//  NOSTR_KEY_PROPAGATION invariant (the load-bearing negative):
//
//    A contact's `Peer.nostrPubkey` is updated ONLY when the update arrives
//    inside a sealed message that opens through `store.openInbound` under the
//    established pairwise session attributing to that contact's identity key.
//    An event that does not open under the contact's session NEVER mutates the
//    row.
//
//  Exercised END-TO-END through the REAL inbound path: an `Envelope` is handed
//  to `FirstContactCoordinator.receive` (the router's `EnvelopeReceiver` entry),
//  which alone can open it; a surviving `.learnedNostrIdentity` event is
//  persisted by the REAL `MessageInbox.run()` loop into a real (in-memory)
//  SwiftData store. No layer is stubbed between the ciphertext and the row.
//
//  ORDERING SENTINEL: coordinator events are yielded synchronously inside each
//  sequential `receive` call and consumed in order by the single `run()` loop,
//  so once a LATER legitimate announce is visible in the store, any earlier
//  injected event would already have been processed. "Sentinel landed + row
//  unchanged" is therefore a real negative, not a timing accident.
//

import XCTest
import SwiftData
@testable import Beacon

@MainActor
final class NostrAnnounceInvariantTests: XCTestCase {

    // Distinct 32-byte x-only keys (content is arbitrary; only identity matters).
    private let npub1    = Data((0..<32).map  { UInt8($0) })
    private let npub2    = Data((50..<82).map { UInt8($0) })
    private let evilNpub = Data((200..<232).map { UInt8($0) })

    // MARK: - Harness (the real receive path, unstubbed)

    private struct Harness {
        let bobStore: SignalSessionStore        // the device under test ("us")
        let coordinator: FirstContactCoordinator
        /// Retained for the harness's lifetime — `mainContext` does not keep its
        /// container alive, and a deallocated container traps inside SwiftData.
        let container: ModelContainer
        let context: ModelContext
        let runTask: Task<Void, Never>
    }

    private func makeHarness() throws -> Harness {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Peer.self, Conversation.self, Message.self,
            configurations: config
        )
        let bobStore = SignalSessionStore()
        let coordinator = FirstContactCoordinator(store: bobStore,
                                                  transport: BLEMeshTransport())
        let inbox = MessageInbox(modelContext: container.mainContext,
                                 coordinator: coordinator,
                                 router: MessageRouter(transports: []),
                                 isVerified: { _ in true })
        let runTask = Task { await inbox.run() }
        return Harness(bobStore: bobStore, coordinator: coordinator,
                       container: container, context: container.mainContext,
                       runTask: runTask)
    }

    /// The exact plaintext `announceNostrIdentity` seals: the tagged, padded
    /// `.nostrIdentity` payload.
    private func announcePlaintext(_ npub: Data) -> Data {
        MessagePayload.nostrIdentityAnnounce(pubkey: npub).sealedPlaintext()
    }

    private func fetchPeer(_ key: Data, in context: ModelContext) throws -> Peer? {
        let descriptor = FetchDescriptor<Peer>(
            predicate: #Predicate { $0.publicKeyData == key }
        )
        return try context.fetch(descriptor).first
    }

    /// Poll (yielding) until `condition` holds or fail the test. The inbox's
    /// run() loop shares the main actor, so each sleep lets it drain.
    private func waitUntil(_ label: String, timeout: TimeInterval = 5,
                           condition: () throws -> Bool) async rethrows {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for: \(label)")
    }

    // MARK: - Accept (inside the session) + last-wins

    func testAnnounceInsideSessionUpdatesRow_andLastAnnouncementWins() async throws {
        let h = try makeHarness()
        defer { h.runTask.cancel() }

        let alice = SignalSessionStore()
        let aliceToBob = try alice.establishSession(from: try h.bobStore.localPrekeyBundle())
        let aliceRaw = h.bobStore.rawPublicKey(of: alice.localIdentity)

        // Announce npub1, sealed by alice's established session with bob.
        let ct1 = try aliceToBob.seal(announcePlaintext(npub1))
        await h.coordinator.receive(Envelope(ciphertext: ct1))
        try await waitUntil("row created with npub1") {
            try self.fetchPeer(aliceRaw, in: h.context)?.nostrPubkey == self.npub1
        }

        // Last-announcement-wins: a later announce with a NEW key replaces it.
        let ct2 = try aliceToBob.seal(announcePlaintext(npub2))
        await h.coordinator.receive(Envelope(ciphertext: ct2))
        try await waitUntil("row updated to npub2") {
            try self.fetchPeer(aliceRaw, in: h.context)?.nostrPubkey == self.npub2
        }
    }

    // MARK: - Same-key re-announce is a pure no-op

    func testSameKeyReannounceIsNoOp() async throws {
        let h = try makeHarness()
        defer { h.runTask.cancel() }

        let alice = SignalSessionStore()
        let aliceToBob = try alice.establishSession(from: try h.bobStore.localPrekeyBundle())
        let aliceRaw = h.bobStore.rawPublicKey(of: alice.localIdentity)

        await h.coordinator.receive(Envelope(ciphertext: try aliceToBob.seal(announcePlaintext(npub1))))
        try await waitUntil("row created with npub1") {
            try self.fetchPeer(aliceRaw, in: h.context)?.nostrPubkey == self.npub1
        }
        let lastSeenAfterFirst = try XCTUnwrap(try fetchPeer(aliceRaw, in: h.context)).lastSeen

        // Give the clock room so a (wrong) second write would move lastSeen.
        try await Task.sleep(nanoseconds: 300_000_000)

        // Re-announce the SAME key, then a sentinel from a second peer. Once the
        // sentinel's row is visible, the same-key event has been processed.
        await h.coordinator.receive(Envelope(ciphertext: try aliceToBob.seal(announcePlaintext(npub1))))
        let carol = SignalSessionStore()
        let carolToBob = try carol.establishSession(from: try h.bobStore.localPrekeyBundle())
        let carolRaw = h.bobStore.rawPublicKey(of: carol.localIdentity)
        await h.coordinator.receive(Envelope(ciphertext: try carolToBob.seal(announcePlaintext(npub2))))
        try await waitUntil("sentinel (carol) row visible") {
            try self.fetchPeer(carolRaw, in: h.context)?.nostrPubkey == self.npub2
        }

        // No-op proven: key unchanged AND lastSeen untouched (the handler's
        // same-key guard returns before either write — MessageInbox.swift:208).
        let aliceRow = try XCTUnwrap(try fetchPeer(aliceRaw, in: h.context))
        XCTAssertEqual(aliceRow.nostrPubkey, npub1)
        XCTAssertEqual(aliceRow.lastSeen, lastSeenAfterFirst)
    }

    // MARK: - Rejection (the invariant): outside the session, nothing mutates

    func testAnnounceOutsideSessionDoesNotMutateAnyRow() async throws {
        let h = try makeHarness()
        defer { h.runTask.cancel() }

        // A pre-existing contact row with a known npub — the attack target.
        let targetRaw = Data((150..<182).map { UInt8($0) })
        h.context.insert(Peer(publicKeyData: targetRaw, nostrPubkey: npub1))
        try h.context.save()

        // (a) A REAL sealed announce — but sealed to a DIFFERENT identity:
        // mallory establishes with carol (not bob) and seals `evilNpub`. Bob's
        // `openInbound` cannot open it, so `receive` drops it at the
        // open-failed catch and no event is emitted.
        let mallory = SignalSessionStore()
        let carol = SignalSessionStore()
        let malloryToCarol = try mallory.establishSession(from: try carol.localPrekeyBundle())
        let evilSealed = try malloryToCarol.seal(announcePlaintext(evilNpub))
        await h.coordinator.receive(Envelope(ciphertext: evilSealed))

        // (b) Raw junk that is not a ciphertext at all.
        await h.coordinator.receive(Envelope(ciphertext: Data(repeating: 0x00, count: 64)))

        // Sentinel: a legitimate announce STILL lands afterwards — the pipeline
        // is alive, and by stream ordering (a)/(b) were already processed.
        let dave = SignalSessionStore()
        let daveToBob = try dave.establishSession(from: try h.bobStore.localPrekeyBundle())
        let daveRaw = h.bobStore.rawPublicKey(of: dave.localIdentity)
        await h.coordinator.receive(Envelope(ciphertext: try daveToBob.seal(announcePlaintext(npub2))))
        try await waitUntil("sentinel (dave) row visible") {
            try self.fetchPeer(daveRaw, in: h.context)?.nostrPubkey == self.npub2
        }

        // The invariant, as real negatives: the target row is byte-identical,
        // and the injected key reached NO row in the store.
        XCTAssertEqual(try XCTUnwrap(try fetchPeer(targetRaw, in: h.context)).nostrPubkey, npub1)
        let allPeers = try h.context.fetch(FetchDescriptor<Peer>())
        XCTAssertFalse(allPeers.contains { $0.nostrPubkey == evilNpub },
                       "an announce that never opened through the session must not reach any row")
    }
}
