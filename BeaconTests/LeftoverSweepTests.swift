//
//  LeftoverSweepTests.swift
//  BeaconTests
//
//  Pins the pre-onboarding leftover sweep: with the identity gone, every
//  sealed store and its Keychain DEK, the session DEK and snapshot file, the
//  Nostr secret, the SwiftData store and device residue must be gone before a
//  new identity's first boot — or `loadOrCreate` hands them to it. Every step
//  runs even when one fails, and every error is reported.
//
//  Real stores and REAL Keychain items under throwaway services; SwiftData and
//  residue are recording doubles so the test never touches real app state.
//

import XCTest
import CryptoKit
@testable import Beacon

final class LeftoverSweepTests: XCTestCase {

    private final class Recorder: @unchecked Sendable {
        var ran: [String] = []
    }
    private struct Step: Wipeable {
        let name: String
        let recorder: Recorder
        var fails = false
        struct Boom: Error {}
        func wipe() async throws {
            recorder.ran.append(name)
            if fails { throw Boom() }
        }
    }

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("leftover-sweep.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func throwawayServices() -> LeftoverSweep.Services {
        let u = UUID().uuidString
        var s = LeftoverSweep.Services(sessionKey: "test.sweep.session.\(u)",
                                       nostrIdentity: "test.sweep.nostr.\(u)")
        s.contactAllowlist = "test.sweep.allow.\(u)"
        s.pendingInvites = "test.sweep.pending.\(u)"
        s.blockedContacts = "test.sweep.blocked.\(u)"
        s.eventLedger = "test.sweep.ledger.\(u)"
        let all = [s.sessionKey, s.contactAllowlist, s.pendingInvites, s.blockedContacts, s.eventLedger]
        addTeardownBlock {
            for svc in all { try? SessionStoreKey.destroy(service: svc) }
            try? NostrSecretStore.destroy(service: s.nostrIdentity)
        }
        return s
    }

    private func bytes(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { Data($0) } }

    /// Seed a previous identity's leftovers: every store saved under its real
    /// Keychain DEK, a session snapshot, and a Nostr secret.
    func testSweepRemovesEveryLeftoverAndEveryKey() async throws {
        let dir = try makeDir()
        let svc = throwawayServices()

        let allowKey = try SessionStoreKey.loadOrCreate(service: svc.contactAllowlist)
        var allow = ContactAllowlist()
        allow.enroll(identity: Data(repeating: 9, count: 32), at: 1, verified: true)
        try ContactAllowlistStore(directory: dir, dek: allowKey, keychainService: svc.contactAllowlist).save(allow)

        let pendKey = try SessionStoreKey.loadOrCreate(service: svc.pendingInvites)
        var pend = PendingInvites(); pend.register(id: Data(repeating: 1, count: 16), expiresAt: 9_999_999_999_999)
        try PendingInvitesStore(directory: dir, dek: pendKey, keychainService: svc.pendingInvites).save(pend)

        let blockKey = try SessionStoreKey.loadOrCreate(service: svc.blockedContacts)
        try BlockedContactsStore(directory: dir, dek: blockKey, keychainService: svc.blockedContacts)
            .save([BlockedContact(rawKey: Data(repeating: 2, count: 32), blockedAt: 1, petname: nil, wasVerified: false)])

        let ledgerKey = try SessionStoreKey.loadOrCreate(service: svc.eventLedger)
        var ledger = ProcessedEventLedger(); _ = ledger.containsOrInsert(String(repeating: "a", count: 64))
        try ProcessedEventLedgerStore(directory: dir, dek: ledgerKey, keychainService: svc.eventLedger).save(ledger)

        let sessionKey = try SessionStoreKey.loadOrCreate(service: svc.sessionKey)
        _ = try SignalSessionStore(appIdentity: IdentityKeypair.generate(), directory: dir, dek: sessionKey)
        let snapshot = dir.appendingPathComponent(PersistentBeaconStore.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path), "precondition: snapshot written")

        let nostr = try NostrIdentity.loadOrCreate(service: svc.nostrIdentity)

        let rec = Recorder()
        let sweep = try LeftoverSweep.standard(storeDirectory: dir, services: svc,
                                               swiftData: Step(name: "swiftData", recorder: rec),
                                               residue: Step(name: "residue", recorder: rec))
        let errors = await sweep.run()

        XCTAssertTrue(errors.isEmpty, "a clean sweep reports nothing: \(errors)")
        XCTAssertEqual(rec.ran, ["swiftData", "residue"])
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(left, [], "every store file and the snapshot must be gone")
        // Every key destroyed: loadOrCreate now mints a DIFFERENT one.
        XCTAssertNotEqual(bytes(try SessionStoreKey.loadOrCreate(service: svc.contactAllowlist)), bytes(allowKey))
        XCTAssertNotEqual(bytes(try SessionStoreKey.loadOrCreate(service: svc.pendingInvites)), bytes(pendKey))
        XCTAssertNotEqual(bytes(try SessionStoreKey.loadOrCreate(service: svc.blockedContacts)), bytes(blockKey))
        XCTAssertNotEqual(bytes(try SessionStoreKey.loadOrCreate(service: svc.eventLedger)), bytes(ledgerKey))
        XCTAssertNotEqual(bytes(try SessionStoreKey.loadOrCreate(service: svc.sessionKey)), bytes(sessionKey))
        XCTAssertNotEqual(try NostrIdentity.loadOrCreate(service: svc.nostrIdentity).publicKeyBytes,
                          nostr.publicKeyBytes, "the old Nostr secret must not be reused")
    }

    func testFreshInstallSweepIsCleanNoOp() async throws {
        let dir = try makeDir()
        let rec = Recorder()
        let sweep = try LeftoverSweep.standard(storeDirectory: dir, services: throwawayServices(),
                                               swiftData: Step(name: "swiftData", recorder: rec),
                                               residue: Step(name: "residue", recorder: rec))
        let errors = await sweep.run()
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testEveryStepRunsAndEveryErrorIsReported() async throws {
        let rec = Recorder()
        let sweep = LeftoverSweep(steps: [
            Step(name: "a", recorder: rec, fails: true),
            Step(name: "b", recorder: rec),
            Step(name: "c", recorder: rec, fails: true),
        ])
        let errors = await sweep.run()
        XCTAssertEqual(rec.ran, ["a", "b", "c"], "a failure must not stop the rest")
        XCTAssertEqual(errors.count, 2)
    }
}
