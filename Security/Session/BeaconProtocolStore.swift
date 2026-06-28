// BeaconProtocolStore.swift
// Security/Session
//
// THE SEAM (Phase 5a.3). One protocol that BOTH storage backends satisfy:
//   • InMemoryBeaconStore     (PASS 1 — fast, ephemeral; kept for tests)
//   • PersistentBeaconStore   (PASS 2 — vault-backed, survives relaunch)
//
// SignalSession / SignalSessionStore type against this protocol instead of the
// concrete in-memory class, so the storage backend can be swapped with no
// change to adapter logic, the crypto boundary, or any caller. The libsignal
// cipher functions take their stores as plain existential parameters, so an
// `any BeaconProtocolStore` upcasts cleanly to each of the six store protocols.
//
// `BundleMaterial` is lifted here (it used to be nested in InMemoryBeaconStore)
// so both backends can produce it, and `freshBundleMaterial` is provided once
// as a protocol extension — the single shared implementation of bundle
// production. The only per-backend difference is how one-time prekey ids are
// allocated (ephemeral counter vs. a persisted one), which is the one
// requirement the protocol adds on top of identity + the six stores.
//

import Foundation
import LibSignalClient

// MARK: - BundleMaterial (lifted to top level)

/// The public + private material for one prekey bundle. The private halves are
/// already stored in the producing store by the time this is returned; the
/// public halves here are what `BundleWire` serializes for the carrier.
struct BundleMaterial {
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

// MARK: - BeaconProtocolStore

/// The union of libsignal's six store protocols plus the two things the adapter
/// needs on top: synchronous access to the local identity, and durable one-time
/// prekey id allocation.
protocol BeaconProtocolStore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore,
    KyberPreKeyStore, SessionStore, SenderKeyStore {

    /// Our own identity, for synchronous, throw-free access (e.g. safetyNumber).
    var localIdentity: IdentityKeyPair { get }

    /// Allocate the next one-time prekey id. The persistent backend persists the
    /// counter so ids never collide across launches; the in-memory backend just
    /// bumps a field.
    func allocateOneTimePreKeyId() throws -> UInt32
}

// MARK: - Shared bundle production

extension BeaconProtocolStore {

    /// Generate, store the private halves of, and return the material for a
    /// fresh prekey bundle (one-time prekey + signed prekey + post-quantum Kyber
    /// prekey). This is the single shared implementation both backends use; it
    /// touches the store only through the six protocol methods, so it is
    /// backend-agnostic. (Was InMemoryBeaconStore.freshBundleMaterial.)
    func freshBundleMaterial(deviceId: UInt32) throws -> BundleMaterial {
        let ctx = NullContext()
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)

        // One-time prekey (EC).
        let preKeyId = try allocateOneTimePreKeyId()
        let preKeyPriv = PrivateKey.generate()
        try storePreKey(try PreKeyRecord(id: preKeyId, privateKey: preKeyPriv),
                        id: preKeyId, context: ctx)

        // Signed prekey (EC), signed by the identity key. Fixed id 1.
        let signedPreKeyId: UInt32 = 1
        let signedPriv = PrivateKey.generate()
        let signedPub = signedPriv.publicKey
        let signedSig = localIdentity.privateKey.generateSignature(message: signedPub.serialize())
        try storeSignedPreKey(
            try SignedPreKeyRecord(id: signedPreKeyId, timestamp: nowMs,
                                   privateKey: signedPriv, signature: signedSig),
            id: signedPreKeyId, context: ctx)

        // Kyber prekey (post-quantum), signed by the identity key. Fixed id 1.
        let kyberPreKeyId: UInt32 = 1
        let kyberPair = KEMKeyPair.generate()
        let kyberSig = localIdentity.privateKey.generateSignature(message: kyberPair.publicKey.serialize())
        try storeKyberPreKey(
            try KyberPreKeyRecord(id: kyberPreKeyId, timestamp: nowMs,
                                  keyPair: kyberPair, signature: kyberSig),
            id: kyberPreKeyId, context: ctx)

        return BundleMaterial(
            registrationId: try localRegistrationId(context: ctx),
            deviceId: deviceId,
            preKeyId: preKeyId, preKeyPublic: preKeyPriv.publicKey,
            signedPreKeyId: signedPreKeyId, signedPreKeyPublic: signedPub,
            signedPreKeySignature: signedSig,
            identityKey: localIdentity.identityKey,
            kyberPreKeyId: kyberPreKeyId, kyberPreKeyPublic: kyberPair.publicKey,
            kyberPreKeySignature: kyberSig)
    }
}

// MARK: - Conformances

// Both backends already provide the six libsignal protocols, `localIdentity`,
// and `allocateOneTimePreKeyId`; `freshBundleMaterial` comes from the extension
// above, so these conformances are empty.
extension InMemoryBeaconStore: BeaconProtocolStore {}
extension PersistentBeaconStore: BeaconProtocolStore {}
