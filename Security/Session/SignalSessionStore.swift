//
//  SignalSessionStore.swift
//  Security/Session
//
//  The `SecureSessionStore` conformance: owns the local libsignal identity and
//  the in-memory protocol store, mints prekey bundles, and runs establishment.
//
//  PASS 1 of 2 — in-memory. See SignalSession.swift header.
//
//  IDENTITY BRIDGING NOTE (important, will be revisited in PASS 2):
//  libsignal uses its OWN `IdentityKeyPair` (an Ed25519-ish Curve25519 key it
//  manages natively). Beacon's `PublicIdentity` (IdentityKeypair.swift) is a
//  CryptoKit Curve25519 identity. These are NOT the same object. For the
//  in-memory pass this store generates a libsignal identity and exposes its
//  PUBLIC half as a `PublicIdentity`, so the boundary type is satisfied. Wiring
//  the app's existing Secure-Enclave-bound identity INTO libsignal (so there is
//  one identity, not two) is a deliberate PASS 2 task — it needs the identity
//  private key in a form libsignal accepts, which touches the Enclave story.
//  Flagged here so it is not forgotten.
//

import Foundation
import LibSignalClient

public final class SignalSessionStore: SecureSessionStore, @unchecked Sendable {

    /// Fixed device id for v1 (single device per identity). Signal allows 1–127.
    private static let deviceId: UInt32 = 1

    private let store: InMemoryBeaconStore
    private let context: StoreContext
    private let localAddress: ProtocolAddress
    public let localIdentity: PublicIdentity

    /// Cache of live per-peer sessions, keyed by the peer's user id (hex).
    private var sessions: [String: SignalSession] = [:]

    /// Create a store with a fresh libsignal identity (in-memory pass).
    public init() {
        let identity = IdentityKeyPair.generate()
        let registrationId = UInt32.random(in: 1...0x3FFF)
        self.store = InMemoryBeaconStore(identity: identity, registrationId: registrationId)
        self.context = NullContext()
        self.localIdentity = PublicIdentity(
            agreementKey: identity.publicKey.serialize(),
            signingKey: identity.publicKey.serialize()   // single libsignal identity key
        )
        // Address name = our identity public key hex (stable, unique, no server).
        let name = identity.publicKey.serialize().map { String(format: "%02x", $0) }.joined()
        self.localAddress = failableAddress(name: name, deviceId: Self.deviceId)
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
        // In-memory store has no per-address delete in the public API; PASS 2's
        // persistent store will implement real deletion. For the in-memory pass,
        // dropping our cache reference is sufficient for tests.
    }

    public func deleteAllSessions() throws {
        sessions.removeAll()
        // PASS 2: clear the persistent store. In-memory state is dropped with
        // the store instance.
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
