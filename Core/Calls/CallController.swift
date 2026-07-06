// CallController.swift
// Core/Calls
//
// The FaceTime-v1 (voice-only) call state machine. One call at a time, both
// parties foreground in the live chat — there is NO server, NO push, NO
// CallKit, so "ringing" is a sealed request plus a local timeout, nothing
// more. This class owns every transition; the UI renders `state`, the
// transports and WebRTC are behind seams.
//
// SEAMS (both injected, neither imported):
//   • `sendSignal` — seals + routes a CallSignal to a peer over the EXISTING
//     addressed path (the same rail text rides). Wired to the coordinator in
//     the wire step (payload tags 8–10 + the 7f verified gate), which lands
//     only after the in-flight stories work in the coordinator commits.
//   • `CallMediaSession` — the WebRTC audio wrapper (RTCPeerConnection,
//     DTLS-SRTP, STUN). The libWebRTC pod is NOT added yet, by build order:
//     this protocol is what keeps the state machine compiling, testable, and
//     mergeable before the heavy dependency lands.
//
// NAT HONESTY (no TURN in v1): STUN-only ICE fails against symmetric NAT /
// CGNAT — common on cellular. That failure surfaces here as `mediaFailed()` →
// `.ended(.connectFailed)`, which the UI renders as "Couldn't connect — try
// joining the same WiFi". It is a THIRD terminal outcome, distinct from
// decline and timeout (the callee DID accept); both ends detect it locally
// from their own ICE state, no extra signaling.
//
// STALE-FRAME RULE: every inbound signal is matched against the current
// call's `callID`; a frame from any other attempt (a late relay delivery, a
// replay, a crossed decline) is dropped without a state change.
//

import Foundation
import Security

// MARK: - CallMediaSession (WebRTC seam)

/// What the state machine needs from the audio stack, and nothing more. The
/// concrete implementation (a later step, after the libWebRTC pod lands)
/// wraps RTCPeerConnection with non-trickle ICE: offer/answer strings here
/// are COMPLETE SDPs, candidates already gathered.
@MainActor
public protocol CallMediaSession: AnyObject {

    /// Caller side: create the peer connection, gather ALL candidates, return
    /// the complete SDP offer (fingerprint inside).
    func makeOffer() async throws -> String

    /// Callee side: apply the remote offer, gather, return the complete
    /// SDP answer.
    func makeAnswer(remoteOffer: String) async throws -> String

    /// Caller side: apply the callee's answer and start connecting.
    func start(remoteAnswer: String) async throws

    /// Tear down the connection and audio session. Idempotent.
    func close()

    /// Fired once when ICE + DTLS complete and audio is flowing.
    var onConnected: (() -> Void)? { get set }

    /// Fired once on ICE failure/disconnect (the no-TURN NAT loss) or any
    /// fatal media error after `start`/`makeAnswer`.
    var onFailed: (() -> Void)? { get set }

    /// Fired once when the REMOTE side closed the connection mid-call (their
    /// hang-up reaches us at the RTC layer — no wire signal post-connect).
    var onRemoteEnded: (() -> Void)? { get set }
}

// MARK: - CallController

@MainActor
public final class CallController {

    // MARK: State

    public enum EndReason: Equatable, Sendable {
        case declined            // we declined an incoming ring
        case remoteDeclined      // they declined our ring
        case timedOut            // ring expired unanswered (either side)
        case connectFailed       // accepted, but ICE never connected (no TURN)
        case hungUp              // either side ended an ACTIVE call
        case failed              // local media error (offer/answer threw)
    }

    public enum State: Equatable {
        case idle
        /// We sent a request and are waiting for answer/decline/timeout.
        case outgoingRinging(callID: Data, peerKey: Data)
        /// A request arrived; the chat shows Accept / Decline.
        case incomingRinging(callID: Data, peerKey: Data, sdpOffer: String)
        /// SDPs exchanged; ICE is running.
        case connecting(callID: Data, peerKey: Data)
        /// Audio is flowing.
        case active(callID: Data, peerKey: Data)
        /// Terminal; renders the outcome, then the UI returns us to `.idle`
        /// via `reset()`.
        case ended(EndReason)
    }

    /// How long a ring stays open, both sides, before it becomes a missed
    /// call. Local-only — there is no server to enforce it, so both ends run
    /// their own clock and the callee's banner simply disappears.
    public static let ringTimeout: TimeInterval = 45

    public private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    // MARK: Seams + hooks

    private let sendSignal: (CallSignal, _ peerKey: Data) async throws -> Void
    private let makeMediaSession: () -> CallMediaSession

    /// UI observer (the in-chat banner / call bar renders from this).
    public var onStateChange: ((State) -> Void)?

    /// Persist-a-row hook: fired exactly once per attempt that ends unanswered
    /// (timeout on either side, or the callee letting it lapse), so the inbox
    /// writes the "missed call" Message. NOT fired for decline/connect-fail —
    /// the caller of this hook decides that copy separately.
    public var onMissedCall: ((_ peerKey: Data) -> Void)?

    private var media: CallMediaSession?
    private var ringTimer: Task<Void, Never>?

    public init(sendSignal: @escaping (CallSignal, _ peerKey: Data) async throws -> Void,
                makeMediaSession: @escaping () -> CallMediaSession) {
        self.sendSignal = sendSignal
        self.makeMediaSession = makeMediaSession
    }

    // MARK: - Outgoing

    /// Caller taps FaceTime. Gathers a complete offer, seals it to the peer,
    /// starts the ring timeout. No-op unless idle (one call at a time).
    public func startCall(peerKey: Data) async {
        guard case .idle = state else { return }
        let callID = Self.randomCallID()
        let session = makeMediaSession()
        media = session
        wireMediaCallbacks(session, callID: callID, peerKey: peerKey)
        do {
            let offer = try await session.makeOffer()
            state = .outgoingRinging(callID: callID, peerKey: peerKey)
            try await sendSignal(.request(callID: callID, sdp: offer), peerKey)
            armRingTimer(callID: callID, peerKey: peerKey)
        } catch {
            teardownMedia()
            state = .ended(.failed)
        }
    }

    /// Caller taps cancel while ringing: send a decline (reused as
    /// cancel-before-connect) so the callee's banner drops, then end quietly.
    public func cancelOutgoing() async {
        guard case .outgoingRinging(let callID, let peerKey) = state else { return }
        stopRingTimer()
        teardownMedia()
        try? await sendSignal(.decline(callID: callID), peerKey)
        state = .ended(.hungUp)
    }

    // MARK: - Incoming

    /// Callee taps Accept: build the answer from the buffered offer, seal it
    /// back, and start connecting. On a media failure the caller just times
    /// out (we cannot answer); we surface `.failed` locally.
    public func accept() async {
        guard case .incomingRinging(let callID, let peerKey, let offer) = state else { return }
        stopRingTimer()
        let session = makeMediaSession()
        media = session
        wireMediaCallbacks(session, callID: callID, peerKey: peerKey)
        do {
            let answer = try await session.makeAnswer(remoteOffer: offer)
            state = .connecting(callID: callID, peerKey: peerKey)
            try await sendSignal(.answer(callID: callID, sdp: answer), peerKey)
        } catch {
            teardownMedia()
            state = .ended(.failed)
        }
    }

    /// Callee taps Decline.
    public func decline() async {
        guard case .incomingRinging(let callID, let peerKey, _) = state else { return }
        stopRingTimer()
        try? await sendSignal(.decline(callID: callID), peerKey)
        state = .ended(.declined)
    }

    /// Either side hangs up an active (or still-connecting) call. Post-connect
    /// there is no wire signal — closing the RTC connection IS the hang-up,
    /// which the peer sees as `onRemoteEnded`.
    public func hangUp() {
        switch state {
        case .active, .connecting:
            teardownMedia()
            state = .ended(.hungUp)
        default:
            break
        }
    }

    /// Terminal → idle, driven by the UI after it has rendered the outcome.
    public func reset() {
        guard case .ended = state else { return }
        state = .idle
    }

    // MARK: - Inbound signals (from the coordinator, already sealed-verified)

    /// Feed one opened, verified call signal into the machine. Frames whose
    /// callID does not match the current attempt are dropped (stale/replay).
    public func handleInbound(_ signal: CallSignal, from peerKey: Data) async {
        switch (signal, state) {

        // A new ring, and we are free: buffer the offer, show Accept/Decline.
        case (.request(let callID, let sdp), .idle):
            state = .incomingRinging(callID: callID, peerKey: peerKey, sdpOffer: sdp)
            armRingTimer(callID: callID, peerKey: peerKey)

        // A ring while any call is in progress: busy — auto-decline the NEW
        // attempt, current call untouched.
        case (.request(let callID, _), _):
            try? await sendSignal(.decline(callID: callID), peerKey)

        // Their answer to our ring: apply it and start connecting.
        case (.answer(let callID, let sdp), .outgoingRinging(let ourID, let ourPeer))
            where callID == ourID && peerKey == ourPeer:
            stopRingTimer()
            state = .connecting(callID: ourID, peerKey: ourPeer)
            do {
                try await media?.start(remoteAnswer: sdp)
            } catch {
                teardownMedia()
                state = .ended(.connectFailed)
            }

        // They declined our ring (or cancelled before we accepted).
        case (.decline(let callID), .outgoingRinging(let ourID, _)) where callID == ourID:
            stopRingTimer()
            teardownMedia()
            state = .ended(.remoteDeclined)

        // Caller cancelled while our banner was up: drop it quietly.
        case (.decline(let callID), .incomingRinging(let ourID, let ourPeer, _))
            where callID == ourID:
            stopRingTimer()
            state = .ended(.timedOut)
            onMissedCall?(ourPeer)

        // Anything else is stale or crossed — ignore, no state change.
        default:
            break
        }
    }

    // MARK: - Internals

    private func wireMediaCallbacks(_ session: CallMediaSession, callID: Data, peerKey: Data) {
        session.onConnected = { [weak self] in
            guard let self, case .connecting(let id, let peer) = self.state,
                  id == callID else { return }
            self.state = .active(callID: id, peerKey: peer)
        }
        session.onFailed = { [weak self] in
            guard let self else { return }
            switch self.state {
            case .connecting(let id, _) where id == callID,
                 .active(let id, _) where id == callID:
                self.teardownMedia()
                self.state = .ended(.connectFailed)
            default:
                break
            }
        }
        session.onRemoteEnded = { [weak self] in
            guard let self, case .active(let id, _) = self.state, id == callID else { return }
            self.teardownMedia()
            self.state = .ended(.hungUp)
        }
    }

    private func armRingTimer(callID: Data, peerKey: Data) {
        stopRingTimer()
        ringTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.ringTimeout))
            guard let self, !Task.isCancelled else { return }
            switch self.state {
            case .outgoingRinging(let id, let peer) where id == callID,
                 .incomingRinging(let id, let peer, _) where id == callID:
                self.teardownMedia()
                self.state = .ended(.timedOut)
                self.onMissedCall?(peer)
            default:
                break
            }
        }
    }

    private func stopRingTimer() {
        ringTimer?.cancel()
        ringTimer = nil
    }

    private func teardownMedia() {
        media?.close()
        media = nil
    }

    private static func randomCallID() -> Data {
        var bytes = [UInt8](repeating: 0, count: CallSignal.callIDByteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}
