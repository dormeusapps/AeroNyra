//
//  HomeView.swift
//  Screens
//
//  STILLWATER · Screen 01 — "The Water" (Home / root).
//
//  VISUAL-ONLY at this stage: pixel-faithful to the Stillwater mockup, built on
//  the Stillwater token foundation, with STATIC placeholder peers and NO app or
//  security wiring. The real screen binds MeshPresence (-> depth zones) and the
//  conversation store later; nothing here imports either.
//
//  "The root is not a list of conversations — it is a cross-section of the pool,
//   and DEPTH IS REACHABILITY. You are the surface: one luminous line. People
//   sort downward by how the mesh can actually reach them. Nothing is sorted by
//   recency; the water sorts by physics."
//

import SwiftUI

struct HomeView: View {

    // Static stand-ins so the screen renders on its own. Real data arrives from
    // MeshPresence + the store in the wiring pass.
    private struct Peer: Identifiable {
        let id = UUID()
        let name: String
        let sublabel: String
        let presence: Stillwater.Presence
        var note: String? = nil          // e.g. "a stone waits" (an unread ripple)
        var breath: Double = 4.0         // desynced per person
        var delay: Double = 0
    }

    private let near: [Peer] = [
        .init(name: "Theo",  sublabel: "in the room · direct", presence: .near, breath: 4.0, delay: 0),
        .init(name: "Priya", sublabel: "nearby · direct",      presence: .near, breath: 4.6, delay: 0.8),
    ]
    private let through: [Peer] = [
        .init(name: "Maya", sublabel: "through theo · 2 hops", presence: .throughOthers,
              note: "a stone waits", breath: 5.2, delay: 0.3),
    ]
    private let beyond: [Peer] = [
        .init(name: "Jun", sublabel: "over the relay · far", presence: .relay, breath: 6.5, delay: 1.1),
    ]
    private let dark: [Peer] = [
        .init(name: "Sana", sublabel: "last felt 3 h ago · your words wait", presence: .gone),
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Stillwater.Palette.water, Stillwater.Palette.abyss, Stillwater.Palette.abyssDeep],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // faint well of light at the very top
            RadialGradient(
                colors: [Stillwater.Palette.biolume.opacity(0.08), .clear],
                center: .init(x: 0.5, y: 0.0), startRadius: 2, endRadius: 260
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        wordmark
                            .padding(.bottom, 18)

                        (Text("the water is calm · ")
                            .font(Stillwater.Serif.italic(19))
                            .foregroundColor(Stillwater.Palette.mist)
                         + Text("two near")
                            .font(Stillwater.Serif.italic(19))
                            .foregroundColor(Stillwater.Palette.foam))

                        surface
                            .padding(.top, 22)
                            .padding(.bottom, 26)

                        zone("near", accentLine: 0.10, peers: near)
                        zone("through others", accentLine: 0.08, peers: through)
                        zone("beyond the water", accentLine: 0.06, peers: beyond)
                        zone("dark", accentLine: 0.04, peers: dark, dim: true)
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Pinned to the bottom — the peer list scrolls above it, this stays put.
                pairingEntry
                    .padding(.horizontal, 26)
                    .padding(.top, 14)
                    .padding(.bottom, 30)
            }
        }
        .background(Stillwater.Palette.abyss)
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Wordmark + your-key light
    // ─────────────────────────────────────────────────────────────
    private var wordmark: some View {
        HStack {
            Text("aeronyra")
                .stillwaterMono(10.5, trackingEm: 0.42)
            Spacer()
            HStack(spacing: 7) {
                BreathingDot(color: Stillwater.Palette.biolume, size: 5, glow: 8,
                             duration: 4.0, delay: 0)
                Text("key alive")
                    .stillwaterMono(8.5, trackingEm: 0.22, color: Stillwater.Palette.mistDim)
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: The surface = you (one luminous line)
    // ─────────────────────────────────────────────────────────────
    private var surface: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("you — the surface")
                .stillwaterMono(8, trackingEm: 0.3, color: Stillwater.Palette.mistDim)
            SurfaceLine()
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: A depth zone (label + hairline + its peers)
    // ─────────────────────────────────────────────────────────────
    private func zone(_ title: String, accentLine: Double, peers: [Peer], dim: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(title)
                    .stillwaterMono(8.5, trackingEm: 0.3,
                                    color: dim ? Stillwater.Palette.mistDimmest : Stillwater.Palette.mistDim)
                Rectangle()
                    .fill(Stillwater.Palette.biolume.opacity(accentLine))
                    .frame(height: 1)
            }
            .padding(.bottom, 10)

            ForEach(peers) { peer in
                peerRow(peer)
            }
        }
        .padding(.bottom, 14)
    }

    private func peerRow(_ peer: Peer) -> some View {
        HStack(spacing: 18) {
            PresenceLight(presence: peer.presence, breath: peer.breath, delay: peer.delay)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(peer.name)
                    .stillwaterSerif(21, color: peer.presence.nameColor)
                Text(peer.sublabel)
                    .stillwaterMono(9, trackingEm: 0.18, color: peer.presence.labelColor)
            }

            Spacer()

            if let note = peer.note {
                Text(note)
                    .stillwaterSerif(13, italic: true, color: Stillwater.Palette.biolume)
            }
        }
        .padding(.vertical, 10)
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Pairing entry ("let someone in")
    // ─────────────────────────────────────────────────────────────
    private var pairingEntry: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .strokeBorder(Stillwater.Palette.biolume.opacity(0.4), lineWidth: 1)
                    .frame(width: 34, height: 34)
                Text("+")
                    .stillwaterSerif(20, color: Stillwater.Palette.biolume)
            }
            Text("let someone in")
                .stillwaterMono(9.5, trackingEm: 0.26)
        }
        .frame(maxWidth: .infinity)
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - A peer's presence light (breathing / rippling by depth)
// ─────────────────────────────────────────────────────────────
private struct PresenceLight: View {
    let presence: Stillwater.Presence
    let breath: Double
    let delay: Double

    var body: some View {
        ZStack {
            switch presence {
            case .near:
                BreathingDot(color: presence.light, size: 13, glow: 20,
                             duration: breath, delay: delay)
            case .throughOthers:
                RippleRing(color: Stillwater.Palette.biolume, duration: 3.4)
                BreathingDot(color: presence.light, size: 11, glow: 14,
                             duration: breath, delay: delay)
            case .relay:
                BreathingDot(color: presence.light, size: 10, glow: 0,
                             duration: breath, delay: delay, dim: true)
            case .gone:
                Circle()
                    .strokeBorder(Stillwater.Palette.goneRing, lineWidth: 1)
                    .frame(width: 10, height: 10)
            }
        }
    }
}

// A soft light that breathes: opacity + scale on a sine-eased loop, desynced.
private struct BreathingDot: View {
    let color: Color
    let size: CGFloat
    let glow: CGFloat
    let duration: Double
    var delay: Double = 0
    var dim: Bool = false

    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: glow > 0 ? color.opacity(0.35) : .clear, radius: glow)
            .scaleEffect(on ? 1.0 : (dim ? 0.92 : 0.9))
            .opacity(on ? (dim ? 0.6 : 1.0) : (dim ? 0.3 : 0.55))
            .animation(Stillwater.Motion.breathe(duration).delay(delay), value: on)
            .onAppear { on = true }
    }
}

// An expanding ring — "reachable through others" / an unread ripple.
private struct RippleRing: View {
    let color: Color
    let duration: Double
    @State private var expanded = false

    var body: some View {
        Circle()
            .strokeBorder(color.opacity(0.55), lineWidth: 1)
            .frame(width: 30, height: 30)
            .scaleEffect(expanded ? 1.0 : 0.45)
            .opacity(expanded ? 0.0 : 0.8)
            .animation(.easeOut(duration: duration).repeatForever(autoreverses: false), value: expanded)
            .onAppear { expanded = true }
    }
}

// You — the surface: one luminous line that pulses slowly.
private struct SurfaceLine: View {
    @State private var alive = false

    var body: some View {
        LinearGradient(
            colors: [.clear,
                     Stillwater.Palette.biolume, Stillwater.Palette.biolume,
                     .clear],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(height: 1)
        .shadow(color: Stillwater.Palette.biolume.opacity(0.45), radius: 6)
        .opacity(alive ? 1.0 : 0.5)
        .animation(.easeInOut(duration: 5).repeatForever(autoreverses: true), value: alive)
        .onAppear { alive = true }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Preview
// ─────────────────────────────────────────────────────────────
#Preview("Stillwater — Home") {
    HomeView()
}
