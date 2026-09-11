// PTTLinkEngine.swift
// Core/Calls
//
// The composition-root face of the live PTT-over-IP link (step 4) — the
// exact counterpart of `CallEngine` for `PTTLinkController`: ONE observable
// object the UI (step 5) reads, owning the controller, manufacturing a
// `WebRTCCallMedia` per link, mirroring state for SwiftUI, and applying the
// same v1 lifecycle policy CallEngine applies to calls.
//
// Wiring (injected by ContentView, nothing imported here):
//   • sendSignal → FirstContactCoordinator.sendCallSignal (the same rail as
//     calls: kind 14 request, kinds 9/10 answer/decline).
//   • autoAnswerPolicy → `!callEngine.isCallInProgress` (fail closed: no
//     engine means decline). A link never pre-empts a call.
//   • Inbound frames arrive via MessageInbox's onCallSignal forward, fanned
//     out AFTER CallEngine in the same Task — CallEngine first so a ring
//     pre-empts the link before the link sees (and drops) the frame.
//   • `CallEngine.preemptLink` → `preempt()` here. A call always pre-empts.
//
// LIFECYCLE POLICY (mirrors CallEngine's v1, honest and simple): a system
// audio interruption or backgrounding CLOSES the link with `.interrupted`
// (a visible reason). There is no `audio` background mode and no resume:
// on return to foreground the link STAYS closed; the walkie surface (step 5)
// decides whether to re-open it, the engine never re-opens on its own.
//
// NOT MIRRORED (deliberately, step 5's call): CallEngine's idle-timer hold.
// Both engines writing the process-global `isIdleTimerDisabled` from their
// own state can fight across the call → link hand-off (a call's `reset()`
// writes false after a link has opened). The surface that presents the
// walkie owns that decision, with both states in view.
//
// INERT until step 5 opens a link outbound. After step 4 an INBOUND
// `.pttRequest` from a verified contact IS auto-answered here (real media,
// real audio session, responder mic live, muted) — nothing ships that can
// send one yet.
//

import Foundation
import Observation
import UIKit
import AVFoundation

@MainActor
@Observable
public final class PTTLinkEngine {

    /// The controller's state, mirrored for SwiftUI observation.
    public private(set) var state: PTTLinkController.State = .idle

    /// Mirror of `PTTLinkController.isTransmitting`.
    public private(set) var isTransmitting = false

    public let controller: PTTLinkController

    private var lifecycleObservers: [NSObjectProtocol] = []

    /// `makeMediaSession`: test seam. nil (the app) means the real
    /// `WebRTCCallMedia`, camera off — the link never negotiates video on.
    public init(sendSignal: @escaping (CallSignal, Data) async throws -> Void,
                autoAnswerPolicy: @escaping () -> Bool,
                makeMediaSession: (() -> PTTLinkMediaSession)? = nil,
                openTimeout: Duration = PTTLinkController.defaultOpenTimeout) {
        controller = PTTLinkController(
            sendSignal: sendSignal,
            makeMediaSession: makeMediaSession ?? {
                WebRTCCallMedia(config: .operatorSupplied, cameraInitiallyEnabled: false)
            },
            openTimeout: openTimeout,
            autoAnswerPolicy: autoAnswerPolicy)
        controller.onStateChange = { [weak self] newState in
            self?.state = newState
        }
        controller.onTransmitChange = { [weak self] transmitting in
            self?.isTransmitting = transmitting
        }
        installLifecycleObservers()
    }

    // MARK: - Teardown on the world intruding (mirrors CallEngine)

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor [weak self] in self?.interruptionBegan() }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.didEnterBackground() }
        })
    }

    /// Split out (internal) so the policy is unit-testable without posting
    /// notifications through the real center.
    func interruptionBegan() {
        controller.close(reason: .interrupted)
    }

    func didEnterBackground() {
        controller.close(reason: .interrupted)
    }

    // MARK: - Intents (UI-facing, step 5)

    public func open(to peerKey: Data) async { await controller.open(to: peerKey) }
    public func close() { controller.close() }
    public func reset() { controller.reset() }

    @discardableResult
    public func pressBegan() -> Bool { controller.pressBegan() }

    @discardableResult
    public func pressEnded() -> Bool { controller.pressEnded() }

    /// The CallEngine seam: a call always pre-empts a link.
    public func preempt() { controller.preempt() }

    /// Inbound frames, forwarded by the inbox fan-out.
    public func handleInbound(_ signal: CallSignal, from peerKey: Data) async {
        await controller.handleInbound(signal, from: peerKey)
    }
}
