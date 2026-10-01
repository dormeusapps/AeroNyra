//
//  BlockCharacterizationTests.swift
//  BeaconTests
//
//  Pins TODAY's Block (Guideline 1.2) before the report step changes it:
//   • `PairingService.block` saves the denylist entry to disk (with the
//     verified snapshot), revokes enrollment, and KEEPS the libsignal session;
//   • `unblock` re-enrolls with the snapshot's verified flag and removes the
//     entry from disk;
//   • a blocked identity's QR and invite are refused (`PairError.blocked`)
//     before any enroll;
//   • the coordinator's receive guard drops everything from a blocked sender.
//
//  Real stores over throwaway temp dirs (the SASMismatchDiscardTests shape).
//

import XCTest
import CryptoKit
import SwiftData
@testable import Beacon

@MainActor
final class BlockCharacterizationTests: XCTestCase {

    private struct Harness {
        let pairing: PairingService
        let enrollment: EnrollmentService
        let sessionStore: SignalSessionStore
        let blockedStore: BlockedContactsStore
        let coordinator: FirstContactCoordinator
        /// A contact with a REAL session in `sessionStore`.
        let contact: Data
        /// The contact's own store (it can mint QR payloads and invites).
        let contactStore: SignalSessionStore
    }

    private func makeDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("block-char.\(tag).\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeHarness(contactVerified: Bool) async throws -> Harness {
        let dir = try makeDir("stores")
        let sessionStore = try SignalSessionStore(appIdentity: IdentityKeypair.generate(),
                                                  directory: try makeDir("session"),
                                                  dek: SymmetricKey(size: .bits256))
        let contactStore = SignalSessionStore()
        let toUs = try contactStore.establishSession(from: try sessionStore.localPrekeyBundle())
        let opened = try sessionStore.openInbound(try toUs.seal(Data("hello".utf8)))
        let contact = sessionStore.rawPublicKey(of: opened.peer)

        let coordinator = FirstContactCoordinator(store: sessionStore, transport: BLEMeshTransport())
        let enrollment = EnrollmentService(
            store: try ContactAllowlistStore(directory: dir, dek: SymmetricKey(size: .bits256),
                                             keychainService: "test.bc.a.\(UUID().uuidString)"),
            pendingStore: try PendingInvitesStore(directory: dir, dek: SymmetricKey(size: .bits256),
                                                  keychainService: "test.bc.p.\(UUID().uuidString)"),
            coordinator: coordinator)
        try await enrollment.enroll(identity: contact, verified: contactVerified)
        let blockedStore = try BlockedContactsStore(directory: try makeDir("blocked"),
                                                    dek: SymmetricKey(size: .bits256),
                                                    keychainService: "test.bc.b.\(UUID().uuidString)")
        let pairing = PairingService(sessionStore: sessionStore, coordinator: coordinator,
                                     enrollment: enrollment, ourNostrPublicKey: nil,
                                     blockedStore: blockedStore, initialBlocked: [])
        return Harness(pairing: pairing, enrollment: enrollment, sessionStore: sessionStore,
                       blockedStore: blockedStore, coordinator: coordinator,
                       contact: contact, contactStore: contactStore)
    }

    /// Reads the stored session (`session(with:)` would hand back a new one).
    private func hasSession(_ h: Harness) -> Bool {
        h.sessionStore.hasSession(with: h.sessionStore.peerIdentity(fromRawKey: h.contact))
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - block / unblock

    func testBlockSavesTheEntryRevokesAndKeepsTheSession() async throws {
        let h = try await makeHarness(contactVerified: true)
        try await h.pairing.block(rawKey: h.contact, petname: "Sam")

        let onDisk = try h.blockedStore.load()
        XCTAssertEqual(onDisk.map(\.rawKey), [h.contact], "entry saved to disk")
        XCTAssertEqual(onDisk.first?.petname, "Sam")
        XCTAssertEqual(onDisk.first?.wasVerified, true, "verified snapshot taken")
        XCTAssertTrue(h.pairing.isBlocked(h.contact))
        XCTAssertFalse(h.enrollment.contains(h.contact), "enrollment revoked")
        XCTAssertFalse(h.pairing.isVerified(h.contact))
        XCTAssertTrue(hasSession(h), "plain block keeps the session so unblock resumes")
    }

    func testUnblockReEnrollsWithTheSnapshotAndRemovesTheEntry() async throws {
        let h = try await makeHarness(contactVerified: true)
        try await h.pairing.block(rawKey: h.contact, petname: nil)
        try await h.pairing.unblock(rawKey: h.contact)

        XCTAssertEqual(try h.blockedStore.load(), [], "entry removed from disk")
        XCTAssertFalse(h.pairing.isBlocked(h.contact))
        XCTAssertTrue(h.enrollment.contains(h.contact))
        XCTAssertTrue(h.pairing.isVerified(h.contact), "verified flag restored")
        XCTAssertTrue(hasSession(h))
    }

    // MARK: - pairing refused while blocked

    func testABlockedIdentitysQRIsRefused() async throws {
        let h = try await makeHarness(contactVerified: false)
        try await h.pairing.block(rawKey: h.contact, petname: nil)
        let payload = PairingPayload(bundle: try h.contactStore.localPrekeyBundle(), nostrPublicKey: nil)
        let qr = "aeronyra://pair/" + base64URL(payload.wireData())
        do {
            try await h.pairing.pairFromScanned(qr)
            XCTFail("a blocked identity's QR must be refused")
        } catch PairingService.PairError.blocked {
        }
        XCTAssertFalse(h.enrollment.contains(h.contact), "nothing enrolled")
    }

    func testABlockedIdentitysInviteIsRefused() async throws {
        let h = try await makeHarness(contactVerified: false)
        try await h.pairing.block(rawKey: h.contact, petname: nil)
        let invite = Invite.mint(payload: PairingPayload(bundle: try h.contactStore.localPrekeyBundle(),
                                                         nostrPublicKey: nil),
                                 now: Int64(Date().timeIntervalSince1970 * 1000))
        do {
            _ = try await h.pairing.redeemInvite(PairingService.encodeInvite(invite))
            XCTFail("a blocked identity's invite must be refused")
        } catch PairingService.PairError.blocked {
        }
        XCTAssertFalse(h.enrollment.contains(h.contact), "nothing enrolled")
    }

    // MARK: - receive guard

    func testTheReceiveGuardDropsEverythingFromABlockedSender() async throws {
        let container = try ModelContainer(for: Peer.self, Conversation.self, Message.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let us = SignalSessionStore()
        let coordinator = FirstContactCoordinator(store: us, transport: BLEMeshTransport())
        let inbox = MessageInbox(modelContext: container.mainContext, coordinator: coordinator,
                                 router: MessageRouter(transports: []), isVerified: { _ in true })
        let run = Task { await inbox.run() }
        defer { run.cancel() }

        let blocked = SignalSessionStore()
        let blockedRaw = us.rawPublicKey(of: blocked.localIdentity)
        let other = SignalSessionStore()
        let otherRaw = us.rawPublicKey(of: other.localIdentity)
        await coordinator.setBlockedIdentities([blockedRaw])

        let announce = MessagePayload.nostrIdentityAnnounce(pubkey: Data(repeating: 9, count: 32)).sealedPlaintext()
        let fromBlocked = try blocked.establishSession(from: try us.localPrekeyBundle())
        await coordinator.receive(Envelope(ciphertext: try fromBlocked.seal(announce)))
        // Sentinel: the same payload from a non-blocked sender lands. Events are
        // consumed in order, so once it is visible the blocked one was processed.
        let fromOther = try other.establishSession(from: try us.localPrekeyBundle())
        await coordinator.receive(Envelope(ciphertext: try fromOther.seal(announce)))

        func peer(_ key: Data) throws -> Peer? {
            try container.mainContext.fetch(FetchDescriptor<Peer>(predicate: #Predicate { $0.publicKeyData == key })).first
        }
        let deadline = Date().addingTimeInterval(5)
        while try peer(otherRaw) == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(try peer(otherRaw), "sentinel landed")
        XCTAssertNil(try peer(blockedRaw), "nothing from a blocked sender reaches the store")
    }
}
