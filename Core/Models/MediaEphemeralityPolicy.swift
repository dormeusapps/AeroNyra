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
//   • A STORY (EITHER direction) self-destructs `storyWindow` after it was
//     first SENT (`Message.sentAt` — outbound: stamped at first send and
//     reused on every retry; inbound: the manifest stamp clamped to arrival).
//   • OUTBOUND NON-STORY media never expires here: the blob is still needed
//     to resend a non-terminal row. Wiping sender-side copies of STORIES is
//     the deliberate reversal SEC-6 flagged as "not taken" — now taken, for
//     stories ONLY. The resend path skips the reaped tombstone (the guard in
//     MessageInbox.resend), so a wiped story can never re-enter a send path.
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
}
