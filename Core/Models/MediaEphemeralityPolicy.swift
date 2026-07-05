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
//   • OUTBOUND media never expires here: the blob is still needed to resend a
//     non-terminal row. Wiping sender-side copies is a separate, deliberate
//     product decision (flagged in SEC-6, not taken).
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
}
