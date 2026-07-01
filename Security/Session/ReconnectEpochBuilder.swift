//
//  ReconnectEpochBuilder.swift
//  Security/Session
//
//  Closed-Contact Step 5d-2. The pure per-epoch builder that turns "our identity
//  + our paired contacts + an epoch" into the two artifacts the reconnection
//  handshake's Phase-1 needs on a fresh BLE link (docs/RECONNECT_AUTH_WIRING_5d.md
//  §2.4 / §1):
//
//      1. our EMISSION SET   — the 64 decoy-padded tokens this device blasts,
//         each real token labelled with OUR identity (the directional rule), and
//      2. our RECOGNIZER TABLE — `BeaconRecognizer.Contact`s that let us predict
//         each contact's token (labelled with THEIR identity) and so recognise
//         who is present in a peer's emission set.
//
//  This is the layer that ties the three KAT-anchored primitives together; it
//  introduces no new crypto of its own:
//      • DiscoverySecret.derive   — S_AC = HKDF(X25519(ourPriv, C_pub))   (5c)
//      • ReconnectBeacon.token / .emissionSet — the emit side               (5a)
//      • BeaconRecognizer.Contact — the recognize side                      (5b)
//
//  SAME SECRET, OPPOSITE LABEL (the directionality the beacon KAT bakes in).
//  Per contact C we derive ONE S_AC and use it twice:
//      emit      token(secret: S_AC, epoch: E, label: OUR id)
//      recognize Contact(identity: C, secret: S_AC) → predicts
//                token(secret: S_AC, epoch: E, label: C id)
//  Because X25519 DH is symmetric (S_AC == S_CA), the token we emit under our own
//  label is byte-for-byte the token the peer's recognizer predicts for us, and
//  vice-versa — which is exactly why two paired devices recognise each other.
//
//  PURE + INJECTED. No clock (the `epoch` is passed in, bucketed by the caller
//  via `ReconnectBeacon.epoch(at:epochLength:)`); no I/O; randomness for the
//  decoy padding is injected via `rng` (CSPRNG in production, seeded in tests).
//
//  ⚠️ A TOKEN MATCH IS A HINT ONLY (Invariant #2). This builder produces the
//  discovery layer; nothing here authenticates or admits a link. Admission gates
//  on the sealed reconnect it's-me opening under the recognised session, never on
//  a token match. The beacon layer is replayable by design.
//
//  WIRING NOTE (Invariant #3, not enforced here): `ourIdentity` MUST be the bytes
//  the peer stored for us at pairing — i.e. `store.rawPublicKey(of:)` for our own
//  identity — since that is definitionally the label the peer's recognizer
//  predicts us under. The builder takes it as a parameter rather than deriving it
//  from the private key, so the composition root supplies the store-sourced bytes.
//

import Foundation
import CryptoKit

public enum ReconnectEpochBuilder {

    /// The two per-epoch artifacts for one device on a fresh link.
    public struct Plan: Equatable, Sendable {
        /// Our fixed-size (decoy-padded, shuffled) emission set — what we blast in
        /// Phase 1. Each real token is labelled with OUR identity.
        public let emissionSet: [Data]
        /// Our recognizer contacts — fed to `BeaconRecognizer.recognize` against a
        /// peer's emission set to learn which contact (if any) is present.
        public let recognizerContacts: [BeaconRecognizer.Contact]

        public init(emissionSet: [Data], recognizerContacts: [BeaconRecognizer.Contact]) {
            self.emissionSet = emissionSet
            self.recognizerContacts = recognizerContacts
        }
    }

    /// Build this device's per-epoch `Plan`.
    ///
    /// - Parameters:
    ///   - ourAgreementPrivate: our identity X25519 key-agreement private key
    ///     (`IdentityKeypair.agreement`). Drives every S_AC.
    ///   - ourIdentity: our raw 32-byte identity key, sourced from
    ///     `store.rawPublicKey(of:)` (Invariant #3) — the label our real tokens
    ///     carry and the one the peer recognises us under.
    ///   - contacts: the raw 32-byte identities to build for — the paired set
    ///     (typically `ContactAllowlist.identities`). Policy (whether to include
    ///     unverified contacts) is the caller's; during 5d coexistence it is all
    ///     paired identities. An empty list yields an all-decoy emission set and an
    ///     empty recognizer table — a contactless device still emits cover traffic.
    ///   - epoch: the current time-bucket index (injected; see
    ///     `ReconnectBeacon.epoch(at:epochLength:)`).
    ///   - size: emission-set size (default 64). Forwarded to
    ///     `ReconnectBeacon.emissionSet`, which preconditions `contacts.count <= size`.
    ///   - rng: randomness for decoy padding + shuffling (injected).
    /// - Returns: our `Plan` for this epoch.
    /// - Throws: `CryptoKitError` from `DiscoverySecret.derive` if any contact
    ///   identity is not a valid X25519 public key (e.g. wrong length). A bad
    ///   contact key is surfaced, never silently skipped.
    public static func plan<R: RandomNumberGenerator>(
        ourAgreementPrivate: Curve25519.KeyAgreement.PrivateKey,
        ourIdentity: Data,
        contacts: [Data],
        epoch: UInt64,
        size: Int = ReconnectBeacon.emissionSetSize,
        using rng: inout R
    ) throws -> Plan {
        precondition(ourIdentity.count == ReconnectBeacon.labelLength,
                     "ourIdentity must be a \(ReconnectBeacon.labelLength)-byte raw identity key, got \(ourIdentity.count)")

        var realTokens: [Data] = []
        realTokens.reserveCapacity(contacts.count)
        var recognizerContacts: [BeaconRecognizer.Contact] = []
        recognizerContacts.reserveCapacity(contacts.count)

        for contact in contacts {
            // ONE S_AC per contact, reused for both directions.
            let secretKey = try DiscoverySecret.derive(
                ourAgreementPrivate: ourAgreementPrivate,
                theirAgreementPublic: contact)
            let secret = DiscoverySecret.rawBytes(of: secretKey)

            // EMIT: our token for this pairing, labelled with OUR identity.
            realTokens.append(
                ReconnectBeacon.token(secret: secret, epoch: epoch, label: ourIdentity))

            // RECOGNIZE: predict the contact's token, labelled with THEIR identity.
            recognizerContacts.append(
                BeaconRecognizer.Contact(identity: contact, secret: secret))
        }

        let emissionSet = ReconnectBeacon.emissionSet(real: realTokens, size: size, using: &rng)
        return Plan(emissionSet: emissionSet, recognizerContacts: recognizerContacts)
    }
}
