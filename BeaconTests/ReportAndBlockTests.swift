//
//  ReportAndBlockTests.swift
//  BeaconTests
//
//  Pins `PairingService.reportAndBlock` (Guideline 1.2 report step): a sent
//  report blocks the contact FOR GOOD — the denylist entry is flagged
//  `reported` on disk, enrollment is revoked, the libsignal session is
//  deleted from disk, the contact's QR and invites are refused, and
//  `unblock` refuses them. A plain block never downgrades a reported entry,
//  and a denylist file written before the flag existed still loads.
//

import XCTest
import CryptoKit
@testable import Beacon

@MainActor
final class ReportAndBlockTests: XCTestCase {

    private struct Harness {
        let pairing: PairingService
        let enrollment: EnrollmentService
        let sessionStore: SignalSessionStore
        let blockedStore: BlockedContactsStore
        let identity: IdentityKeypair
        let sessionDir: URL
        let sessionDEK: SymmetricKey
        let contact: Data
        let contactStore: SignalSessionStore
    }

    private func makeDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("report-block.\(tag).\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeHarness(contactVerified: Bool = true) async throws -> Harness {
        let dir = try makeDir("stores")
        let identity = IdentityKeypair.generate()
        let sessionDir = try makeDir("session")
        let sessionDEK = SymmetricKey(size: .bits256)
        let sessionStore = try SignalSessionStore(appIdentity: identity, directory: sessionDir, dek: sessionDEK)
        let contactStore = SignalSessionStore()
        let toUs = try contactStore.establishSession(from: try sessionStore.localPrekeyBundle())
        let opened = try sessionStore.openInbound(try toUs.seal(Data("hello".utf8)))
        let contact = sessionStore.rawPublicKey(of: opened.peer)

        let coordinator = FirstContactCoordinator(store: sessionStore, transport: BLEMeshTransport())
        let enrollment = EnrollmentService(
            store: try ContactAllowlistStore(directory: dir, dek: SymmetricKey(size: .bits256),
                                             keychainService: "test.rb.a.\(UUID().uuidString)"),
            pendingStore: try PendingInvitesStore(directory: dir, dek: SymmetricKey(size: .bits256),
                                                  keychainService: "test.rb.p.\(UUID().uuidString)"),
            coordinator: coordinator)
        try await enrollment.enroll(identity: contact, verified: contactVerified)
        let blockedStore = try BlockedContactsStore(directory: try makeDir("blocked"),
                                                    dek: SymmetricKey(size: .bits256),
                                                    keychainService: "test.rb.b.\(UUID().uuidString)")
        let pairing = PairingService(sessionStore: sessionStore, coordinator: coordinator,
                                     enrollment: enrollment, ourNostrPublicKey: nil,
                                     blockedStore: blockedStore, initialBlocked: [])
        return Harness(pairing: pairing, enrollment: enrollment, sessionStore: sessionStore,
                       blockedStore: blockedStore, identity: identity, sessionDir: sessionDir,
                       sessionDEK: sessionDEK, contact: contact, contactStore: contactStore)
    }

    /// Session presence read back from DISK (a fresh store over the same file).
    private func sessionOnDisk(_ h: Harness) throws -> Bool {
        let fresh = try SignalSessionStore(appIdentity: h.identity, directory: h.sessionDir, dek: h.sessionDEK)
        return fresh.hasSession(with: fresh.peerIdentity(fromRawKey: h.contact))
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - reportAndBlock

    func testReportAndBlockFlagsTheEntryRevokesAndDeletesTheSession() async throws {
        let h = try await makeHarness()
        XCTAssertTrue(try sessionOnDisk(h), "precondition: a session on disk")
        try await h.pairing.reportAndBlock(rawKey: h.contact, petname: "Sam")

        let onDisk = try h.blockedStore.load()
        XCTAssertEqual(onDisk.map(\.rawKey), [h.contact])
        XCTAssertEqual(onDisk.first?.reported, true, "flagged reported on disk")
        XCTAssertEqual(onDisk.first?.petname, "Sam")
        XCTAssertTrue(h.pairing.isBlocked(h.contact))
        XCTAssertTrue(h.pairing.isReported(h.contact))
        XCTAssertFalse(h.enrollment.contains(h.contact), "enrollment revoked")
        XCTAssertFalse(try sessionOnDisk(h), "the session is deleted from disk")
    }

    func testReportingAnAlreadyBlockedContactKeepsItsBlockDate() async throws {
        let h = try await makeHarness()
        try await h.pairing.block(rawKey: h.contact, petname: "Sam")
        let blockedAt = try XCTUnwrap(h.blockedStore.load().first?.blockedAt)
        try await h.pairing.reportAndBlock(rawKey: h.contact, petname: "Sam")
        let entry = try XCTUnwrap(h.blockedStore.load().first)
        XCTAssertEqual(entry.blockedAt, blockedAt)
        XCTAssertTrue(entry.wasVerified, "the verified snapshot from the first block is kept")
        XCTAssertTrue(entry.reported)
        XCTAssertFalse(try sessionOnDisk(h))
    }

    // MARK: - never pair again

    func testAReportedContactsQRAndInviteAreRefused() async throws {
        let h = try await makeHarness(contactVerified: false)
        try await h.pairing.reportAndBlock(rawKey: h.contact, petname: nil)

        let qr = "aeronyra://pair/" + base64URL(PairingPayload(bundle: try h.contactStore.localPrekeyBundle(),
                                                               nostrPublicKey: nil).wireData())
        do {
            try await h.pairing.pairFromScanned(qr)
            XCTFail("a reported contact's QR must be refused")
        } catch PairingService.PairError.reported {}

        let invite = Invite.mint(payload: PairingPayload(bundle: try h.contactStore.localPrekeyBundle(),
                                                         nostrPublicKey: nil),
                                 now: Int64(Date().timeIntervalSince1970 * 1000))
        do {
            _ = try await h.pairing.redeemInvite(PairingService.encodeInvite(invite))
            XCTFail("a reported contact's invite must be refused")
        } catch PairingService.PairError.reported {}
        XCTAssertFalse(h.enrollment.contains(h.contact))
    }

    func testUnblockRefusesAReportedContact() async throws {
        let h = try await makeHarness()
        try await h.pairing.reportAndBlock(rawKey: h.contact, petname: nil)
        do {
            try await h.pairing.unblock(rawKey: h.contact)
            XCTFail("a reported contact can never be unblocked")
        } catch PairingService.BlockError.reported {}
        XCTAssertEqual(try h.blockedStore.load().map(\.reported), [true], "entry untouched on disk")
        XCTAssertTrue(h.pairing.isBlocked(h.contact))
        XCTAssertFalse(h.enrollment.contains(h.contact), "not re-enrolled")
    }

    func testAPlainBlockNeverDowngradesAReportedEntry() async throws {
        let h = try await makeHarness()
        try await h.pairing.reportAndBlock(rawKey: h.contact, petname: "Sam")
        try await h.pairing.block(rawKey: h.contact, petname: "Sam")
        XCTAssertEqual(try h.blockedStore.load().map(\.reported), [true])
        XCTAssertTrue(h.pairing.isReported(h.contact))
    }

    func testPlainBlockStillKeepsTheSessionAndUnblocks() async throws {
        let h = try await makeHarness()
        try await h.pairing.block(rawKey: h.contact, petname: nil)
        XCTAssertFalse(h.pairing.isReported(h.contact))
        XCTAssertTrue(try sessionOnDisk(h))
        try await h.pairing.unblock(rawKey: h.contact)
        XCTAssertTrue(h.enrollment.contains(h.contact))
    }

    // MARK: - file compatibility

    func testAnEntryWrittenBeforeTheFlagExistedLoadsAsNotReported() throws {
        let json = #"[{"rawKey":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=","blockedAt":1,"petname":"Sam","wasVerified":true}]"#
        let decoded = try JSONDecoder().decode([BlockedContact].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertFalse(decoded[0].reported)
        XCTAssertEqual(decoded[0].petname, "Sam")
    }

    func testTheFlagRoundTripsThroughTheStore() async throws {
        let h = try await makeHarness()
        let entry = BlockedContact(rawKey: h.contact, blockedAt: 5, petname: nil, wasVerified: false, reported: true)
        try h.blockedStore.save([entry])
        XCTAssertEqual(try h.blockedStore.load(), [entry])
    }
}
