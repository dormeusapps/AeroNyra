//
//  StoryTrimScrubber.swift
//  Stories
//
//  STILLWATER · in-composer video trim (T1).
//
//  A filmstrip with two drag handles: the window between them is the segment
//  that posts. Pure control — thumbnails + duration + the legal cap in, the
//  selected in/out seconds out through a Binding. It never sees the inbox,
//  the conversation, or the transcoder: the composer reads
//  `VideoTranscoder.maxClipSeconds` and hands it down, and the cap here is
//  DISPLAY ONLY (readout + warning tone). No gate moves anywhere — the
//  transcoder still gates the trimmed file's true bytes downstream.
//

import SwiftUI
import UIKit

struct StoryTrimScrubber: View {

    let thumbnails: [UIImage]
    /// Full clip length, seconds.
    let duration: Double
    /// Display-only cap the readout warns against (the composer passes the
    /// transcoder's own constant — read, never restated).
    let legalCap: Double
    @Binding var selection: ClosedRange<Double>

    private static let stripHeight: CGFloat = 44
    private static let handleWidth: CGFloat = 14
    /// Smallest selectable window; a sub-second source clamps to itself.
    private var minGap: Double { min(1, duration) }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let width = geo.size.width
                let inX = x(of: selection.lowerBound, in: width)
                let outX = x(of: selection.upperBound, in: width)

                ZStack(alignment: .leading) {
                    filmstrip(width: width)

                    // Dim what's outside the window, on top of the strip.
                    Color.black.opacity(0.6)
                        .frame(width: max(0, inX))
                    Color.black.opacity(0.6)
                        .frame(width: max(0, width - outX))
                        .offset(x: outX)

                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Stillwater.Palette.biolume.opacity(0.85), lineWidth: 2)
                        .frame(width: max(0, outX - inX))
                        .offset(x: inX)

                    handle(atX: inX, in: width, isIn: true)
                    handle(atX: outX, in: width, isIn: false)
                }
            }
            .frame(height: Self.stripHeight)

            readout
        }
    }

    // MARK: Strip
    private func filmstrip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, thumb in
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFill()
                    .frame(width: thumbnails.isEmpty ? 0 : width / CGFloat(thumbnails.count),
                           height: Self.stripHeight)
                    .clipped()
            }
        }
        .frame(width: width, height: Self.stripHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Handles
    /// Absolute-position drag: the handle tracks the finger's x directly.
    /// The visible capsule rides inside a wider invisible hit target.
    private func handle(atX x: CGFloat, in width: CGFloat, isIn: Bool) -> some View {
        Capsule()
            .fill(Stillwater.Palette.biolume)
            .frame(width: Self.handleWidth, height: Self.stripHeight + 12)
            .frame(width: 44, height: Self.stripHeight + 12)   // hit target
            .contentShape(Rectangle())
            .position(x: x, y: Self.stripHeight / 2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        drag(toX: value.location.x, width: width, isIn: isIn)
                    }
            )
    }

    private func drag(toX x: CGFloat, width: CGFloat, isIn: Bool) {
        guard width > 0, duration > 0 else { return }
        let sec = (Double(x / width) * duration).clamped(to: 0...duration)
        if isIn {
            let newIn = min(sec, selection.upperBound - minGap)
            selection = max(0, newIn)...selection.upperBound
        } else {
            let newOut = max(sec, selection.lowerBound + minGap)
            selection = selection.lowerBound...min(duration, newOut)
        }
    }

    private func x(of seconds: Double, in width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(seconds / duration) * width
    }

    // MARK: Readout
    private var selectedSeconds: Double { selection.upperBound - selection.lowerBound }
    private var overCap: Bool { selectedSeconds > legalCap }

    private var readout: some View {
        Text(overCap
             ? "\(Int(selectedSeconds.rounded()))s — trim to \(Int(legalCap))s"
             : "\(Self.stamp(selection.lowerBound)) – \(Self.stamp(selection.upperBound)) · \(Int(selectedSeconds.rounded()))s of \(Int(legalCap))s")
            .stillwaterMono(8, trackingEm: 0.2,
                            color: overCap ? Stillwater.Palette.mistDim
                                           : Stillwater.Palette.mistDimmest)
    }

    private static func stamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
