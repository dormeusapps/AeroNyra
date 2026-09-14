//
//  NostrInboxTagTable.swift
//  Core/Nostr
//
//  v59 connection-leak fix · Stage 2 · the contact tag table.
//
//  Stage 1 (`NostrInboxTag`) produces ONE tag from (S_AB, epoch, label). This
//  file turns "our identity + our paired contacts" into the two things the Nostr
//  leg will need once it is wired (Stage 4/5): the tag to put in the `p` slot
//  when PUBLISHING to a contact, and the set of tags we must SUBSCRIBE to so a
//  contact's publishes reach us. It is built and tested in isolation — no wire
//  change, no socket, no call site.
//
//  THE STAGE 2 FINDING — the two sides do not need the same inputs:
//    • SUBSCRIBE needs our agreement private key + each contact's raw X25519
//      identity (`ContactAllowlist.identities`). No npub.
//    • PUBLISH needs S_AB for the contact the router addressed BY NPUB
//      (`NostrTransport.publish(_:to:)` takes the x-only secp256k1 key, a
//      DISTINCT key from the X25519 identity — `PersistentModels.swift:69-78`).
//  So a row whose `nostrPubkey` is nil is a legitimate SUBSCRIBE-ONLY row, not
//  an error and not a skip: we can listen for a contact whose npub has never
//  been bootstrapped. Only the publish side needs the npub → identity join.
//
//  DIRECTIONALITY (KAT §1: `label` is always the EMITTER's identity):
//      we publish to C     tag(secret: S_AC, epoch: E, label: OUR raw identity)
//      we subscribe for C  tag(secret: S_AC, epoch: E, label: C's raw identity)
//  Same secret, opposite label — the rule `ReconnectEpochBuilder` already
//  implements for BLE (`ReconnectEpochBuilder.swift:112-118`). X25519 DH is
//  symmetric, so the tag we publish under our label is exactly the tag C's
//  table predicts for us; `tag(A→B) != tag(B→A)`, so no pairing edge is
//  visible. This is a SENDER-LABELLED tag, not a shared inbox: the subscribe
//  set holds one tag per contact per epoch.
//
//  RULING — `subscribeTags` is SORTED ASCENDING and DE-DUPLICATED. Not
//  cosmetic: Stage 3 needs the padded set BYTE-STABLE for a whole epoch (a
//  relay that diffs two REQs inside one epoch unmasks every value that moved),
//  and the real identities come from a `Set<Data>` whose iteration order is not
//  stable across launches. Stage 5 needs a canonical order to prove a rolled
//  frame differs only by the rolled epoch. Ordering leaks nothing — every value
//  becomes public the moment it is published.
//
//  NEVER fall back to the npub. `publishTag(to:)` for an unknown npub returns
//  nil; a caller that put the npub itself in the `p` slot would recreate the
//  exact leak this fix exists to remove.
//
//  NO CAP HERE. The subscribe set is `rows.count × window`; capping against the
//  relay filter budget is Stage 3's job (with the padding). A precondition here
//  would crash a device that legitimately has many contacts.
//
//  PURE + INJECTED. No clock (`epochWindow(atSeconds:)` takes the instant), no
//  I/O, no randomness (decoys are Stage 3). Mirrors `ReconnectEpochBuilder.plan`
//  deliberately: one `DiscoverySecret.derive` per contact, a malformed contact
//  key THROWS rather than being skipped.
//

import Foundation
import CryptoKit

public struct NostrInboxTagTable: Equatable, Sendable {

    // MARK: Locked constants (v1)

    /// Subscribe window: 30 epochs back + 1 ahead = 32 epochs (KAT §1 — forced
    /// by the relay filter budget at 86,400-second epochs).
    public static let epochsBack: UInt64 = 30
    public static let epochsAhead: UInt64 = 1

    // MARK: Rows

    /// One paired contact. `nostrPubkey` nil = subscribe-only (npub not yet
    /// bootstrapped); the row still contributes to the subscribe set.
    public struct Row: Equatable, Sendable {
        /// The contact's raw 32-byte X25519 identity — THEIR emission label.
        public let identity: Data
        /// S_AB, 32 bytes, from `DiscoverySecret.rawBytes(of:)`.
        public let secret: Data
        /// The contact's 32-byte x-only secp256k1 Nostr key, or nil.
        public let nostrPubkey: Data?

        public init(identity: Data, secret: Data, nostrPubkey: Data?) {
            self.identity = identity
            self.secret = secret
            self.nostrPubkey = nostrPubkey
        }
    }

    /// Our raw 32-byte identity — the label on everything we publish.
    public let ourIdentity: Data
    public let rows: [Row]

    /// TEST SEAM (internal, not public): lets the KAT vectors be injected as
    /// secrets directly, the same reason `NostrInboxTag.candidate` is internal.
    /// Production goes through `build`, which derives every secret.
    init(ourIdentity: Data, rows: [Row]) {
        precondition(ourIdentity.count == NostrInboxTag.labelLength,
                     "ourIdentity must be a \(NostrInboxTag.labelLength)-byte raw identity key, got \(ourIdentity.count)")
        self.ourIdentity = ourIdentity
        self.rows = rows
    }

    // MARK: Builder (mirrors ReconnectEpochBuilder.plan)

    /// Build the table for this device.
    ///
    /// - Parameters:
    ///   - ourAgreementPrivate: our identity X25519 key-agreement private key.
    ///   - ourIdentity: our raw 32-byte identity — MUST be the bytes the peer
    ///     stored for us at pairing (`store.rawPublicKey(of:)` for our own
    ///     identity), since that is the label the peer's table predicts us under.
    ///   - contacts: each paired contact's raw 32-byte X25519 identity and its
    ///     npub if bootstrapped (nil = subscribe-only row).
    /// - Throws: `CryptoKitError` from `DiscoverySecret.derive` if any contact
    ///   identity is not a valid X25519 public key (e.g. wrong length). A bad
    ///   contact key is surfaced, never silently skipped.
    public static func build(
        ourAgreementPrivate: Curve25519.KeyAgreement.PrivateKey,
        ourIdentity: Data,
        contacts: [(identity: Data, nostrPubkey: Data?)]
    ) throws -> NostrInboxTagTable {
        precondition(ourIdentity.count == NostrInboxTag.labelLength,
                     "ourIdentity must be a \(NostrInboxTag.labelLength)-byte raw identity key, got \(ourIdentity.count)")
        var rows: [Row] = []
        rows.reserveCapacity(contacts.count)
        for contact in contacts {
            // ONE S_AC per contact, reused for both directions.
            let secretKey = try DiscoverySecret.derive(
                ourAgreementPrivate: ourAgreementPrivate,
                theirAgreementPublic: contact.identity)
            rows.append(Row(identity: contact.identity,
                            secret: DiscoverySecret.rawBytes(of: secretKey),
                            nostrPubkey: contact.nostrPubkey))
        }
        return NostrInboxTagTable(ourIdentity: ourIdentity, rows: rows)
    }

    // MARK: Publish side (needs the npub → row join)

    /// The tag to put in the `p` slot when publishing to this npub in this
    /// epoch: `tag(S_AC, epoch, label: OUR identity)`. nil for an npub with no
    /// row — NEVER fall back to the npub itself.
    public func publishTag(to nostrPubkey: Data, epoch: UInt64) -> NostrInboxTag.Tag? {
        guard let row = rows.first(where: { $0.nostrPubkey == nostrPubkey }) else { return nil }
        return NostrInboxTag.tag(secret: row.secret, epoch: epoch, label: ourIdentity)
    }

    // MARK: Subscribe side (no npub needed)

    /// Every tag we must be subscribed to across `epochs`: for each row and each
    /// epoch, `tag(S_AC, epoch, label: THE CONTACT's identity)`, as 64-char
    /// lowercase hex, SORTED ASCENDING and de-duplicated (see the file header).
    public func subscribeTags(epochs: ClosedRange<UInt64>) -> [String] {
        var tags = Set<String>()
        for row in rows {
            for epoch in epochs {
                tags.insert(NostrInboxTag.tag(secret: row.secret, epoch: epoch,
                                              label: row.identity).hex)
            }
        }
        return tags.sorted()
    }

    // MARK: Epoch window (now INJECTED)

    /// The locked subscribe window around the epoch containing `now`: 30 epochs
    /// back + 1 ahead = 32 epochs. `now` is INJECTED — this never reads the wall
    /// clock. The low end is clamped at epoch 0, so a `now` inside the first 30
    /// epochs yields a shorter window rather than underflowing.
    public static func epochWindow(atSeconds now: UInt64) -> ClosedRange<UInt64> {
        let current = NostrInboxTag.epoch(at: now)
        let low = current >= epochsBack ? current - epochsBack : 0
        return low...(current + epochsAhead)
    }
}
