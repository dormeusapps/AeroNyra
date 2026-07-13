//
//  OpusVoiceCodecTests.swift
//  BeaconTests
//
//  Round-trip fidelity + structural KAT for the Opus codec seam (BLE-live step
//  1). Opus encoder output isn't bit-reproducible, so "known-answer" here is
//  deterministic INPUT → asserted round-trip fidelity and geometry invariants
//  (byte-exact KAT vectors belong to step 2's crypto). Tests 5 (PLC) and 6
//  (FEC) are REAL exercises of the packet-loss paths the BLE receiver depends
//  on — they assert recovered audio, not just non-crashing stubs.
//

import XCTest
@testable import Beacon

final class OpusVoiceCodecTests: XCTestCase {

    // MARK: Signal helpers

    /// Deterministic continuous 440 Hz tone (voiced-like), `frames` × 960 samples.
    private func sine(frames: Int, freq: Double = 440, amp: Double = 8000) -> [Int16] {
        let n = frames * OpusVoiceCodec.samplesPerFrame
        let sr = Double(OpusVoiceCodec.sampleRate)
        var out = [Int16](); out.reserveCapacity(n)
        for i in 0..<n {
            let v = amp * sin(2 * Double.pi * freq * Double(i) / sr)
            out.append(Int16(max(-32768, min(32767, v.rounded()))))
        }
        return out
    }

    private func frame(_ signal: [Int16], _ f: Int) -> [Int16] {
        let s = f * OpusVoiceCodec.samplesPerFrame
        return Array(signal[s ..< s + OpusVoiceCodec.samplesPerFrame])
    }

    private func rms(_ x: [Int16]) -> Double {
        guard !x.isEmpty else { return 0 }
        let s = x.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (s / Double(x.count)).squareRoot()
    }

    /// Best-lag normalized cross-correlation — tolerant of Opus's algorithmic
    /// delay (the decoded signal lags the input by a fixed offset).
    private func bestLagNCC(_ a: [Int16], _ b: [Int16], maxLag: Int = 480) -> Double {
        let n = min(a.count, b.count)
        let fa = a.map(Double.init), fb = b.map(Double.init)
        var best = -1.0
        for lag in 0...maxLag {
            var num = 0.0, da = 0.0, db = 0.0, i = 0
            while i + lag < n {
                let x = fa[i], y = fb[i + lag]
                num += x * y; da += x * x; db += y * y
                i += 1
            }
            if da > 0, db > 0 { best = max(best, num / (da.squareRoot() * db.squareRoot())) }
        }
        return best
    }

    private func encodeStream(_ signal: [Int16], _ enc: OpusVoiceCodec.Encoder) throws -> [Data] {
        let frames = signal.count / OpusVoiceCodec.samplesPerFrame
        return try (0..<frames).map { try enc.encode(frame(signal, $0)) }
    }

    // MARK: 1 — geometry pins (wire-breaking if changed)

    func testFrameGeometryPinned() {
        XCTAssertEqual(OpusVoiceCodec.sampleRate, 48_000)
        XCTAssertEqual(OpusVoiceCodec.channels, 1)
        XCTAssertEqual(OpusVoiceCodec.frameMs, 20)
        XCTAssertEqual(OpusVoiceCodec.samplesPerFrame, 960)
        // 960 samples must equal 20 ms at 48 kHz — the invariant the wire rides on.
        XCTAssertEqual(OpusVoiceCodec.samplesPerFrame,
                       Int(OpusVoiceCodec.sampleRate) * OpusVoiceCodec.frameMs / 1000)
    }

    // MARK: 2 — encoder honors the configured bitrate

    func testEncoderReportsConfiguredBitrate() throws {
        let enc = try OpusVoiceCodec.Encoder()
        XCTAssertEqual(enc.currentBitrate(), OpusVoiceCodec.bitrate, accuracy: 2_000)
    }

    // MARK: 3 — sine round-trip fidelity (steady state, delay-tolerant)

    func testSineRoundTripFidelity() throws {
        let enc = try OpusVoiceCodec.Encoder()
        let dec = try OpusVoiceCodec.Decoder()
        let signal = sine(frames: 8)
        var decoded = [Int16]()
        for pkt in try encodeStream(signal, enc) { decoded += try dec.decode(pkt) }

        XCTAssertEqual(decoded.count, signal.count)
        // Compare steady-state middle (skip 2 frames of codec warm-up).
        let lo = 2 * OpusVoiceCodec.samplesPerFrame, hi = 6 * OpusVoiceCodec.samplesPerFrame
        let ncc = bestLagNCC(Array(signal[lo..<hi]), Array(decoded[lo..<hi]))
        XCTAssertGreaterThan(ncc, 0.9, "round-trip tone should reconstruct faithfully (ncc=\(ncc))")
    }

    // MARK: 4 — silence stays silent

    func testSilenceRoundTrip() throws {
        let enc = try OpusVoiceCodec.Encoder()
        let dec = try OpusVoiceCodec.Decoder()
        let silence = [Int16](repeating: 0, count: OpusVoiceCodec.samplesPerFrame)
        let out = try dec.decode(try enc.encode(silence))
        XCTAssertEqual(out.count, OpusVoiceCodec.samplesPerFrame)
        XCTAssertLessThan(rms(out), 100, "encoded silence must decode to near-silence")
    }

    // MARK: 5 — PLC actually conceals a lost frame (REAL, not a stub)

    func testPLCProducesConcealedAudio() throws {
        let enc = try OpusVoiceCodec.Encoder()
        let dec = try OpusVoiceCodec.Decoder()
        let signal = sine(frames: 3)
        let packets = try encodeStream(signal, enc)

        // Decode two real frames so the decoder has pitch history…
        _ = try dec.decode(packets[0])
        _ = try dec.decode(packets[1])
        // …then a frame is LOST → PLC (nil packet) must extrapolate real audio.
        let concealed = try dec.decode(nil)
        XCTAssertEqual(concealed.count, OpusVoiceCodec.samplesPerFrame)
        XCTAssertGreaterThan(rms(concealed), 300,
                             "PLC must synthesize a voiced frame, not silence (rms=\(rms(concealed)))")
    }

    // MARK: 6 — inband FEC actually recovers a lost frame (REAL, not a stub)

    func testFECRecoversLostFrame() throws {
        let enc = try OpusVoiceCodec.Encoder()   // FEC on, packet-loss-perc 10 (see seam)
        let dec = try OpusVoiceCodec.Decoder()
        let signal = sine(frames: 3)
        let packets = try encodeStream(signal, enc)

        // frame0 decoded normally (history); frame1 is "lost"; recover it from
        // frame2's packet via inband FEC (fec: true pulls the embedded copy).
        _ = try dec.decode(packets[0])
        let recovered = try dec.decode(packets[2], fec: true)

        XCTAssertEqual(recovered.count, OpusVoiceCodec.samplesPerFrame)
        XCTAssertGreaterThan(rms(recovered), 300,
                             "FEC recovery must yield audio, not silence (rms=\(rms(recovered)))")
        // And it should resemble the lost frame, not arbitrary noise.
        let ncc = bestLagNCC(frame(signal, 1), recovered)
        XCTAssertGreaterThan(ncc, 0.5, "FEC frame should resemble the lost frame (ncc=\(ncc))")
    }

    // MARK: 7 — a multi-frame stream stays frame-consistent

    func testStreamFramesConsistent() throws {
        let enc = try OpusVoiceCodec.Encoder()
        let dec = try OpusVoiceCodec.Decoder()
        let packets = try encodeStream(sine(frames: 25), enc)   // ~500 ms
        XCTAssertEqual(packets.count, 25)
        for pkt in packets {
            XCTAssertFalse(pkt.isEmpty)
            XCTAssertEqual(try dec.decode(pkt).count, OpusVoiceCodec.samplesPerFrame)
        }
    }
}
