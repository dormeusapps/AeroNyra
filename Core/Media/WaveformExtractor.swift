//
//  WaveformExtractor.swift
//  Core/Media
//
//  Turns recorded audio into a static waveform — N normalized amplitude
//  bars derived from the .m4a's actual PCM samples.
//
//  This is the honest, transport-symmetric source for the playback waveform:
//  the live recording meter is real-time-only and never saved, so the bubble
//  can't reuse it. Instead BOTH sender and receiver compute the same bars from
//  the same bytes — no invented data, no extra wire field. Decode → bucket the
//  samples by RMS → peak-normalize so quiet recordings still read.
//
//  Pure logic (Data in, [CGFloat] out); no UI, no main-actor coupling.
//

import Foundation
import AVFoundation

enum WaveformExtractor {

    /// Compute `count` normalized amplitude bars (0...1) from .m4a `data`.
    /// Returns a faint flat line on any decode failure so the bubble still
    /// renders rather than collapsing.
    static func bars(from data: Data, count: Int = 30) -> [CGFloat] {
        guard count > 0 else { return [] }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-\(UUID().uuidString).m4a")
        do {
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: frameCount)
            else { return flat(count) }

            try file.read(into: buffer)

            guard let channel = buffer.floatChannelData?[0] else {
                return flat(count)
            }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return flat(count) }

            // RMS per bucket across channel 0 (recordings are mono).
            let samplesPerBar = max(1, frames / count)
            var bars: [CGFloat] = []
            bars.reserveCapacity(count)

            for i in 0..<count {
                let start = i * samplesPerBar
                let end = min(start + samplesPerBar, frames)
                guard start < end else { bars.append(0); continue }

                var sumSquares: Float = 0
                for j in start..<end {
                    let s = channel[j]
                    sumSquares += s * s
                }
                let rms = sqrt(sumSquares / Float(end - start))
                bars.append(CGFloat(rms))
            }

            return normalize(bars)
        } catch {
            print("[WaveformExtractor] failed: \(error)")
            return flat(count)
        }
    }

    /// Scale so the loudest bucket reaches 1.0; leaves an all-silent clip flat.
    private static func normalize(_ bars: [CGFloat]) -> [CGFloat] {
        guard let peak = bars.max(), peak > 0 else { return bars }
        return bars.map { min(1, $0 / peak) }
    }

    /// Fallback when there's nothing decodable: a faint, even line.
    private static func flat(_ count: Int) -> [CGFloat] {
        Array(repeating: 0.12, count: count)
    }
}
