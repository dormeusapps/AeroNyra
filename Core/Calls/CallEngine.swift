// CallEngine.swift
// Core/Calls
//
// The composition-root face of calling (P3): ONE object the UI observes.
// Owns the committed CallController (untouched), manufactures a
// WebRTCCallMedia per attempt, and keeps a handle to the CURRENT one so the
// UI can reach the video surfaces and the in-band controls (camera / mute) —
// the state machine's seam stays voice-shaped, exactly as committed.
//
// Wiring (injected by ContentView, nothing imported here):
//   • sendSignal → FirstContactCoordinator.sendCallSignal (the existing
//     sealer: kinds 8-10, 7f-gated on the receive side, BLE/Nostr rail).
//   • onMissedCall → MessageInbox.recordMissedCall (the transcript row).
//   • Inbound frames arrive via MessageInbox's onCallSignal forward — the
//     inbox stays the events stream's single consumer.
//
// "Voice call" vs "video call" is the SAME wire (always audio+video,
// operator ruling); the buttons differ only in whether the camera starts on.
//

import Foundation
import Observation
import UIKit
import AVFoundation

@MainActor
@Observable
public final class CallEngine {

    /// The state machine's state, mirrored for SwiftUI observation.
    public private(set) var state: CallController.State = .idle

    public let controller: CallController

    /// The media session of the CURRENT attempt (video surfaces + in-band
    /// controls live here). Cleared on reset, kept through `.ended` so the
    /// outcome screen can still render.
    public private(set) var activeMedia: WebRTCCallMedia? {
        get { mediaBox.current }
        set { mediaBox.current = newValue }
    }

    /// Camera/mute mirrors so SwiftUI updates without observing WebRTC types.
    public private(set) var cameraOn = false
    public private(set) var micMuted = false
    /// Mirror of the media's speaker route (same shape as `cameraOn`/
    /// `micMuted`). Re-synced from the media on every controller state
    /// change — the connect-time seed (speaker for camera-on calls) happens
    /// inside the media during setup, and the `.active` transition is where
    /// this mirror learns of it, so the button is truthful on its first frame.
    public private(set) var speakerEnabled = false

    /// Fix 2 — remote frame activity (staleness-based, no wire): drives the
    /// "video paused" placeholder instead of a frozen last frame. `WasEver`
    /// keeps voice-only calls from showing a video placeholder at all.
    public private(set) var remoteVideoActive = false
    public private(set) var remoteVideoWasEverActive = false

    /// Factory plumbing: CallController's `makeMediaSession` closure must
    /// exist before `self` does, so the handle lives in a box both share.
    private final class MediaBox {
        var current: WebRTCCallMedia?
        var cameraOnNextAttempt = false
    }
    private let mediaBox: MediaBox

    public init(sendSignal: @escaping (CallSignal, Data) async throws -> Void,
                onMissedCall: @escaping (Data) -> Void) {
        let box = MediaBox()
        mediaBox = box
        controller = CallController(
            sendSignal: sendSignal,
            makeMediaSession: {
                let media = WebRTCCallMedia(config: .operatorSupplied,
                                            cameraInitiallyEnabled: box.cameraOnNextAttempt)
                box.current = media
                return media
            })
        controller.onMissedCall = onMissedCall
        controller.onStateChange = { [weak self] newState in
            guard let self else { return }
            self.state = newState
            self.cameraOn = self.activeMedia?.cameraEnabled ?? false
            self.micMuted = self.activeMedia?.micMuted ?? false
            self.speakerEnabled = self.activeMedia?.speakerEnabled ?? false
            // Fix 2: hook the current attempt's frame-activity callback once.
            if let media = self.activeMedia, media.onRemoteVideoActive == nil {
                media.onRemoteVideoActive = { [weak self] active in
                    self?.remoteVideoActive = active
                    if active { self?.remoteVideoWasEverActive = true }
                }
            }
        }
        installLifecycleObservers()
    }

    // MARK: - Teardown on the world intruding (P5)

    /// v1 POLICY, honest and simple: a system audio interruption (an incoming
    /// phone call, Siri) or backgrounding ENDS the call — there is no `audio`
    /// background mode configured and no CallKit hold, so pretending to keep
    /// the call alive would just strand the peer against a dead pipe. In-ring
    /// states end politely (cancel/decline seals the frame so the far banner
    /// drops); connected states hang up (the RTC close IS the signal).
    private var lifecycleObservers: [NSObjectProtocol] = []

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor [weak self] in await self?.endForExternalEvent() }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.endForExternalEvent() }
        })
    }

    private func endForExternalEvent() async {
        switch state {
        case .active, .connecting:
            hangUp()
        case .outgoingRinging:
            await cancelOutgoing()
        case .incomingRinging:
            await decline()
        case .idle, .ended:
            break
        }
    }

    // MARK: - Intents (UI-facing)

    /// Same wire either way — the camera just starts off for a voice call.
    public func startVoiceCall(peerKey: Data) async {
        mediaBox.cameraOnNextAttempt = false
        await controller.startCall(peerKey: peerKey)
    }

    public func startVideoCall(peerKey: Data) async {
        mediaBox.cameraOnNextAttempt = true
        await controller.startCall(peerKey: peerKey)
    }

    public func accept(withCamera: Bool) async {
        mediaBox.cameraOnNextAttempt = withCamera
        await controller.accept()
    }

    public func decline() async { await controller.decline() }
    public func cancelOutgoing() async { await controller.cancelOutgoing() }
    public func hangUp() { controller.hangUp() }

    public func reset() {
        controller.reset()
        activeMedia = nil
        cameraOn = false
        micMuted = false
        speakerEnabled = false
        remoteVideoActive = false
        remoteVideoWasEverActive = false
    }

    /// Inbound frames, forwarded by the inbox (the events stream's single
    /// consumer).
    public func handleInbound(_ signal: CallSignal, from peerKey: Data) async {
        await controller.handleInbound(signal, from: peerKey)
    }

    // MARK: - Video surfaces (typed UIView so the UI never imports WebRTC)

    public var localVideoSurface: UIView? { activeMedia?.localVideoView }
    public var remoteVideoSurface: UIView? { activeMedia?.remoteVideoView }

    // MARK: - In-band controls (never the wire)

    public func setCameraEnabled(_ enabled: Bool) {
        activeMedia?.setCameraEnabled(enabled)
        cameraOn = enabled
    }

    public func setMicMuted(_ muted: Bool) {
        activeMedia?.setMicMuted(muted)
        micMuted = muted
    }

    public func setSpeakerEnabled(_ enabled: Bool) {
        activeMedia?.setSpeakerEnabled(enabled)
        speakerEnabled = enabled
    }

    /// Fix 1: front ↔ back capture swap, forwarded — no wire, no sender,
    /// no renegotiation.
    public func flipCamera() {
        activeMedia?.flipCamera()
    }
}
