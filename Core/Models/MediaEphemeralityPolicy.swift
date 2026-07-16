//
//  MediaEphemeralityPolicy.swift
//  Core/Models
//
//  THE single source of truth for how long ephemeral media lives (SEC-6 / P3).
//
//  Shared by the render layer (the tombstone gates + in-view scheduled wipes
//  in Conversation1View) and the MessageInbox reaper, so the two can never
//  drift apart. Before this hoist each window lived as a `private static let`
//  inside a private view struct, which the reaper could not see — and a
//  duplicated constant is exactly the kind of drift the threat model can't
//  afford (ephemeral content must leave no trace).
//
//  POLICY:
//   • An INBOUND photo self-destructs `photoWindow` after it ARRIVED
//     (`Message.timestamp`, stamped at insert; nothing on the re-drive or
//     dedup paths ever resets it).
//   • An INBOUND voice note self-destructs `voiceListenWindow` after the
//     recipient FINISHED LISTENING (`Message.listenedAt`). An unlistened note
//     never expires — expiry is listen-armed by design.
//   • An OUTBOUND voice note self-destructs `voiceListenWindow` after it was
//     first CONFIRMED RECEIVED (`Message.deliveredAt` — stamped on
//     `.delivered`/`.relayed`). Delivery-anchored because the sender never
//     learns the receiver played it (there is no listened receipt on the
//     wire). An unconfirmed note never expires: `.notDelivered` keeps its
//     blob forever (it is the resend source), and `.cast` is a relay commit,
//     not a receipt.
//   • An INBOUND non-story VIDEO behaves exactly like a photo (v1 video
//     messages): `photoWindow` after arrival, receiver-side only.
//   • A STORY (EITHER direction) self-destructs `storyWindow` after it was
//     first SENT (`Message.sentAt` — outbound: stamped at first send and
//     reused on every retry; inbound: the manifest stamp clamped to arrival).
//   • Other OUTBOUND media never expires here: the blob is still needed to
//     resend a non-terminal row. Wiping sender-side copies is the deliberate
//     SEC-6 reversal, taken only where the blob's job is provably done —
//     STORIES (time-anchored) and CONFIRMED-DELIVERED voice notes. The resend
//     path skips any reaped tombstone (the guard in MessageInbox.resend), so
//     a wiped row can never re-enter a send path.
//

import Foundation

/// Namespace for the ephemeral-media windows. An enum with no cases so it
/// cannot be instantiated — constants only.
public enum MediaEphemeralityPolicy {

    /// Inbound photos disappear this long after receipt (received-time; no
    /// view/first-open tracking).
    public static let photoWindow: TimeInterval = 24 * 60 * 60

    /// Inbound voice notes disappear this long after the recipient finished
    /// listening.
    public static let voiceListenWindow: TimeInterval = 120

    /// Stories disappear this long after they were SENT — on BOTH ends,
    /// sender included (the stories-only SEC-6 reversal). Anchored on
    /// `Message.sentAt`, never on receipt or on a retry's re-send time.
    public static let storyWindow: TimeInterval = 8 * 60 * 60

    /// THE per-row expiry decision, pure and unit-testable: is this media
    /// row's blob past its policy window at `now`? The reaper's fetch
    /// predicate — NOT this function — excludes outbound rows that must keep
    /// their blob (non-story, non-delivered-voice); every row handed here is
    /// already reap-eligible by direction. Direction never needs to be passed:
    /// `listenedAt` is only ever stamped on inbound rows and `deliveredAt`
    /// only on outbound ones, so the non-nil anchor identifies the side.
    public static func isExpired(isStory: Bool,
                                 mime: MediaMimeType?,
                                 timestamp: Date,
                                 sentAt: Date?,
                                 listenedAt: Date?,
                                 deliveredAt: Date? = nil,
                                 now: Date) -> Bool {
        if isStory {
            // STORIES: one rule, BOTH directions — `storyWindow` after the
            // send anchor. `sentAt` is stamped at send (outbound) or clamped
            // at persist (inbound); an anomalous story row missing it falls
            // back to insert time rather than living forever.
            return now.timeIntervalSince(sentAt ?? timestamp) >= storyWindow
        }
        switch mime {
        case .jpeg:
            return now.timeIntervalSince(timestamp) >= photoWindow
        case .mp4:
            // v1 VIDEO MESSAGES: a non-story video is a photo, policy-wise —
            // `photoWindow` after ARRIVAL.
            return now.timeIntervalSince(timestamp) >= photoWindow
        case .m4a:
            // Inbound: listen-armed — an unlistened voice note never expires.
            if let listenedAt {
                return now.timeIntervalSince(listenedAt) >= voiceListenWindow
            }
            // Outbound: delivery-armed — the sender's copy expires the same
            // window after first confirmed receipt. Unconfirmed (nil anchor,
            // incl. `.notDelivered` forever and `.cast`) never expires: the
            // blob is still the resend/re-drive source.
            if let deliveredAt {
                return now.timeIntervalSince(deliveredAt) >= voiceListenWindow
            }
            return false
        case nil:
            return false   // blob with no mime — unknown kind, leave it alone
        }
    }
}
