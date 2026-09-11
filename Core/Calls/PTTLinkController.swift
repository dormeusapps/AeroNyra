// PTTLinkController.swift
// Core/Calls
//
// The live PTT-over-IP link state machine — a SIBLING of `CallController`,
// not a state inside it. It opens and holds a no-ring WebRTC audio link for
// push-to-talk and gates the microphone on press/release. Reuses, unchanged:
// the `CallMediaSession` seam (extended below with mute/speaker), the
// `WebRTCCallMedia` implementation, `CallSignal` (kind 14 request; kinds 9/10
// answer/decline keyed by the same 16-byte id), and the `sendCallSignal` rail.
// `CallController` and kinds 8–10 are untouched.
//
// LOCKED DESIGN (operator rulings — do not re-derive):
//   • Link lifetime = walkie SCREEN lifetime, not press lifetime. Open when
//     the surface appears; close on dismiss / background / interruption /
//     call pre-emption. Press and release only toggle `setMicMuted`.
//   • On connect: `setMicMuted(true)` then `setSpeakerEnabled(true)` — a
//     voice-only WebRTC session seeds the earpiece; a walkie must not.
//   • Auto-answer, no mutual-cover requirement: a link opens to a peer who
//     has not opened their walkie screen. CONSEQUENCE, stated plainly: the
//     RESPONDER'S MIC HARDWARE GOES LIVE AT `makeAnswer` TIME, BEFORE CONNECT,
//     because that is where `WebRTCCallMedia` activates the audio session;
//     iOS will light the mic indicator. This is not deferrable without
//     touching `WebRTCCallMedia`. The mitigation is a persistent, honest
//     responder banner (step 5); the `role` carried in `State` is the hook
//     for it. The track is muted before the answer leaves, so nothing is
//     TRANSMITTED until a press — but the hardware is up.
//   • Open timeout is INJECTABLE and ends in a VISIBLE terminal state. Every
//     current real user runs a build that silently drops kind 14 and never
//     declines (see the compat note at the coordinator's `.pttRequest` arm),
//     so `.closed(.unreachable)` is the NORMAL outcome today, not an edge
//     case. It must render as "Couldn't reach X", never a spinner that
//     quietly stops.
//   • A call always pre-empts a link; a link never pre-empts a call.
//     `preempt()` is the entry point `CallEngine` calls (wired in step 4).
//     `autoAnswerPolicy` is where "no call in progress" is injected.
//
// DELIBERATE DIVERGENCES FROM CallController (intentional — do not "fix"
// this controller to match):
//   • `.closed` is treated like `.idle` for an inbound request and for
//     `open(to:)`. CallController's `.ended` state auto-declines a new ring
//     until the UI resets it (a known bug, pinned as-is there). A peer's
//     retry must not be refused because our outcome screen is still up.
//   • `state` enters `.opening` BEFORE the offer/answer is built, so a
//     request that arrives during the SDP suspension meets the busy/glare
//     rule instead of spawning a second media session.
//   • The timeout is a `Duration` injected at init, not a static constant.
//   • Inbound frames are matched on BOTH link id and peer.
//
// GLARE (both users open their walkie screens at once — likely, given the
// screen-lifetime rule): a `.pttRequest` from the SAME peer we are awaiting
// an answer from is resolved deterministically by the LOWER link id (byte
// order). The loser abandons its own attempt silently and answers the
// winner's request; the winner declines the loser's. The loser's abandoned
// id makes the winner's decline stale on arrival, so both sides converge on
// one link with no extra signaling.
//
// AUDIO-SESSION COEXISTENCE: this file never touches AVAudioSession — all of
// that is inside `WebRTCCallMedia`. A live link and `PTTCaptureEngine` must
// NOT run at once (the capture engine's teardown deactivates the shared
// session out from under WebRTC's audio unit); step 5 branches on `isOpen`
// to guarantee it. Two `WebRTCCallMedia` instances (a call and a link) must
// never be alive together either — the audio device module is process-
// global and whichever closes first silences the other; strict pre-emption
// in step 4 is the guarantee, `preempt()` is the seam.
//
// INERT after this step: nothing instantiates `PTTLinkController` until the
// composition root wires it (step 4).
//

import Foundation
import Security

// MARK: - PTTLinkMediaSession (the seam, extended)

/// What the link needs from the audio stack beyond `CallMediaSession`: the
/// two in-band controls that make half-duplex work. `WebRTCCallMedia`
/// already has both; the conformance below is empty.
@MainActor
public protocol PTTLinkMediaSession: CallMediaSession {
    /// Flip the local audio track's `isEnabled`. Effective only once the
    /// track exists (after `makeOffer` / `makeAnswer` return).
    func setMicMuted(_ muted: Bool)
    /// Force the loudspeaker route. Sticks only on an ACTIVE audio session,
    /// i.e. after `start` (initiator) / `makeAnswer` (responder).
    func setSpeakerEnabled(_ enabled: Bool)
}

extension WebRTCCallMedia: PTTLinkMediaSession {}

// MARK: - PTTLinkController

@MainActor
public final class PTTLinkController {

    // MARK: State

    public enum Role: Equatable, Sendable {
        case initiator   // we sent the `.pttRequest`
        case responder   // we auto-answered theirs — our mic is live pre-press (see header)
    }

    public enum OpeningPhase: Equatable, Sendable {
        case awaitingAnswer   // initiator only: request sent, no `.answer` yet ("Reaching X")
        case connecting       // SDPs exchanged, ICE running ("Connecting")
    }

    public enum CloseReason: Equatable, Sendable {
        case unreachable      // no answer inside the open timeout — the old-build default
        case remoteDeclined   // they sent `.decline` (busy / in a call / policy)
        case connectFailed    // answered, but ICE never connected (timeout or media failure)
        case remoteEnded      // they closed, or the network died, while open
        case failed           // local media or send error
        case localClosed      // the walkie screen was dismissed
        case preempted        // CallEngine closed it for a call
        case interrupted      // system interruption / backgrounding (passed by step 4)

        /// Whether an honest UI must render this outcome, versus a quiet
        /// return to idle. Enumerated here so no view has to.
        public var isUserVisible: Bool {
            switch self {
            case .localClosed, .preempted:
                return false
            case .unreachable, .remoteDeclined, .connectFailed, .remoteEnded,
                 .failed, .interrupted:
                return true
            }
        }
    }

    public enum State: Equatable {
        case idle
        /// A link attempt is in flight, in either role.
        case opening(linkID: Data, peerKey: Data, role: Role, phase: OpeningPhase)
        /// Audio is flowing (muted until a press).
        case open(linkID: Data, peerKey: Data, role: Role)
        /// Terminal; the UI renders the outcome (if `isUserVisible`) then
        /// returns us to `.idle` via `reset()`. Also accepts a new inbound
        /// request or `open(to:)` directly (see header).
        case closed(CloseReason)

        public var linkID: Data? {
            switch self {
            case .opening(let id, _, _, _), .open(let id, _, _): return id
            case .idle, .closed: return nil
            }
        }

        public var peerKey: Data? {
            switch self {
            case .opening(_, let peer, _, _), .open(_, let peer, _): return peer
            case .idle, .closed: return nil
            }
        }
    }

    /// Default open timeout: covers the initiator's 5 s gather bound, two
    /// relay legs, and the responder's 5 s gather, with margin — and is short
    /// enough that "Couldn't reach X" arrives before the user gives up alone.
    public static let defaultOpenTimeout: Duration = .seconds(20)

    public private(set) var state: State = .idle {
        didSet {
            // FIELD DIAGNOSTICS (2026-09-11): every transition, through the
            // redacting logger. Label = state names / role / phase / reason
            // only; link id prefix + peer hex prefix ride in the DEBUG-only
            // private detail, same discipline as first-contact's lines.
            RedactLog.event("ptt-link: \(Self.describe(oldValue)) → \(Self.describe(state))",
                            Self.detail(state.linkID ?? oldValue.linkID, state.peerKey ?? oldValue.peerKey))
            onStateChange?(state)
        }
    }

    /// True while the local mic is un-muted by a press. Forced false by every
    /// close, so a link that dies mid-press cannot report a live mic.
    public private(set) var isTransmitting = false {
        didSet { if isTransmitting != oldValue { onTransmitChange?(isTransmitting) } }
    }

    public var isOpen: Bool {
        if case .open = state { return true }
        return false
    }

    // MARK: Diagnostics helpers (labels carry NO identifier — RedactLog contract)

    static func describe(_ state: State) -> String {
        switch state {
        case .idle:                                  return "idle"
        case .opening(_, _, let role, let phase):    return "opening(\(role), \(phase))"
        case .open(_, _, let role):                  return "open(\(role))"
        case .closed(let reason):                    return "closed(\(reason))"
        }
    }

    static func detail(_ linkID: Data?, _ peerKey: Data?) -> String {
        "link \(hexPrefix(linkID)) peer \(hexPrefix(peerKey))…"
    }

    private static func hexPrefix(_ data: Data?) -> String {
        guard let data else { return "-" }
        return data.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Seams + hooks

    private let sendSignal: (CallSignal, _ peerKey: Data) async throws -> Void
    private let makeMediaSession: () -> PTTLinkMediaSession
    private let openTimeout: Duration
    /// Consulted on every inbound request while we are free. Step 4 wires it
    /// to "no call in progress"; default admits everything.
    private let autoAnswerPolicy: () -> Bool

    public var onStateChange: ((State) -> Void)?
    public var onTransmitChange: ((Bool) -> Void)?

    private var media: PTTLinkMediaSession?
    private var openTimer: Task<Void, Never>?

    public init(sendSignal: @escaping (CallSignal, _ peerKey: Data) async throws -> Void,
                makeMediaSession: @escaping () -> PTTLinkMediaSession,
                openTimeout: Duration = PTTLinkController.defaultOpenTimeout,
                autoAnswerPolicy: @escaping () -> Bool = { true }) {
        self.sendSignal = sendSignal
        self.makeMediaSession = makeMediaSession
        self.openTimeout = openTimeout
        self.autoAnswerPolicy = autoAnswerPolicy
    }

    // MARK: - Initiator

    /// The walkie screen appeared: open a link to `peerKey`. No-op unless
    /// idle or closed (one link at a time).
    public func open(to peerKey: Data) async {
        switch state {
        case .idle, .closed: break
        case .opening, .open:
            RedactLog.event("ptt-link: open(to:) refused — already \(Self.describe(state))",
                            Self.detail(state.linkID, peerKey))
            return
        }
        let linkID = Self.randomLinkID()
        let session = makeMediaSession()
        media = session
        wireMediaCallbacks(session, linkID: linkID)
        // Enter .opening BEFORE the offer is built (see header): a request
        // arriving during the gather suspension meets the busy/glare rule.
        state = .opening(linkID: linkID, peerKey: peerKey, role: .initiator, phase: .awaitingAnswer)
        do {
            let offer = try await session.makeOffer()
            guard isCurrent(session, linkID) else { return }   // superseded mid-gather
            // The track exists now: mute it BEFORE the SDP leaves, so no
            // audio can ride the first connected packets.
            session.setMicMuted(true)
            try await sendSignal(.pttRequest(callID: linkID, sdp: offer), peerKey)
            guard isCurrent(session, linkID) else { return }
            RedactLog.event("ptt-link: request sent, open timer armed", Self.detail(linkID, peerKey))
            armOpenTimer(linkID: linkID)
        } catch {
            guard isCurrent(session, linkID) else { return }
            RedactLog.event("ptt-link: open failed (offer or send)", "\(type(of: error)) \(Self.detail(linkID, peerKey))")
            teardownMedia()
            state = .closed(.failed)
        }
    }

    // MARK: - Local control

    /// Close from any in-flight or open state. `reason` is what the UI will
    /// render (or not — see `CloseReason.isUserVisible`). No-op when idle or
    /// already closed.
    public func close(reason: CloseReason = .localClosed) {
        switch state {
        case .opening, .open:
            RedactLog.event("ptt-link: close(\(reason)) from \(Self.describe(state))",
                            Self.detail(state.linkID, state.peerKey))
            stopOpenTimer()
            teardownMedia()
            state = .closed(reason)
        case .idle, .closed:
            break
        }
    }

    /// The CallEngine seam: a call always pre-empts a link.
    public func preempt() {
        close(reason: .preempted)
    }

    /// Terminal → idle, driven by the UI after it has rendered the outcome.
    public func reset() {
        guard case .closed = state else { return }
        state = .idle
    }

    /// Press: un-mute. Returns false (and touches nothing) unless the link is
    /// open, so the caller can fall through to the BLE-live path.
    @discardableResult
    public func pressBegan() -> Bool {
        guard isOpen, let media else {
            RedactLog.event("ptt-link: press ignored — \(Self.describe(state))", Self.detail(state.linkID, state.peerKey))
            return false
        }
        media.setMicMuted(false)
        isTransmitting = true
        return true
    }

    /// Release: mute. Same contract as `pressBegan`.
    @discardableResult
    public func pressEnded() -> Bool {
        guard isOpen, let media else { return false }
        media.setMicMuted(true)
        isTransmitting = false
        return true
    }

    // MARK: - Inbound signals (from the coordinator, already sealed-verified)

    /// Feed one opened, verified call-kind frame. Frames that are not ours —
    /// call rings (`.request`), unknown ids, wrong peers — are dropped with no
    /// state change and NO reply, so step 4 can fan the `.callSignal` event
    /// out to both controllers unconditionally.
    public func handleInbound(_ signal: CallSignal, from peerKey: Data) async {
        switch (signal, state) {

        // A request while we are free: auto-answer if policy allows, else
        // decline. `.closed` counts as free (see header).
        case (.pttRequest(let id, let sdp), .idle),
             (.pttRequest(let id, let sdp), .closed):
            guard autoAnswerPolicy() else {
                RedactLog.event("ptt-link: inbound request while free — policy refused, declining",
                                Self.detail(id, peerKey))
                try? await sendSignal(.decline(callID: id), peerKey)
                return
            }
            RedactLog.event("ptt-link: inbound request while \(Self.describe(state)) — auto-answering",
                            Self.detail(id, peerKey))
            await autoAnswer(linkID: id, peerKey: peerKey, offer: sdp)

        // GLARE: the peer we are waiting on opened to us at the same time.
        // Lower link id wins.
        case (.pttRequest(let theirID, let sdp),
              .opening(let ourID, let ourPeer, .initiator, .awaitingAnswer))
            where peerKey == ourPeer && theirID != ourID:
            if theirID.lexicographicallyPrecedes(ourID) {
                // They win: abandon ours silently (their decline of it, if
                // any, arrives stale) and answer theirs.
                RedactLog.event("ptt-link: glare — they win, abandoning ours, answering theirs",
                                Self.detail(theirID, peerKey))
                stopOpenTimer()
                teardownMedia()
                await autoAnswer(linkID: theirID, peerKey: peerKey, offer: sdp)
            } else {
                // We win: decline theirs; they abandon it and answer ours.
                RedactLog.event("ptt-link: glare — we win, declining theirs", Self.detail(theirID, peerKey))
                try? await sendSignal(.decline(callID: theirID), peerKey)
            }

        // A request while a link is in flight or open: busy — decline the
        // NEW attempt, current link untouched.
        case (.pttRequest(let id, _), _):
            RedactLog.event("ptt-link: inbound request while \(Self.describe(state)) — busy, declining",
                            Self.detail(id, peerKey))
            try? await sendSignal(.decline(callID: id), peerKey)

        // Their answer to our request: apply it, ICE runs.
        case (.answer(let id, let sdp),
              .opening(let ourID, let ourPeer, .initiator, .awaitingAnswer))
            where id == ourID && peerKey == ourPeer:
            guard let session = media else { return }
            RedactLog.event("ptt-link: answer received — applying", Self.detail(ourID, peerKey))
            state = .opening(linkID: ourID, peerKey: ourPeer, role: .initiator, phase: .connecting)
            do {
                try await session.start(remoteAnswer: sdp)
            } catch {
                guard isCurrent(session, ourID) else { return }
                RedactLog.event("ptt-link: applying answer failed", "\(type(of: error)) \(Self.detail(ourID, peerKey))")
                stopOpenTimer()
                teardownMedia()
                state = .closed(.connectFailed)
            }

        // They declined our request (busy, in a call, or policy refused).
        case (.decline(let id),
              .opening(let ourID, let ourPeer, .initiator, .awaitingAnswer))
            where id == ourID && peerKey == ourPeer:
            RedactLog.event("ptt-link: our request was declined", Self.detail(ourID, peerKey))
            stopOpenTimer()
            teardownMedia()
            state = .closed(.remoteDeclined)

        // Everything else is a call frame, stale, or crossed — ignore.
        // Log the ptt-relevant drops (a late answer/decline, a foreign id) —
        // call rings (`.request`) are CallController's and stay silent here.
        default:
            switch signal {
            case .answer(let id, _):
                RedactLog.event("ptt-link: dropped answer while \(Self.describe(state))", Self.detail(id, peerKey))
            case .decline(let id):
                RedactLog.event("ptt-link: dropped decline while \(Self.describe(state))", Self.detail(id, peerKey))
            default:
                break
            }
        }
    }

    // MARK: - Responder

    private func autoAnswer(linkID: Data, peerKey: Data, offer: String) async {
        let session = makeMediaSession()
        media = session
        wireMediaCallbacks(session, linkID: linkID)
        state = .opening(linkID: linkID, peerKey: peerKey, role: .responder, phase: .connecting)
        do {
            // NOTE: WebRTCCallMedia activates the audio session inside
            // makeAnswer — the responder's mic hardware is live from here.
            let answer = try await session.makeAnswer(remoteOffer: offer)
            guard isCurrent(session, linkID) else { return }
            session.setMicMuted(true)   // track exists now; nothing transmits pre-press
            try await sendSignal(.answer(callID: linkID, sdp: answer), peerKey)
            guard isCurrent(session, linkID) else { return }
            RedactLog.event("ptt-link: answer sent, open timer armed", Self.detail(linkID, peerKey))
            armOpenTimer(linkID: linkID)
        } catch {
            guard isCurrent(session, linkID) else { return }
            RedactLog.event("ptt-link: auto-answer failed (answer or send)", "\(type(of: error)) \(Self.detail(linkID, peerKey))")
            teardownMedia()
            state = .closed(.failed)
        }
    }

    // MARK: - Internals

    /// Still the attempt we started? False once superseded (closed, pre-empted,
    /// glare-abandoned, or replaced by a new attempt) during a suspension.
    private func isCurrent(_ session: PTTLinkMediaSession, _ linkID: Data) -> Bool {
        media === session && state.linkID == linkID
    }

    private func wireMediaCallbacks(_ session: PTTLinkMediaSession, linkID: Data) {
        session.onConnected = { [weak self] in
            guard let self,
                  case .opening(let id, let peer, let role, _) = self.state,
                  id == linkID, let media = self.media else {
                RedactLog.event("ptt-link: media connected for a non-current link — ignored", Self.detail(linkID, nil))
                return
            }
            RedactLog.event("ptt-link: media connected", Self.detail(id, peer))
            self.stopOpenTimer()
            // Locked order: mute, then loudspeaker (the session is active on
            // both roles by now, so the override sticks).
            media.setMicMuted(true)
            media.setSpeakerEnabled(true)
            self.state = .open(linkID: id, peerKey: peer, role: role)
        }
        session.onFailed = { [weak self] in
            guard let self else { return }
            switch self.state {
            case .opening(let id, let peer, _, _) where id == linkID:
                RedactLog.event("ptt-link: media failed before connect (ICE failed/closed)", Self.detail(id, peer))
                self.stopOpenTimer()
                self.teardownMedia()
                self.state = .closed(.connectFailed)
            case .open(let id, let peer, _) where id == linkID:
                RedactLog.event("ptt-link: media failed while open (ICE decay → remote ended)", Self.detail(id, peer))
                self.teardownMedia()
                self.state = .closed(.remoteEnded)
            default:
                RedactLog.event("ptt-link: media failed for a non-current link — ignored", Self.detail(linkID, nil))
            }
        }
        session.onRemoteEnded = { [weak self] in
            guard let self, case .open(let id, let peer, _) = self.state, id == linkID else {
                RedactLog.event("ptt-link: media remote-ended for a non-current link — ignored", Self.detail(linkID, nil))
                return
            }
            RedactLog.event("ptt-link: media remote-ended (ICE decay after connect)", Self.detail(id, peer))
            self.teardownMedia()
            self.state = .closed(.remoteEnded)
        }
    }

    /// One timer covers the whole `.opening` window on both roles. Which
    /// terminal it lands in depends on how far the attempt got.
    private func armOpenTimer(linkID: Data) {
        stopOpenTimer()
        let timeout = openTimeout
        openTimer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled else { return }
            self.openTimedOut(linkID: linkID)
        }
    }

    private func openTimedOut(linkID: Data) {
        guard case .opening(let id, let peer, _, let phase) = state, id == linkID else { return }
        RedactLog.event("ptt-link: open timer fired while opening(\(phase))", Self.detail(id, peer))
        teardownMedia()
        state = .closed(phase == .awaitingAnswer ? .unreachable : .connectFailed)
    }

    private func stopOpenTimer() {
        openTimer?.cancel()
        openTimer = nil
    }

    private func teardownMedia() {
        isTransmitting = false
        media?.close()
        media = nil
    }

    private static func randomLinkID() -> Data {
        var bytes = [UInt8](repeating: 0, count: CallSignal.callIDByteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}
