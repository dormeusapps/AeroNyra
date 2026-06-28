//
//  SignalSession.swift
//  Security/Session
//
//  THE libsignal ADAPTER.
//
//  Conforms the `SecureSession` / `SecureSessionStore` boundary to libsignal's
//  Triple Ratchet (Double Ratchet + post-quantum Kyber prekeys, via PQXDH).
//  The rest of the app talks only to the boundary; this file is the single
//  place libsignal's API is touched.
//
//  STORAGE BACKENDS (Phase 5a.3): the per-peer `SignalSession` and the store
//  hold their libsignal store as `any BeaconProtocolStore` — satisfied by both
//  `InMemoryBeaconStore` (ephemeral, kept for tests) and `PersistentBeaconStore`
//  (vault-backed, survives relaunch). Bundle production now lives once in the
//  `BeaconProtocolStore` extension (see BeaconProtocolStore.swift), so swapping
//  the backend touches neither this adapter's logic nor any caller.
//
//  Bundle format note: libsignal's `PreKeyBundle` is a native object, but the
//  boundary's `PrekeyBundle` is opaque `Data` (carrier-neutral — BLE/QR/etc.).
//  This adapter serializes the bundle's PUBLIC fields to a flat wire layout in
//  `localPrekeyBundle()` and reconstructs the native bundle in
//  `establishSession(from:)`.
//

import Foundation
import LibSignalClient

// MARK: - Errors

public enum SignalAdapterError: Error {
    case bundleSerializationFailed
    case bundleMalformed
    case notEstablished
    case unexpectedMessageType
    case signal(underlying: Error)
}

// MARK: - In-memory store

/// libsignal store backed by memory. Subclassing `InMemorySignalProtocolStore`
/// gives us conformance to all six store protocols for free; we add only the
/// one-time-prekey id bookkeeping the bundle producer needs on top, plus the
/// `localIdentity` handle.
///
/// Kept as the EPHEMERAL backend (tests, the convenience `SignalSessionStore()`
/// init). Production uses PersistentBeaconStore. Both satisfy BeaconProtocolStore.
final class InMemoryBeaconStore: InMemorySignalProtocolStore, @unchecked Sendable {

    /// Rotating id space for one-time prekeys. (Signed + Kyber prekeys use the
    /// fixed id 1, applied in the shared `freshBundleMaterial`.)
    private var nextOneTimePreKeyId: UInt32 = 1

    /// Our own identity, kept for synchronous, throw-free access. NOTE: do NOT
    /// name this `identityKeyPair` — the superclass exposes
    /// `open func identityKeyPair(context:)`, and a stored property of the same
    /// name collides with it ("Overriding declaration requires an 'override'
    /// keyword"). The superclass copy still backs the protocol conformance; this
    /// is just an ergonomic handle.
    let localIdentity: IdentityKeyPair

    override init(identity: IdentityKeyPair, registrationId: UInt32) {
        self.localIdentity = identity
        super.init(identity: identity, registrationId: registrationId)
    }

    /// Ephemeral one-time prekey id allocation (BeaconProtocolStore requirement).
    /// No persistence needed — this store is thrown away on relaunch.
    func allocateOneTimePreKeyId() throws -> UInt32 {
        let id = nextOneTimePreKeyId
        nextOneTimePreKeyId &+= 1
        return id
    }
}

// MARK: - Bundle wire format

/// Flat serialization of a prekey bundle's public fields, so the boundary can
/// stay `Data`-shaped (carrier-neutral). Layout is length-prefixed fields; the
/// exact format is private to this adapter.
enum BundleWire {

    static func encode(_ m: BundleMaterial) -> Data {
        var d = Data()
        func putU32(_ v: UInt32) { var be = v.bigEndian; withUnsafeBytes(of: &be) { d.append(contentsOf: $0) } }
        func putBlob(_ b: Data) { putU32(UInt32(b.count)); d.append(b) }

        putU32(m.registrationId)
        putU32(m.deviceId)
        putU32(m.preKeyId)
        putBlob(m.preKeyPublic.serialize())
        putU32(m.signedPreKeyId)
        putBlob(m.signedPreKeyPublic.serialize())
        putBlob(m.signedPreKeySignature)
        putBlob(m.identityKey.serialize())
        putU32(m.kyberPreKeyId)
        putBlob(m.kyberPreKeyPublic.serialize())
        putBlob(m.kyberPreKeySignature)
        return d
    }

    struct Decoded {
        let registrationId: UInt32
        let deviceId: UInt32
        let preKeyId: UInt32
        let preKeyPublic: PublicKey
        let signedPreKeyId: UInt32
        let signedPreKeyPublic: PublicKey
        let signedPreKeySignature: Data
        let identityKey: IdentityKey
        let kyberPreKeyId: UInt32
        let kyberPreKeyPublic: KEMPublicKey
        let kyberPreKeySignature: Data
    }

    static func decode(_ data: Data) throws -> Decoded {
        var cursor = data.startIndex
        func need(_ n: Int) throws {
            guard data.distance(from: cursor, to: data.endIndex) >= n else {
                throw SignalAdapterError.bundleMalformed
            }
        }
        func getU32() throws -> UInt32 {
            try need(4)
            let slice = data[cursor..<data.index(cursor, offsetBy: 4)]
            cursor = data.index(cursor, offsetBy: 4)
            return slice.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        func getBlob() throws -> Data {
            let len = Int(try getU32())
            try need(len)
            let slice = data[cursor..<data.index(cursor, offsetBy: len)]
            cursor = data.index(cursor, offsetBy: len)
            return Data(slice)
        }

        let registrationId = try getU32()
        let deviceId = try getU32()
        let preKeyId = try getU32()
        let preKeyPublic = try PublicKey(getBlob())
        let signedPreKeyId = try getU32()
        let signedPreKeyPublic = try PublicKey(getBlob())
        let signedPreKeySignature = try getBlob()
        let identityKey = try IdentityKey(bytes: getBlob())
        let kyberPreKeyId = try getU32()
        let kyberPreKeyPublic = try KEMPublicKey(getBlob())
        let kyberPreKeySignature = try getBlob()

        return Decoded(
            registrationId: registrationId, deviceId: deviceId,
            preKeyId: preKeyId, preKeyPublic: preKeyPublic,
            signedPreKeyId: signedPreKeyId, signedPreKeyPublic: signedPreKeyPublic,
            signedPreKeySignature: signedPreKeySignature,
            identityKey: identityKey,
            kyberPreKeyId: kyberPreKeyId, kyberPreKeyPublic: kyberPreKeyPublic,
            kyberPreKeySignature: kyberPreKeySignature
        )
    }
}

// MARK: - Per-peer session

/// A `SecureSession` for one peer, backed by libsignal's `signalEncrypt` /
/// `signalDecrypt`. Holds no ratchet state itself — that lives in the store;
/// this is a thin handle over a `ProtocolAddress`.
final class SignalSession: SecureSession, @unchecked Sendable {

    let peer: PublicIdentity
    private let peerAddress: ProtocolAddress
    private let localAddress: ProtocolAddress
    private let store: any BeaconProtocolStore
    private let context: StoreContext

    private(set) var state: SecureSessionState

    init(peer: PublicIdentity,
         peerAddress: ProtocolAddress,
         localAddress: ProtocolAddress,
         store: any BeaconProtocolStore,
         context: StoreContext,
         established: Bool) {
        self.peer = peer
        self.peerAddress = peerAddress
        self.localAddress = localAddress
        self.store = store
        self.context = context
        self.state = established ? .established : .uninitialized
    }

    func seal(_ plaintext: Data) throws -> Data {
        do {
            let msg = try signalEncrypt(
                message: plaintext,
                for: peerAddress,
                localAddress: localAddress,
                sessionStore: store,
                identityStore: store,
                context: context
            )
            state = .established
            // Prefix the libsignal message-type byte so `open` knows whether
            // this is a prekey (establishing) message or a normal one.
            var out = Data([msg.messageType.rawValue])
            out.append(msg.serialize())
            return out
        } catch {
            throw SignalAdapterError.signal(underlying: error)
        }
    }

    func open(_ payload: Data) throws -> Data {
        guard let typeByte = payload.first else {
            throw SignalAdapterError.unexpectedMessageType
        }
        let body = payload.dropFirst()
        let type = CiphertextMessage.MessageType(rawValue: typeByte)

        do {
            switch type {
            case .preKey:
                // First inbound message — establishes the session as a side
                // effect, consuming our stored prekeys.
                let message = try PreKeySignalMessage(bytes: body)
                let plaintext = try signalDecryptPreKey(
                    message: message,
                    from: peerAddress,
                    localAddress: localAddress,
                    sessionStore: store,
                    identityStore: store,
                    preKeyStore: store,
                    signedPreKeyStore: store,
                    kyberPreKeyStore: store,
                    context: context
                )
                state = .established
                return plaintext

            case .whisper:
                let message = try SignalMessage(bytes: body)
                let plaintext = try signalDecrypt(
                    message: message,
                    from: peerAddress,
                    to: localAddress,
                    sessionStore: store,
                    identityStore: store,
                    context: context
                )
                state = .established
                return plaintext

            default:
                throw SignalAdapterError.unexpectedMessageType
            }
        } catch let e as SignalAdapterError {
            throw e
        } catch {
            throw SignalAdapterError.signal(underlying: error)
        }
    }

    func safetyNumber() throws -> SafetyNumber {
        // Derived from BOTH identity public keys, deterministically — survives
        // session resets (the review's §3.5 constraint).
        let generator = NumericFingerprintGenerator(iterations: 5200)
        let localKey = try PublicKey(store.localIdentity.publicKey.serialize())
        let remoteKey = try PublicKey(peer.agreementKey)  // see note below
        let fp = try generator.create(
            version: 2,
            localIdentifier: Data(store.localIdentity.publicKey.serialize()),
            localKey: store.localIdentity.publicKey,
            remoteIdentifier: Data(remoteKey.serialize()),
            remoteKey: remoteKey
        )
        _ = localKey
        return SafetyNumber(
            displayString: fp.displayable.formatted,
            qrPayload: fp.scannable.encoding
        )
    }
}
