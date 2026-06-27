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

    /// Convenience: stand up a store with a fresh app identity. Used by tests
    /// and any standalone path that doesn't (yet) have the Enclave-bound
    /// identity to hand in. Routes through the same bridge as production, so it
    /// exercises the real identity path rather than a throwaway one.
    public convenience init() {
        // A generated app identity has the same shape as the real one; the only
        // difference in production is that the real one is Enclave-bound.
        self.init(appIdentity: IdentityKeypair.generate())
    }

    /// Designated init (PASS 2, Option A): the libsignal session identity is
    /// DERIVED from the app's Enclave-bound Curve25519 identity, so there is one
    /// identity, not two (see SignalIdentityBridge.swift). The representation the
    /// store exposes is unchanged — still libsignal's serialized identity key —
    /// so addresses, peer identity, and safety numbers are unaffected; only the
    /// key's ORIGIN changed (app key vs. a fresh random one).
    public init(appIdentity: IdentityKeypair) {
        // Bridge the app identity into libsignal. For a CryptoKit-generated key
        // this cannot fail; trap loudly if it ever does, matching the file's
        // existing "validated input, fail fast" stance (failableAddress below).
        let identity: IdentityKeyPair
        do {
            identity = try appIdentity.libsignalIdentityKeyPair()
        } catch {
            fatalError("Bridging app identity into libsignal failed for a validated key: \(error)")
        }
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

    // MARK: Inbound attribution (completes the boundary's receive side)

    /// Read the peer's public identity from a received bundle WITHOUT
    /// establishing a session. Used to attribute a link and to pick a
    /// deterministic first-contact initiator (so both sides don't initiate at
    /// once). Could be promoted to the SecureSessionStore protocol if a second
    /// engine ever appears; kept concrete for now.
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
    // bytes (confirmed against the installed PublicKey API: serialize() == 33,
    // keyBytes == raw 32, see SESSION_HANDOFF §6). These two helpers are the
    // ONLY place that mapping happens, so the 33-byte serialized rep never
    // leaks out of this adapter into the persistence layer and back — the two
    // representations stay isolated, and Peer.publicKeyData always matches the
    // same raw-32 form our own identity uses.

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
    /// stored as `Peer.publicKeyData`. Prepends libsignal's Curve25519 type
    /// byte so the result hex-matches the identity produced at establishment —
    /// which is what `session(with:)` looks up by.
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
