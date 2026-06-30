//
//  BeaconRecognizer.swift
//  Security/Session
//
//  Receiver side of the closed-contact reconnection handshake (Step 5, see
//  docs/RECONNECT_HANDSHAKE.md). Given the discovery beacons observed on a BLE
//  link, decides which — if any — of our known contacts is present, by matching
//  the observed tokens against the tokens each contact is predicted to emit this
//  epoch (and the adjacent epochs, to absorb clock skew).
//
//  PURE + INJECTED. This type derives no secrets and reads no clock. Each
//  contact's per-pairing discovery secret `S_AB` is INJECTED (`Contact.secret`),
//  the same way SASWordPhrase injects its wordlist — so the recognizer is
//  independent of how `S_AB` is produced. The current epoch is passed in.
//
//  LABEL CONVENTION (RECONNECT_BEACON_KAT.md): a contact emits its beacon
//  labelled with ITS OWN identity, so to predict contact i's token we evaluate
//  ReconnectBeacon.token(secret: S_i, epoch: e, label: identity_i). `identity` is
//  the raw 32-byte key (`Peer.publicKeyData`) the coordinator already uses — and
//  it doubles as the beacon label.
//
//  ⚠️ A MATCH IS A HINT ONLY (Invariant #2, RECONNECT_HANDSHAKE §7). Recognition
//  says which session to ATTEMPT. Admission of the BLE link and any presence flip
//  MUST gate on the sealed "it's-me" opening under that session — NEVER on a
//  token match here. The beacon layer is replayable by design.
//

import Foundation

public enum BeaconRecognizer {

    /// One known contact's recognition material.
    public struct Contact: Equatable, Sendable {
        /// Raw 32-byte identity key (`Peer.publicKeyData`). Also the beacon label
        /// this contact emits under.
        public let identity: Data
        /// The per-pairing discovery secret `S_AB`. Derivation is external and
        /// injected here (see file header).
        public let secret: Data

        public init(identity: Data, secret: Data) {
            self.identity = identity
            self.secret = secret
        }
    }

    /// The epochs to predict for, given a current epoch and a skew tolerance:
    /// `{epoch-skew … epoch+skew}`, clamped at 0 so a low epoch never underflows
    /// (UInt64). Defensive against overflow at the top end as well.
    public static func epochWindow(epoch: UInt64, skew: UInt64 = 1) -> [UInt64] {
        let lo = epoch >= skew ? epoch &- skew : 0
        let hi = epoch > UInt64.max &- skew ? UInt64.max : epoch &+ skew
        var out: [UInt64] = []
        var e = lo
        while true {
            out.append(e)
            if e == hi { break }
            e &+= 1
        }
        return out
    }

    /// Build the expected `token → identity` table over all contacts across the
    /// epoch skew window. O(contacts × window) cheap PRF evals; mutates no state.
    /// On the astronomically-improbable token collision, last write wins —
    /// harmless, since admission re-checks via the sealed it's-me anyway.
    public static func expectedTable(
        contacts: [Contact],
        epoch: UInt64,
        skew: UInt64 = 1
    ) -> [Data: Data] {
        let window = epochWindow(epoch: epoch, skew: skew)
        var table: [Data: Data] = [:]
        table.reserveCapacity(contacts.count * window.count)
        for e in window {
            for c in contacts {
                let token = ReconnectBeacon.token(secret: c.secret, epoch: e, label: c.identity)
                table[token] = c.identity
            }
        }
        return table
    }

    /// Recognize which known contacts are present in an observed emission set.
    /// Returns the raw identities whose predicted token (within the skew window)
    /// appears in `emissionSet`. Decoys and strangers match nothing.
    ///
    /// Matching is a hash-set lookup, not secret equality — no constant-time
    /// compare needed (these are public-on-the-wire tokens, not secrets).
    public static func recognize(
        emissionSet: [Data],
        contacts: [Contact],
        epoch: UInt64,
        skew: UInt64 = 1
    ) -> Set<Data> {
        guard !contacts.isEmpty else { return [] }
        let table = expectedTable(contacts: contacts, epoch: epoch, skew: skew)
        var present: Set<Data> = []
        for token in emissionSet {
            if let identity = table[token] { present.insert(identity) }
        }
        return present
    }
}
