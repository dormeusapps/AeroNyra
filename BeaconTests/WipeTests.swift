//
//  WipeTests.swift
//  BeaconTests
//
//  Verifies the crypto-erase coordinator (Security/Wipe/EmergencyWipe).
//
//  Runs on the simulator: identity + vault use `.deviceUnlockOnly` and no
//  Secure Enclave wrapper (nil). The properties under test are behavioral —
//  that a full wipe erases identity AND vault, that it's idempotent, and
//  (the important ones) that a failing step does NOT halt the rest, and that
//  the optional session/additional hooks actually fire.
//

import XCTest
@testable import Beacon

final class WipeTests: XCTestCase {

    // MARK: Test doubles

    /// A session store that only records whether it was asked to wipe. The
    /// unused protocol methods are never reached by EmergencyWipe.
    private final class MockSessionStore: SecureSessionStore, @unchecked Sendable {
        private(set) var deleteAllCalled = false
        let localIdentity: PublicIdentity

        init() { localIdentity = IdentityKeypair.generate().publicIdentity }

        func localPrekeyBundle() throws -> PrekeyBundle {
            throw SecureSessionError.notEstablished
        }
        func establishSession(from bundle: PrekeyBundle) throws -> SecureSession {
            throw SecureSessionError.notEstablished
        }
        func session(with peer: PublicIdentity) throws -> SecureSession {
            throw SecureSessionError.notEstablished
        }
        func hasSession(with peer: PublicIdentity) -> Bool { false }
        func deleteSession(with peer: PublicIdentity) throws {}
        func deleteAllSessions() throws { deleteAllCalled = true }
    }

    /// A wipe step that always throws — to prove best-effort continuation.
    private struct FailingStep: Wipeable {
        struct Boom: Error {}
        func wipe() async throws { throw Boom() }
    }

    /// A wipe step that records whether it ran.
    private final class RecordingStep: Wipeable, @unchecked Sendable {
        private(set) var ran = false
        func wipe() async throws { ran = true }
    }

    // MARK: Helpers

    private func makeIdentityStore() -> IdentityStore {
        let service = "test.wipe.id.\(UUID().uuidString)"
        let store = IdentityStore(service: service, protection: .deviceUnlockOnly)
        addTeardownBlock { try? store.delete() }
        return store
    }

    private func makeVault() -> MessageVault {
        let service = "test.wipe.vault.\(UUID().uuidString)"
        let vault = MessageVault(service: service, protection: .deviceUnlockOnly)
        addTeardownBlock { try? await vault.destroy() }
        return vault
    }

    private func assertThrowsAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ handler: (Error) -> Void = { _ in }
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected an error but none was thrown", file: file, line: line)
        } catch {
            handler(error)
        }
    }

    // MARK: Full erasure

    func testWipeErasesIdentityAndVault() async throws {
        let idStore = makeIdentityStore()
        let vault = makeVault()
        _ = try idStore.loadOrCreate()          // provision identity
        try await vault.provisionIfNeeded()     // provision vault

        // Sanity: both exist beforehand.
        XCTAssertNoThrow(try idStore.load())
        let provisionedBefore = try await vault.isProvisioned
        XCTAssertTrue(provisionedBefore)

        let wipe = EmergencyWipe(identityStore: idStore, vault: vault)
        let errors = await wipe.perform()
        XCTAssertTrue(errors.isEmpty)

        // Identity item is gone (no ghost left behind).
        XCTAssertThrowsError(try idStore.load()) {
            XCTAssertEqual($0 as? IdentityError, .notFound)
        }
        // Vault DEK is gone.
        let provisionedAfter = try await vault.isProvisioned
        XCTAssertFalse(provisionedAfter)
    }

    // MARK: Idempotency

    func testWipeIsIdempotent() async throws {
        let idStore = makeIdentityStore()
        let vault = makeVault()
        _ = try idStore.loadOrCreate()
        try await vault.provisionIfNeeded()

        let wipe = EmergencyWipe(identityStore: idStore, vault: vault)
        let first = await wipe.perform()
        let second = await wipe.perform()

        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)   // wiping already-wiped state is clean
    }

    func testWipeOnEmptyStateIsClean() async throws {
        // Nothing provisioned — wipe should still complete with no errors.
        let wipe = EmergencyWipe(identityStore: makeIdentityStore(),
                                 vault: makeVault())
        let errors = await wipe.perform()
        XCTAssertTrue(errors.isEmpty)
    }

    // MARK: Best-effort continuation

    func testFailingStepDoesNotPreventCoreErasure() async throws {
        let idStore = makeIdentityStore()
        let vault = makeVault()
        _ = try idStore.loadOrCreate()
        try await vault.provisionIfNeeded()

        let recording = RecordingStep()
        // Failing step is ordered BEFORE the recording step: if a thrown error
        // halted the sequence, `recording` would never run.
        let wipe = EmergencyWipe(identityStore: idStore, vault: vault,
                                 additionalSteps: [FailingStep(), recording])
        let errors = await wipe.perform()

        // Core erasures still happened despite the failure.
        XCTAssertThrowsError(try idStore.load()) {
            XCTAssertEqual($0 as? IdentityError, .notFound)
        }
        let provisioned = try await vault.isProvisioned
        XCTAssertFalse(provisioned)

        // The later step still ran...
        XCTAssertTrue(recording.ran)
        // ...and the failure was reported, not swallowed.
        XCTAssertTrue(errors.contains { $0 is FailingStep.Boom })
    }

    func testPerformStrictThrowsOnPartialFailure() async throws {
        let wipe = EmergencyWipe(identityStore: makeIdentityStore(),
                                 vault: makeVault(),
                                 additionalSteps: [FailingStep()])
        await assertThrowsAsync(try await wipe.performStrict()) { error in
            guard case EmergencyWipe.WipeError.incomplete(let errs) = error else {
                return XCTFail("expected .incomplete, got \(error)")
            }
            XCTAssertEqual(errs.count, 1)
        }
    }

    // MARK: Hooks fire

    func testSessionStoreIsWiped() async throws {
        let sessions = MockSessionStore()
        let wipe = EmergencyWipe(identityStore: makeIdentityStore(),
                                 vault: makeVault(),
                                 sessionStore: sessions)
        _ = await wipe.perform()
        XCTAssertTrue(sessions.deleteAllCalled)
    }

    func testAdditionalStepsRun() async throws {
        let step = RecordingStep()
        let wipe = EmergencyWipe(identityStore: makeIdentityStore(),
                                 vault: makeVault(),
                                 additionalSteps: [step])
        _ = await wipe.perform()
        XCTAssertTrue(step.ran)
    }

    // MARK: No vault (SwiftData-message posture)

    /// With no vault wired (the post-SwiftData default), the vault step is
    /// skipped but the rest of the sequence must still run in full: identity is
    /// erased, the session hook fires, and additional steps run. This is the
    /// shape the composition root uses now — messages are erased via an
    /// `additionalSteps` Wipeable, not the vault (see §3.7/§3.8).
    func testWipeWithoutVaultStillErasesEverythingElse() async throws {
        let idStore = makeIdentityStore()
        _ = try idStore.loadOrCreate()          // provision identity
        XCTAssertNoThrow(try idStore.load())    // sanity: exists beforehand

        let sessions = MockSessionStore()
        let step = RecordingStep()

        // No vault argument at all — exercises the `vault: nil` default and the
        // `if let vault` skip in perform().
        let wipe = EmergencyWipe(identityStore: idStore,
                                 sessionStore: sessions,
                                 additionalSteps: [step])
        let errors = await wipe.perform()

        // Clean wipe: skipping the vault must not manufacture an error.
        XCTAssertTrue(errors.isEmpty)

        // Identity (step 3) still erased — no ghost.
        XCTAssertThrowsError(try idStore.load()) {
            XCTAssertEqual($0 as? IdentityError, .notFound)
        }
        // Session hook (step 2) still fired.
        XCTAssertTrue(sessions.deleteAllCalled)
        // Additional step (step 5) still ran.
        XCTAssertTrue(step.ran)
    }
}
