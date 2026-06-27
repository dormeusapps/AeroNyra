//
//  PresenceChain.swift
//  DesignSystem
//
//  The little node-chain that says "here is the path to this person right
//  now" (DESIGN_TOKENS §5, §10). It is one of the load-bearing visual ideas
//  of the whole app: the mesh is INVISIBLE until something like this paints
//  it on the screen, and the wedge — making the mesh feel real — lives
//  partly in this component.
//
//  Used in three places: Nearby rows, the Conversation header, and Chats
//  list rows. One source of truth, no inline redraws.
//
//  Quiet Rule (DESIGN_TOKENS §0) reminder: "direct" is GREEN (the only state
//  that earns the full healthy hue at a glance — being in range with no relay
//  is a thing worth showing). 1-hop and 2-hop are AMBER on the relay nodes
//  to mark that the mesh is doing work. Out-of-range goes muted and dashed.
//

import SwiftUI

struct PresenceChain: View {

    /// What we're rendering. Each case maps to a node sequence; the view
    /// decides colors and dash style from the case alone.
    enum Reachability: Equatable, Sendable {
        case direct                 // self — peer
        case oneHop                 // self — relay — peer
        case twoHops                // self — relay — relay — peer
        case outOfRange             // self - - - peer  (dashed, muted)
    }

    let reachability: Reachability

    // MARK: - Spec constants (DESIGN_TOKENS §5)

    /// Node circle diameter. Matches the receipt-card spec for consistency
    /// across the two places nodes appear.
    private static let nodeSize: CGFloat = 7

    /// Connector stroke width. Spec: 2px.
    private static let connectorWidth: CGFloat = 2

    /// How long each connector segment is. Tuned to feel proportional to the
    /// 7pt node; bump in one place if a denser layout is ever needed.
    private static let connectorLength: CGFloat = 10

    /// Dash pattern for the out-of-range connector.
    private static let dashPattern: [CGFloat] = [2, 2]

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { index, node in
                circle(for: node)
                if index < nodes.count - 1 {
                    connector
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Node model

    /// Roles a node can play in the chain. The view maps each role to a
    /// color and ring treatment; callers never deal in raw colors here.
    private enum NodeRole {
        case selfOrPeer   // the green endpoints (you / the other person)
        case relay        // an amber midpoint (mesh is doing work)
        case dim          // muted endpoint, used when out of range
    }

    /// The node sequence for the current reachability.
    private var nodes: [NodeRole] {
        switch reachability {
        case .direct:     return [.selfOrPeer, .selfOrPeer]
        case .oneHop:     return [.selfOrPeer, .relay, .selfOrPeer]
        case .twoHops:    return [.selfOrPeer, .relay, .relay, .selfOrPeer]
        case .outOfRange: return [.dim, .dim]
        }
    }

    // MARK: - Drawing

    @ViewBuilder
    private func circle(for node: NodeRole) -> some View {
        Circle()
            .fill(color(for: node))
            .frame(width: Self.nodeSize, height: Self.nodeSize)
    }

    private var connector: some View {
        // Use a single horizontal line drawn as a Shape so we can apply a
        // dash to the out-of-range variant without swapping primitives.
        ConnectorLine()
            .stroke(
                connectorColor,
                style: StrokeStyle(
                    lineWidth: Self.connectorWidth,
                    lineCap: .round,
                    dash: reachability == .outOfRange ? Self.dashPattern : []
                )
            )
            .frame(width: Self.connectorLength, height: Self.connectorWidth)
    }

    private func color(for node: NodeRole) -> Color {
        switch node {
        case .selfOrPeer: return .statusHealthy
        case .relay:      return .statusRelay
        case .dim:        return .statusNeutral
        }
    }

    /// The connector picks up the muted tone for out-of-range, and a low-key
    /// neutral for in-range chains — the colored info is carried by the
    /// nodes, not the lines between them.
    private var connectorColor: Color {
        reachability == .outOfRange ? .statusNeutral : .textTertiary
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        switch reachability {
        case .direct:     return "Direct connection"
        case .oneHop:     return "Reachable, one hop"
        case .twoHops:    return "Reachable, two hops"
        case .outOfRange: return "Out of range"
        }
    }
}

// MARK: - ConnectorLine

/// A horizontal line shape. Drawing it as a Shape (rather than a Rectangle)
/// lets the StrokeStyle's dash pattern apply cleanly.
private struct ConnectorLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let y = rect.midY
        p.move(to: CGPoint(x: rect.minX, y: y))
        p.addLine(to: CGPoint(x: rect.maxX, y: y))
        return p
    }
}

// MARK: - Previews

#Preview("Reachability variants") {
    VStack(alignment: .leading, spacing: 18) {
        row(.direct,     label: "In range · direct connection")
        row(.oneHop,     label: "Reachable · 1 hop · via Theo")
        row(.twoHops,    label: "Reachable · 2 hops · via mesh")
        row(.outOfRange, label: "Out of range · searching…")
    }
    .padding(28)
    .background(Color.bgApp)
    .preferredColorScheme(.dark)
}

@ViewBuilder
private func row(_ reach: PresenceChain.Reachability, label: String) -> some View {
    HStack(spacing: 10) {
        PresenceChain(reachability: reach)
        Text(label)
            .font(Typography.headerPresence)
            .foregroundStyle(Color.textSecondary)
    }
}
