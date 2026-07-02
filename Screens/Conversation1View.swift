//
//  ConversationView.swift
//  Screens
//
//  STILLWATER · Screen 02 — "The Stream" (Conversation).
//
//  VISUAL-ONLY at this stage: pixel-faithful to the Stillwater mockup, built on
//  the Stillwater token foundation, with STATIC placeholder messages and NO app
//  or security wiring. The real screen binds MessageInbox + send/ack later;
//  nothing here imports either.
//
//  "No bubbles — a bubble is a container, and containers hide. Words sit directly
//   on the dark: their words in foam, yours tinted with the accent — light you
//   cast into the water. Send is a stone SKIPPED: a dotted arc rises from you,
//   touches each carrier, lands with a ripple. Read isn't a checkmark; it's a
//   ripple ring — 'she held it.' An undelivered message waits on the water,
//   pulsing at breath tempo, and hops the moment anyone from your circle passes."
//

import SwiftUI

struct StreamView: View {

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Stillwater.Palette.water, Stillwater.Palette.abyssDeep],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                stream
                composer
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Stillwater.Palette.abyss)
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Header — who, and how the mesh reaches them
    // ─────────────────────────────────────────────────────────────
    private var header: some View {
        HStack(spacing: 14) {
            Text("‹")
                .stillwaterSerif(15, color: Stillwater.Palette.mistDim)

            ZStack {
                RippleRing(color: Stillwater.Palette.biolume, size: 22, duration: 3.4)
                Circle()
                    .fill(Stillwater.Palette.biolume.opacity(0.6))
                    .frame(width: 10, height: 10)
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("Maya")
                    .stillwaterSerif(22, color: Stillwater.Palette.foam)
                Text("through theo · 2 hops · alive")
                    .stillwaterMono(8.5, trackingEm: 0.2)
            }
            Spacer()
        }
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Stillwater.Palette.biolume.opacity(0.09)).frame(height: 1)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: The stream — words on the dark, newest at the bottom
    // ─────────────────────────────────────────────────────────────
    private var stream: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {

                dayMark("tuesday · the rain")

                theirLine("the power's out on my whole street again", time: "13:58")

                myLine("I can see your light from here. literally",
                       meta: "13:59 · she held it", read: true)

                theirLine("ha. okay. come over when the rain stops", time: "14:02")

                // mine — delivered, with the skip-arc journey line
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Spacer(minLength: 40)
                        Text("leaving now")
                            .font(Stillwater.Serif.regular(17))
                            .foregroundColor(Stillwater.Palette.biolume.opacity(0.9))
                            .multilineTextAlignment(.trailing)
                        Circle().fill(Stillwater.Palette.foam)
                            .frame(width: 5, height: 5).padding(.top, 6)
                    }
                    SkipArc()
                        .frame(width: 252, height: 52)
                    Text("14:04 · surfaced for maya · via theo · 2 hops · 0.6 s")
                        .stillwaterMono(8.5, trackingEm: 0.18, color: Stillwater.Palette.mistDim)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)

                // mine — waiting on the water (undelivered, breathing)
                WaitingOnWater()
            }
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Composer — write into the water
    // ─────────────────────────────────────────────────────────────
    private var composer: some View {
        HStack(spacing: 14) {
            Text("write into the water…")
                .font(Stillwater.Serif.italic(16))
                .foregroundColor(Stillwater.Palette.mistDim)
            Spacer()
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [Stillwater.Palette.shallow, Stillwater.Palette.water],
                        center: .init(x: 0.36, y: 0.32), startRadius: 1, endRadius: 26))
                    .frame(width: 38, height: 38)
                    .overlay(Circle().strokeBorder(Stillwater.Palette.biolume.opacity(0.22)))
                    .shadow(color: Stillwater.Palette.biolume.opacity(0.14), radius: 7)
                Circle().fill(Stillwater.Palette.biolume)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.top, 16)
        .overlay(alignment: .top) {
            Rectangle().fill(Stillwater.Palette.biolume.opacity(0.09)).frame(height: 1)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Message primitives
    // ─────────────────────────────────────────────────────────────
    private func dayMark(_ text: String) -> some View {
        Text(text)
            .stillwaterMono(8.5, trackingEm: 0.28, color: Stillwater.Palette.mistDimmest)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // Her voice — foam, a small accent dot, left-aligned.
    private func theirLine(_ text: String, time: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(Stillwater.Palette.biolume)
                .frame(width: 5, height: 5).padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                Text(text)
                    .font(Stillwater.Serif.regular(17))
                    .foregroundColor(Stillwater.Palette.foam)
                Text(time)
                    .stillwaterMono(8.5, trackingEm: 0.18, color: Stillwater.Palette.mistDimmest)
            }
            Spacer(minLength: 40)
        }
    }

    // My voice — accent-tinted light, right-aligned. `read` shows a ripple ring.
    private func myLine(_ text: String, meta: String, read: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 5) {
                Text(text)
                    .font(Stillwater.Serif.regular(17))
                    .foregroundColor(Stillwater.Palette.biolume.opacity(0.9))
                    .multilineTextAlignment(.trailing)
                Text(meta)
                    .stillwaterMono(8.5, trackingEm: 0.18, color: Stillwater.Palette.mistDimmest)
            }
            ZStack {
                if read { RippleRing(color: Stillwater.Palette.biolume, size: 14, duration: 4.0) }
                Circle().fill(Stillwater.Palette.foam.opacity(0.85))
                    .frame(width: 5, height: 5)
            }
            .frame(width: 14, height: 14)
            .padding(.top, 1)
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - The skip: a stone crossing the water via its carriers
// ─────────────────────────────────────────────────────────────
//
// A dotted arc YOU → THEO → MAYA. A bright mote travels the arc on a loop
// (the message skipping), and the landing point ripples (delivered).
private struct SkipArc: View {
    @State private var landed = false
    private let period: Double = 2.8

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let you  = CGPoint(x: w * 0.055, y: h * 0.69)
            let theo = CGPoint(x: w * 0.5,   y: h * 0.69)
            let maya = CGPoint(x: w * 0.945, y: h * 0.69)
            let c1   = CGPoint(x: w * 0.275, y: h * 0.12)
            let c2   = CGPoint(x: w * 0.725, y: h * 0.23)

            ZStack {
                // the two dotted skip segments
                arcPath(you, c1, theo)
                    .stroke(Stillwater.Palette.biolume.opacity(0.35),
                            style: .init(lineWidth: 1, lineCap: .round, dash: [1, 5]))
                arcPath(theo, c2, maya)
                    .stroke(Stillwater.Palette.biolume.opacity(0.35),
                            style: .init(lineWidth: 1, lineCap: .round, dash: [1, 5]))

                // carrier nodes
                node(you,  color: Stillwater.Palette.foam,                r: 2.5)
                node(theo, color: Stillwater.Palette.biolume.opacity(0.55), r: 2.5)
                node(maya, color: Stillwater.Palette.biolume,             r: 3)

                // the landing ripple at Maya
                Circle()
                    .strokeBorder(Stillwater.Palette.biolume.opacity(0.45), lineWidth: 1)
                    .frame(width: landed ? 26 : 8, height: landed ? 26 : 8)
                    .opacity(landed ? 0 : 0.8)
                    .position(maya)
                    .animation(.easeOut(duration: 3).repeatForever(autoreverses: false), value: landed)

                // the travelling mote — recomputed per frame so it follows the
                // ARC (a plain .position animation would cut a straight line).
                TimelineView(.animation) { tl in
                    let t = CGFloat((tl.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: period)) / period)
                    Circle().fill(Stillwater.Palette.biolume)
                        .frame(width: 4.4, height: 4.4)
                        .shadow(color: Stillwater.Palette.biolume.opacity(0.6), radius: 4)
                        .position(mote(t, you, c1, theo, c2, maya))
                }

                // labels
                label("you",  at: you,  h: h)
                label("theo", at: theo, h: h)
                label("maya", at: maya, h: h)
            }
            .onAppear { landed = true }
        }
    }

    private func arcPath(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint) -> Path {
        var p = Path(); p.move(to: a); p.addQuadCurve(to: b, control: c); return p
    }

    private func node(_ p: CGPoint, color: Color, r: CGFloat) -> some View {
        Circle().fill(color).frame(width: r * 2, height: r * 2).position(p)
    }

    private func label(_ s: String, at p: CGPoint, h: CGFloat) -> some View {
        Text(s)
            .stillwaterMono(7.5, trackingEm: 0.15, color: Stillwater.Palette.mistDimmest)
            .position(x: p.x, y: h * 0.94)
    }

    // Position across the two-segment arc (first half YOU→THEO, second THEO→MAYA).
    private func mote(_ t: CGFloat, _ a: CGPoint, _ c1: CGPoint, _ b: CGPoint,
                      _ c2: CGPoint, _ d: CGPoint) -> CGPoint {
        if t < 0.5 { return quad(t / 0.5, a, c1, b) }
        return quad((t - 0.5) / 0.5, b, c2, d)
    }

    private func quad(_ t: CGFloat, _ a: CGPoint, _ c: CGPoint, _ b: CGPoint) -> CGPoint {
        let u = 1 - t
        let x = u*u*a.x + 2*u*t*c.x + t*t*b.x
        let y = u*u*a.y + 2*u*t*c.y + t*t*b.y
        return CGPoint(x: x, y: y)
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Waiting on the water (undelivered — breathing)
// ─────────────────────────────────────────────────────────────
private struct WaitingOnWater: View {
    @State private var breathing = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Spacer(minLength: 40)
                Text("bringing candles")
                    .font(Stillwater.Serif.regular(17))
                    .foregroundColor(Stillwater.Palette.biolume.opacity(0.36))
                    .multilineTextAlignment(.trailing)
                Circle()
                    .strokeBorder(Stillwater.Palette.mistDim, lineWidth: 1)
                    .frame(width: 5, height: 5).padding(.top, 6)
            }
            Text("on the water — will hop when someone passes")
                .stillwaterMono(8.5, trackingEm: 0.18, color: Stillwater.Palette.mistDimmest)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .opacity(breathing ? 0.62 : 0.38)
        .animation(.easeInOut(duration: 5).repeatForever(autoreverses: true), value: breathing)
        .onAppear { breathing = true }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Ripple ring (reused: presence + read receipt)
// ─────────────────────────────────────────────────────────────
private struct RippleRing: View {
    let color: Color
    var size: CGFloat = 22
    let duration: Double
    @State private var expanded = false

    var body: some View {
        Circle()
            .strokeBorder(color.opacity(0.5), lineWidth: 1)
            .frame(width: size, height: size)
            .scaleEffect(expanded ? 1.0 : 0.4)
            .opacity(expanded ? 0.0 : 0.8)
            .animation(.easeOut(duration: duration).repeatForever(autoreverses: false), value: expanded)
            .onAppear { expanded = true }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────────────────────
#Preview("Stillwater — Conversation") {
    StreamView()
}
