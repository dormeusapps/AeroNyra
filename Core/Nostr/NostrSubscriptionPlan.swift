//
//  NostrSubscriptionPlan.swift
//  Core/Nostr
//
//  v59 connection-leak fix · Stage 5 · what the REQ carries, decided purely.
//
//  Turns the transport's inputs at one instant — the contact tag table, the
//  decoy secret, the live invite-echo registrations, the clock — into the
//  exact list of subscriptions to hold open on every relay socket:
//
//    • CONTACT PAGES: the padded subscribe set for the locked window
//      (30 epochs back + 1 ahead), cut into pages of 60 slots × 32 epochs =
//      1,920 values. One REQ per page. A device with zero contacts still holds
//      one full page of decoys (cover traffic). nil table or nil decoy secret
//      → NO pages: subscribing to a bare, unpadded set is exactly the leak, so
//      the plan refuses rather than degrades, and the transport logs it.
//
//    • INVITE-ECHO TAGS: while any minted invite is live, the minter listens
//      for the redeemer's echo on `NostrInviteEchoTag` tags across the skew
//      window {e-1, e, e+1}. Their OWN subscription, not folded into a page:
//      folding would move values inside a page mid-epoch (mint / expiry), and
//      3-per-invite does not fit the 32-per-slot shape. A relay therefore sees
//      a short-lived second subscription while an invite is pending — an
//      "invite in flight" tell for at most TTL + skew, bound to nothing durable.
//      Expired registrations are pruned here on every plan.
//
//  ROLLOVER: `secondsUntilNextEpoch` gives the transport its timer; on fire it
//  re-plans and re-REQs on the SAME subscription ids (NIP-01 filter replacement).
//
//  PURE + INJECTED. No clock, no I/O, no randomness. Byte-stable: same inputs →
//  same pages (the padding is deterministic per epoch and the sets are sorted).
//

import Foundation

public struct NostrSubscriptionPlan: Equatable, Sendable {

    /// A minted invite the minter is still listening for.
    public struct InviteEcho: Equatable, Sendable, Hashable {
        public let inviteID: Data
        public let expiresAtMillis: Int64
        public init(inviteID: Data, expiresAtMillis: Int64) {
            self.inviteID = inviteID
            self.expiresAtMillis = expiresAtMillis
        }
    }

    /// Contact pages, each a sorted list of 64-char lowercase hex tags.
    public let pages: [[String]]
    /// Invite-echo tags across the skew window for every live invite, sorted
    /// and de-duplicated. Empty when no invite is live.
    public let inviteEchoTags: [String]

    public static let echoEpochsBack: UInt64 = 1
    public static let echoEpochsAhead: UInt64 = 1

    // MARK: Build

    public static func make(table: NostrInboxTagTable?,
                            decoySecret: Data?,
                            inviteEchoes: [InviteEcho],
                            nowSeconds: UInt64,
                            pageSlots: Int = NostrInboxDecoy.pageSlotCount,
                            skewMillis: Int64 = Invite.defaultSkewMillis) -> NostrSubscriptionPlan {
        var pages: [[String]] = []
        if let table, let decoySecret {
            let window = NostrInboxTagTable.epochWindow(atSeconds: nowSeconds)
            pages = NostrInboxDecoy.paddedSubscribeTags(table: table, epochs: window,
                                                        decoySecret: decoySecret,
                                                        pageSlots: pageSlots).paged
        }
        let epoch = NostrInboxTag.epoch(at: nowSeconds)
        let low = epoch >= echoEpochsBack ? epoch - echoEpochsBack : 0
        var echoSet = Set<String>()
        for echo in liveEchoes(inviteEchoes, nowSeconds: nowSeconds, skewMillis: skewMillis) {
            for tag in NostrInviteEchoTag.subscribeTags(inviteID: echo.inviteID,
                                                       epochs: low...(epoch + echoEpochsAhead)) {
                echoSet.insert(tag)
            }
        }
        return NostrSubscriptionPlan(pages: pages, inviteEchoTags: echoSet.sorted())
    }

    /// The registrations still worth listening for: `now <= expiresAt + skew`,
    /// the same leniency `Invite.isLive` applies on the redeem side.
    public static func liveEchoes(_ echoes: [InviteEcho],
                                  nowSeconds: UInt64,
                                  skewMillis: Int64 = Invite.defaultSkewMillis) -> [InviteEcho] {
        let nowMillis = Int64(nowSeconds) * 1000
        return echoes.filter { nowMillis <= $0.expiresAtMillis + skewMillis }
    }

    // MARK: Rollover

    /// Seconds from `nowSeconds` to the start of the next epoch. Never 0: at an
    /// exact boundary the answer is a full epoch, because that boundary's
    /// rollover is the one firing now.
    public static func secondsUntilNextEpoch(nowSeconds: UInt64) -> UInt64 {
        let length = NostrInboxTag.epochLength
        let intoEpoch = nowSeconds % length
        return length - intoEpoch
    }
}
