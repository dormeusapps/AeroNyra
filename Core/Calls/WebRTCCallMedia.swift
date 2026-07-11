// WebRTCCallMedia.swift
// Core/Calls
//
// The concrete `CallMediaSession` (FaceTime v1, P2): libwebrtc
// (stasel/WebRTC-lib, exact-pinned in the Podfile) behind the seam the
// committed state machine already speaks. The state machine is UNTOUCHED —
// this file plus CallICEConfig is the whole media layer.
//
// NON-TRICKLE (LOCKED, CallSignal.swift): offer/answer returned from here are
// COMPLETE SDPs — we set the local description, wait for ICE gathering to
// complete (bounded by `gatherTimeout`; whatever has gathered by then rides),
// and only then hand the SDP up to be SEALED to the verified contact. The
// SDP carries the DTLS-SRTP `a=fingerprint:` line, so media keys are
// authenticated by the existing trust root — this file does no key handling
// of its own, by design.
//
// AUDIO+VIDEO, ALWAYS (operator ruling): every offer/answer negotiates both
// an audio and a video track — the camera toggle flips the local video
// track's `isEnabled` + capture IN-BAND, never the wire. Kinds 8-10 stay
// byte-compatible; both peers must run a calls build (flag day, accepted).
//
// ICE SERVERS come from `CallICEConfig.operatorSupplied` — the one config
// seam. Nothing here names a host.
//
// REMOTE HANG-UP honesty: post-connect there is no wire signal (committed
// design) — the peer's close reaches us as ICE/PC state decay, which can take
// seconds to be conclusive. `connectedOnce` splits the two callbacks: decay
// before connect → onFailed (the no-TURN NAT outcome); decay after →
// onRemoteEnded (their hang-up or a dead network — indistinguishable here).
//

import Foundation
import AVFoundation
import WebRTC
import os

@MainActor
public final class WebRTCCallMedia: NSObject, CallMediaSession {

    public enum MediaError: Error {
        case peerConnectionFailed   // factory refused the configuration
        case noLocalSDP             // gathering finished but no description
        case closed                 // API called after close()
    }

    // MARK: Process-wide factory
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    /// Non-trickle gathering bound: proceed with whatever candidates exist if
    /// ICE gathering hasn't reported complete by then (TURN allocations can
    /// straggle; an SDP with the candidates gathered so far still connects).
    static let gatherTimeout: TimeInterval = 5

    // MARK: Video quality (adaptive; operator-locked settings)

    /// Capture target: 720p30. The pixel ceiling — congestion control and the
    /// degradation preference adapt BELOW it; nothing custom loops above it.
    /// `nonisolated`: immutable Sendable constants read by the nonisolated
    /// pure selector (`bestFormatIndex`) — Swift 6 strict isolation requires
    /// the declaration to match the reader.
    nonisolated static let targetCaptureWidth = 1280
    nonisolated static let targetCaptureHeight = 720
    nonisolated static let targetCaptureFPS = 30

    /// Encoder spend ceiling (sender.maxBitrateBps). LOCKED at 1.5 Mbps —
    /// visibly sharper than the old VGA path, cheaper than full 720p spend.
    /// The richer ceiling, if the operator ever wants it: 2_500_000.
    static let maxVideoBitrateBps = 1_500_000

    // MARK: Seam callbacks (CallMediaSession)
    public var onConnected: (() -> Void)?
    public var onFailed: (() -> Void)?
    public var onRemoteEnded: (() -> Void)?

    /// Fix 2 — remote video activity, NO wire change: fires false when remote
    /// frames stop arriving (their camera off — capture stops, so the last
    /// decoded frame would otherwise freeze on screen) and true when they
    /// resume. Staleness-based, so it cannot distinguish camera-off from a
    /// network stall; the UI copy must stay honest about that.
    public var onRemoteVideoActive: ((Bool) -> Void)?

    // MARK: Video surfaces + in-band controls (UI talks to the CONCRETE type
    // via CallEngine; the state machine's seam stays voice-shaped.)
    public let localVideoView = RTCMTLVideoView()
    public let remoteVideoView = RTCMTLVideoView()

    public private(set) var cameraEnabled: Bool
    public private(set) var micMuted = false
    /// Which camera feeds the call. Flipping swaps the CAPTURE device only —
    /// the video track, sender, and SDP are untouched (no wire change).
    public private(set) var cameraPosition: AVCaptureDevice.Position = .front

    // MARK: Internals
    private let config: CallICEConfig
    private var pc: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    private var localVideoTrack: RTCVideoTrack?
    /// The video RTCRtpSender, retained (its add() return was previously
    /// discarded) — the handle the encoding ceiling + degradation preference
    /// are set on. Internal for the loopback test's parameter assertions.
    private(set) var videoSender: RTCRtpSender?
    /// The REMOTE video track, retained. Retention is load-bearing: the
    /// renderer's sink registration does not keep the ObjC track wrapper
    /// alive, and an unretained remote track deallocates after the attach —
    /// frames then never reach the renderer (remote stays black while local,
    /// which IS retained, renders fine).
    private var remoteVideoTrack: RTCVideoTrack?
    private var videoSource: RTCVideoSource?
    private var capturer: RTCCameraVideoCapturer?
    private let remoteFrameMonitor = RemoteFrameMonitor()
    private var remoteActivityWatch: Task<Void, Never>?
    private var remoteVideoActiveReported = false
    private var gatherContinuation: CheckedContinuation<Void, Never>?
    private var connectedOnce = false
    private var terminalFired = false
    private var isClosed = false

    public init(config: CallICEConfig = .operatorSupplied,
                cameraInitiallyEnabled: Bool = false) {
        self.config = config
        self.cameraEnabled = cameraInitiallyEnabled
        super.init()
    }

    // MARK: - ICE server mapping (the config seam's WebRTC edge; unit-tested)

    nonisolated static func iceServers(from config: CallICEConfig) -> [RTCIceServer] {
        var servers: [RTCIceServer] = []
        if config.hasSTUN {
            servers.append(RTCIceServer(urlStrings: config.stunURLs))
        }
        if config.hasTURN {
            servers.append(RTCIceServer(urlStrings: config.turnURLs,
                                        username: config.turnUsername,
                                        credential: config.turnCredential))
        }
        return servers
    }

    // MARK: - CallMediaSession

    public func makeOffer() async throws -> String {
        let pc = try makePeerConnection()
        addLocalTracks(to: pc)
        let offer = try await Self.createOffer(pc)
        try await Self.setLocal(pc, offer)
        applyVideoEncodingParameters()   // re-apply post-negotiation (idempotent)
        await waitForGathering(pc)
        guard let sdp = pc.localDescription?.sdp, !sdp.isEmpty else {
            throw MediaError.noLocalSDP
        }
        return sdp
    }

    public func makeAnswer(remoteOffer: String) async throws -> String {
        let pc = try makePeerConnection()
        addLocalTracks(to: pc)
        try await Self.setRemote(pc, RTCSessionDescription(type: .offer, sdp: remoteOffer))
        attachRemoteVideo(from: pc)
        let answer = try await Self.createAnswer(pc)
        try await Self.setLocal(pc, answer)
        applyVideoEncodingParameters()   // re-apply post-negotiation (idempotent)
        await waitForGathering(pc)
        guard let sdp = pc.localDescription?.sdp, !sdp.isEmpty else {
            throw MediaError.noLocalSDP
        }
        configureAudioSession()
        return sdp
    }

    public func start(remoteAnswer: String) async throws {
        guard let pc, !isClosed else { throw MediaError.closed }
        try await Self.setRemote(pc, RTCSessionDescription(type: .answer, sdp: remoteAnswer))
        attachRemoteVideo(from: pc)
        configureAudioSession()
    }

    /// Deterministic remote-video attach: pull the video track from the peer
    /// connection's receivers, RETAIN it, and hand it to the main renderer.
    /// Called after every setRemoteDescription — the caller's receivers are
    /// pre-created by the offerToReceive constraints, so the didAddReceiver
    /// delegate ("called when a receiver … is CREATED") is not guaranteed to
    /// fire there; pulling is. Idempotent: a track already attached is left
    /// alone. The delegate path stays wired for late-created receivers and
    /// routes here.
    private func attachRemoteVideo(from pc: RTCPeerConnection) {
        guard !isClosed else { return }
        for receiver in pc.receivers {
            guard let track = receiver.track as? RTCVideoTrack else { continue }
            attachRemoteVideoTrack(track)
            return
        }
    }

    private func attachRemoteVideoTrack(_ track: RTCVideoTrack) {
        guard !isClosed, remoteVideoTrack !== track else { return }
        remoteVideoTrack?.remove(remoteVideoView)
        remoteVideoTrack?.remove(remoteFrameMonitor)
        remoteVideoTrack = track          // retention is the fix — see property doc
        track.isEnabled = true
        track.add(remoteVideoView)
        track.add(remoteFrameMonitor)     // second sink: frame-activity stamps
        startRemoteActivityWatch()
    }

    /// Half-second poll over the monitor's last-frame stamp: >1s without a
    /// frame flips inactive (their camera off / stalled), a fresh frame flips
    /// it back. Cheap by design — the per-frame cost is one lock-protected
    /// Date store in the monitor.
    private func startRemoteActivityWatch() {
        remoteActivityWatch?.cancel()
        remoteActivityWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !self.isClosed else { return }
                let active = Date().timeIntervalSince(self.remoteFrameMonitor.lastFrameAt) < 1.0
                if active != self.remoteVideoActiveReported {
                    self.remoteVideoActiveReported = active
                    self.onRemoteVideoActive?(active)
                }
            }
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        gatherContinuation?.resume()
        gatherContinuation = nil
        capturer?.stopCapture()
        capturer = nil
        pc?.close()
        pc = nil
        audioTrack = nil
        localVideoTrack = nil
        videoSender = nil
        remoteActivityWatch?.cancel()
        remoteActivityWatch = nil
        remoteVideoTrack?.remove(remoteVideoView)
        remoteVideoTrack?.remove(remoteFrameMonitor)
        remoteVideoTrack = nil
        videoSource = nil
    }

    // MARK: - In-band controls (never the wire)

    public func setCameraEnabled(_ enabled: Bool) {
        cameraEnabled = enabled
        localVideoTrack?.isEnabled = enabled
        if enabled {
            startCaptureIfPossible()
        } else {
            capturer?.stopCapture()
        }
    }

    public func setMicMuted(_ muted: Bool) {
        micMuted = muted
        audioTrack?.isEnabled = !muted
    }

    /// Flip front ↔ back mid-call: restart capture on the other device, put
    /// through the SAME bestFormatIndex selection (the flipped camera gets
    /// the 720p treatment too). Capture-source swap only.
    public func flipCamera() {
        cameraPosition = (cameraPosition == .front) ? .back : .front
        guard cameraEnabled else { return }   // takes effect on next enable
        capturer?.stopCapture()
        startCaptureIfPossible()
    }

    // MARK: - Peer connection assembly

    private func makePeerConnection() throws -> RTCPeerConnection {
        let rtcConfig = RTCConfiguration()
        rtcConfig.iceServers = Self.iceServers(from: config)
        rtcConfig.sdpSemantics = .unifiedPlan
        // Non-trickle: gather everything up front (continualGathering off).
        rtcConfig.continualGatheringPolicy = .gatherOnce
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: nil)
        guard let pc = Self.factory.peerConnection(with: rtcConfig,
                                                   constraints: constraints,
                                                   delegate: self) else {
            throw MediaError.peerConnectionFailed
        }
        self.pc = pc
        return pc
    }

    /// Audio + video tracks on EVERY call (the always-offer-both ruling).
    /// Video starts enabled per `cameraEnabled`; capture only runs while on.
    private func addLocalTracks(to pc: RTCPeerConnection) {
        let audioSource = Self.factory.audioSource(with: nil)
        let audio = Self.factory.audioTrack(with: audioSource, trackId: "audio0")
        pc.add(audio, streamIds: ["call0"])
        audioTrack = audio

        let source = Self.factory.videoSource()
        videoSource = source
        let video = Self.factory.videoTrack(with: source, trackId: "video0")
        video.isEnabled = cameraEnabled
        videoSender = pc.add(video, streamIds: ["call0"])   // retained: carries the ceiling
        localVideoTrack = video
        video.add(localVideoView)
        capturer = RTCCameraVideoCapturer(delegate: source)
        if cameraEnabled { startCaptureIfPossible() }
        applyVideoEncodingParameters()
    }

    /// The two explicit adaptation knobs below the capture ceiling: the
    /// 1.5 Mbps spend cap and maintain-framerate degradation (drop resolution
    /// first, keep motion smooth — faces on a call). WebRTC's congestion
    /// control ramps freely UNDER these; no custom loop. Idempotent, and
    /// re-applied after negotiation in case the encodings list was empty at
    /// track-add time.
    private func applyVideoEncodingParameters() {
        guard let sender = videoSender else { return }
        let parameters = sender.parameters
        parameters.degradationPreference = NSNumber(
            value: RTCDegradationPreference.maintainFramerate.rawValue)
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = NSNumber(value: Self.maxVideoBitrateBps)
        }
        sender.parameters = parameters
    }

    /// One camera format candidate, decoupled from AVCaptureDevice.Format so
    /// the selection below is a PURE, unit-testable function.
    struct CaptureFormatCandidate: Equatable {
        let width: Int
        let height: Int
        /// Across the format's supported ranges.
        let minFrameRate: Double
        let maxFrameRate: Double
    }

    /// THE capture-format choice (pure): target 720p, preferring formats that
    /// can run at 30 fps.
    ///  • Exotic formats that can ONLY run above 30 (minFrameRate > 30 —
    ///    slo-mo modes) are ignored outright.
    ///  • Primary score: distance to the 1280 target width — sharpness is the
    ///    point, so a 1280×720@24 beats a 640×480@30.
    ///  • Tie-breaks: can-do-30 first, then height closest to 720.
    /// Returns the index into `candidates`, or nil if none is eligible.
    nonisolated static func bestFormatIndex(of candidates: [CaptureFormatCandidate]) -> Int? {
        let eligible = candidates.indices.filter { candidates[$0].minFrameRate <= 30 }
        return eligible.min { i, j in
            let a = candidates[i], b = candidates[j]
            let da = abs(a.width - targetCaptureWidth)
            let db = abs(b.width - targetCaptureWidth)
            if da != db { return da < db }
            let a30 = a.maxFrameRate >= 30 ? 0 : 1
            let b30 = b.maxFrameRate >= 30 ? 0 : 1
            if a30 != b30 { return a30 < b30 }
            return abs(a.height - targetCaptureHeight) < abs(b.height - targetCaptureHeight)
        }
    }

    /// The `cameraPosition` camera at the best 720p30-target format it offers
    /// (the pure selector above decides). Silently a no-op where no camera
    /// exists (simulator), so the audio path is never held hostage by capture.
    private func startCaptureIfPossible() {
        guard let capturer,
              let device = RTCCameraVideoCapturer.captureDevices()
                .first(where: { $0.position == cameraPosition })
                ?? RTCCameraVideoCapturer.captureDevices().first else { return }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let candidates = formats.map { format -> CaptureFormatCandidate in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let ranges = format.videoSupportedFrameRateRanges
            return CaptureFormatCandidate(
                width: Int(dims.width),
                height: Int(dims.height),
                minFrameRate: ranges.map(\.minFrameRate).min() ?? 0,
                maxFrameRate: ranges.map(\.maxFrameRate).max() ?? 0)
        }
        guard let index = Self.bestFormatIndex(of: candidates) else { return }
        let fps = min(Int(candidates[index].maxFrameRate), Self.targetCaptureFPS)
        capturer.startCapture(with: device, format: formats[index], fps: fps)
    }

    /// Voice-chat audio session; video calls prefer the speaker. Full
    /// interruption/route handling is P5 — this is just "sound works".
    private func configureAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try? session.setCategory(.playAndRecord,
                                 mode: cameraEnabled ? .videoChat : .voiceChat,
                                 options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? session.setActive(true)
        session.unlockForConfiguration()
    }

    // MARK: - Non-trickle gathering wait

    private func waitForGathering(_ pc: RTCPeerConnection) async {
        if pc.iceGatheringState == .complete { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            gatherContinuation = cont
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.gatherTimeout))
                guard let self else { return }
                self.gatherContinuation?.resume()
                self.gatherContinuation = nil
            }
        }
    }

    // MARK: - Continuation wrappers over the callback API (no API guessed:
    // these are the documented completion-handler entry points).

    private static func createOffer(_ pc: RTCPeerConnection) async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue,
            ],
            optionalConstraints: nil)
        return try await withCheckedThrowingContinuation { cont in
            pc.offer(for: constraints) { sdp, error in
                if let sdp { cont.resume(returning: sdp) }
                else { cont.resume(throwing: error ?? MediaError.noLocalSDP) }
            }
        }
    }

    private static func createAnswer(_ pc: RTCPeerConnection) async throws -> RTCSessionDescription {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: nil)
        return try await withCheckedThrowingContinuation { cont in
            pc.answer(for: constraints) { sdp, error in
                if let sdp { cont.resume(returning: sdp) }
                else { cont.resume(throwing: error ?? MediaError.noLocalSDP) }
            }
        }
    }

    private static func setLocal(_ pc: RTCPeerConnection, _ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    private static func setRemote(_ pc: RTCPeerConnection, _ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }
}

// MARK: - Remote frame monitor (Fix 2)

/// A second renderer sink on the remote track (tracks support multiple
/// sinks): stamps when the last frame arrived. `renderFrame` runs on the
/// decode thread at frame rate — the body is one lock-protected Date store.
private final class RemoteFrameMonitor: NSObject, RTCVideoRenderer {

    private let stamp = OSAllocatedUnfairLock(initialState: Date.distantPast)

    var lastFrameAt: Date { stamp.withLock { $0 } }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil else { return }
        let now = Date()
        stamp.withLock { $0 = now }
    }
}

// MARK: - RTCPeerConnectionDelegate (libwebrtc threads → main actor)

extension WebRTCCallMedia: RTCPeerConnectionDelegate {

    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection,
                                           didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { @MainActor [weak self] in
            self?.gatherContinuation?.resume()
            self?.gatherContinuation = nil
        }
    }

    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection,
                                           didChange newState: RTCIceConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, !self.isClosed else { return }
            switch newState {
            case .connected, .completed:
                guard !self.connectedOnce else { return }
                self.connectedOnce = true
                self.onConnected?()
            case .failed, .closed:
                guard !self.terminalFired else { return }
                self.terminalFired = true
                if self.connectedOnce {
                    self.onRemoteEnded?()   // their hang-up or a dead network
                } else {
                    self.onFailed?()        // never connected (the NAT outcome)
                }
            default:
                break
            }
        }
    }

    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection,
                                           didAdd rtpReceiver: RTCRtpReceiver,
                                           streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        Task { @MainActor [weak self] in
            self?.attachRemoteVideoTrack(track)   // retains + renders
        }
    }

    // Required-but-unused delegate surface.
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection,
                                           didChange stateChanged: RTCSignalingState) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection,
                                           didAdd stream: RTCMediaStream) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection,
                                           didRemove stream: RTCMediaStream) {}
    nonisolated public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection,
                                           didGenerate candidate: RTCIceCandidate) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection,
                                           didRemove candidates: [RTCIceCandidate]) {}
    nonisolated public func peerConnection(_ peerConnection: RTCPeerConnection,
                                           didOpen dataChannel: RTCDataChannel) {}
}
