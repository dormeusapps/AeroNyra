//
//  PTTCaptureEngineTests.swift
//  BeaconTests
//
//  Deterministic, pre-hardware tests for the capture seam's correctness core.
//  The AVAudioEngine/converter/AVAudioFile path is hardware-gated (a device log
//  validates it); these cover the load-bearing pure DSP: the 960-sample slicer's
//  seam integrity (no sample dropped or duplicated across tap-buffer boundaries),
//  the Float→Int16 clamp, and the RMS meter mapping.
//

import XCTest
import AVFoundation
import CryptoKit
@testable import Beacon

final class PTTCaptureEngineTests: XCTestCase {

    // MARK: Slicer — exact 960 frames + remainder carried across seams

    func testSlicerSeamIntegrityAcrossBufferSizes() {
        // Two buffer-size profiles: a 48 kHz-ish cadence and an irregular
        // 44.1→48 kHz resample cadence, both with sizes that are NOT multiples
        // of 960, plus tiny/odd buffers to stress the seams.
        let profiles: [[Int]] = [
            [4096, 4096, 960, 1, 959, 1920, 4096, 1234, 4096],       // ~48 kHz
            [4459, 4459, 4459, 4459, 1, 2, 3, 4459, 4459, 4459],     // ~44.1→48 kHz
        ]
        for profile in profiles {
            var slicer = OpusFrameSlicer()
            var fedTotal = 0
            var collected: [Float] = []       // all emitted frame samples, in order
            var frameCount = 0

            for size in profile {
                // A global ramp (sample i == Float(i)) makes any drop/dup/reorder detectable.
                let buf = (0..<size).map { Float(fedTotal + $0) }
                fedTotal += size
                for frame in slicer.push(buf) {
                    XCTAssertEqual(frame.count, OpusVoiceCodec.samplesPerFrame)
                    collected += frame
                    frameCount += 1
                }
            }

            // Emitted frames == floor(total/960); remainder == total % 960.
            XCTAssertEqual(frameCount, fedTotal / OpusVoiceCodec.samplesPerFrame)
            XCTAssertEqual(slicer.remainderCount, fedTotal % OpusVoiceCodec.samplesPerFrame)
            // Emitted samples are exactly the contiguous ramp prefix — no loss/dup/reorder.
            XCTAssertEqual(collected, (0..<(frameCount * OpusVoiceCodec.samplesPerFrame)).map { Float($0) })

            // Seam continuity: complete the pending remainder; the final frame must
            // continue the ramp exactly, proving the remainder was carried verbatim.
            if slicer.remainderCount > 0 {
                let need = OpusVoiceCodec.samplesPerFrame - slicer.remainderCount
                let tail = (0..<need).map { Float(fedTotal + $0) }
                let final = slicer.push(tail)
                XCTAssertEqual(final.count, 1)
                let base = frameCount * OpusVoiceCodec.samplesPerFrame
                XCTAssertEqual(final[0], (base..<(base + OpusVoiceCodec.samplesPerFrame)).map { Float($0) })
                XCTAssertEqual(slicer.remainderCount, 0)
            }
        }
    }

    func testSlicerEmitsNothingBelowAFullFrame() {
        var slicer = OpusFrameSlicer()
        XCTAssertTrue(slicer.push((0..<959).map(Float.init)).isEmpty)
        XCTAssertEqual(slicer.remainderCount, 959)
        let frames = slicer.push([Float(959)])   // now exactly 960
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(slicer.remainderCount, 0)
    }

    // MARK: Float → Int16 clamp

    func testInt16ClampAtAndBeyondFullScale() {
        XCTAssertEqual(PTTCaptureDSP.int16(0), 0)
        XCTAssertEqual(PTTCaptureDSP.int16(1.0), 32767)
        XCTAssertEqual(PTTCaptureDSP.int16(-1.0), -32767)
        XCTAssertEqual(PTTCaptureDSP.int16(2.0), 32767)     // overshoot clamps, not wraps
        XCTAssertEqual(PTTCaptureDSP.int16(-2.0), -32767)
        XCTAssertEqual(PTTCaptureDSP.int16(0.5), 16383)     // 0.5 * 32767 = 16383.5 → 16383
        XCTAssertEqual(PTTCaptureDSP.int16(-0.5), -16383)
    }

    // MARK: RMS meter mapping

    func testMeterSilenceAndFullScale() {
        let silence = [Float](repeating: 0, count: 960)
        XCTAssertEqual(PTTCaptureDSP.meterLevel(rms: PTTCaptureDSP.rms(silence)), 0, accuracy: 0.001)

        // Full-scale square wave: RMS == 1 → 0 dBFS → meter 1.
        let full = (0..<960).map { $0 % 2 == 0 ? Float(1) : Float(-1) }
        XCTAssertEqual(PTTCaptureDSP.rms(full), 1, accuracy: 0.0001)
        XCTAssertEqual(PTTCaptureDSP.meterLevel(rms: PTTCaptureDSP.rms(full)), 1, accuracy: 0.001)

        // A known mid level: RMS 0.1 → -20 dBFS → (−20 − −50)/50 = 0.6.
        XCTAssertEqual(PTTCaptureDSP.meterLevel(rms: 0.1), 0.6, accuracy: 0.001)
    }

    // MARK: Note-gate — live holds that shipped audio leave no note

    /// The pure decision table stop() applies. INERT in shipped builds (live
    /// is always nil → liveHold never true); pinned here so live PTT can never
    /// come up without the clog fix already in place.
    func testNoteGateSuppressesOnlyLiveHoldsAtThreshold() {
        let t = PTTCaptureEngine.noteSuppressionMinFrames
        // Live + frames at/above threshold → note suppressed (they heard it).
        XCTAssertTrue(PTTCaptureEngine.shouldSuppressNote(liveHold: true, sentFrames: t))
        XCTAssertTrue(PTTCaptureEngine.shouldSuppressNote(liveHold: true, sentFrames: t + 500))
        // Live + frames below threshold → note still ships. Load-bearing: a
        // live session that opened but moved (almost) no audio must leave the
        // note — it is the only copy of the utterance anywhere.
        XCTAssertFalse(PTTCaptureEngine.shouldSuppressNote(liveHold: true, sentFrames: t - 1))
        XCTAssertFalse(PTTCaptureEngine.shouldSuppressNote(liveHold: true, sentFrames: 0))
        // Note-only hold → never suppressed, whatever the counter claims.
        XCTAssertFalse(PTTCaptureEngine.shouldSuppressNote(liveHold: false, sentFrames: t + 500))
    }

    /// Send-invocation recorder for the live-pipeline tests. `@unchecked
    /// Sendable` matches the pipeline's own discipline: in these tests
    /// `process()` runs synchronously on the test thread, so the counter is
    /// single-thread confined exactly like the render-thread counter it checks.
    private final class SendRecorder: @unchecked Sendable {
        var calls = 0
    }

    /// One 2880-sample buffer through a LIVE pipeline (sealer + send) must
    /// seal-and-send exactly three 960-sample frames and count all three.
    func testLivePipelineCountsSealedSentFrames() throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: 48_000, channels: 1, interleaved: false)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptt-test-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = SendRecorder()
        let pipe = try PTTCapturePipeline(
            hwFormat: fmt, targetFormat: fmt, fileURL: url,
            onLevel: { _ in },
            sealer: PTTFrameSealer(key: SymmetricKey(size: .bits256)),
            send: { [recorder] _ in recorder.calls += 1 })

        let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 2880)!
        buffer.frameLength = 2880   // zeros: silence encodes fine
        pipe.process(buffer)

        XCTAssertEqual(recorder.calls, 3, "three exact 960-sample frames must ship")
        XCTAssertEqual(pipe.sentFrameCount, 3, "the counter must match the sends 1:1")
    }

    /// The same buffer through a NOTE-ONLY pipeline (nil sealer/send) must
    /// leave the counter untouched — the shipped path's behavior, unchanged.
    func testNoteOnlyPipelineNeverTouchesCounter() throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: 48_000, channels: 1, interleaved: false)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptt-test-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let pipe = try PTTCapturePipeline(hwFormat: fmt, targetFormat: fmt,
                                          fileURL: url, onLevel: { _ in })

        let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 2880)!
        buffer.frameLength = 2880
        pipe.process(buffer)

        XCTAssertEqual(pipe.sentFrameCount, 0,
            "a note-only hold must never increment the sent-frames counter")
    }

    // MARK: Hold-token ownership (red-first)
    // These pin that stop() must act ONLY for the hold that owns the engine.
    // Against the tokenless API they cannot all pass — stop() acts for every
    // caller — which is the point: the red run proves the API cannot express
    // the table before the token lands.

    @MainActor
    func testStopByOwnerStops() {
        let engine = PTTCaptureEngine()
        engine._testForceState(.recording, ownerToken: 7)
        _ = engine.stop(holdToken: 7)
        XCTAssertFalse(engine.isRecording, "the owning hold's stop must act")
    }

    @MainActor
    func testStaleStopNoOpsInStarting() {
        let engine = PTTCaptureEngine()
        engine._testForceState(.starting, ownerToken: 7)
        _ = engine.stop(holdToken: 6)   // a caller that does NOT own the hold
        XCTAssertFalse(engine._testAbortRequested,
            "a non-owner's stop must not abort someone else's in-flight start")
    }

    @MainActor
    func testStaleStopNoOpsInRecording() {
        let engine = PTTCaptureEngine()
        engine._testForceState(.recording, ownerToken: 7)
        _ = engine.stop(holdToken: 6)   // a caller that does NOT own the hold
        XCTAssertTrue(engine.isRecording,
            "a non-owner's stop must not kill someone else's live capture")
    }

    /// The cover-dismiss wedge in miniature: once the owner token is
    /// unreachable no stop(holdToken:) can ever match again — the engine keeps
    /// transmitting. cancelUnowned() is the ONE sanctioned bypass; this pin
    /// guards it against ever growing an ownership check of its own.
    @MainActor
    func testUnownedCancelKillsAnyHold() {
        let engine = PTTCaptureEngine()
        engine._testForceState(.recording, ownerToken: 7)
        _ = engine.stop(holdToken: 8)         // the wedge: newer tokens never match
        XCTAssertTrue(engine.isRecording, "precondition — the wedge is real")
        engine.cancelUnowned()                // the sanctioned teardown bypass
        XCTAssertFalse(engine.isRecording,
            "teardown must kill any hold regardless of owner — the surface is gone and no release can ever arrive")
    }
}
