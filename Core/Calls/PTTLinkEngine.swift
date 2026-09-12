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

    /// The peer's voice on the open link, on the sphere's 0…1 meter scale
    /// (`PTTCaptureDSP.meterLevel` — the same dB mapping the mic meter uses,
    /// so both voices move the globe alike). 0 unless a walkie cover has the
    /// meter running AND the link is `.open` (globe pulse, loop 2).
    public private(set) var remoteLevel: Double = 0

    /// The cover's intent (`setRemoteLevelMeter`); the loop itself only ticks
    /// while the link is open — see `syncMeter`.
    private var meterWanted = false
    private var meterTask: Task<Void, Never>?
    /// 20 Hz: RTP packets arrive every 20 ms and the sphere eases between
    /// samples, so faster buys nothing. Deliberately unpinned (timer loop,
    /// same ruling as the open timeout).
    private static let meterInterval: Duration = .milliseconds(50)

    public let controller: PTTLinkController

    private var lifecycleObservers: [NSObjectProtocol] = []

    /// The link id currently registered with `PTTSessionOwner` as an external
    /// hold (see that file): registered on the FIRST `.opening` state (the
    /// responder's session is active from `makeAnswer`, before connect) and
    /// released on `.closed` / `.idle`, AFTER the controller has closed the
    /// media — so WebRTC skips its own deactivation (it reads `isLive`) and
    /// the owner releases the session exactly once. A nil `shared` owner
    /// (not yet wired) means no hold and WebRTC's own deactivation runs.
    private var heldLinkID: Data?

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
            guard let self else { return }
            self.state = newState
            self.syncSessionHold(for: newState)
            self.syncMeter()
        }
        controller.onTransmitChange = { [weak self] transmitting in
            self?.isTransmitting = transmitting
        }
        installLifecycleObservers()
    }

    // MARK: - Audio-session hold (IC8 choke point, see PTTSessionOwner)

    private func syncSessionHold(for newState: PTTLinkController.State) {
        switch newState {
        case .opening(let id, _, _, _), .open(let id, _, _):
            guard heldLinkID != id else { return }
            // Glare re-key: HOLD the new id BEFORE releasing the old one, so
            // the owner's set is never empty mid-hand-off and the flag never
            // dips (a dip would deactivate the session between the abandoned
            // attempt's close and the answer's activation). The last close
            // still releases exactly once.
            let old = heldLinkID
            PTTSessionOwner.shared?.hold(externalID: id)
            heldLinkID = id
            if let old { PTTSessionOwner.shared?.release(externalID: old) }
        case .idle, .closed:
            guard let old = heldLinkID else { return }
            heldLinkID = nil
            PTTSessionOwner.shared?.release(externalID: old)
        }
    }

    // MARK: - Remote level meter (globe pulse, loop 2)

    /// The walkie cover's intent: run the meter while the cover is up. The
    /// loop runs only while ALSO `.open` — nothing ticks while reaching,
    /// connecting, ended, or with no cover (a responder-role link behind its
    /// banner meters nothing). Idempotent.
    public func setRemoteLevelMeter(wanted: Bool) {
        meterWanted = wanted
        syncMeter()
    }

    /// The one place the loop starts or stops. Called from the intent and
    /// from every state change, so the loop self-stops the moment the link
    /// leaves `.open` and restarts if a later attempt opens under the same
    /// cover. Every start/stop is logged so a missing pulse in the field is
    /// diagnosable: no "meter started" line = the cover never asked or the
    /// link never opened; "level unavailable" = the read returns nil.
    private func syncMeter() {
        let shouldRun = meterWanted && controller.isOpen
        if shouldRun {
            guard meterTask == nil else { return }
            RedactLog.event("ptt-link meter: started", "state \(PTTLinkController.describe(state))")
            meterTask = Task { [weak self] in
                var reportedUnavailable = false
                var reportedAvailable = false
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.meterInterval)
                    guard let self, !Task.isCancelled else { return }
                    let raw = self.controller.remoteAudioLevel
                    // Log each outcome ONCE per run, so the field log says
                    // whether the level source exists at all.
                    if raw == nil, !reportedUnavailable, self.controller.isOpen {
                        reportedUnavailable = true
                        RedactLog.event("ptt-link meter: level unavailable (audioLevel nil — header extension not negotiated, or no packet played yet)", "")
                    } else if raw != nil, !reportedAvailable {
                        reportedAvailable = true
                        RedactLog.event("ptt-link meter: level available", "")
                    }
                    let mapped = Double(PTTCaptureDSP.meterLevel(rms: Float(raw ?? 0)))
                    if mapped != self.remoteLevel { self.remoteLevel = mapped }
                }
            }
        } else {
            guard meterTask != nil || remoteLevel != 0 else { return }
            if meterTask != nil {
                RedactLog.event("ptt-link meter: stopped", "wanted \(meterWanted) state \(PTTLinkController.describe(state))")
            }
            meterTask?.cancel()
            meterTask = nil
            remoteLevel = 0
        }
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
        RedactLog.event("ptt-link engine: audio interruption began — closing link", "state \(PTTLinkController.describe(state))")
        controller.close(reason: .interrupted)
    }

    func didEnterBackground() {
        RedactLog.event("ptt-link engine: entered background — closing link", "state \(PTTLinkController.describe(state))")
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
