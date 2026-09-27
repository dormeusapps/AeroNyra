//
//  EnrollmentLiveGateRaceTests.swift
//  BeaconTests
//
//  LIVE GATES FOLLOW THE ALLOWLIST. `enroll` and `markVerified` adopt the new
//  allowlist and THEN await the coordinator's live-gate adds; a `revoke` can run
//  on the main actor during that suspension, and its removals can reach the
//  coordinator BEFORE the adds (nothing orders the two hops). Without the
//  post-checks the add lands last and a REVOKED key sits in the live reconnect /
//  verified gate until relaunch — fail-open.
//
//  Each test forces that exact order with a coordinator double that HOLDS one
//  add on a continuation: the add is entered, the revoke runs to completion
//  (its removes hit an empty set), then the add is released and inserts. The
//  post-check must then remove the key. No sleeps: every wait is a continuation.
//
//  The control test pins that the post-checks are SILENT on the normal path.
//

import XCTest
import CryptoKit
@testable import Beacon

@MainActor
final class EnrollmentLiveGateRaceTests: XCTestCase {

    /// A coordinator double with REAL live sets, able to hold one add until
    /// released. Reentrant by construction (actor), so removes run while an add
    /// is suspended on its continuation — exactly the production interleave.
    private actor GatedLiveGates: ReconnectEnrolling {
        enum Gate { case none, reconnectAdd, verifiedAdd }

        private var gate: Gate = .none
        private(set) var reconnect = Set<Data>()
        private(set) var verified = Set<Data>()
        private(set) var removeCalls = 0

        private var held: CheckedContinuation<Void, Never>?
        private var entered = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?

        /// Hold the NEXT add of this kind.
        func arm(_ g: Gate) { gate = g; entered = false }

        func addReconnectContact(rawIdentity: Data) async {
            if gate == .reconnectAdd { gate = .none; await hold() }
            reconnect.insert(rawIdentity)
        }
        func addVerifiedContact(rawIdentity: Data) async {
            if gate == .verifiedAdd { gate = .none; await hold() }
            verified.insert(rawIdentity)
        }
        func removeReconnectContact(rawIdentity: Data) async {
            removeCalls += 1
            reconnect.remove(rawIdentity)
        }
        func removeVerifiedContact(rawIdentity: Data) async {
            removeCalls += 1
            verified.remove(rawIdentity)
        }

        private func hold() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                held = c
                entered = true
                enteredWaiter?.resume()
                enteredWaiter = nil
            }
        }

        /// Returns once the armed add has been entered (and is held).
        func addEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiter = $0 }
        }

        /// Let the held add finish (it inserts into its live set).
        func release() {
            held?.resume()
            held = nil
        }
    }

    // MARK: Fixtures

    private let dek = SymmetricKey(size: .bits256)
    private let fixedNow: @Sendable () -> Int64 = { 1_700_000_000_000 }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("livegate.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeStore(in dir: URL) throws -> ContactAllowlistStore {
        try ContactAllowlistStore(directory: dir, dek: dek,
                                  keychainService: "test.livegate.\(UUID().uuidString)")
    }

    private func makeService(in dir: URL, gates: GatedLiveGates) throws -> EnrollmentService {
        let pending = try PendingInvitesStore(directory: dir, dek: SymmetricKey(size: .bits256),
                                              keychainService: "test.livegate.p.\(UUID().uuidString)")
        return EnrollmentService(store: try makeStore(in: dir), pendingStore: pending,
                                 coordinator: gates, nowMillis: fixedNow)
    }

    private func makeIdentity() -> Data {
        var b = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &b)
        return Data(b)
    }

    /// The allowlist as persisted (a fresh store over the same file + DEK).
    private func reloaded(_ dir: URL) throws -> ContactAllowlist {
        try makeStore(in: dir).load()
    }

    // MARK: 1 — enroll (unverified) vs revoke: reconnect gate

    func testEnrollRacingRevokeEndsWithKeyOutOfReconnectGate() async throws {
        let dir = try makeTempDirectory()
        let gates = GatedLiveGates()
        let svc = try makeService(in: dir, gates: gates)
        let k = makeIdentity()

        await gates.arm(.reconnectAdd)
        let enrollTask = Task { try await svc.enroll(identity: k, verified: false) }
        await gates.addEntered()                 // enroll adopted, its add is held
        try await svc.revoke(identity: k)        // removes run FIRST (set still empty)
        await gates.release()                    // the add lands LAST — the fail-open order
        try await enrollTask.value

        XCTAssertFalse(svc.contains(k))
        XCTAssertFalse(try reloaded(dir).contains(identity: k))
        let inReconnect = await gates.reconnect.contains(k)
        let inVerified = await gates.verified.contains(k)
        XCTAssertFalse(inReconnect, "a revoked key must not stay in the live reconnect gate")
        XCTAssertFalse(inVerified)
    }

    // MARK: 2 — QR enroll (verified) vs revoke: verified gate

    func testVerifiedEnrollRacingRevokeEndsWithKeyOutOfVerifiedGate() async throws {
        let dir = try makeTempDirectory()
        let gates = GatedLiveGates()
        let svc = try makeService(in: dir, gates: gates)
        let k = makeIdentity()

        await gates.arm(.verifiedAdd)
        let enrollTask = Task { try await svc.enroll(identity: k, verified: true) }
        await gates.addEntered()                 // reconnect add done, verified add held
        try await svc.revoke(identity: k)
        await gates.release()
        try await enrollTask.value

        XCTAssertFalse(svc.contains(k))
        XCTAssertFalse(try reloaded(dir).contains(identity: k))
        let inReconnect = await gates.reconnect.contains(k)
        let inVerified = await gates.verified.contains(k)
        XCTAssertFalse(inReconnect)
        XCTAssertFalse(inVerified, "a revoked key must not stay in the live VERIFIED gate")
    }

    // MARK: 3 — markVerified vs revoke: verified gate

    func testMarkVerifiedRacingRevokeEndsWithKeyOutOfVerifiedGate() async throws {
        let dir = try makeTempDirectory()
        let gates = GatedLiveGates()
        let svc = try makeService(in: dir, gates: gates)
        let k = makeIdentity()
        try await svc.enroll(identity: k, verified: false)   // no race

        await gates.arm(.verifiedAdd)
        let verifyTask = Task { try await svc.markVerified(identity: k) }
        await gates.addEntered()                 // verified adopted, its add is held
        try await svc.revoke(identity: k)
        await gates.release()
        try await verifyTask.value

        XCTAssertFalse(svc.contains(k))
        XCTAssertFalse(svc.isVerified(k))
        XCTAssertFalse(try reloaded(dir).contains(identity: k))
        let inReconnect = await gates.reconnect.contains(k)
        let inVerified = await gates.verified.contains(k)
        XCTAssertFalse(inReconnect)
        XCTAssertFalse(inVerified, "a revoked key must not stay in the live VERIFIED gate")
    }

    // MARK: 4 — control: no race, post-checks silent

    func testNoRaceEnrollAndVerifyIssueNoRemovals() async throws {
        let dir = try makeTempDirectory()
        let gates = GatedLiveGates()
        let svc = try makeService(in: dir, gates: gates)
        let k = makeIdentity()

        try await svc.enroll(identity: k, verified: false)
        try await svc.markVerified(identity: k)

        XCTAssertTrue(svc.contains(k))
        XCTAssertTrue(svc.isVerified(k))
        let inReconnect = await gates.reconnect.contains(k)
        let inVerified = await gates.verified.contains(k)
        let removes = await gates.removeCalls
        XCTAssertTrue(inReconnect)
        XCTAssertTrue(inVerified)
        XCTAssertEqual(removes, 0, "the post-checks must not fire on the normal path")
    }
}
