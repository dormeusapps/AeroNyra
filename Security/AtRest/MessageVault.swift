//
//  MessageVault.swift
//  Security/AtRest
//
//  THE AT-REST LAYER (defense in depth, orthogonal to the wire crypto).
//
//  The wire is protected by the Triple Ratchet (SecureSession). That does
//  NOTHING for a phone left unlocked on a table — that threat lives entirely
//  at rest and at the app boundary. This vault is the answer.
//
//  It manages a Data Encryption Key (DEK) used to encrypt message content
//  BEFORE it is written to the store. Three independent protections wrap that
//  key (HANDOFF §3.7):
//   1. The DEK is Enclave-wrapped (SecureEnclaveWrapper) — unextractable
//      off this device.
//   2. The wrapped DEK is stored under a Keychain access control requiring
//      USER PRESENCE (Face ID / Touch ID / passcode) to read — so the OS,
//      not just app logic, refuses to release it until the user authenticates
//      to the app. This is the app-lock that defends the unlocked-device case.
//   3. The DEK lives in memory ONLY while unlocked; `lock()` (called on
//      backgrounding) zeroizes it, forcing re-auth to reopen.
//
//  Beneath all of this, the store file itself should also carry iOS Data
//  Protection (NSFileProtectionComplete) — that is a separate OS-level layer
//  configured at the persistence layer, not here.
//
//  Destroying the DEK (and its Enclave key) crypto-erases the message store:
//  the emergency wipe (§3.7) calls `destroy()`.
//

import Foundation
import CryptoKit
import Security
import LocalAuthentication

// MARK: - Errors

public enum VaultError: Error, Equatable {
    /// An operation needing the DEK was attempted while locked.
    case locked
    /// No DEK has been provisioned yet (call `provisionIfNeeded` first).
    case notProvisioned
    /// User authentication failed or was cancelled at unlock.
    case authenticationFailed
    /// Building the SecAccessControl gate failed.
    case accessControlCreationFailed
    /// Enclave wrap/unwrap failed.
    case wrapping
    /// AEAD seal/open failed.
    case cryptographicFailure
    /// A Keychain operation failed.
    case keychain(OSStatus)
}

// MARK: - MessageVault

public actor MessageVault {

    /// How the wrapped DEK is gated in the Keychain.
    public enum Protection: Sendable {
        /// Production: requires user presence (biometric or device passcode)
        /// to read the DEK — the app-lock. Reading triggers the system prompt.
        case userPresence
        /// Tests / simulator: device-unlock only, no prompt.
        case deviceUnlockOnly
    }

    private static let dekByteCount = 32   // 256-bit

    /// Per-purpose KDF domain-separation label for Enclave wrapping. Distinct
    /// from the identity store's context so DEK-wrap and identity-wrap derive
    /// independent keys even when sharing one Enclave key.
    private static let kdfContext = Data("beacon.vault.dek.v1".utf8)

    private let service: String
    private let account = "vault.dek.v1"
    private let protection: Protection
    private let wrapper: SecureEnclaveWrapper?

    /// The Data Encryption Key. Present ONLY while unlocked; `lock()` clears it.
    /// CryptoKit zeroizes the backing store when the value is released.
    private var dek: SymmetricKey?

    /// - Parameters:
    ///   - service: stable bundle-scoped identifier for the Keychain item.
    ///   - protection: `.userPresence` in production, `.deviceUnlockOnly` for tests.
    ///   - wrapper: Enclave wrapper (nil on the simulator → raw storage).
    public init(service: String,
                protection: Protection = .userPresence,
                wrapper: SecureEnclaveWrapper? = nil) {
        self.service = service
        self.protection = protection
        self.wrapper = wrapper
    }

    // MARK: State

    public var isUnlocked: Bool { dek != nil }

    public var isProvisioned: Bool {
        get throws { try keychainItemExists() }
    }

    // MARK: Provisioning

    /// Create and store a fresh DEK if none exists yet. Idempotent and silent
    /// (provisioning does not prompt — only unlocking does). Returns `true`
    /// if a new DEK was created.
    @discardableResult
    public func provisionIfNeeded() throws -> Bool {
        if try keychainItemExists() { return false }

        // Fresh 256-bit DEK from the system CSPRNG. Fail gracefully rather than
        // crashing the process if the (effectively never-failing) call fails.
        var raw = [UInt8](repeating: 0, count: Self.dekByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, Self.dekByteCount, &raw)
        guard status == errSecSuccess else {
            Self.secureZero(&raw)
            throw VaultError.cryptographicFailure
        }
        var rawData = Data(raw)
        defer {
            rawData.resetBytes(in: 0..<rawData.count)   // best-effort (CoW)
            Self.secureZero(&raw)                        // memset_s — not elided
        }

        let payload = try wrapForStorage(rawData)
        try storeWrappedDEK(payload)
        return true
    }

    // MARK: Lock / Unlock

    /// Authenticate and load the DEK into memory.
    ///
    /// With `.userPresence` protection this presents the system biometric/
    /// passcode prompt via an `LAContext` (Apple's current recommendation over
    /// the legacy `kSecUseOperationPrompt`). `reason` is shown to the user.
    /// `reuseWindow` lets back-to-back unlocks within that many seconds skip a
    /// second prompt. Throws `.authenticationFailed` on cancel/failure, or
    /// `.notProvisioned` if no DEK exists.
    ///
    /// Note: this blocks until the user responds. It runs on the actor's
    /// executor (never the main thread), so the UI stays responsive.
    public func unlock(reason: String, reuseWindow: TimeInterval = 0) throws {
        let context = LAContext()
        context.localizedReason = reason
        if reuseWindow > 0 {
            context.touchIDAuthenticationAllowableReuseDuration = reuseWindow
        }

        guard let payload = try readWrappedDEK(reason: reason, context: context) else {
            throw VaultError.notProvisioned
        }
        var rawData = try unwrapFromStorage(payload)
        defer { rawData.resetBytes(in: 0..<rawData.count) }
        dek = SymmetricKey(data: rawData)
    }

    /// Drop the in-memory DEK. Call on app backgrounding (the auto-lock). The
    /// lifecycle wiring (UIApplication notifications) belongs in the app layer.
    public func lock() {
        dek = nil   // releasing the SymmetricKey zeroizes its backing store
    }

    // MARK: Encrypt / Decrypt

    /// Encrypt content for storage, binding it to associated data.
    ///
    /// `aad` should be a stable identifier for the record this ciphertext
    /// belongs to (message id, channel id, row id…). It is authenticated but
    /// NOT encrypted, and binds the ciphertext to its slot: a record swapped or
    /// reordered on disk will fail to open under its new `aad`, defeating
    /// substitution attacks against the store. Decrypt must pass the same `aad`.
    ///
    /// Throws `.locked` if the vault is locked.
    public func encrypt(_ plaintext: Data, aad: Data = Data()) throws -> Data {
        guard let dek else { throw VaultError.locked }
        do {
            return try ChaChaPoly.seal(plaintext,
                                       using: dek,
                                       authenticating: aad).combined
        } catch {
            throw VaultError.cryptographicFailure
        }
    }

    /// Decrypt stored content, authenticating against the same `aad` used to
    /// encrypt it. Throws `.locked` if locked, `.cryptographicFailure` if the
    /// `aad` doesn't match (wrong slot / tampering) or the data is corrupt.
    public func decrypt(_ ciphertext: Data, aad: Data = Data()) throws -> Data {
        guard let dek else { throw VaultError.locked }
        do {
            let box = try ChaChaPoly.SealedBox(combined: ciphertext)
            return try ChaChaPoly.open(box, using: dek, authenticating: aad)
        } catch {
            throw VaultError.cryptographicFailure
        }
    }

    // MARK: Destroy (crypto-erase)

    /// Destroy the DEK and its Enclave wrapping key. After this, all content
    /// encrypted with the DEK is permanently unrecoverable. Part of the
    /// emergency wipe (§3.7).
    ///
    /// Both halves are torn down even if one throws: the Enclave key is removed
    /// in a `defer` so a failure deleting the wrapped DEK can't strand it. The
    /// data is crypto-erased as soon as either the wrapped blob or the Enclave
    /// key is gone (one is useless without the other), but we destroy both so
    /// nothing stale is left behind.
    public func destroy() throws {
        lock()
        defer { try? wrapper?.deleteEnclaveKey() }
        try deleteWrappedDEK()
    }

    // TODO(§3.7 rotation): add `rotate()` that provisions a fresh DEK, re-wraps
    // it, and re-encrypts the store under the new key. Requires the persistence
    // layer to exist first. Until then, a DEK compromise is recoverable only by
    // `destroy()` + re-provision (which discards history).

    // MARK: - Secure zeroization

    /// Overwrite a byte buffer with zeros via `memset_s`, which the optimizer
    /// is not permitted to elide (unlike a plain loop over dead storage). This
    /// is best-effort for buffers we own; `SymmetricKey` remains the
    /// load-bearing scrub for the live key.
    private static func secureZero(_ bytes: inout [UInt8]) {
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                memset_s(base, raw.count, 0, raw.count)
            }
        }
    }

    // MARK: - Storage helpers

    private func wrapForStorage(_ raw: Data) throws -> Data {
        guard let wrapper else { return raw }   // simulator: raw under Data Protection
        do {
            return try wrapper.wrap(raw, context: Self.kdfContext).serialized()
        } catch {
            throw VaultError.wrapping
        }
    }

    private func unwrapFromStorage(_ stored: Data) throws -> Data {
        guard let wrapper else { return stored }
        do {
            return try wrapper.unwrap(try WrappedBlob(serialized: stored),
                                      context: Self.kdfContext)
        } catch {
            throw VaultError.wrapping
        }
    }

    // MARK: - Keychain

    private func keychainItemExists() throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   false,
            kSecMatchLimit as String:   kSecMatchLimitOne,
            // Avoid triggering the auth prompt just to check existence.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed:
            // InteractionNotAllowed means the item exists but needs auth — which
            // still tells us it exists.
            return true
        case errSecItemNotFound:
            return false
        default:
            throw VaultError.keychain(status)
        }
    }

    private func storeWrappedDEK(_ payload: Data) throws {
        var attributes: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String:          payload,
        ]
        switch protection {
        case .userPresence:
            attributes[kSecAttrAccessControl as String] = try makeAccessControl()
        case .deviceUnlockOnly:
            attributes[kSecAttrAccessible as String] =
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    private func readWrappedDEK(reason: String, context: LAContext) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne,
        ]
        if case .userPresence = protection {
            // Modern path: drive the prompt through an LAContext rather than the
            // legacy kSecUseOperationPrompt, enabling reuse windows and clean
            // cancellation.
            query[kSecUseAuthenticationContext as String] = context
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        case errSecUserCanceled, errSecAuthFailed:
            throw VaultError.authenticationFailed
        default:
            throw VaultError.keychain(status)
        }
    }

    private func deleteWrappedDEK() throws {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultError.keychain(status)
        }
    }

    private func makeAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.userPresence],   // biometric or device passcode — the app-lock
            &error
        ) else {
            throw VaultError.accessControlCreationFailed
        }
        return access
    }
}
