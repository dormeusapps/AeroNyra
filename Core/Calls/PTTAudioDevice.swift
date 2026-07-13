// PTTAudioDevice.swift
// Core/Calls
//
// SKELETON (Commit 3, plan stage) — a custom WebRTC `RTCAudioDevice` (ADM) that
// owns ONE capture and forks the mic PCM to (i) WebRTC, (ii) the `.m4a`
// insurance-note writer, and (iii) the BLE-live Opus encoder — the single tap
// the whole walkie-talkie ladder needs. Wired into the factory via
// `RTCPeerConnectionFactory(encoderFactory:decoderFactory:audioDevice:)`.
//
// ⚠️ THIS FILE IS A SKELETON, NOT A WORKING ADM. The Core Audio audio-unit
// internals (VoiceProcessingIO setup, the @convention(c) render/record
// callbacks, format negotiation, interruption handling) are STUBBED and marked
// `UNIMPLEMENTED`. It compiles and is INERT — nothing instantiates it, and the
// factory is NOT switched to it (see FACTORY SWAP below). Its acceptance test —
// "calls still work on hardware" — is unrunnable off-device, so the full
// implementation must be iterated with two phones in the loop. Reference impl
// the WebRTC header points to: https://github.com/mstyura/RTCAudioDevice
//
// ─────────────────────────────────────────────────────────────────────────
// FACTORY SWAP (the ONE risky line — NOT applied here):
//   `WebRTCCallMedia.factory` today uses the 2-arg init (default ADM). The
//   switch is:
//       RTCPeerConnectionFactory(encoderFactory: …, decoderFactory: …,
//                                audioDevice: PTTAudioDevice.shared)
//   This RE-ROUTES the shipped calling feature's audio. Do NOT apply it until
//   the audio-unit internals below are implemented AND the AVAudioSession plan
//   is in place, and even then its acceptance is the on-device call-regression
//   pass (voice, video, music-doesn't-stop, teardown, interruptions), and it
//   commits ALONE and reverts ALONE if calls regress.
//
// AVAudioSession OWNERSHIP (preserve the shipped music-fix):
//   The header says a custom ADM is "fully responsible for configuring the
//   app's AVAudioSession." So this ADM REPLACES the `RTCAudioSession
//   .useManualAudio` foundation the current music-fix (commit 2a420f0) is built
//   on. It must itself:
//     • NOT activate the session until `startRecording`/`startPlayout` (so
//       merely constructing the factory never grabs audio → music keeps
//       playing at app launch, same property the manual-audio guard gives).
//     • Configure `.playAndRecord` (voiceChat/videoChat) on start.
//     • Deactivate with `.notifyOthersOnDeactivation` on stop, so music/podcast
//       RESUMES after a call — the exact behavior `deactivateAudioSession()`
//       gives today, now owned here.
//   Losing any of these = a music-fix regression, which is part of what the
//   hardware acceptance re-verifies.
//
// MIC-FORK TAP (the reason this ADM exists):
//   `onRecordedFrame` is called from the record callback with each PCM buffer.
//   Subscribers: the `.m4a` insurance writer (Step 2 fallback) and the BLE-live
//   Opus encoder (Step 3). One capture, all legs — no second recorder, no ADM
//   contention.
//

import Foundation
import AVFoundation
import AudioToolbox
import WebRTC

/// Custom WebRTC audio device. SKELETON — audio-unit internals unimplemented.
final class PTTAudioDevice: NSObject {

    /// Process-wide instance the factory would hold (the ADM is one-per-process,
    /// like `WebRTCCallMedia.factory`).
    static let shared = PTTAudioDevice()

    // MARK: Mic-fork tap (the reason this ADM exists)

    /// PCM callback for the insurance-note writer + BLE Opus encoder. Called
    /// from the record callback (real-time audio thread) once the audio unit
    /// is implemented — subscribers must be non-blocking. nil = no fork (calls
    /// only). NOT wired to anything yet.
    var onRecordedFrame: ((UnsafePointer<AudioBufferList>, _ frames: UInt32, _ sampleRate: Double) -> Void)?

    // MARK: WebRTC delegate + audio-unit handles

    private weak var delegate: RTCAudioDeviceDelegate?
    private var audioUnit: AudioUnit?           // VoiceProcessingIO — UNIMPLEMENTED

    private var initialized = false
    private var playoutInitialized = false
    private var recordingInitialized = false
    private var playing = false
    private var recording = false

    // MARK: Format constants (documented defaults; real values come from the
    // negotiated audio unit once implemented, and changes must be reported via
    // the delegate's notifyAudio*ParametersChange).

    /// WebRTC's canonical mono 48 kHz — the ADM negotiates the real device rate
    /// and resamples; 48 kHz is the safe declared default for the skeleton.
    private static let sampleRate: Double = 48_000
    private static let channels: Int = 1
    private static let ioBufferDuration: TimeInterval = 0.02   // 20 ms, WebRTC frame
}

// MARK: - RTCAudioDevice conformance (SKELETON)

extension PTTAudioDevice: RTCAudioDevice {

    // Format properties — declared constants for now; the real audio unit
    // supplies these and reports changes via the delegate.
    var deviceInputSampleRate: Double { Self.sampleRate }
    var inputIOBufferDuration: TimeInterval { Self.ioBufferDuration }
    var inputNumberOfChannels: Int { Self.channels }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { Self.sampleRate }
    var outputIOBufferDuration: TimeInterval { Self.ioBufferDuration }
    var outputNumberOfChannels: Int { Self.channels }
    var outputLatency: TimeInterval { 0 }

    var isInitialized: Bool { initialized }
    var isPlayoutInitialized: Bool { playoutInitialized }
    var isPlaying: Bool { playing }
    var isRecordingInitialized: Bool { recordingInitialized }
    var isRecording: Bool { recording }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        // REAL: retain `delegate`; it provides `getPlayoutData` (pull PCM to
        // render) and `deliverRecordedData` (push captured PCM to WebRTC).
        self.delegate = delegate
        initialized = true
        return true
    }

    func terminateDevice() -> Bool {
        // REAL: tear down the audio unit, drop the delegate.
        delegate = nil
        initialized = false
        return true
    }

    func initializePlayout() -> Bool {
        // UNIMPLEMENTED: create/configure the VoiceProcessingIO audio unit for
        // output; set the output stream format to (sampleRate, channels).
        playoutInitialized = true
        return true
    }

    func startPlayout() -> Bool {
        // UNIMPLEMENTED: activate AVAudioSession (.playAndRecord), start the
        // audio unit; the render callback pulls PCM via delegate.getPlayoutData.
        playing = true
        return true
    }

    func stopPlayout() -> Bool {
        // UNIMPLEMENTED: stop the unit if neither playing nor recording;
        // deactivate the session with .notifyOthersOnDeactivation.
        playing = false
        return true
    }

    func initializeRecording() -> Bool {
        // UNIMPLEMENTED: configure the audio unit input bus; enable input.
        recordingInitialized = true
        return true
    }

    func startRecording() -> Bool {
        // UNIMPLEMENTED: start the unit; the record callback (a) hands PCM to
        // delegate.deliverRecordedData for WebRTC AND (b) forwards it to
        // `onRecordedFrame` (the .m4a note + BLE Opus fork).
        recording = true
        return true
    }

    func stopRecording() -> Bool {
        // UNIMPLEMENTED: stop input; if not playing, stop the unit + deactivate.
        recording = false
        return true
    }
}

// ─────────────────────────────────────────────────────────────────────────
// HARD PARTS (what the full implementation must get right — the on-device
// iteration list, in priority order):
//
//  1. @convention(c) render + record callbacks. AURenderCallback is a C
//     function pointer that cannot capture `self`; pass the instance via
//     `AudioUnitSetProperty(kAudioUnitProperty_SetRenderCallback / …input…)`'s
//     `inputProcRefCon` as an `Unmanaged<PTTAudioDevice>` and reconstitute it
//     inside the callback. Both callbacks run on the real-time audio thread —
//     no allocation, no locks, no Swift runtime-heavy calls.
//  2. Playout render: pull from `delegate.getPlayoutData(actionFlags,
//     timestamp, busNumber, frameCount, outputData)` and write into the unit's
//     output buffer.
//  3. Record deliver: after `AudioUnitRender` into an input buffer, call
//     `delegate.deliverRecordedData(actionFlags, timestamp, busNumber,
//     frameCount, inputData, renderContext, renderBlock)` for WebRTC, then
//     `onRecordedFrame(...)` for the fork.
//  4. Format negotiation: read the hardware sample rate from AVAudioSession,
//     resample to WebRTC's 48 kHz mono if needed, and report any change via
//     `dispatchAsync { delegate.notifyAudioInputParametersChange() }`.
//  5. AVAudioSession ownership preserving the music-fix (see header): activate
//     only on start, `.notifyOthersOnDeactivation` on stop.
//  6. Interruptions/route changes: on AVAudioSession interruption, call
//     `delegate.notifyAudioInputInterrupted()/notifyAudioOutputInterrupted()`
//     via `dispatchAsync`, tear the unit down, and rebuild on resume.
//  7. Threading: all delegate `notify*` calls MUST run on the ADM thread via
//     `delegate.dispatchAsync`/`dispatchSync`.
//
// Only after 1–7 are implemented does the FACTORY SWAP (header) get applied —
// and then the acceptance is the two-device call-regression pass, not a build.
// ─────────────────────────────────────────────────────────────────────────
