//
//  NearbyView.swift
//  Screens
//
//  The signature screen — "who can I reach right now, and how"
//  (DESIGN_TOKENS §12). Hybrid C variation (locked default): a compact
//  radar hero on top, list below.
//
//  Header: title + a small mono status line that reads as the radio's
//  duty cycle ("Mesh active · N reachable · scanning"). The pulsing
//  dot is the always-present ALIVE element from the design posture —
//  the radio breathing in the corner.
//

import SwiftUI
import SwiftData

struct NearbyView: View {

    /// All known peers, most-recently-seen first.
    @Query(sort: \Peer.lastSeen, order: .reverse)
    private var allPeers: [Peer]

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            ScrollView {
                VStack(spacing: 0) {
                    radarBlock
                    sections
                    if allPeers.isEmpty {
                        emptyState
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .background(Color.bgApp.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nearby")
                .font(.custom("Geist-Bold", size: 26))
                .foregroundStyle(Color.textPrimary)
            statusLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            PingDot()
            Text(statusText)
                .font(Typography.deliveryChip)
                .foregroundStyle(Color.textSecondary)
        }
    }

    /// Honest status: until BLE wires real reachability, this just says
    /// the radio is scanning. Becomes more specific the moment we have
    /// a real reachability monitor.
    private var statusText: String {
        let reachable = reachablePeers.count
        if reachable == 0 {
            return "Mesh active · scanning…"
        }
        return "Mesh active · \(reachable) reachable · scanning"
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(height: 1)
    }

    // MARK: - Radar

    private var radarBlock: some View {
        VStack {
            RadarHero(blips: [], isScanning: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Sections

    @ViewBuilder
    private var sections: some View {
        section(title: "Reachable now",
                peers: reachablePeers,
                isRecent: false)
        section(title: "Recently seen",
                peers: recentPeers,
                isRecent: true)
    }

    /// Currently reachable peers. Empty until BLE drives it.
    private var reachablePeers: [Peer] { [] }

    /// Peers we know about but aren't currently in range. Until BLE wires
    /// real-time reachability, every known peer falls in this bucket.
    private var recentPeers: [Peer] { allPeers }

    @ViewBuilder
    private func section(title: String,
                         peers: [Peer],
                         isRecent: Bool) -> some View {
        if !peers.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .beaconEyebrow()
                    .foregroundStyle(Color.textTertiary)
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 10)
                ForEach(peers) { peer in
                    NearbyRow(
                        peer: peer,
                        reachability: .outOfRange,
                        signalStrength: nil,
                        signalColor: .statusNeutral,
                        isRecentlySeen: isRecent,
                        relayName: nil
                    )
                    Rectangle()
                        .fill(Color.hairline)
                        .frame(height: 1)
                        .padding(.leading, 64)
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack {
            Spacer().frame(height: 32)
            Text("no peers detected yet")
                .font(Typography.deliveryChip)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - PingDot

/// The "ping" animation from DESIGN_TOKENS §12 — a small dot that pulses
/// to indicate the radio is actively cycling its scan. Always present in
/// the Nearby header; the radio's heartbeat made visible.
private struct PingDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Color.statusHealthy)
            .frame(width: 6, height: 6)
            .opacity(on ? 1.0 : 0.30)
            .animation(
                .easeOut(duration: 1.8).repeatForever(autoreverses: true),
                value: on
            )
            .onAppear { on = true }
    }
}
