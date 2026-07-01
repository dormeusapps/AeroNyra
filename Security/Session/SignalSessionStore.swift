//
//  SignalSessionStore.swift
//  Security/Session
//
//  The `SecureSessionStore` conformance: owns the local libsignal identity and
//  the protocol store, mints prekey bundles, and runs establishment.
//
//  Phase 5a.3 — the store backend is now `any BeaconProtocolStore`, so this
//  class drives EITHER InMemoryBeaconStore (ephemeral; the convenience inits,
//  used by tests) OR PersistentBeaconStore (vault-backed; production). The
//  persistent path lets the store OWN its registrationId — the in-memory path's
//  `UInt32.random(...)` per construction is fine only because that store is
//  thrown away, but it must NOT be used for a persistent store (a fresh id each
//  launch silently breaks every existing session).
//
//  IDENTITY BRIDGING NOTE:
//  The libsignal session identity is DERIVED from the app's Enclave-bound
//  Curve25519 identity (SignalIdentityBridge.swift), so there is one identity,
//  not two. The representation exposed is unchanged — libsignal's serialized
//  identity key — so addresses, peer identity, and safety numbers are
//  unaffected; only the key's ORIGIN is the app key rather than a fresh random.
//

import Foundation
import CryptoKit
import LibSignalClient

public final class SignalSessionStore: SecureSessionStore, @unchecked Sendable {

    /// Fixed device id for v1 (single device per identity). Signal allows 1–127.
    private static let deviceId: UInt32 = 1

    private let store: any BeaconProtocolStore
    private let context: StoreContext
    private let localAddress: ProtocolAddress
    public let localIdentity: PublicIdentity

    /// Cache of live per-peer sessions, keyed by the peer's user id (hex).
    private var sessions: [String: SignalSession] = [:]

    /// Convenience: stand up an EPHEMERAL (in-memory) store with a fresh app
    /// identity. Used by tests and any standalone path that doesn't have the
    /// Enclave-bound identity to hand in. Routes through the same bridge as
    /// production, so it exercises the real identity path.
    public convenience init() {
        self.init(appIdentity: IdentityKeypair.generate())
    }

    /// EPHEMERAL designated init (in-memory backend). registrationId is random
    /// because the store is discarded on relaunch; never use this for traffic
    /// that must survive a restart — use `init(appIdentity:directory:dek:)`.
    public init(appIdentity: IdentityKeypair) {
        let identity = Self.bridge(appIdentity)
        let registrationId = UInt32.random(in: 1...0x3FFF)
        self.store = InMemoryBeaconStore(identity: identity, registrationId: registrationId)
        self.context = NullContext()
        (self.localIdentity, self.localAddress) = Self.localBindings(for: identity)
    }

    /// PERSISTENT designated init (vault-backed backend). The store OWNS its
    /// registrationId (generated once, reused), so sessions survive relaunch.
    /// - Parameters:
    ///   - appIdentity: the Enclave-bound app identity (bridged into libsignal).
    ///   - directory: where the encrypted session file lives.
    ///   - dek: the Data Encryption Key sealing that file (from SessionStoreKey).
    public init(appIdentity: IdentityKeypair, directory: URL, dek: SymmetricKey) throws {
        let identity = Self.bridge(appIdentity)
        self.store = try PersistentBeaconStore(identity: identity, directory: directory, key: dek)
        self.context = NullContext()
        (self.localIdentity, self.localAddress) = Self.localBindings(for: identity)
    }

    // MARK: Construction helpers

    /// Bridge the app identity into libsignal. For a CryptoKit-generated key this
    /// cannot fail; trap loudly if it ever does, matching this file's existing
    /// "validated input, fail fast" stance.
    private static func bridge(_ appIdentity: IdentityKeypair) -> IdentityKeyPair {
        do {
            return try appIdentity.libsignalIdentityKeyPair()
        } catch {
            fatalError("Bridging app identity into libsignal failed for a validated key: \(error)")
        }
    }

    /// Derive the public boundary identity + our local address from the bridged
    /// libsignal identity. Address name = our identity public key hex (stable,
    /// unique, no server).
    private static func localBindings(for identity: IdentityKeyPair)
        -> (PublicIdentity, ProtocolAddress) {
        let pub = identity.publicKey.serialize()
        let local = PublicIdentity(agreementKey: pub, signingKey: pub)
        let name = pub.map { String(format: "%02x", $0) }.joined()
        return (local, failableAddress(name: name, deviceId: deviceId))
    }

    // MARK: Bundle production

    public func localPrekeyBundle() throws -> PrekeyBundle {
        let material = try store.freshBundleMaterial(deviceId: Self.deviceId)
        return PrekeyBundle(data: BundleWire.encode(material))
    }

    // MARK: Establishment (initiator)

    public func establishSession(from bundle: PrekeyBundle) throws -> SecureSession {
        let decoded = try BundleWire.decode(bundle.data)

        // Reconstruct libsignal's native bundle from the wire fields.
        let nativeBundle = try PreKeyBundle(
            registrationId: decoded.registrationId,
            deviceId: decoded.deviceId,
            prekeyId: decoded.preKeyId,
            prekey: decoded.preKeyPublic,
            signedPrekeyId: decoded.signedPreKeyId,
            signedPrekey: decoded.signedPreKeyPublic,
            signedPrekeySignature: decoded.signedPreKeySignature,
            identity: decoded.identityKey,
            kyberPrekeyId: decoded.kyberPreKeyId,
            kyberPrekey: decoded.kyberPreKeyPublic,
            kyberPrekeySignature: decoded.kyberPreKeySignature
        )

        // Peer identity + address derived from the bundle's identity key.
        let peerKeyData = decoded.identityKey.serialize()
        let peer = PublicIdentity(agreementKey: peerKeyData, signingKey: peerKeyData)
        let peerAddress = failableAddress(name: peer.userIDHex, deviceId: decoded.deviceId)

        // Process the bundle: builds the outgoing session in our store.
        try processPreKeyBundle(
            nativeBundle,
            for: peerAddress,
            ourAddress: localAddress,
            sessionStore: store,
            identityStore: store,
            context: context
        )

        let session = SignalSession(
            peer: peer,
            peerAddress: peerAddress,
            localAddress: localAddress,
            store: store,
            context: context,
            established: true
        )
        sessions[peer.userIDHex] = session
        return session
    }

    // MARK: Retrieval

    public func session(with peer: PublicIdentity) throws -> SecureSession {
        if let existing = sessions[peer.userIDHex] { return existing }
        // Responder path: no bundle processed, but a session may form on the
        // first inbound `open`. Hand back a session bound to the peer address;
        // its state advances when the prekey message arrives.
        let peerAddress = failableAddress(name: peer.userIDHex, deviceId: Self.deviceId)
        let session = SignalSession(
            peer: peer,
            peerAddress: peerAddress,
            localAddress: localAddress,
            store: store,
            context: context,
            established: false
        )
        sessions[peer.userIDHex] = session
        return session
    }

    public func hasSession(with peer: PublicIdentity) -> Bool {
        (try? store.loadSession(
            for: failableAddress(name: peer.userIDHex, deviceId: Self.deviceId),
            context: context
        )) != nil
    }

    public func deleteSession(with peer: PublicIdentity) throws {
        sessions[peer.userIDHex] = nil
        // Persistent backend supports real per-address deletion; the in-memory
        // backend has no public delete, so dropping the cache reference is all
        // it can do (and all it needs — that store is ephemeral anyway).
        if let persistent = store as? PersistentBeaconStore {
            try persistent.removeSession(
                for: failableAddress(name: peer.userIDHex, deviceId: Self.deviceId))
        }
    }

    public func deleteAllSessions() throws {
        sessions.removeAll()
        if let persistent = store as? PersistentBeaconStore {
            try persistent.wipe()
        }
    }

    // MARK: Inbound attribution (completes the boundary's receive side)

    /// Warm the trial-decrypt cache from the closed-contact allowlist
    /// (RECONNECT_HANDSHAKE.md §4 / RECONNECT_AUTH_WIRING_5d.md §2.3, Invariant #1).
    ///
    /// `openInbound`'s `.whisper` branch trial-opens only the in-RAM `sessions`
    /// cache, which is populated lazily and is EMPTY after relaunch — even though
    /// the persistent store still holds every ratchet on disk. In the closed model
    /// nothing re-runs `establishSession` to repopulate it (the over-RF bundle
    /// re-exchange is gone), so a reconnecting pair's sealed it's-me would open
    /// against an empty set → not admitted → BLE dark for real pairs. This warms a
    /// peer-bound wrapper for every paired identity at startup, BEFORE any 0x03
    /// reconnect frame can arrive, so the `.whisper` loop opens against the
    /// on-disk ratchet.
    ///
    /// Mechanics: it reuses `session(with:)` purely for its cache-insert side
    /// effect (the same responder-path constructor already trusted on first
    /// inbound), via the store's own `peerIdentity(fromRawKey:)` so the raw↔
    /// serialized mapping stays inside this adapter. Resilient by design — a
    /// malformed entry is skipped, not fatal, and a failed warm for one identity
    /// never aborts the rest (this runs on the launch path and must not crash).
    ///
    /// - Parameter rawIdentities: paired contacts' raw 32-byte X25519 keys
    ///   (`ContactAllowlist.identities`, i.e. `store.rawPublicKey(of:)` form).
    public func warmInboundSessions(for rawIdentities: [Data]) {
        for raw in rawIdentities {
            guard raw.count == 32 else { continue }   // skip a corrupt entry, don't trap
            _ = try? session(with: peerIdentity(fromRawKey: raw))
        }
    }

    /// Read the peer's public identity from a received bundle WITHOUT
    /// establishing a session. Used to attribute a link and to pick a
    /// deterministic first-contact initiator (so both sides don't initiate at
    /// once).
    public func peerIdentity(from bundle: PrekeyBundle) throws -> PublicIdentity {
        let decoded = try BundleWire.decode(bundle.data)
        let keyData = decoded.identityKey.serialize()
        return PublicIdentity(agreementKey: keyData, signingKey: keyData)
    }

    /// Open an inbound opaque payload whose sender is not yet attributed.
    ///
    /// A first-contact (prekey) message self-identifies its sender, so we read
    /// the identity straight from the message and establish/advance that
    /// session. A normal (whisper) message carries no sender identity, so we try
    /// it against each established session — correct for any number of peers,
    /// and the honest interim until sealed sender lands (open ledger). Returns
    /// the recovered peer and plaintext.
    public func openInbound(_ payload: Data) throws -> (peer: PublicIdentity, plaintext: Data) {
        guard let typeByte = payload.first else {
            throw SignalAdapterError.unexpectedMessageType
        }
        switch CiphertextMessage.MessageType(rawValue: typeByte) {
        case .preKey:
            let message = try PreKeySignalMessage(bytes: payload.dropFirst())
            let keyData = message.identityKey.serialize()
            let peer = PublicIdentity(agreementKey: keyData, signingKey: keyData)
            let plaintext = try session(with: peer).open(payload)
            return (peer, plaintext)

        case .whisper:
            for (_, session) in sessions {
                if let plaintext = try? session.open(payload) {
                    return (session.peer, plaintext)
                }
            }
            throw SecureSessionError.openFailed

        default:
            throw SignalAdapterError.unexpectedMessageType
        }
    }

    // MARK: Raw-key bridging  (Peer.publicKeyData  ↔  session identity)
    //
    // The SwiftData layer keys a Peer by its RAW 32-byte X25519 public key
    // (Peer.publicKeyData). The session layer keys everything by libsignal's
    // SERIALIZED identity key — 33 bytes = one 0x05 type byte || the 32 raw
    // bytes. These two helpers are the ONLY place that mapping happens, so the
    // 33-byte serialized rep never leaks out of this adapter into the
    // persistence layer and back.

    /// Raw 32-byte X25519 public key for a peer, suitable for
    /// `Peer.publicKeyData`. Strips libsignal's leading type byte.
    public func rawPublicKey(of peer: PublicIdentity) -> Data {
        let serialized = peer.agreementKey
        precondition(serialized.count == 33,
                     "expected 33-byte serialized identity key, got \(serialized.count)")
        return Data(serialized.dropFirst())
    }

    /// Inverse of `rawPublicKey(of:)`: reconstruct the `PublicIdentity` (the
    /// 33-byte serialized rep that keys sessions) from the raw 32-byte key
    /// stored as `Peer.publicKeyData`.
    public func peerIdentity(fromRawKey raw: Data) -> PublicIdentity {
        precondition(raw.count == 32,
                     "expected 32-byte raw X25519 key, got \(raw.count)")
        var serialized = Data([0x05])
        serialized.append(raw)
        return PublicIdentity(agreementKey: serialized, signingKey: serialized)
    }
}

// MARK: - Helpers

/// ProtocolAddress(name:deviceId:) throws only on a malformed name; our names
/// are hex of a public key, always valid, so a failure here is a programmer
/// error worth trapping loudly.
private func failableAddress(name: String, deviceId: UInt32) -> ProtocolAddress {
    do {
        return try ProtocolAddress(name: name, deviceId: deviceId)
    } catch {
        fatalError("ProtocolAddress construction failed for a validated name: \(error)")
    }
}
