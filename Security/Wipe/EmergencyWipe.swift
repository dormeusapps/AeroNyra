//
//  EmergencyWipe.swift
//  Security/Wipe
//
//  CRYPTO-ERASE (HANDOFF §3.7).
//
//  "EMERGENCY WIPE (triple-tap): crypto-erase — destroy the keys so all stored
//   ciphertext becomes permanently unrecoverable. Instant."
//
//  This coordinator destroys every piece of secret-bearing key material in one
//  pass. Once the keys are gone, the ciphertext they protected (message store,
//  ratchet state, wrapped identity) is mathematically unrecoverable — there is
//  no slow "overwrite every row" step, which is what makes it instant.
//
//  Two properties are load-bearing and intentional:
//
//   • BEST-EFFORT. Every step runs even if an earlier one throws. A panic wipe
//     must never abort halfway and leave a secret behind because step 2 failed.
//     Failures are collected and reported, but only AFTER everything has been
//     attempted.
//
//   • NO GHOST. The identity Keychain item is deleted regardless of the Enclave
//     key's state. IdentityStore and MessageVault may share one Secure Enclave
//     wrapping key; destroying the vault destroys that key, which would leave
//     the identity item unloadable (its wrap can no longer be opened). If the
//     wipe did not also delete the identity item, you'd strand an item that
//     can't be read and that the app's normal flow never removes. So we delete
//     it explicitly. (This is the asymmetry the security review called out.)
//
//  After this runs, the app layer should route the user back to onboarding
//  (or terminate) — there is no identity left to operate with. That lifecycle
//  step belongs above this layer.
//

import Foundation

// MARK: - Wipeable

/// Anything that holds secret material and can be crypto-erased. Implementations
/// MUST be idempotent — wiping an already-wiped component must not throw.
///
/// Used for components added after this file (e.g. the message-DB store) so the
/// wipe can grow without editing the coordinator's core sequence.
public protocol Wipeable: Sendable {
    func wipe() async throws
}

// MARK: - EmergencyWipe

public struct EmergencyWipe {

    /// Raised by `performStrict()` when one or more steps failed. All steps were
    /// still attempted — this reports what didn't complete, it does not mean the
    /// wipe stopped early.
    public enum WipeError: Error {
        case incomplete([Error])
    }

    private let identityStore: IdentityStore
    private let vault: MessageVault
    private let sessionStore: SecureSessionStore?
    private let sharedEnclaveWrapper: SecureEnclaveWrapper?
    private let additionalSteps: [Wipeable]

    /// - Parameters:
    ///   - identityStore: the long-term identity store (its item is always deleted).
    ///   - vault: the at-rest message vault (DEK + its Enclave key destroyed).
    ///   - sessionStore: the secure-session store, when one exists (ratchet
    ///     state destroyed). Optional until the session adapter ships.
    ///   - sharedEnclaveWrapper: the Enclave wrapper shared by identity + vault,
    ///     deleted as a final safety net so the hardware-binding key is gone even
    ///     if no component above tore it down. Idempotent if already deleted.
    ///   - additionalSteps: any other secret-bearing components (message DB,
    ///     caches…) to erase.
    public init(identityStore: IdentityStore,
                vault: MessageVault,
                sessionStore: SecureSessionStore? = nil,
                sharedEnclaveWrapper: SecureEnclaveWrapper? = nil,
                additionalSteps: [Wipeable] = []) {
        self.identityStore = identityStore
        self.vault = vault
        self.sessionStore = sessionStore
        self.sharedEnclaveWrapper = sharedEnclaveWrapper
        self.additionalSteps = additionalSteps
    }

    /// Crypto-erase everything, best-effort. Returns the errors from any steps
    /// that failed; an empty array means a fully clean wipe. Every step is
    /// attempted regardless of earlier failures.
    @discardableResult
    public func perform() async -> [Error] {
        var errors: [Error] = []

        // 1. Vault: destroy the DEK (and, via its wrapper, the Enclave key).
        //    The message store at rest becomes immediately unreadable.
        do { try await vault.destroy() } catch { errors.append(error) }

        // 2. Sessions: destroy all ratchet/handshake state, if a store exists.
        if let sessionStore {
            do { try sessionStore.deleteAllSessions() } catch { errors.append(error) }
        }

        // 3. Identity: delete the Keychain item. Done unconditionally so no
        //    unloadable ghost survives the Enclave-key teardown above.
        do { try identityStore.delete() } catch { errors.append(error) }

        // 4. Shared Enclave key: safety-net teardown of the hardware-binding
        //    key. Idempotent — a no-op if step 1's wrapper already removed it.
        if let sharedEnclaveWrapper {
            do { try sharedEnclaveWrapper.deleteEnclaveKey() }
            catch { errors.append(error) }
        }

        // 5. Anything else holding secrets (message DB file, caches, …).
        for step in additionalSteps {
            do { try await step.wipe() } catch { errors.append(error) }
        }

        return errors
    }

    /// Throwing variant: attempts every step, then throws `WipeError.incomplete`
    /// if any failed. Use when the caller wants to surface a partial wipe.
    public func performStrict() async throws {
        let errors = await perform()
        if !errors.isEmpty { throw WipeError.incomplete(errors) }
    }
}
