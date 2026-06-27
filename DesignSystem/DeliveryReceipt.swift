//
//  DeliveryReceipt.swift
//  DesignSystem
//
//  The tap-to-expand route card under a message (DESIGN_TOKENS §6).
//
//  Shows the path a message actually took — the chain of nodes it passed
//  through, with a status line carrying hops, time, and signal. This is the
//  "lean-in" detail that lives ON TOP of the Quiet Rule: once the user taps
//  to see the route, full color is earned (green endpoints, amber relays).
//
//  Composes SignalBars in the status line. The connector layout deliberately
//  uses a stretchy line between intrinsically-sized node columns so the
//  card adapts gracefully to longer peer names without redoing math.
//

import SwiftUI

struct DeliveryReceipt: View {

    /// What role a node plays in the route. Drives both color and label tone.
    enum NodeKind: Sendable, Equatable {
        case origin       // the local device
        case relay        // a midpoint that forwarded the message
        case peer         // the recipient
        case pending      // a planned stop that hasn't been reached yet
    }

    struct Node: Identifiable, Sendable, Equatable {
        let id: UUID
        let name: String
        let kind: NodeKind

        init(id: UUID = UUID(), name: String, kind: NodeKind) {
            self.id = id
            self.name = name
            self.kind = kind
        }
    }

    // MARK: - Props (DESIGN_TOKENS §6)

    let nodes: [Node]
    let statusText: String
    let hopsLabel: String
    let timeText: String
    let signalText: String
    let signalColor: Color
    let signalBars: SignalBars.Strength

    // MARK: - Spec constants

    private static let cardWidth: CGFloat = 248
    private static let cardRadius: CGFloat = 14
    private static let cardPaddingV: CGFloat = 13
    private static let cardPaddingH: CGFloat = 15

    /// Solid circle size.
    private static let nodeSize: CGFloat = 11
    /// How much wider the faint ring around each node is (each side).
    private static let nodeRingExtra: CGFloat = 8
    /// Ring opacity per spec ("ring 16% alpha").
    private static let nodeRingOpacity: Double = 0.16

    private static let connectorWidth: CGFloat = 1
    private static let nodeLabelTopPad: CGFloat = 6

    /// Pending-node fill. Single dark value per spec — kept inline here
    /// (rather than promoted to Colors.swift) since this is its sole user.
    private static let pendingFill = Color(
        red: 0x3A / 255.0,
        green: 0x42 / 255.0,
        blue: 0x3F / 255.0
    )

    var body: some View {
        VStack(spacing: 12) {
            nodePathRow
            Rectangle()
                .fill(Color.hairline)
                .frame(height: 1)
            statusLine
        }
        .padding(.vertical, Self.cardPaddingV)
        .padding(.horizontal, Self.cardPaddingH)
        .frame(width: Self.cardWidth)
        .background(
            RoundedRectangle(cornerRadius: Self.cardRadius)
                .fill(Color.bgSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: Self.cardRadius)
                        .stroke(Color.hairline, lineWidth: 1)
                )
        )
    }

    // MARK: - Node path row

    private var nodePathRow: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { idx, node in
                nodeColumn(node)
                if idx < nodes.count - 1 {
                    connector
                }
            }
        }
    }

    @ViewBuilder
    private func nodeColumn(_ node: Node) -> some View {
        VStack(spacing: Self.nodeLabelTopPad) {
            ZStack {
                Circle()
                    .fill(fillColor(for: node.kind).opacity(Self.nodeRingOpacity))
                    .frame(
                        width:  Self.nodeSize + Self.nodeRingExtra,
                        height: Self.nodeSize + Self.nodeRingExtra
                    )
                Circle()
                    .fill(fillColor(for: node.kind))
                    .frame(width: Self.nodeSize, height: Self.nodeSize)
            }
            Text(node.name)
                .font(Typography.receiptNodeLabel)
                .foregroundStyle(labelColor(for: node.kind))
        }
    }

    /// A stretchy 1-pt line between two node columns, vertically centered on
    /// the (ringed) node. The +nodeRingExtra/2 keeps it aligned even when the
    /// ring expands the node's visual height.
    private var connector: some View {
        Rectangle()
            .fill(Color.textTertiary)
            .frame(height: Self.connectorWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 2)
            .padding(.top,
                     (Self.nodeSize + Self.nodeRingExtra) / 2
                     - Self.connectorWidth / 2)
    }

    private func fillColor(for kind: NodeKind) -> Color {
        switch kind {
        case .origin, .peer: return .statusHealthy
        case .relay:         return .statusRelay
        case .pending:       return Self.pendingFill
        }
    }

    private func labelColor(for kind: NodeKind) -> Color {
        switch kind {
        case .origin, .peer: return .statusHealthy
        case .relay:         return .statusRelay
        case .pending:       return .textTertiary
        }
    }

    // MARK: - Status line

    /// Mono telemetry strip — the bottom row of the card. Reads as
    /// instrumentation rather than copy, by design.
    private var statusLine: some View {
        HStack(spacing: 6) {
            mono(statusText)
            separator
            mono(hopsLabel)
            separator
            mono(timeText)
            Spacer(minLength: 4)
            SignalBars(strength: signalBars, color: signalColor)
            mono(signalText)
        }
    }

    private func mono(_ text: String) -> some View {
        Text(text)
            .font(Typography.receiptStatus)
            .foregroundStyle(Color.textSecondary)
    }

    private var separator: some View {
        Text("·")
            .font(Typography.receiptStatus)
            .foregroundStyle(Color.textTertiary)
    }
}
