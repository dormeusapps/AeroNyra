//
//  RemoveContactSessionTests.swift
//  BeaconTests
//
//  Pins that Remove Contact (`PairingService.revoke`) deletes the libsignal
//  session AFTER the revoke is saved, and that a failed delete THROWS (a
//  surviving session is reused by a same-key re-pair: an old-ratchet message
//  still opens). Also pins the deliberate contrast: Block KEEPS the session so
//  unblock resumes on the same ratchet.
//
//  Real stores, persistent session store in its own temp dir (chmod-able);
//  session presence read back from DISK via a fresh store.
//

import XCTest
import CryptoKit
@testable import Beacon

@MainActor
final class RemoveContactSessionTests: XCTestCase {

    private struct NoopGates: ReconnectEnrolling {
        func addReconnectContact(rawIdentity: Data) async {}
        func removeReconnectContact(rawIdentity: Data) async {}
        func addVerifiedContact(rawIdentity: Data) async {}
        func removeVerifiedContact(rawIdentity: Data) async {}
    }

    private struct Harness {
        let pairing: PairingService
        let enrollment: EnrollmentService
        let sessionDir: URL
        let sessionDEK: SymmetricKey
        let ourIdentity: IdentityKeypair
        let contact: Data
        let contactPeer: PublicIdentity
    }

    private func makeDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remove-contact.\(tag).\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private func makeHarness(verified: Bool) async throws -> Harness {
        let sessionDir = try makeDir("session")
        let storesDir = try makeDir("stores")
        let sessionDEK = SymmetricKey(size: .bits256)
        let ourIdentity = IdentityKeypair.generate()
        let sessionStore = try SignalSessionStore(appIdentity: ourIdentity,
                                                  directory: sessionDir, dek: sessionDEK)
        let other = SignalSessionStore()
        let toUs = try other.establishSession(from: try sessionStore.localPrekeyBundle())
        let opened = try sessionStore.openInbound(try toUs.seal(Data("hi".utf8)))
        let contact = sessionStore.rawPublicKey(of: opened.peer)

        let enrollment = EnrollmentService(
            store: try ContactAllowlistStore(directory: storesDir, dek: SymmetricKey(size: .bits256),
                                             keychainService: "test.rc.a.\(UUID().uuidString)"),
            pendingStore: try PendingInvitesStore(directory: storesDir, dek: SymmetricKey(size: .bits256),
                                                  keychainService: "test.rc.p.\(UUID().uuidString)"),
            coordinator: NoopGates())
        try await enrollment.enroll(identity: contact, verified: verified)
        let blocked = try BlockedContactsStore(directory: storesDir, dek: SymmetricKey(size: .bits256),
                                               keychainService: "test.rc.b.\(UUID().uuidString)")
        let pairing = PairingService(
            sessionStore: sessionStore,
            coordinator: FirstContactCoordinator(store: sessionStore, transport: BLEMeshTransport()),
            enrollment: enrollment, ourNostrPublicKey: nil, blockedStore: blocked)
        return Harness(pairing: pairing, enrollment: enrollment, sessionDir: sessionDir,
                       sessionDEK: sessionDEK, ourIdentity: ourIdentity,
                       contact: contact, contactPeer: opened.peer)
    }

    private func sessionOnDisk(_ h: Harness) throws -> Bool {
        try SignalSessionStore(appIdentity: h.ourIdentity, directory: h.sessionDir, dek: h.sessionDEK)
            .hasSession(with: h.contactPeer)
    }

    func testRemoveContactDeletesSessionFromDisk() async throws {
        let h = try await makeHarness(verified: true)
        XCTAssertTrue(try sessionOnDisk(h), "precondition")

        try await h.pairing.revoke(h.contact)

        XCTAssertFalse(h.enrollment.contains(h.contact))
        XCTAssertFalse(try sessionOnDisk(h), "Remove Contact must delete the session")
    }

    func testRemoveContactSessionDeleteFailureThrowsAndRetryRemovesIt() async throws {
        let h = try await makeHarness(verified: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: h.sessionDir.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.sessionDir.path)
        }

        var threw = false
        do { try await h.pairing.revoke(h.contact) } catch { threw = true }
        XCTAssertTrue(threw, "a failed session delete must THROW")
        XCTAssertFalse(h.enrollment.contains(h.contact), "the revoke itself was saved first")
        XCTAssertTrue(try sessionOnDisk(h))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.sessionDir.path)
        try await h.pairing.revoke(h.contact)
        XCTAssertFalse(try sessionOnDisk(h), "the retry must remove it")
    }

    func testBlockKeepsSessionByDesign() async throws {
        let h = try await makeHarness(verified: true)

        try await h.pairing.block(rawKey: h.contact, petname: nil)

        XCTAssertFalse(h.enrollment.contains(h.contact))
        XCTAssertTrue(try sessionOnDisk(h), "Block keeps the session so unblock resumes")
    }
}
