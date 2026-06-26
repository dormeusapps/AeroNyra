//
//  VaultTests.swift
//  BeaconTests
//
//  Verifies the at-rest vault (Security/AtRest/MessageVault) without UI.
//
//  Runs on the simulator via `.deviceUnlockOnly` protection — no biometric
//  prompt, no Secure Enclave (wrapper nil → raw-under-Data-Protection path).
//  Each test uses a unique Keychain service and destroys it in teardown, so
//  runs never collide. The AEAD/round-trip/AAD/tamper assertions exercise the
//  same crypto that runs in production; only the Keychain gating differs.
//

import XCTest
@testable import Beacon

final class VaultTests: XCTestCase {

    // MARK: Helpers

    /// A fresh vault on a unique service, scrubbed in teardown.
    private func makeVault() -> MessageVault {
        let service = "test.vault.\(UUID().uuidString)"
        let vault = MessageVault(service: service, protection: .deviceUnlockOnly)
        addTeardownBlock { try? await vault.destroy() }
        return vault
    }

    /// A provisioned + unlocked vault, ready to encrypt/decrypt.
    private func makeUnlockedVault() async throws -> MessageVault {
        let vault = makeVault()
        try await vault.provisionIfNeeded()
        try await vault.unlock(reason: "unit test")
        return vault
    }

    /// async-friendly throwing assertion (XCTAssertThrowsError isn't async).
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

    // MARK: Provisioning

    func testProvisionIsIdempotent() async throws {
        let vault = makeVault()

        let createdFirst = try await vault.provisionIfNeeded()
        let createdSecond = try await vault.provisionIfNeeded()

        XCTAssertTrue(createdFirst)              // minted on first call
        XCTAssertFalse(createdSecond)            // not re-minted
        let provisioned = try await vault.isProvisioned
        XCTAssertTrue(provisioned)
    }

    func testNewVaultStartsUnprovisionedAndLocked() async throws {
        let vault = makeVault()
        let provisioned = try await vault.isProvisioned
        let unlocked = await vault.isUnlocked
        XCTAssertFalse(provisioned)
        XCTAssertFalse(unlocked)
    }

    // MARK: Lock state gating

    func testEncryptFailsBeforeUnlock() async throws {
        let vault = makeVault()
        try await vault.provisionIfNeeded()      // provisioned but still locked

        await assertThrowsAsync(try await vault.encrypt(Data("x".utf8))) {
            XCTAssertEqual($0 as? VaultError, .locked)
        }
    }

    func testLockClearsKey() async throws {
        let vault = try await makeUnlockedVault()
        let ct = try await vault.encrypt(Data("before lock".utf8))

        await vault.lock()

        let unlocked = await vault.isUnlocked
        XCTAssertFalse(unlocked)
        await assertThrowsAsync(try await vault.decrypt(ct)) {
            XCTAssertEqual($0 as? VaultError, .locked)
        }
    }

    func testUnlockWithoutProvisionThrows() async throws {
        let vault = makeVault()
        await assertThrowsAsync(try await vault.unlock(reason: "x")) {
            XCTAssertEqual($0 as? VaultError, .notProvisioned)
        }
    }

    // MARK: Round-trip

    func testEncryptDecryptRoundTrip() async throws {
        let vault = try await makeUnlockedVault()
        let plaintext = Data("hello mesh".utf8)

        let ciphertext = try await vault.encrypt(plaintext)
        let recovered = try await vault.decrypt(ciphertext)

        XCTAssertEqual(recovered, plaintext)
        XCTAssertNotEqual(ciphertext, plaintext)     // actually encrypted
    }

    func testNonceIsRandomizedPerEncryption() async throws {
        let vault = try await makeUnlockedVault()
        let plaintext = Data("same input".utf8)

        let a = try await vault.encrypt(plaintext)
        let b = try await vault.encrypt(plaintext)

        // Random nonce per seal => identical plaintext yields different ciphertext.
        XCTAssertNotEqual(a, b)
    }

    // MARK: AAD binding (the substitution-resistance the review flagged)

    func testAADRoundTrip() async throws {
        let vault = try await makeUnlockedVault()
        let plaintext = Data("bound to a row".utf8)
        let aad = Data("message-id:42".utf8)

        let ciphertext = try await vault.encrypt(plaintext, aad: aad)
        let recovered = try await vault.decrypt(ciphertext, aad: aad)

        XCTAssertEqual(recovered, plaintext)
    }

    func testWrongAADRejected() async throws {
        let vault = try await makeUnlockedVault()
        let ciphertext = try await vault.encrypt(Data("secret".utf8),
                                                 aad: Data("message-id:42".utf8))

        // A record moved into a different slot (different id) must NOT open.
        await assertThrowsAsync(
            try await vault.decrypt(ciphertext, aad: Data("message-id:99".utf8))
        ) {
            XCTAssertEqual($0 as? VaultError, .cryptographicFailure)
        }
    }

    func testMissingAADRejectedWhenBound() async throws {
        let vault = try await makeUnlockedVault()
        let ciphertext = try await vault.encrypt(Data("secret".utf8),
                                                 aad: Data("message-id:42".utf8))

        // Opening without the AAD it was bound to must fail.
        await assertThrowsAsync(try await vault.decrypt(ciphertext)) {
            XCTAssertEqual($0 as? VaultError, .cryptographicFailure)
        }
    }

    // MARK: Tamper rejection

    func testTamperedCiphertextRejected() async throws {
        let vault = try await makeUnlockedVault()
        var ciphertext = try await vault.encrypt(Data("integrity".utf8))

        // Flip the last byte (within the auth tag) — open must fail.
        ciphertext[ciphertext.count - 1] ^= 0xFF
        await assertThrowsAsync(try await vault.decrypt(ciphertext)) {
            XCTAssertEqual($0 as? VaultError, .cryptographicFailure)
        }
    }

    // MARK: Persistence across instances

    func testDEKPersistsAcrossVaultInstances() async throws {
        let service = "test.vault.\(UUID().uuidString)"

        let first = MessageVault(service: service, protection: .deviceUnlockOnly)
        addTeardownBlock { try? await first.destroy() }
        try await first.provisionIfNeeded()
        try await first.unlock(reason: "x")
        let ciphertext = try await first.encrypt(Data("persisted".utf8))

        // A separate instance bound to the same service must read the same DEK
        // and decrypt what the first one sealed.
        let second = MessageVault(service: service, protection: .deviceUnlockOnly)
        try await second.unlock(reason: "x")
        let recovered = try await second.decrypt(ciphertext)

        XCTAssertEqual(recovered, Data("persisted".utf8))
    }

    // MARK: Destroy (crypto-erase)

    func testDestroyRemovesDEK() async throws {
        let vault = makeVault()
        try await vault.provisionIfNeeded()

        try await vault.destroy()

        let provisioned = try await vault.isProvisioned
        XCTAssertFalse(provisioned)
        await assertThrowsAsync(try await vault.unlock(reason: "x")) {
            XCTAssertEqual($0 as? VaultError, .notProvisioned)
        }
    }

    func testDestroyIsIdempotent() async throws {
        let vault = makeVault()
        try await vault.provisionIfNeeded()

        // Destroying twice must not throw on the second pass.
        try await vault.destroy()
        try await vault.destroy()
    }
}
