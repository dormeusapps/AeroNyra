//
//  LiveTransit.swift
//  DesignSystem
//
//  The "Finding a path" hero widget (DESIGN_TOKENS §7).
//
//  When a message is mid-flight through the mesh, this card appears in the
//  conversation and shows the route as it happens: a pulsing green
//  origin, an active leg with a traveling dot, a relay that pulses when
//  reached, and the still-pending peer drawn hollow until delivery lands.
//  A live elapsed timer ticks in the header.
//
//  Spec build-note (§8): "in SwiftUI these are NOT infinite timers. They run
//  only while a message is in the matching state, and stop the instant the
//  real delivery pipeline advances the state." This is satisfied
//  structurally — the animations live INSIDE this view, so they exist only
//  while the parent shows this view (i.e. while the message is .findingPath).
//

import SwiftUI

struct LiveTransit: View {

    /// Per-node visual state for the path row.
    enum NodeState: Sendable, Equatable {
        case origin           // the local device — solid green
        case reachedRelay     // a relay we've handed off to — amber, pulses
        case unreached        // a planned stop not yet reached — hollow
    }

    struct Node: Identifiable, Sendable, Equatable {
        let id: UUID
        let name: String
        let state: NodeState

        init(id: UUID = UUID(), name: String, state: NodeState) {
            self.id = id
            self.name = name
            self.state = state
        }
    }

    // MARK: - Props

    let nodes: [Node]
    /// Which leg has the traveling dot. 0 = the leg between nodes[0] and
    /// nodes[1], etc. Pass `nil` to draw all legs as static lines.
    let activeLegIndex: Int?
    /// Name shown in the footer's "Relaying through {name}…" line.
    let relayingThroughLabel: String
    /// When the in-flight state began, for the elapsed-time readout.
    let startedAt: Date

    // MARK: - Spec constants (§7)

    private static let cardRadius: CGFloat = 16
    private static let cardPaddingV: CGFloat = 13
    private static let cardPaddingH: CGFloat = 15
    private static let borderOpacity: Double = 0.22       // §7: "1px border at status/healthy 22% alpha"

    private static let nodeSize: CGFloat = 14
    private static let nodeLabelTopPad: CGFloat = 6

    /// §7: "unreached node is hollow #3A423F w/ #4A534F border."
    private static let unreachedFill = Color(
        red:   0x3A / 255.0,
        green: 0x42 / 255.0,
        blue:  0x3F / 255.0
    )
    private static let unreachedBorder = Color(
        red:   0x4A / 255.0,
        green: 0x53 / 255.0,
        blue:  0x4F / 255.0
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            pathRow
            footer
        }
        .padding(.vertical,   Self.cardPaddingV)
        .padding(.horizontal, Self.cardPaddingH)
        .background(
            RoundedRectangle(cornerRadius: Self.cardRadius)
                .fill(Color.bgElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: Self.cardRadius)
                        .stroke(Color.statusHealthy.opacity(Self.borderOpacity),
                                lineWidth: 1)
                )
        )
    }

    // MARK: - Header

    /// Pulsing green dot + label + live elapsed timer, right-aligned mono.
    private var header: some View {
        HStack(spacing: 8) {
            PulsingDot(color: .statusHealthy)
            Text("Finding a path")
                .font(Typography.receiptStatus)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            // TimelineView re-renders every second; cheaper than a Timer and
            // pauses automatically when the view isn't visible.
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(Self.elapsed(from: startedAt, to: context.date))
                    .font(Typography.receiptStatus)
                    .foregroundStyle(Color.textSecondary)
                    .monospacedDigit()
            }
        }
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Path row

    private var pathRow: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { idx, node in
                nodeColumn(node)
                if idx < nodes.count - 1 {
                    leg(isActive: activeLegIndex == idx)
                }
            }
        }
    }

    @ViewBuilder
    private func nodeColumn(_ node: Node) -> some View {
        VStack(spacing: Self.nodeLabelTopPad) {
            nodeCircle(node)
            Text(node.name)
                .font(Typography.receiptNodeLabel)
                .foregroundStyle(labelColor(for: node.state))
        }
    }

    @ViewBuilder
    private func nodeCircle(_ node: Node) -> some View {
        switch node.state {
        case .origin:
            Circle()
                .fill(Color.statusHealthy)
                .frame(width: Self.nodeSize, height: Self.nodeSize)

        case .reachedRelay:
            PulsingRelayNode(size: Self.nodeSize)

        case .unreached:
            Circle()
                .fill(Self.unreachedFill)
                .overlay(
                    Circle().stroke(Self.unreachedBorder, lineWidth: 1)
                )
                .frame(width: Self.nodeSize, height: Self.nodeSize)
        }
    }

    private func labelColor(for state: NodeState) -> Color {
        switch state {
        case .origin:       return .statusHealthy
        case .reachedRelay: return .statusRelay
        case .unreached:    return .textTertiary
        }
    }

    /// One segment between two nodes. The active leg renders the
    /// green→amber gradient and the traveling-dot animation; other legs are
    /// a static muted line.
    @ViewBuilder
    private func leg(isActive: Bool) -> some View {
        Group {
            if isActive {
                ActiveLeg()
            } else {
                Rectangle()
                    .fill(Color.textTertiary)
                    .frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 2)
        .padding(.top, Self.nodeSize / 2 - 0.5)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.statusRelay)
            Text("Relaying through \(relayingThroughLabel)…")
                .font(Typography.receiptStatus)
                .foregroundStyle(Color.statusRelay)
        }
    }
}

// MARK: - Animations
//
// Each animated piece is its own private view so the animation state stays
// scoped — when the parent removes LiveTransit from the view tree, the
// @State is torn down with it and the animation stops.

/// "find" animation (§8): opacity .28↔1, scale .82↔1, ease-in-out, 1.3s.
private struct PulsingDot: View {
    let color: Color
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(on ? 1.0 : 0.28)
            .scaleEffect(on ? 1.0 : 0.82)
            .animation(
                .easeInOut(duration: 1.3).repeatForever(autoreverses: true),
                value: on
            )
            .onAppear { on = true }
    }
}

/// "node" animation (§8): an amber ring that expands outward from the relay
/// and fades, looping every 1.5s. The solid relay dot sits in the center.
private struct PulsingRelayNode: View {
    let size: CGFloat
    @State private var on = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.statusRelay, lineWidth: 1.5)
                .scaleEffect(on ? 1.8 : 1.0)
                .opacity(on ? 0.0 : 0.7)
                .animation(
                    .easeOut(duration: 1.5).repeatForever(autoreverses: false),
                    value: on
                )
            Circle()
                .fill(Color.statusRelay)
        }
        .frame(width: size, height: size)
        .onAppear { on = true }
    }
}

/// "travel" animation (§8): an active leg drawn as a green→amber gradient
/// with a small green dot that travels left-to-right, fading at the ends so
/// it doesn't appear to spawn or vanish at the nodes.
private struct ActiveLeg: View {
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: [.statusHealthy, .statusRelay],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 2)
                .frame(maxHeight: .infinity, alignment: .center)

                Circle()
                    .fill(Color.statusHealthy)
                    .frame(width: 4, height: 4)
                    .offset(x: progress * geo.size.width - 2)
                    .opacity(edgeFade(progress))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 4)
        .animation(
            .linear(duration: 1.5).repeatForever(autoreverses: false),
            value: progress
        )
        .onAppear { progress = 1.0 }
    }

    /// Fade the traveling dot in and out at the ends of the leg.
    private func edgeFade(_ p: CGFloat) -> Double {
        if p < 0.08 { return Double(p / 0.08) }
        if p > 0.92 { return Double((1 - p) / 0.08) }
        return 1.0
    }
}
