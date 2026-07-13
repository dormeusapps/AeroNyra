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
}
