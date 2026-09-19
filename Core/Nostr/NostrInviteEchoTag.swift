//
//  NostrInviteEchoTag.swift
//  Core/Nostr
//
//  v59 connection-leak fix · Stage 4 · the invite-echo tag.
//
//  THE GAP THIS CLOSES. The redeemer routes the sealed invite echo to the
//  minter's npub BEFORE the minter is enrolled or learned on the redeemer side
//  (`FirstContactCoordinator.redeemInvite` routes at the top, yields
//  `.established` / `.learnedNostrIdentity` after; `PairingService.redeemInvite`
//  enrolls after that). So at echo time the contact tag table has no row for
//  the minter, and the mirror is true on the minter side: it cannot predict
//  `tag(S_AB, e, redeemer)` before the echo tells it who the redeemer is. The
//  pair secret is the wrong key for this one message.
//
//  THE ONE THING BOTH SIDES HOLD BEFORE THE ECHO is the invite id — 16 CSPRNG
//  bytes minted by the minter, carried inside the invite, echoed back by the
//  redeemer. So the echo rides a tag keyed on it:
//
//      secret  = HKDF-SHA256(ikm = inviteID, salt = "", info = secretInfo, 32)
//      label   = SHA256(labelDomain)            fixed 32 bytes, no identity
//      tag(e)  = NostrInboxTag.tag(secret, e, label)   same search, curve-valid
//
//  The minter subscribes to `tag(e-1…e+1)` while the invite is live (Stage 5);
//  the redeemer's transport publishes the echo to `tag(e_now)` via a ONE-SHOT
//  registration keyed by the minter's npub (`NostrTransport.registerInviteEchoTag`),
//  consumed on the first publish to that npub. Every later message to the
//  minter rides the pair-secret tag from the table, which exists by then.
//
//  WHAT A RELAY LEARNS: an opaque, epoch-scoped tag that is a real-tag
//  computation (indistinguishable from any other `p` value), published once,
//  subscribed to by one connection while the invite is live — and, AS BUILT,
//  until the next plan refresh after expiry (typically the next epoch
//  rollover), not merely TTL plus skew: nothing arms a timer at expiry, so the
//  three-value subscription lingers (measured 2026-09-19; timer queued —
//  THREAT_MODEL §9.3). It binds to nothing durable: the invite id is
//  single-use and burned on echo.
//  Anyone holding the invite link can compute the tag — the same party can
//  redeem the invite outright, so no new capability is granted (CONTACT_MODEL
//  §14.3: the envelope is unauthenticated by design; SAS is the MITM defense).
//
//  PURE + INJECTED. No clock, no I/O. Vectors in the XCTest were computed out
//  of implementation (Python) before this Swift existed.
//

import Foundation
import CryptoKit

public enum NostrInviteEchoTag {

    // MARK: Locked constants (v1)

    /// HKDF `info` for deriving the echo secret from the invite id.
    public static let secretInfo = Data("AeroNyra/nostr-invite-echo-secret/v1".utf8)

    /// Domain hashed into the fixed 32-byte label.
    public static let labelDomain = Data("AeroNyra/nostr-invite-echo-label/v1".utf8)

    /// The fixed label: `SHA256(labelDomain)`. There is no identity to label the
    /// echo with, so the label is a constant — the invite id carries the secret.
    public static let label = Data(SHA256.hash(data: labelDomain))

    /// Invite id length (`Invite.idByteCount`).
    public static let inviteIDLength = 16

    /// Bytes of the derived echo secret.
    public static let secretLength = 32

    // MARK: Secret

    /// `HKDF-SHA256(ikm = inviteID, salt = "", info = secretInfo, L = 32)`. Empty
    /// salt is the RFC 5869 "not provided" path, the same convention as
    /// `DiscoverySecret` and `NostrInboxDecoy`.
    public static func secret(fromInviteID inviteID: Data) -> Data {
        precondition(inviteID.count == inviteIDLength,
                     "invite id must be \(inviteIDLength) bytes, got \(inviteID.count)")
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: inviteID),
                                             salt: Data(), info: secretInfo,
                                             outputByteCount: secretLength)
        return derived.withUnsafeBytes { Data($0) }
    }

    // MARK: Tag

    /// The echo tag for `inviteID` in `epoch`: the Stage 1 search under the
    /// invite-derived secret and the fixed label.
    public static func tag(inviteID: Data, epoch: UInt64) -> NostrInboxTag.Tag {
        NostrInboxTag.tag(secret: secret(fromInviteID: inviteID), epoch: epoch, label: label)
    }

    /// The minter's subscribe set for a live invite across `epochs` (clock skew
    /// window), 64-char lowercase hex, sorted ascending, de-duplicated — the
    /// same shape as `NostrInboxTagTable.subscribeTags`.
    public static func subscribeTags(inviteID: Data, epochs: ClosedRange<UInt64>) -> [String] {
        let secret = secret(fromInviteID: inviteID)
        var set = Set<String>()
        for epoch in epochs {
            set.insert(NostrInboxTag.tag(secret: secret, epoch: epoch, label: label).hex)
        }
        return set.sorted()
    }
}
