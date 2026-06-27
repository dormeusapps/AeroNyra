//
//  RadarHero.swift
//  Screens
//
//  The signature visual of the Nearby screen — a compact radar where
//  rings encode HOP DISTANCE (not actual physical distance), an animated
//  sweep shows the BLE radio actively scanning, and the center is YOU.
//
//  Per DESIGN_TOKENS §12: angle on a ring is DECORATIVE; only the ring
//  itself carries real meaning. This is the hybrid C variation (locked
//  default) — compact, feeding a list below it, rather than immersive.
//
//  Drives entirely from props. Right now NearbyView passes `blips: []` —
//  the radar shows YOU + rings + sweep, nothing else, which is exactly
//  the truth while the BLE transport hasn't landed. When that arrives,
//  the same component renders real peers.
//
//  MOTION MODEL (why TimelineView, not @State + repeatForever):
//  The sweep and the breathing halo are PURE FUNCTIONS OF TIME, computed
//  fresh each frame from `timeline.date`. There is no animation state to
//  restart, so a parent re-render (the @Query ticking, a tab redraw)
//  can't snap the sweep back to zero — the old bug. The 360°→0° wrap is
//  seamless because the conic gradient is identical at 0 and 360. And
//  TimelineView naturally stops redrawing when the view is off-screen,
//  which is the §8 "drive from real state, not free-running timers" rule
//  honored by construction.
//

import SwiftUI

struct RadarHero: View {

    struct Blip: Identifiable, Equatable {
        let id: UUID
        let ring: Ring
        /// Angle on the ring, in radians. Decorative.
        let angle: Double
        /// Hue offset in degrees from the brand-teal base gradient.
        let hueDegrees: Double
    }

    enum Ring: Int, CaseIterable, Sendable {
        case direct  = 0   // innermost
        case oneHop  = 1
        case twoHops = 2   // outermost
    }

    /// Visible blips. Empty until the BLE layer surfaces reachable peers;
    /// nothing is invented here.
    let blips: [Blip]

    /// Whether the sweep animates. Driven by the radio's scan state once
    /// BLE lands.
    let isScanning: Bool

    // MARK: - Spec constants

    private static let canvasSize: CGFloat = 240
    private static let centerDotSize: CGFloat = 10
    private static let blipSize: CGFloat = 8

    /// Ring radii as a fraction of the canvas, innermost first.
    private static let ringRatios: [CGFloat] = [0.36, 0.68, 1.0]

    /// Seconds per full sweep rotation (§12 sweep = 4.5s).
    private static let sweepPeriod: Double = 4.5
    /// Seconds per breath of the "you" halo (§12 scan = 2.4s).
    private static let breathePeriod: Double = 2.4

    var body: some View {
        // One time source for the whole radar. Both the sweep and the
        // breath read `timeline.date`, so they stay phase-stable across
        // any parent re-render.
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                rings
                if isScanning { sweep(at: t) }
                youDot(at: t)
                ForEach(blips) { blip in
                    blipDot(blip)
                }
            }
        }
        .frame(width: Self.canvasSize, height: Self.canvasSize)
    }

    // MARK: - Rings

    private var rings: some View {
        ZStack {
            ForEach(Ring.allCases, id: \.rawValue) { ring in
                let ratio = Self.ringRatios[ring.rawValue]
                Circle()
                    .stroke(Color.hairline, lineWidth: 1)
                    .frame(
                        width:  Self.canvasSize * ratio,
                        height: Self.canvasSize * ratio
                    )
            }
        }
    }

    // MARK: - Sweep

    /// A conic gradient that stays transparent for most of its arc, then
    /// fades to a faint healthy wash near the trailing edge. Rotating it
    /// gives the classic radar-sweep silhouette without per-frame work.
    ///
    /// The rotation is `(t mod period) / period · 360`, applied directly —
    /// no `.animation` modifier. TimelineView re-renders each frame, so the
    /// motion is already smooth and, crucially, continuous across the wrap.
    private func sweep(at t: TimeInterval) -> some View {
        let phase = (t.truncatingRemainder(dividingBy: Self.sweepPeriod))
            / Self.sweepPeriod
        return Circle()
            .fill(
                AngularGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.statusHealthy.opacity(0.00), location: 0.0),
                        .init(color: Color.statusHealthy.opacity(0.00), location: 0.75),
                        .init(color: Color.statusHealthy.opacity(0.22), location: 1.0),
                    ]),
                    center: .center,
                    startAngle: .degrees(0),
                    endAngle:   .degrees(360)
                )
            )
            .frame(width: Self.canvasSize, height: Self.canvasSize)
            .rotationEffect(.degrees(phase * 360))
            .mask(Circle())
    }

    // MARK: - YOU

    /// The center. A solid green dot with a breathing halo — the "scan"
    /// animation from §12. This is the calm/alive surface of the radar:
    /// the radio at your own position, listening.
    ///
    /// The halo scale/opacity are a smooth sine of time, so the breath
    /// never restarts or jumps when the view recomputes.
    private func youDot(at t: TimeInterval) -> some View {
        // 0…1 triangle-free progress via a raised sine (one full breath
        // per `breathePeriod`).
        let progress = (sin(t * 2 * .pi / Self.breathePeriod) + 1) / 2
        let scale   = 1.0 + 0.5 * progress      // 1.0 → 1.5
        let opacity = 0.55 * (1 - progress)     // 0.55 → 0.0

        return ZStack {
            Circle()
                .stroke(Color.statusHealthy.opacity(0.35), lineWidth: 1)
                .frame(width: 26, height: 26)
                .scaleEffect(scale)
                .opacity(opacity)
            Circle()
                .fill(Color.statusHealthy)
                .frame(width: Self.centerDotSize, height: Self.centerDotSize)
        }
    }

    // MARK: - Blip

    @ViewBuilder
    private func blipDot(_ blip: Blip) -> some View {
        let radius = ringRadius(blip.ring)
        let x = cos(blip.angle) * radius
        let y = sin(blip.angle) * radius
        Circle()
            .fill(LinearGradient.avatarBrand)
            .hueRotation(.degrees(blip.hueDegrees))
            .frame(width: Self.blipSize, height: Self.blipSize)
            .offset(x: x, y: y)
    }

    private func ringRadius(_ ring: Ring) -> CGFloat {
        let ratio = Self.ringRatios[ring.rawValue]
        return Self.canvasSize * ratio / 2
    }
}
