// PTTLiveInboundMeter.swift
// Core/Media
//
// The walkie sphere's inbound meter for BLE-live sessions (globe pulse,
// loop 4). Two facts, joined here because nothing else holds both:
//   • WHICH peer's live session is open toward me — from the coordinator's
//     `.pttOpened` / `.pttClosed` events, which already reach the composition
//     root (`MessageInbox.onPTTSession`); the player itself knows only a link
//     id, never a peer.
//   • THEIR LEVEL — from `PTTPlayer.onLevel`, one sample per 20 ms frame as
//     it is scheduled, hopped onto the main actor by the composition root.
// `PTTAutoPlay` is the note-path twin of this (per conversation, claim-keyed);
// this one is app-lifetime because a live session can open on any screen.
//
// Pure state, pinned hardware-free (PTTLiveInboundMeterTests). The sphere
// reads `level(for:)` per frame, gated on the session's peer being the
// cover's peer, so a session from someone else never moves this globe.
//
// KNOWN MINOR (recorded 2026-09-12): a session that ends by LOSS rather than
// a `.pttClose` leaves `activePeer` set until the close arrives or the owner
// times the session out. The level itself goes to 0 at spurt end, so the
// sphere settles either way; only the reduce-motion pause stays off for that
// window. Written down here so it is not rediscovered.
//

import Foundation
import Observation

@MainActor
@Observable
public final class PTTLiveInboundMeter {

    /// The peer whose live session is open toward me; nil when none.
    public private(set) var activePeer: Data?

    /// Their voice, 0…1 on the meter scale; 0 whenever `activePeer` is nil.
    public private(set) var level: CGFloat = 0

    public init() {}

    /// `.pttOpened`: a new session replaces any previous one (the player
    /// claims one link at a time; the newest open is the audible one).
    public func sessionOpened(peerKey: Data) {
        if activePeer != peerKey { level = 0 }
        activePeer = peerKey
    }

    /// `.pttClosed`: clears only if it names the active peer — a late close
    /// for an older session must not blank a newer one.
    public func sessionClosed(peerKey: Data) {
        guard activePeer == peerKey else { return }
        activePeer = nil
        level = 0
    }

    /// One playout sample. Dropped while no session is open, so a straggling
    /// frame after a close can never move the sphere.
    public func report(_ sample: CGFloat) {
        guard activePeer != nil else { return }
        let clamped = max(0, min(1, sample))
        if clamped != level { level = clamped }
    }

    /// The sphere's read: nil unless THIS peer's session is open.
    public func level(for peerKey: Data) -> Double? {
        guard activePeer == peerKey else { return nil }
        return Double(level)
    }
}
