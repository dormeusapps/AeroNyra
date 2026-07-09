// PersistentBeaconStore.swift
// Security/Session
//
// PASS 2 of 2 — the VAULT-BACKED libsignal store (replaces the relaunch-
// fragile InMemoryBeaconStore from SignalSession.swift). A faithful twin of
// libsignal's `InMemorySignalProtocolStore`: it holds the same live record
// objects in memory for fast, synchronous, throw-free protocol responses, but
// write-through-persists the entire store state to a single encrypted file on
// every mutation, and reloads it on init. Sessions, prekeys, the TOFU trust
// table, and the post-quantum replay-defense state therefore survive an app
// relaunch.
//
// WHY THIS EXISTS (HANDOFF v7, ledger item 1): the in-memory pass proved the
// libsignal integration but lost all session state on relaunch, so after a
// restart you could not decrypt new traffic from an old peer until a fresh
// first-contact. This store closes that gap.
//
// WHAT IS / ISN'T PERSISTED
//   PERSISTED (this file owns it durably):
//     • registrationId — generated ONCE and reused. The in-memory pass
//       regenerated it with `UInt32.random` on every launch, which silently
//       broke every existing session even when records survived. Owning it
//       here is the single most important fix in this file.
//     • one-time prekeys, the signed prekey, the kyber prekey
//     • kyberPrekeysUsed + baseKeysSeen — the post-quantum REPLAY DEFENSE.
//       `markKyberPreKeyUsed` does not delete the kyber key (libsignal reuses
//       it); the actual defense is `baseKeysSeen` rejecting a reused base key.
//       If that reset on relaunch a captured prekey message could be replayed,
//       so it is serialized like any other state.
//     • per-peer sessions (the Double/Triple Ratchet state)
//     • the TOFU identity-trust table (publicKeys) — must persist or
//       `isTrustedIdentity` silently changes behaviour after relaunch.
//     • sender-key records — dormant in v1 (group/sender-key messaging,
//       Phase 8 geohash territory) but persisted so it is not a gap later.
//   NOT PERSISTED HERE (by design):
//     • the private identity key. It is injected on every launch from the
//       Keychain/Enclave-bound identity (the app's existing identity story),
//       exactly as InMemoryBeaconStore took it via init. We never write the
//       private identity into this store's file.
//
// AT REST: the whole snapshot is sealed with ChaCha20-Poly1305 under a Data
// Encryption Key supplied at init (the composition root provisions it from the
// Keychain; tests inject a fixed key). The file is written with iOS Data
// Protection `completeUntilFirstUserAuthentication` — deliberately NOT
// `complete`, because a mesh messenger must be able to receive in the
// background while the screen is locked, which `complete` forbids. Message
// *content* at rest can still ride MessageVault's stricter user-presence DEK;
// this is the crypto session layer, a different threat slice. Destroying the
// DEK crypto-erases the store (a wrong/missing key loads as empty, which is the
// emergency-wipe semantics).
//
// CONCURRENCY: `@unchecked Sendable`, lock-free — identical stance to
// InMemoryBeaconStore. The invariant is single-actor confinement: the
// FirstContactCoordinator owns the store and every libsignal call into it
// happens on that actor. Do not share one instance across actors.
//

import Foundation
import CryptoKit
import LibSignalClient

// MARK: - Errors

public enum PersistentStoreError: Error {
    /// The store directory could not be created.
    case directoryUnavailable(underlying: Error)
    /// Writing the encrypted snapshot failed.
    case writeFailed(underlying: Error)
}

// MARK: - PersistentBeaconStore

public final class PersistentBeaconStore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore,
    KyberPreKeyStore, SessionStore, SenderKeyStore, @unchecked Sendable {

    private static let logPrefix = "📦 PersistentBeaconStore:"

    /// AAD binding the ciphertext to this store + format version. A snapshot
    /// sealed under one version/key cannot be silently opened under another.
    private static let snapshotAAD = Data("beacon.signalstore.v1".utf8)

    // MARK: Injected identity (NOT persisted here)

    /// Our own identity, kept for synchronous throw-free access — the same
    /// ergonomic handle InMemoryBeaconStore exposed (and that SignalSession's
    /// safetyNumber() reads). Sourced from the Keychain/Enclave identity.
    public let localIdentity: IdentityKeyPair

    // MARK: Durable id allocation (owned here)

    private var registrationId: UInt32 = 0
    /// Reserved for PASS-2 bundle production (freshBundleMaterial moves onto the
    /// store in the seam step); persisted so prekey ids never collide across
    /// launches. See `allocateOneTimePreKeyId()`.
    private var nextOneTimePreKeyId: UInt32 = 1

    // MARK: In-memory mirror (live record objects, like the reference)

    private var publicKeys: [ProtocolAddress: IdentityKey] = [:]
    private var prekeyMap: [UInt32: PreKeyRecord] = [:]
    private var signedPrekeyMap: [UInt32: SignedPreKeyRecord] = [:]
    private var kyberPrekeyMap: [UInt32: KyberPreKeyRecord] = [:]
    private var kyberPrekeysUsed: Set<UInt32> = []
    private var baseKeysSeen: [UInt64: [PublicKey]] = [:]
    private var sessionMap: [ProtocolAddress: SessionRecord] = [:]
    private var senderKeyMap: [SenderKeyName: SenderKeyRecord] = [:]

    // MARK: Persistence backing

    private let fileURL: URL
    private let key: SymmetricKey

    /// - Parameters:
    ///   - identity: the libsignal identity (bridged from the app's Enclave
    ///     identity in production; generated in tests). Same role as the
    ///     `identity:` argument InMemoryBeaconStore took.
    ///   - directory: where the encrypted state file lives. Created if absent.
    ///   - key: the Data Encryption Key sealing the snapshot. The composition
    ///     root provisions a stable one from the Keychain; tests inject a fixed
    ///     key.
    public init(identity: IdentityKeyPair, directory: URL, key: SymmetricKey) throws {
        self.localIdentity = identity
        self.key = key
        self.fileURL = directory.appendingPathComponent("signalstore.dat")

        // Ensure the directory exists. On a fresh install the parent
        // (Library/Application Support) may not exist yet and the sandbox blocks
        // creating through a missing parent, so create it explicitly first, then
        // best-effort tag it with Data Protection at the directory level.
        do {
            let parent = directory.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path)
        } catch {
            throw PersistentStoreError.directoryUnavailable(underlying: error)
        }

        if let snapshot = Self.loadSnapshot(from: fileURL, key: key) {
            apply(snapshot)
            print("\(Self.logPrefix) loaded (regId \(registrationId), "
                + "\(sessionMap.count) session(s), \(prekeyMap.count) prekey(s))")
        } else {
            // No file, or it could not be decrypted (wrong/missing key →
            // crypto-erase semantics). Start fresh with a STABLE registrationId
            // and write it so the next launch reuses it.
            self.registrationId = UInt32.random(in: 1...0x3FFF)
            self.nextOneTimePreKeyId = 1
            try persist()
            print("\(Self.logPrefix) initialized fresh (regId \(registrationId))")
        }
    }

    /// Default production location: Application Support/BeaconSignalStore.
    ///
    /// On a fresh install `Library/Application Support` may not exist yet and the
    /// sandbox won't let a bare `createDirectory` punch through a missing parent
    /// (this is the same condition that makes CoreData log "Failed to create
    /// file; code = 2" on first launch). Using `url(for:…create: true)` forces
    /// the parent into existence first, then we create our subfolder under it.
    public static func defaultDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("BeaconSignalStore", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Reserved for the seam step (freshBundleMaterial). Allocates and persists
    /// the next one-time prekey id so ids never repeat across launches.
    public func allocateOneTimePreKeyId() throws -> UInt32 {
        let id = nextOneTimePreKeyId
        nextOneTimePreKeyId &+= 1
        try persist()
        return id
    }

    // MARK: - IdentityKeyStore

    public func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair {
        localIdentity
    }

    public func localRegistrationId(context: StoreContext) throws -> UInt32 {
        registrationId
    }

    public func saveIdentity(_ identity: IdentityKey,
                             for address: ProtocolAddress,
                             context: StoreContext) throws -> IdentityChange {
        let old = publicKeys.updateValue(identity, forKey: address)
        try persist()
        if old == nil || old == identity {
            return .newOrUnchanged
        } else {
            return .replacedExisting
        }
    }

    public func isTrustedIdentity(_ identity: IdentityKey,
                                  for address: ProtocolAddress,
                                  direction: Direction,
                                  context: StoreContext) throws -> Bool {
        if let known = publicKeys[address] {
            return known == identity
        }
        return true   // TOFU
    }

    public func identity(for address: ProtocolAddress,
                         context: StoreContext) throws -> IdentityKey? {
        publicKeys[address]
    }

    // MARK: - PreKeyStore

    public func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        guard let record = prekeyMap[id] else {
            throw SignalError.invalidKeyIdentifier("no prekey with this identifier")
        }
        return record
    }

    public func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        prekeyMap[id] = record
        try persist()
    }

    public func removePreKey(id: UInt32, context: StoreContext) throws {
        prekeyMap.removeValue(forKey: id)
        try persist()
    }

    // MARK: - SignedPreKeyStore

    public func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        guard let record = signedPrekeyMap[id] else {
            throw SignalError.invalidKeyIdentifier("no signed prekey with this identifier")
        }
        return record
    }

    public func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32,
                                  context: StoreContext) throws {
        signedPrekeyMap[id] = record
        try persist()
    }

    // MARK: - KyberPreKeyStore

    public func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        guard let record = kyberPrekeyMap[id] else {
            throw SignalError.invalidKeyIdentifier("no kyber prekey with this identifier")
        }
        return record
    }

    public func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32,
                                 context: StoreContext) throws {
        kyberPrekeyMap[id] = record
        try persist()
    }

    public func markKyberPreKeyUsed(id: UInt32, signedPreKeyId: UInt32,
                                    baseKey: PublicKey, context: StoreContext) throws {
        // Mirrors InMemorySignalProtocolStore exactly: the (kyberId, signedId)
        // pair maps to the set of base keys already seen; a repeat is a replay.
        let bothKeyIds = (UInt64(id) << 32) | UInt64(signedPreKeyId)
        if baseKeysSeen[bothKeyIds, default: []].contains(baseKey) {
            throw SignalError.invalidMessage("reused base key")
        }
        baseKeysSeen[bothKeyIds, default: []].append(baseKey)
        kyberPrekeysUsed.insert(id)
        try persist()
    }

    // MARK: - SessionStore

    public func loadSession(for address: ProtocolAddress,
                            context: StoreContext) throws -> SessionRecord? {
        sessionMap[address]
    }

    public func loadExistingSessions(for addresses: [ProtocolAddress],
                                     context: StoreContext) throws -> [SessionRecord] {
        try addresses.map { address in
            guard let session = sessionMap[address] else {
                throw SignalError.sessionNotFound("\(address)")
            }
            return session
        }
    }

    public func storeSession(_ record: SessionRecord, for address: ProtocolAddress,
                             context: StoreContext) throws {
        sessionMap[address] = record
        try persist()
    }

    // MARK: - SenderKeyStore

    public func storeSenderKey(from sender: ProtocolAddress, distributionId: UUID,
                               record: SenderKeyRecord, context: StoreContext) throws {
        senderKeyMap[SenderKeyName(sender: sender, distributionId: distributionId)] = record
        try persist()
    }

    public func loadSenderKey(from sender: ProtocolAddress, distributionId: UUID,
                              context: StoreContext) throws -> SenderKeyRecord? {
        senderKeyMap[SenderKeyName(sender: sender, distributionId: distributionId)]
    }

    // MARK: - Deletion (real, unlike the in-memory pass)

    /// Remove one peer's session (the persistent deletion the in-memory pass
    /// could not do). Used by the boundary's `deleteSession(with:)` in the seam.
    public func removeSession(for address: ProtocolAddress) throws {
        sessionMap.removeValue(forKey: address)
        try persist()
    }

    /// Wipe ALL crypto state and the file (the persistent half of an emergency
    /// wipe / `deleteAllSessions`). Identity is injected, so it is untouched.
    public func wipe() throws {
        publicKeys.removeAll(); prekeyMap.removeAll(); signedPrekeyMap.removeAll()
        kyberPrekeyMap.removeAll(); kyberPrekeysUsed.removeAll(); baseKeysSeen.removeAll()
        sessionMap.removeAll(); senderKeyMap.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Snapshot persistence

    private func persist() throws {
        let snapshot = makeSnapshot()
        do {
            let json = try JSONEncoder().encode(snapshot)
            let sealed = try ChaChaPoly.seal(
                json, using: key, authenticating: Self.snapshotAAD).combined
            // Atomic write only. Data Protection is applied at the directory
            // level (see init); the per-write file-protection option was the
            // cause of "Failed to create file; code = 2" on first launch when
            // Application Support did not yet exist.
            try sealed.write(to: fileURL, options: [.atomic])
        } catch {
            // Loud, not silent: a swallowed write here would masquerade as a
            // fresh start on the next launch (sessions appearing not to persist).
            RedactLog.event("\(Self.logPrefix) ⚠️ persist failed", "\(type(of: error))")
            throw PersistentStoreError.writeFailed(underlying: error)
        }
    }

    private func makeSnapshot() -> Snapshot {
        Snapshot(
            registrationId: registrationId,
            nextOneTimePreKeyId: nextOneTimePreKeyId,
            identities: publicKeys.map {
                AddrRecord(name: $0.key.name, deviceId: $0.key.deviceId,
                           bytes: $0.value.serialize())
            },
            preKeys: prekeyMap.map { IdRecord(id: $0.key, bytes: $0.value.serialize()) },
            signedPreKeys: signedPrekeyMap.map { IdRecord(id: $0.key, bytes: $0.value.serialize()) },
            kyberPreKeys: kyberPrekeyMap.map { IdRecord(id: $0.key, bytes: $0.value.serialize()) },
            kyberUsed: Array(kyberPrekeysUsed),
            baseKeysSeen: baseKeysSeen.map {
                BaseKeysEntry(combined: $0.key, keys: $0.value.map { $0.serialize() })
            },
            sessions: sessionMap.map {
                AddrRecord(name: $0.key.name, deviceId: $0.key.deviceId,
                           bytes: $0.value.serialize())
            },
            senderKeys: senderKeyMap.map {
                SenderRecord(name: $0.key.sender.name, deviceId: $0.key.sender.deviceId,
                             distributionId: $0.key.distributionId, bytes: $0.value.serialize())
            }
        )
    }

    /// Read + decrypt + decode. Returns nil if the file is absent OR cannot be
    /// decrypted/decoded (wrong key, corruption) — the caller then starts fresh,
    /// which is the crypto-erase semantics.
    private static func loadSnapshot(from url: URL, key: SymmetricKey) -> Snapshot? {
        guard let sealed = try? Data(contentsOf: url) else { return nil }
        do {
            let box = try ChaChaPoly.SealedBox(combined: sealed)
            let json = try ChaChaPoly.open(box, using: key, authenticating: snapshotAAD)
            return try JSONDecoder().decode(Snapshot.self, from: json)
        } catch {
            RedactLog.event("\(logPrefix) snapshot unreadable; starting fresh", "\(type(of: error))")
            return nil
        }
    }

    /// Rehydrate in-memory state. Best-effort per record: a single record that
    /// fails to deserialize (version skew, corruption) is skipped with a warning
    /// rather than failing app launch. Scalars always recover.
    private func apply(_ s: Snapshot) {
        registrationId = s.registrationId
        nextOneTimePreKeyId = s.nextOneTimePreKeyId
        kyberPrekeysUsed = Set(s.kyberUsed)

        for r in s.identities {
            if let addr = try? ProtocolAddress(name: r.name, deviceId: r.deviceId),
               let idk = try? IdentityKey(bytes: r.bytes) {
                publicKeys[addr] = idk
            } else { warnSkip("identity", r.name) }
        }
        for r in s.preKeys {
            if let rec = try? PreKeyRecord(bytes: r.bytes) { prekeyMap[r.id] = rec }
            else { warnSkip("prekey", "\(r.id)") }
        }
        for r in s.signedPreKeys {
            if let rec = try? SignedPreKeyRecord(bytes: r.bytes) { signedPrekeyMap[r.id] = rec }
            else { warnSkip("signedPrekey", "\(r.id)") }
        }
        for r in s.kyberPreKeys {
            if let rec = try? KyberPreKeyRecord(bytes: r.bytes) { kyberPrekeyMap[r.id] = rec }
            else { warnSkip("kyberPrekey", "\(r.id)") }
        }
        for e in s.baseKeysSeen {
            baseKeysSeen[e.combined] = e.keys.compactMap { try? PublicKey($0) }
        }
        for r in s.sessions {
            if let addr = try? ProtocolAddress(name: r.name, deviceId: r.deviceId),
               let rec = try? SessionRecord(bytes: r.bytes) {
                sessionMap[addr] = rec
            } else { warnSkip("session", r.name) }
        }
        for r in s.senderKeys {
            if let addr = try? ProtocolAddress(name: r.name, deviceId: r.deviceId),
               let rec = try? SenderKeyRecord(bytes: r.bytes) {
                senderKeyMap[SenderKeyName(sender: addr, distributionId: r.distributionId)] = rec
            } else { warnSkip("senderKey", r.name) }
        }
    }

    private func warnSkip(_ kind: String, _ id: String) {
        RedactLog.event("\(Self.logPrefix) skipped unreadable \(kind) on load", "[\(id)]")
    }

    // MARK: - Sender-key composite key (mirrors the reference's private struct)

    private struct SenderKeyName: Hashable {
        let sender: ProtocolAddress
        let distributionId: UUID
    }

    // MARK: - Codable snapshot (UInt32-keyed maps become arrays for JSON)

    private struct Snapshot: Codable {
        var registrationId: UInt32
        var nextOneTimePreKeyId: UInt32
        var identities: [AddrRecord]
        var preKeys: [IdRecord]
        var signedPreKeys: [IdRecord]
        var kyberPreKeys: [IdRecord]
        var kyberUsed: [UInt32]
        var baseKeysSeen: [BaseKeysEntry]
        var sessions: [AddrRecord]
        var senderKeys: [SenderRecord]
    }
    private struct AddrRecord: Codable { var name: String; var deviceId: UInt32; var bytes: Data }
    private struct IdRecord: Codable { var id: UInt32; var bytes: Data }
    private struct BaseKeysEntry: Codable { var combined: UInt64; var keys: [Data] }
    private struct SenderRecord: Codable {
        var name: String; var deviceId: UInt32; var distributionId: UUID; var bytes: Data
    }
}
