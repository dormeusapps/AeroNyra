//
//  SecureEnclaveWrapper.swift
//  Security/Identity
//
//  Hardware binding for the identity blob.
//
//  HANDOFF §3.2: "wrap the at-rest key blob with a Secure Enclave P-256 key
//  (ECDH-derived wrapping key). Note: the Secure Enclave only holds P-256,
//  not Curve25519 — so the SE protects the blob, while the messaging keys
//  themselves stay Curve25519 for Noise. Result: the identity is unwrappable
//  only on THIS device's SE."
//
//  STEP 2 of 2. The Enclave holds a P-256 key-agreement key that never leaves
//  the silicon. We can't ECDH with a single key, so wrapping uses an ECIES
//  construction: generate an ephemeral P-256 keypair, ECDH it against the
//  Enclave's PUBLIC key to derive a symmetric key, seal the blob, and keep
//  `ephemeralPublic ‖ ciphertext`. Unwrapping runs the same ECDH from INSIDE
//  the Enclave (private key never extracted) — that step is what binds the
//  identity to this device.
//
//  Simulator note: the Secure Enclave does not exist on the simulator.
//  `isAvailable` is false there, and IdentityStore falls back to storing the
//  blob under Keychain Data Protection only — fine for development, but with
//  NO hardware binding. Hardware binding is a device-only guarantee.
//

import Foundation
import CryptoKit
import Security

// MARK: - Errors

public enum SecureEnclaveError: Error, Equatable {
    /// The Secure Enclave is unavailable (e.g. running on the simulator).
    case unavailable
    /// Generating the Enclave key failed.
    case keyGenerationFailed
    /// A stored wrapped blob was malformed.
    case malformedWrappedBlob
    /// ECDH / KDF / AEAD failed during wrap or unwrap.
    case cryptographicFailure
    /// Building the SecAccessControl gate failed.
    case accessControlCreationFailed
    /// A Keychain operation failed.
    case keychain(OSStatus)
}

// MARK: - WrappedBlob

/// The product of wrapping: the ephemeral public key needed to reconstruct the
/// shared secret, alongside the AEAD-sealed payload. None of it is secret —
/// without the Enclave's private key the ciphertext cannot be opened.
public struct WrappedBlob: Equatable, Sendable {

    /// Ephemeral P-256 key-agreement public key, raw (x‖y) = 64 bytes.
    public let ephemeralPublicKey: Data

    /// ChaChaPoly sealed box, combined form (nonce ‖ ciphertext ‖ tag).
    public let sealed: Data

    static let ephemeralKeyLength = 64

    /// Flat layout for storage: `ephemeralPublicKey(64) ‖ sealed(rest)`.
    public func serialized() -> Data {
        var d = Data(capacity: Self.ephemeralKeyLength + sealed.count)
        d.append(ephemeralPublicKey)
        d.append(sealed)
        return d
    }

    public init(ephemeralPublicKey: Data, sealed: Data) {
        self.ephemeralPublicKey = ephemeralPublicKey
        self.sealed = sealed
    }

    /// Minimum sealed size: ChaChaPoly nonce (12) + tag (16) = 28, even for an
    /// empty plaintext. Anything smaller is corruption, caught here rather than
    /// deeper in `ChaChaPoly.open`.
    static let minSealedLength = 28

    public init(serialized data: Data) throws {
        guard data.count >= Self.ephemeralKeyLength + Self.minSealedLength else {
            throw SecureEnclaveError.malformedWrappedBlob
        }
        self.ephemeralPublicKey = data.prefix(Self.ephemeralKeyLength)
        self.sealed = data.suffix(from: data.startIndex + Self.ephemeralKeyLength)
    }
}

// MARK: - SecureEnclaveWrapper

public struct SecureEnclaveWrapper {

    /// Whether the Secure Enclave is present. False on the simulator.
    public static var isAvailable: Bool { SecureEnclave.isAvailable }

    /// Fixed salt for HKDF. Constant is fine here — the ECDH shared secret is
    /// the entropy source; the salt only provides domain separation.
    private static let kdfSalt = Data("beacon.se.salt.v1".utf8)

    private let service: String
    private let account = "se.identity.wrapKey.v1"

    /// - Parameter service: a stable bundle-scoped identifier; the Enclave
    ///   key reference is stored under this service in the Keychain.
    /// - Throws: `.unavailable` if the Enclave is not present.
    public init(service: String) throws {
        guard SecureEnclaveWrapper.isAvailable else {
            throw SecureEnclaveError.unavailable
        }
        self.service = service
    }

    // MARK: Wrap / Unwrap

    /// Wrap a (secret) blob so only this device's Enclave can unwrap it.
    ///
    /// - Parameters:
    ///   - blob: secret bytes. Not zeroized here — the caller owns that copy.
    ///   - context: a per-purpose domain-separation label (e.g.
    ///     "beacon.identity.wrap.v1" vs "beacon.vault.dek.v1"). Different
    ///     contexts derive independent wrapping keys from the SAME Enclave key,
    ///     so two callers sharing one Enclave key cannot have their ciphertexts
    ///     substituted for one another. `unwrap` must be given the same context.
    public func wrap(_ blob: Data, context: Data) throws -> WrappedBlob {
        let enclaveKey = try loadOrCreateEnclaveKey()

        // Ephemeral keypair for this single wrap.
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let ephemeralPublic = ephemeral.publicKey.rawRepresentation

        do {
            let shared = try ephemeral.sharedSecretFromKeyAgreement(
                with: enclaveKey.publicKey)
            let symmetricKey = Self.deriveKey(from: shared,
                                              ephemeralPublic: ephemeralPublic,
                                              context: context)
            let box = try ChaChaPoly.seal(blob, using: symmetricKey)
            return WrappedBlob(ephemeralPublicKey: ephemeralPublic,
                               sealed: box.combined)
        } catch {
            throw SecureEnclaveError.cryptographicFailure
        }
    }

    /// Unwrap a blob previously produced by `wrap` with the SAME `context`.
    /// Requires this device's Enclave. The returned `Data` is secret — the
    /// caller must zeroize it.
    public func unwrap(_ wrapped: WrappedBlob, context: Data) throws -> Data {
        let enclaveKey = try loadOrCreateEnclaveKey()

        do {
            let ephemeralPublic = try P256.KeyAgreement.PublicKey(
                rawRepresentation: wrapped.ephemeralPublicKey)
            // ECDH happens INSIDE the Enclave; the private key is never extracted.
            let shared = try enclaveKey.sharedSecretFromKeyAgreement(
                with: ephemeralPublic)
            let symmetricKey = Self.deriveKey(
                from: shared,
                ephemeralPublic: wrapped.ephemeralPublicKey,
                context: context)
            let box = try ChaChaPoly.SealedBox(combined: wrapped.sealed)
            return try ChaChaPoly.open(box, using: symmetricKey)
        } catch {
            throw SecureEnclaveError.cryptographicFailure
        }
    }

    // MARK: Key derivation

    private static func deriveKey(from shared: SharedSecret,
                                  ephemeralPublic: Data,
                                  context: Data) -> SymmetricKey {
        // Bind both the per-purpose context AND the ephemeral public key into
        // the KDF info (domain separation + standard ECIES hygiene).
        shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: kdfSalt,
            sharedInfo: context + ephemeralPublic,
            outputByteCount: 32
        )
    }

    // MARK: Enclave key lifecycle

    /// Load the persisted Enclave key, generating and storing one on first use.
    private func loadOrCreateEnclaveKey() throws
        -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        if let representation = try loadKeyReference() {
            do {
                return try SecureEnclave.P256.KeyAgreement.PrivateKey(
                    dataRepresentation: representation)
            } catch {
                // The stored reference is unreadable (deleted out from under us,
                // an OS-upgrade quirk, etc.). Self-heal: drop the stale item and
                // regenerate, rather than permanently bricking the wrapper.
                //
                // NOTE: regenerating produces a NEW Enclave key, so any blob
                // previously wrapped by the old key becomes unrecoverable. That
                // is the correct outcome here — the old key is already gone; the
                // alternative is a hard brick. Callers whose wrapped data must
                // survive a lost Enclave key need a separate recovery story.
                try? deleteKeyReference()
                return try generateAndStoreEnclaveKey()
            }
        }
        return try generateAndStoreEnclaveKey()
    }

    private func generateAndStoreEnclaveKey() throws
        -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        let access = try makeKeyAccessControl()
        let key: SecureEnclave.P256.KeyAgreement.PrivateKey
        do {
            key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                accessControl: access)
        } catch {
            throw SecureEnclaveError.keyGenerationFailed
        }
        try storeKeyReference(key.dataRepresentation)
        return key
    }

    /// Access control for the Enclave key: usable only when the device is
    /// unlocked, only on this device. No biometric prompt on use, so unwrapping
    /// at launch is silent — the device-unlock state is the gate.
    private func makeKeyAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage],
            &error
        ) else {
            throw SecureEnclaveError.accessControlCreationFailed
        }
        return access
    }

    // MARK: Keychain storage of the (opaque) key reference

    // The Enclave key's `dataRepresentation` is an opaque, device-bound handle
    // — not the key itself. It is meaningless on any other device, but we still
    // store it WhenUnlockedThisDeviceOnly and non-synchronizable.

    private func loadKeyReference() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:    return item as? Data
        case errSecItemNotFound: return nil
        default:               throw SecureEnclaveError.keychain(status)
        }
    }

    private func storeKeyReference(_ representation: Data) throws {
        let attributes: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String:     kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String:          representation,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // A stale reference is already present. We must NOT treat this as
            // success — the freshly generated key would be silently dropped and
            // the next load would return the old (now key-less) reference,
            // wedging the wrapper. Overwrite the stored data with the new key.
            let query: [String: Any] = [
                kSecClass as String:       kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let changes: [String: Any] = [kSecValueData as String: representation]
            let updateStatus = SecItemUpdate(query as CFDictionary,
                                             changes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw SecureEnclaveError.keychain(updateStatus)
            }
        default:
            throw SecureEnclaveError.keychain(status)
        }
    }

    /// Delete just the stored key reference (used during self-heal). Distinct
    /// from `deleteEnclaveKey()` only in intent; same Keychain item.
    private func deleteKeyReference() throws {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureEnclaveError.keychain(status)
        }
    }

    /// Destroy the Enclave key reference. Part of crypto-erase (§3.7): once the
    /// reference is gone, any blob wrapped by this key is permanently
    /// unrecoverable, even on this device.
    public func deleteEnclaveKey() throws {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureEnclaveError.keychain(status)
        }
    }
}
