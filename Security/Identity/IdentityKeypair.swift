//
//  IdentityKeypair.swift
//  Security/Identity
//
//  The device's long-term cryptographic identity.
//
//  HANDOFF §3.2: "On first launch, generate a long-term identity: X25519
//  (Curve25519) keypair for key agreement; Ed25519 keypair for signatures.
//  Public key (32 bytes) = the permanent, unique user ID. Private keys stored
//  in iOS Keychain: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
//  non-synchronizable, gated by device passcode/biometric (SecAccessControl)."
//
//  STEP 1 of 2. This file generates the identity and persists it in the
//  Keychain with the access-control flags above. HARDWARE BINDING — wrapping
//  the at-rest blob with a Secure Enclave P-256 key (§3.2) — is layered on in
//  step 2 (SecureEnclaveWrapper.swift). Until then the blob is protected by
//  the Keychain's own at-rest encryption and Data Protection, which is already
//  meaningful (it's the "lost/stolen LOCKED device" defense from §3.8).
//
//  GOLDEN RULES honored here (§3.1): vetted primitives only (CryptoKit), keys
//  generated from the system CSPRNG (CryptoKit does this internally), private
//  key material zeroized after use, never logged, never leaves the device.
//

import Foundation
import CryptoKit
import Security
import LocalAuthentication

// MARK: - PublicIdentity

/// The public half of a peer's identity — safe to share, transmit, and display.
///
/// The X25519 public key is the permanent, unique user ID (§3.2). The Ed25519
/// public key verifies that peer's signatures. Together they're what a safety
/// number / QR verification (§3.5) is computed over.
public struct PublicIdentity: Equatable, Hashable, Sendable, Codable {

    /// X25519 (Curve25519 key-agreement) public key, 32 bytes. The user ID.
    public let agreementKey: Data

    /// Ed25519 (signature) public key, 32 bytes.
    public let signingKey: Data

    public init(agreementKey: Data, signingKey: Data) {
        self.agreementKey = agreementKey
        self.signingKey = signingKey
    }

    /// The 32-byte permanent user ID (the X25519 public key).
    public var userID: Data { agreementKey }

    /// Lowercase hex of the user ID, for logs/debug display only — never used
    /// as a security boundary.
    public var userIDHex: String {
        agreementKey.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - IdentityError

public enum IdentityError: Error, Equatable {
    /// No identity exists in the Keychain yet (expected on first launch).
    case notFound
    /// An identity already exists; generation refused to overwrite it.
    case alreadyExists
    /// The stored blob was malformed or the wrong size.
    case corruptedKeyData
    /// The identity item exists but could not be Enclave-unwrapped — distinct
    /// from `corruptedKeyData` so the cause is diagnosable. The usual culprit
    /// is the Enclave key having been destroyed (e.g. by a vault wipe that
    /// shares the Enclave key). This is NOT auto-recovered: regenerating would
    /// silently change the user's permanent identity, which must never happen
    /// without an explicit user-driven reset.
    case identityUnwrapFailed
    /// A Keychain operation failed; carries the OSStatus for diagnosis.
    case keychain(OSStatus)
    /// Building the SecAccessControl gate failed.
    case accessControlCreationFailed
}

// MARK: - IdentityKeypair

/// The full identity: both private keys plus their public halves.
///
/// Private key material lives here only transiently, while in use. The
/// canonical at-rest copy is in the Keychain (see `IdentityStore`). Instances
/// zeroize their serialized private bytes when encoded for storage.
public struct IdentityKeypair: Sendable {

    public let agreement: Curve25519.KeyAgreement.PrivateKey
    public let signing: Curve25519.Signing.PrivateKey

    public init(agreement: Curve25519.KeyAgreement.PrivateKey,
                signing: Curve25519.Signing.PrivateKey) {
        self.agreement = agreement
        self.signing = signing
    }

    /// Generate a fresh identity from the system CSPRNG.
    public static func generate() -> IdentityKeypair {
        IdentityKeypair(
            agreement: Curve25519.KeyAgreement.PrivateKey(),
            signing: Curve25519.Signing.PrivateKey()
        )
    }

    /// The shareable public identity.
    public var publicIdentity: PublicIdentity {
        PublicIdentity(
            agreementKey: agreement.publicKey.rawRepresentation,
            signingKey: signing.publicKey.rawRepresentation
        )
    }
}

// MARK: - Storage serialization

extension IdentityKeypair {

    /// On-disk layout of the *private* identity blob: two 32-byte raw keys,
    /// agreement first, then signing. Fixed size = 64 bytes. This blob is what
    /// SecureEnclaveWrapper will wrap in step 2; for now it goes to the
    /// Keychain as-is under Data Protection.
    static let blobSize = 64

    /// Serialize private keys to the 64-byte blob.
    ///
    /// The returned `Data` holds secret material. Callers must not log or
    /// retain it; `IdentityStore.save` zeroizes its copy after writing.
    func serializedPrivateBlob() -> Data {
        var blob = Data()
        blob.append(agreement.rawRepresentation)   // 32
        blob.append(signing.rawRepresentation)     // 32
        return blob
    }

    /// Reconstruct from the 64-byte blob. Throws `.corruptedKeyData` on a
    /// wrong-size or invalid buffer.
    init(privateBlob blob: Data) throws {
        guard blob.count == IdentityKeypair.blobSize else {
            throw IdentityError.corruptedKeyData
        }
        let agreementBytes = blob.prefix(32)
        let signingBytes = blob.suffix(32)
        do {
            let agreement = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: agreementBytes)
            let signing = try Curve25519.Signing.PrivateKey(
                rawRepresentation: signingBytes)
            self.init(agreement: agreement, signing: signing)
        } catch {
            throw IdentityError.corruptedKeyData
        }
    }
}

// MARK: - IdentityStore

/// Persists the identity blob in the iOS Keychain with the access control the
/// handoff specifies (§3.2): WhenUnlockedThisDeviceOnly, non-synchronizable,
/// gated by a SecAccessControl requiring device unlock.
///
/// When a `SecureEnclaveWrapper` is supplied, the blob is SE-wrapped before it
/// is written and unwrapped on read, giving the §3.2 hardware binding. Without
/// one (simulator), the blob is stored raw under Data Protection only.
public struct IdentityStore {

    /// How the Keychain item is protected at rest.
    public enum Protection: Sendable {
        /// Production (§3.2 strict): gated on device unlock, this device only,
        /// AND requires a device passcode to be set (SecAccessControl with
        /// `.devicePasscode`). Adding the item fails if no passcode exists —
        /// which is the desired behavior on a real device, but means this
        /// policy cannot be used on a passcode-less simulator.
        case devicePasscode
        /// Device-unlock only: `WhenUnlockedThisDeviceOnly` with no passcode or
        /// biometric requirement. Works on a simulator without a passcode and
        /// never prompts on access. Use for tests, or where a strict gate's
        /// prompt would harm the launch flow.
        case deviceUnlockOnly
    }

    /// Keychain item identifiers. Service is constant; account names the item.
    private let service: String
    private let account = "identity.v1"
    private let protection: Protection

    /// Per-purpose KDF domain-separation label for Enclave wrapping. Distinct
    /// from the vault's context so identity-wrap and DEK-wrap derive
    /// independent keys even when they share one Enclave key.
    fileprivate static let kdfContext = Data("beacon.identity.wrap.v1".utf8)

    /// Optional hardware binding. When present, the blob is SE-wrapped before
    /// it touches the Keychain and unwrapped on read. When nil (e.g. on the
    /// simulator), the blob is stored raw under Data Protection only.
    ///
    /// Whether a wrapper is used must be stable for a given install — the same
    /// device always resolves the Enclave the same way — since a wrapped item
    /// can only be read back through the wrapper that produced it.
    private let wrapper: SecureEnclaveWrapper?

    /// - Parameters:
    ///   - service: a stable bundle-scoped identifier
    ///     (e.g. "com.yourorg.beacon.identity"). Keep it constant across launches.
    ///   - protection: the at-rest protection policy. Defaults to the strict
    ///     `.devicePasscode` for production; use `.deviceUnlockOnly` for tests
    ///     and the simulator.
    ///   - wrapper: the Secure Enclave wrapper, or nil for raw storage.
    ///     Typically: `try? SecureEnclaveWrapper(service:)`, which yields a
    ///     wrapper on device and nil on the simulator.
    public init(service: String,
                protection: Protection = .devicePasscode,
                wrapper: SecureEnclaveWrapper? = nil) {
        self.service = service
        self.protection = protection
        self.wrapper = wrapper
    }

    // MARK: Load / create

    /// Load the existing identity, or generate-and-store one on first launch.
    /// This is the normal entry point at app start.
    public func loadOrCreate() throws -> IdentityKeypair {
        do {
            return try load()
        } catch IdentityError.notFound {
            let fresh = IdentityKeypair.generate()
            try save(fresh, overwrite: false)
            return fresh
        }
    }

    /// Load the stored identity. Throws `.notFound` if none exists.
    public func load() throws -> IdentityKeypair {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      account,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let stored = item as? Data else {
                throw IdentityError.corruptedKeyData
            }
            // If wrapped, unwrap inside the Enclave first; otherwise the stored
            // bytes are the raw blob. Either way, zeroize the secret blob after
            // reconstructing the keypair.
            var blob: Data
            if let wrapper {
                do {
                    let wrapped = try WrappedBlob(serialized: stored)
                    blob = try wrapper.unwrap(wrapped, context: Self.kdfContext)
                } catch {
                    // The item exists but won't unwrap — distinct from a
                    // malformed blob, and deliberately NOT auto-recovered.
                    throw IdentityError.identityUnwrapFailed
                }
            } else {
                blob = stored
            }
            defer { blob.resetBytes(in: 0..<blob.count) }   // zeroize
            return try IdentityKeypair(privateBlob: blob)
        case errSecItemNotFound:
            throw IdentityError.notFound
        default:
            throw IdentityError.keychain(status)
        }
    }

    // MARK: Save

    /// Store the identity. With `overwrite: false` (the default for first
    /// launch) it refuses to clobber an existing identity, throwing
    /// `.alreadyExists`.
    public func save(_ identity: IdentityKeypair, overwrite: Bool = false) throws {
        var blob = identity.serializedPrivateBlob()
        defer { blob.resetBytes(in: 0..<blob.count) }       // zeroize our copy

        // Wrap with the Enclave if available; otherwise store the raw blob.
        // The wrapped bytes are not secret, so only `blob` needs zeroizing.
        let payload: Data
        if let wrapper {
            do {
                payload = try wrapper.wrap(blob, context: Self.kdfContext).serialized()
            } catch {
                throw IdentityError.corruptedKeyData
            }
        } else {
            payload = blob
        }

        var attributes: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecAttrSynchronizable as String: false,        // never iCloud-synced
            kSecValueData as String:          payload,
        ]

        // Apply the protection policy. The two are mutually exclusive: you set
        // either a SecAccessControl object or a plain accessibility constant,
        // never both.
        switch protection {
        case .devicePasscode:
            attributes[kSecAttrAccessControl as String] = try makeAccessControl()
        case .deviceUnlockOnly:
            attributes[kSecAttrAccessible as String] =
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let status = SecItemAdd(attributes as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            if overwrite {
                try update(blob: payload)
            } else {
                throw IdentityError.alreadyExists
            }
        default:
            throw IdentityError.keychain(status)
        }
    }

    /// Replace the data of an existing item (used only when overwrite == true).
    ///
    /// LIMITATION: this updates only `kSecValueData`. The item's original access
    /// control / accessibility is preserved, so calling `save(overwrite: true)`
    /// with a *different* `protection` than the item was created with does NOT
    /// change its protection. To change protection, delete then re-save. In
    /// practice protection is fixed per install, so this isn't hit.
    private func update(blob: Data) throws {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        let changes: [String: Any] = [kSecValueData as String: blob]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        guard status == errSecSuccess else {
            throw IdentityError.keychain(status)
        }
    }

    // MARK: Delete

    /// Remove the identity from the Keychain. This is the key-destruction
    /// primitive the emergency wipe (§3.7) builds on: destroying the keys
    /// renders all stored ciphertext permanently unrecoverable (crypto-erase).
    public func delete() throws {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IdentityError.keychain(status)
        }
    }

    // MARK: Access control

    /// Build the SecAccessControl gate: the item is readable only when the
    /// device is unlocked, only on THIS device, and is bound to the device
    /// passcode being set. Matches §3.2.
    private func makeAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.devicePasscode],          // require a passcode to be set/used
            &error
        ) else {
            throw IdentityError.accessControlCreationFailed
        }
        return access
    }
}
