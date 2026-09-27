//
//  SASMismatchDiscardTests.swift
//  BeaconTests
//
//  Pins `PairingService.discardMismatchedPairing` — the SAS "Doesn't match"
//  service call (CONTACT_MODEL §4.2 step 5). ORDER under test:
//    refuse malformed / VERIFIED → cancelAllInvites (sync) → revoke →
//    deleteSession (THROWS) → repaint.
//
//  Real stores over throwaway temp dirs — allowlist, invite ledger and the
//  PERSISTENT session store each in their OWN directory, so a test can make
//  exactly one of them unwritable (chmod) to force that step's save to fail.
//  Session presence is always read back from DISK (a fresh store over the same
//  file), because `deleteSession` clears the in-memory copy before its write.
//
//  The during-revoke echo test holds `revoke`'s live-gate removal on a
//  continuation (no sleeps) and redeems an invite that was open before the
//  discard: it must enroll nobody, which only holds because the invites are
//  cancelled BEFORE revoke's first suspension.
//

import XCTest
import CryptoKit
@testable import Beacon

@MainActor
final class SASMismatchDiscardTests: XCTestCase {

    // MARK: Live-gate double (can hold one removal)

    private actor HoldableGates: ReconnectEnrolling {
        private var holdNextRemove = false
        private var held: CheckedContinuation<Void, Never>?
        private var entered = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?

        func armRemoveHold() { holdNextRemove = true; entered = false }

        func addReconnectContact(rawIdentity: Data) async {}
        func addVerifiedContact(rawIdentity: Data) async {}
        func removeVerifiedContact(rawIdentity: Data) async {}
        func removeReconnectContact(rawIdentity: Data) async {
            guard holdNextRemove else { return }
            holdNextRemove = false
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                held = c
                entered = true
                enteredWaiter?.resume()
                enteredWaiter = nil
            }
        }
        func removeEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiter = $0 }
        }
        func release() { held?.resume(); held = nil }
    }

    // MARK: Harness

    private struct Harness {
        let pairing: PairingService
        let enrollment: EnrollmentService
        let gates: HoldableGates
        let allowlistDir: URL
        let pendingDir: URL
        let sessionDir: URL
        let allowlistDEK: SymmetricKey
        let pendingDEK: SymmetricKey
        let sessionDEK: SymmetricKey
        let ourIdentity: IdentityKeypair
        let blockedStore: BlockedContactsStore
        /// An unverified contact with a REAL session on disk.
        let contact: Data
        let contactPeer: PublicIdentity
    }

    private func makeDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sas-discard.\(tag).\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    /// Make `dir` unwritable; restored in tearDown whatever happens.
    private func makeReadOnly(_ dir: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        }
    }

    private func makeWritable(_ dir: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
    }

    private func makeHarness(contactVerified: Bool = false,
                             initialBlocked: [BlockedContact] = []) async throws -> Harness {
        let allowlistDir = try makeDir("allowlist")
        let pendingDir = try makeDir("pending")
        let sessionDir = try makeDir("session")
        let blockedDir = try makeDir("blocked")
        let allowlistDEK = SymmetricKey(size: .bits256)
        let pendingDEK = SymmetricKey(size: .bits256)
        let sessionDEK = SymmetricKey(size: .bits256)

        let ourIdentity = IdentityKeypair.generate()
        let sessionStore = try SignalSessionStore(appIdentity: ourIdentity,
                                                  directory: sessionDir, dek: sessionDEK)

        // A real session with the contact: they establish from our bundle and
        // send a prekey message; we open it (our side of the session is saved).
        let other = SignalSessionStore()
        let toUs = try other.establishSession(from: try sessionStore.localPrekeyBundle())
        let first = try toUs.seal(Data("hello".utf8))
        let opened = try sessionStore.openInbound(first)
        let contact = sessionStore.rawPublicKey(of: opened.peer)

        let gates = HoldableGates()
        let enrollment = EnrollmentService(
            store: try ContactAllowlistStore(directory: allowlistDir, dek: allowlistDEK,
                                             keychainService: "test.sas.a.\(UUID().uuidString)"),
            pendingStore: try PendingInvitesStore(directory: pendingDir, dek: pendingDEK,
                                                  keychainService: "test.sas.p.\(UUID().uuidString)"),
            coordinator: gates)
        try await enrollment.enroll(identity: contact, verified: contactVerified)

        let blockedStore = try BlockedContactsStore(directory: blockedDir, dek: SymmetricKey(size: .bits256),
                                                    keychainService: "test.sas.b.\(UUID().uuidString)")
        if !initialBlocked.isEmpty { try blockedStore.save(initialBlocked) }

        let coordinator = FirstContactCoordinator(store: sessionStore, transport: BLEMeshTransport())
        let pairing = PairingService(sessionStore: sessionStore, coordinator: coordinator,
                                     enrollment: enrollment, ourNostrPublicKey: nil,
                                     blockedStore: blockedStore, initialBlocked: initialBlocked)
        return Harness(pairing: pairing, enrollment: enrollment, gates: gates,
                       allowlistDir: allowlistDir, pendingDir: pendingDir, sessionDir: sessionDir,
                       allowlistDEK: allowlistDEK, pendingDEK: pendingDEK, sessionDEK: sessionDEK,
                       ourIdentity: ourIdentity, blockedStore: blockedStore,
                       contact: contact, contactPeer: opened.peer)
    }

    private func payload() -> PairingPayload {
        PairingPayload(bundle: PrekeyBundle(data: Data([0xDE, 0xAD])), nostrPublicKey: nil)
    }

    // Disk read-backs.
    private func sessionOnDisk(_ h: Harness) throws -> Bool {
        try SignalSessionStore(appIdentity: h.ourIdentity, directory: h.sessionDir, dek: h.sessionDEK)
            .hasSession(with: h.contactPeer)
    }
    private func allowlistOnDisk(_ h: Harness) throws -> ContactAllowlist {
        try ContactAllowlistStore(directory: h.allowlistDir, dek: h.allowlistDEK,
                                  keychainService: "test.sas.read.\(UUID().uuidString)").load()
    }
    private func pendingOnDisk(_ h: Harness) throws -> PendingInvites {
        try PendingInvitesStore(directory: h.pendingDir, dek: h.pendingDEK,
                                keychainService: "test.sas.read.p.\(UUID().uuidString)").load()
    }

    // MARK: 1 — the whole discard

    func testDiscardUnverifiedRemovesContactInvitesAndSession() async throws {
        let h = try await makeHarness()
        _ = try await h.enrollment.mintInvite(payload: payload())
        XCTAssertTrue(try sessionOnDisk(h), "precondition: a real session on disk")

        try await h.pairing.discardMismatchedPairing(h.contact)

        XCTAssertFalse(h.enrollment.contains(h.contact))
        XCTAssertFalse(h.pairing.isVerified(h.contact))
        XCTAssertFalse(try allowlistOnDisk(h).contains(identity: h.contact))
        XCTAssertEqual(h.enrollment.pendingInviteCount, 0)
        XCTAssertEqual(try pendingOnDisk(h).count, 0)
        XCTAssertFalse(try sessionOnDisk(h), "the session must be gone from disk")
    }

    // MARK: 2 — a VERIFIED contact is refused, nothing changes

    func testDiscardRefusesVerifiedContactAndChangesNothing() async throws {
        let h = try await makeHarness(contactVerified: true)
        _ = try await h.enrollment.mintInvite(payload: payload())

        do {
            try await h.pairing.discardMismatchedPairing(h.contact)
            XCTFail("a verified contact must be refused")
        } catch PairingService.DiscardError.refusedVerified {}

        XCTAssertTrue(h.enrollment.contains(h.contact))
        XCTAssertTrue(h.pairing.isVerified(h.contact))
        XCTAssertEqual(h.enrollment.pendingInviteCount, 1, "invites untouched")
        XCTAssertTrue(try sessionOnDisk(h), "session untouched")
    }

    // MARK: 3 — revoke's save fails: the session survives (trust first)

    func testRevokeFailureStopsBeforeSessionDelete() async throws {
        let h = try await makeHarness()
        try makeReadOnly(h.allowlistDir)

        do {
            try await h.pairing.discardMismatchedPairing(h.contact)
            XCTFail("revoke's save must fail on a read-only directory")
        } catch EnrollmentService.EnrollmentError.persistFailed {}

        XCTAssertTrue(h.enrollment.contains(h.contact), "still enrolled: revoke did not adopt")
        XCTAssertTrue(try sessionOnDisk(h), "the session must survive a failed revoke")
    }

    // MARK: 4 — session delete fails: throws; a retry removes it

    func testSessionDeleteFailureThrowsAndRetryRemovesIt() async throws {
        let h = try await makeHarness()
        try makeReadOnly(h.sessionDir)

        var threw = false
        do { try await h.pairing.discardMismatchedPairing(h.contact) } catch { threw = true }
        XCTAssertTrue(threw, "a failed session delete must THROW, not be swallowed")
        XCTAssertFalse(h.enrollment.contains(h.contact), "revoke already happened")
        XCTAssertTrue(try sessionOnDisk(h), "the session is still on disk after the failure")

        try makeWritable(h.sessionDir)
        try await h.pairing.discardMismatchedPairing(h.contact)
        XCTAssertFalse(try sessionOnDisk(h), "the retry must remove the session from disk")
    }

    // MARK: 5 — an echo for an invite open before the discard enrolls nobody

    func testEchoForPreviouslyOpenInviteDuringAndAfterDiscardEnrollsNobody() async throws {
        let h = try await makeHarness()
        let invite = try await h.enrollment.mintInvite(payload: payload())

        await h.gates.armRemoveHold()
        let discard = Task { try await h.pairing.discardMismatchedPairing(h.contact) }
        await h.gates.removeEntered()          // revoke adopted, suspended in its removal

        // DURING the revoke: the same key tries to come back through the old invite.
        let during = try await h.enrollment.redeemEcho(inviteID: invite.id, redeemerIdentity: h.contact)
        XCTAssertFalse(during, "the invite must already be cancelled while revoke is suspended")
        XCTAssertFalse(h.enrollment.contains(h.contact))

        await h.gates.release()
        try await discard.value

        // AFTER the discard: still nothing.
        let after = try await h.enrollment.redeemEcho(inviteID: invite.id, redeemerIdentity: h.contact)
        XCTAssertFalse(after)
        XCTAssertFalse(h.enrollment.contains(h.contact))
        XCTAssertFalse(try allowlistOnDisk(h).contains(identity: h.contact))
    }

    // MARK: 6 — never touches the blocked list

    func testDiscardLeavesBlockedListUntouched() async throws {
        var other = [UInt8](repeating: 0, count: 32); _ = SecRandomCopyBytes(kSecRandomDefault, 32, &other)
        let entry = BlockedContact(rawKey: Data(other), blockedAt: 1, petname: "x", wasVerified: false)
        let h = try await makeHarness(initialBlocked: [entry])

        try await h.pairing.discardMismatchedPairing(h.contact)

        XCTAssertEqual(h.pairing.blockedContacts, [entry])
        XCTAssertEqual(try h.blockedStore.load(), [entry])
        XCTAssertFalse(h.pairing.isBlocked(h.contact), "discard must not block")
    }

    // MARK: 7 — not enrolled: no throw, allowlist unchanged

    func testDiscardOfUnenrolledKeyChangesNoContact() async throws {
        let h = try await makeHarness()
        var raw = [UInt8](repeating: 0, count: 32); _ = SecRandomCopyBytes(kSecRandomDefault, 32, &raw)
        let before = try allowlistOnDisk(h)

        try await h.pairing.discardMismatchedPairing(Data(raw))

        XCTAssertEqual(try allowlistOnDisk(h), before)
        XCTAssertTrue(h.enrollment.contains(h.contact), "the real contact is untouched")
        XCTAssertTrue(try sessionOnDisk(h), "the real contact's session is untouched")
    }

    // MARK: 8 — malformed key: refused before any change

    func testDiscardRefusesMalformedKey() async throws {
        let h = try await makeHarness()
        _ = try await h.enrollment.mintInvite(payload: payload())

        do {
            try await h.pairing.discardMismatchedPairing(Data(repeating: 1, count: 31))
            XCTFail("a 31-byte key must be refused")
        } catch PairingService.DiscardError.invalidKey {}

        XCTAssertEqual(h.enrollment.pendingInviteCount, 1, "nothing cancelled")
        XCTAssertTrue(h.enrollment.contains(h.contact))
    }
}
