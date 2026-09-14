//
//  NostrInboxDecoy.swift
//  Core/Nostr
//
//  v59 connection-leak fix · Stage 3 · decoy padding for the subscribe set.
//
//  The Stage 2 table's subscribe set is `rows × window` tags, so its size on the
//  REQ is the contact count in the clear. This file pads it to a FIXED slot
//  count per page so a relay cannot read the count off the filter. Still off
//  the socket: no transport, no wrap, no wire change.
//
//  TWO WAYS THIS DOES NOTHING, both designed out (KAT §6):
//
//   1. Decoys must be CURVE-VALID. About half of random 32-byte values fail the
//      secp256k1 x-only test, so random padding lets a relay split the set into
//      "plausible pubkeys" and "not", and the real count falls straight out.
//      A decoy here IS a real-tag computation: `NostrInboxTag.tag` under a
//      device-local secret and a synthetic per-slot label — same domain, same
//      HMAC, same counter search, same distribution. By construction there is
//      no property, other than whether anyone ever publishes to it, that
//      separates a decoy from a real tag.
//
//   2. Decoys must be BYTE-IDENTICAL for a whole epoch, and across the sliding
//      window. `NostrTransport` re-sends the REQ on every reconnect (:442); if
//      padding were re-randomised per REQ, a relay diffs two subscriptions
//      inside one epoch and everything that moved is a decoy — which unmasks
//      the real tags exactly. And the window slides one epoch per day, so a
//      decoy for epoch E must be the SAME bytes on every day E is in the
//      window, or the day-over-day diff separates decoys (churn) from real
//      tags (persist). Every decoy is therefore a pure function of
//      (decoy secret, epoch, slot): deterministic per device, stable for the
//      life of that epoch, different every epoch (a slot yielding the same
//      value every epoch would be a device fingerprint).
//
//  THE DECOY SECRET IS KEYED ON THE LIBSIGNAL IDENTITY, NOT THE NSEC — so it
//  cannot churn independently of the contact set. Every real tag is keyed on
//  S_AB = DH(our X25519 identity, theirs) and never touches the Nostr key. If
//  the decoy secret were derived from the nsec, an npub rotation (A2) would
//  change every decoy while every real tag stayed put, and a relay diffing the
//  REQ across that moment would separate the two sets exactly — the §6 attack,
//  triggered by a rotation instead of a re-REQ. Derived from the identity
//  agreement private key instead (HKDF-SHA256 under its own info string), the
//  decoy secret has exactly S_AB's lifetime: an npub rotation changes NOTHING
//  in the REQ (tags never involve the npub), and an identity regeneration
//  changes the whole set at once, real and decoy alike, which is the uniform
//  discontinuity a re-pair implies anyway. Derived, never stored: it survives
//  relaunch with the identity (`IdentityStore`, WhenUnlockedThisDeviceOnly,
//  Secure-Enclave-wrapped) and dies with it under crypto-erase (the identity
//  store is the core wipe step). Nothing new to register, so this cannot be
//  the class of miss the accent key is. The builder already receives
//  `ourAgreementPrivate` (`NostrInboxTagTable.build`), so wiring adds no new
//  plumbing. This file never touches the Keychain.
//
//  PAGE SIZE S = 60 SLOTS, confirmed against a real serialized frame: the REQ
//  the transport builds (`["REQ", subID, {"kinds":[1059], "#p":[…]}]`, compact
//  JSON) carries 60 × 32 = 1,920 values in 128,691 bytes, under nos.lol's
//  131,072-byte frame with 2,381 bytes to spare; 61 fits with 237 to spare and
//  62 does not. The 2,047-value filter cap binds later (S ≤ 63). So the FRAME
//  binds, at 60. Cost: ~129 KB per page per relay on every reconnect.
//
//  BEYOND ONE PAGE — BUCKET PADDING, NEVER BARE. Real contacts past S do not
//  drop the padding (that would reveal the exact count, a silent privacy cliff
//  for having many contacts) and do not crash. The slot count rounds UP to a
//  whole number of pages, every page fully padded, so a relay learns the count
//  only to page granularity: "≤60", "61–120", …. `pages` says how many. A second
//  filter object in the same REQ does NOT help on nos.lol — the frame cap is
//  per message, not per filter — so carrying page 2 means a second REQ
//  (subscriptions are capped at 20 per connection on nos.lol and primal) or, on
//  the 1 MB-frame relays, extra filter objects (200 per REQ). Which, is the
//  transport's call at Stage 5; this file hands over a sorted set already cut
//  into pages (`paged`), each page byte-stable for the epoch on its own.
//
//  SLOT ASSIGNMENT: real contacts occupy slots 0..<realSlots (by count only —
//  no ordering leaks, the whole set is sorted); decoys fill the rest. A
//  duplicated row consumes one slot, matching the table's own de-duplication.
//
//  RESIDUALS (recorded, not fixed — carried to Stage 5 and the §3 rewrite):
//   • Adding a contact mid-epoch displaces exactly one decoy slot, so a relay
//     sees exactly 32 values leave and 32 arrive and can bucket that contact's
//     whole window as real; removing one is the mirror. Over repeated
//     enrollments it learns which slots are real. Stage 5 may apply contact
//     changes at the next epoch rollover, where the whole set moves anyway.
//   • Nobody ever publishes to a decoy, so over time a relay that also carries
//     the contact's traffic can count tags that receive events — the number of
//     ACTIVE contact-epochs, not the list size. Inherent to any padding.
//   • Consecutive-day windows overlap in 31/32 of their values, so a receiver
//     connection is linkable across days by its subscription, decoys included.
//     Inherent to the sliding window; recorded in the options analysis.
//
//  PURE + INJECTED. No clock, no I/O, no randomness.
//

import Foundation
import CryptoKit

public enum NostrInboxDecoy {

    // MARK: Locked constants (v1)

    /// HKDF `info` for deriving the decoy secret from the identity agreement key.
    public static let secretInfo = Data("AeroNyra/nostr-inbox-decoy-secret/v1".utf8)

    /// Domain for the synthetic per-slot label fed to the tag search.
    public static let labelDomain = Data("AeroNyra/nostr-inbox-decoy-label/v1".utf8)

    /// Fixed slot count per page. See the file header for the frame measurement.
    public static let pageSlotCount = 60

    /// Bytes of the derived decoy secret.
    public static let secretLength = 32

    // MARK: Decoy secret (derived from the identity, never stored)

    /// The device-local decoy secret: `HKDF-SHA256(ikm = our X25519 identity
    /// agreement private key (raw 32 bytes), salt = "", info = secretInfo,
    /// L = 32)`. Empty salt is the RFC 5869 "not provided" path, the same
    /// convention as `DiscoverySecret`. Keyed on the identity so its lifetime
    /// is exactly S_AB's (see the file header).
    public static func secret(fromAgreementPrivate key: Curve25519.KeyAgreement.PrivateKey) -> Data {
        let raw = key.rawRepresentation
        precondition(raw.count == 32, "X25519 private key must be 32 bytes, got \(raw.count)")
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: raw),
                                             salt: Data(), info: secretInfo,
                                             outputByteCount: secretLength)
        return derived.withUnsafeBytes { Data($0) }
    }

    // MARK: Slot label

    /// The synthetic 32-byte "identity" for decoy slot `slot`:
    /// `SHA256(labelDomain ‖ slot_be4)`. Public inputs only — the secret enters
    /// through the HMAC key in `decoy`, exactly as `S_AB` does for a real tag.
    public static func slotLabel(_ slot: UInt32) -> Data {
        var message = Data()
        message.append(labelDomain)
        var be = slot.bigEndian
        withUnsafeBytes(of: &be) { message.append(contentsOf: $0) }
        return Data(SHA256.hash(data: message))
    }

    // MARK: One decoy

    /// The decoy for `slot` in `epoch`: `NostrInboxTag.tag(secret: decoySecret,
    /// epoch: epoch, label: slotLabel(slot))`. Same construction as a real tag,
    /// so it is curve-valid, epoch-scoped, and deterministic.
    public static func decoy(secret: Data, epoch: UInt64, slot: UInt32) -> NostrInboxTag.Tag {
        NostrInboxTag.tag(secret: secret, epoch: epoch, label: slotLabel(slot))
    }

    // MARK: Padded subscribe set

    /// The padded subscribe set and what it is made of.
    public struct PaddedSet: Equatable, Sendable {
        /// Real tags ∪ decoys, 64-char lowercase hex, SORTED ASCENDING, de-duplicated.
        public let tags: [String]
        /// Distinct contact identities in the table (slots 0..<realSlots).
        public let realSlots: Int
        /// Decoy slots filled (realSlots..<slots).
        public let decoySlots: Int
        /// Total slots = pages × pageSlotCount; always a whole number of pages.
        public let slots: Int
        /// Whole pages the set spans. 1 unless real contacts exceed one page.
        public let pages: Int
        /// Values per page = pageSlotCount × epochs in the window.
        public let valuesPerPage: Int

        /// True when real contacts exceed one page: the set is still fully
        /// padded, but spans more than one REQ / filter. Stage 5 should log it.
        public var spilled: Bool { pages > 1 }

        /// The sorted set cut into `pages` consecutive chunks of `valuesPerPage`,
        /// the last possibly shorter only if de-duplication removed a value
        /// (probability ≈ 2⁻²⁵⁶). Each chunk is byte-stable for the epoch on
        /// its own, so a page can be carried as its own REQ or filter object.
        public var paged: [[String]] {
            stride(from: 0, to: tags.count, by: valuesPerPage).map {
                Array(tags[$0 ..< min($0 + valuesPerPage, tags.count)])
            }
        }
    }

    /// Pad `table`'s subscribe set over `epochs` to a whole number of pages of
    /// `pageSlots` contact slots each.
    ///
    /// - Parameters:
    ///   - table: the Stage 2 table (its `subscribeTags` supplies the real set).
    ///   - epochs: the subscribe window (`NostrInboxTagTable.epochWindow`).
    ///   - decoySecret: from `secret(fromAgreementPrivate:)`. INJECTED.
    ///   - pageSlots: slots per page; `pageSlotCount` in production, small in tests.
    public static func paddedSubscribeTags(table: NostrInboxTagTable,
                                           epochs: ClosedRange<UInt64>,
                                           decoySecret: Data,
                                           pageSlots: Int = pageSlotCount) -> PaddedSet {
        precondition(pageSlots > 0, "pageSlots must be positive")
        let real = table.subscribeTags(epochs: epochs)
        // Distinct identities, to match subscribeTags' own de-duplication of a
        // duplicated row.
        let realSlots = Set(table.rows.map(\.identity)).count
        // Round UP to whole pages, never bare, never fewer than one page.
        let pages = max(1, (realSlots + pageSlots - 1) / pageSlots)
        let slots = pages * pageSlots
        let decoySlots = slots - realSlots

        var set = Set(real)
        for slot in realSlots..<slots {
            for epoch in epochs {
                set.insert(decoy(secret: decoySecret, epoch: epoch, slot: UInt32(slot)).hex)
            }
        }
        return PaddedSet(tags: set.sorted(), realSlots: realSlots, decoySlots: decoySlots,
                         slots: slots, pages: pages,
                         valuesPerPage: pageSlots * epochs.count)
    }
}
