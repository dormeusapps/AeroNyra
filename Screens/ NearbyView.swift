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
//  PRESENCE — TWO RESOLUTIONS:
//   • The radar blips and the "N reachable" status count are driven by the
//     RADIO-level set (MeshPresence.reachableIDs): ephemeral linked-device ids,
//     including devices we sense but haven't yet identified. That's honest for a
//     radar — it shows radios, not names.
//   • The "Reachable now" / "Recently seen" peer SECTIONS are driven by the
//     IDENTITY-resolved set (MeshPresence.isReachable, Phase 7a): a known peer
//     is "Reachable now" iff its crypto identity is in the live presence set.
//     This de-dups the per-role double-count — a peer linked over both GATT
//     directions still surfaces as ONE named row.
//
//  A device linked but not yet identity-exchanged shows as a radar blip and in
//  the count, but does NOT appear as a named row until identity exists —
//  fabricating a Peer from a BLE id would be inventing identity.
//

import SwiftUI
import SwiftData

struct NearbyView: View {

    /// All known peers, most-recently-seen first.
    @Query(sort: \Peer.lastSeen, order: .reverse)
    private var allPeers: [Peer]

    /// Live radio presence (linked device ids + scan state) from the transport.
    @Environment(MeshPresence.self) private var presence

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            ScrollView {
                VStack(spacing: 0) {
                    radarBlock
                    sections
                    if allPeers.isEmpty && presence.reachableIDs.isEmpty {
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

    /// Honest status driven by the live linked-device count. These are
    /// reachable RADIOS, not yet identified peers.
    private var statusText: String {
        let reachable = presence.reachableCount
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
            RadarHero(blips: blips, isScanning: presence.isScanning)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    /// One blip per currently-linked device, placed on the innermost (direct)
    /// ring. Angle and hue are DECORATIVE (DESIGN_TOKENS §12) but derived
    /// deterministically from the device's real BLE id, so a given device sits
    /// in a stable spot rather than jumping around frame to frame.
    private var blips: [RadarHero.Blip] {
        presence.reachableIDs.map { id in
            let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
            let angle = Double(Int(bytes[0]) << 8 | Int(bytes[1])) / 65535.0 * 2 * .pi
            let hue = Double(bytes[2]) / 255.0 * 360
            return RadarHero.Blip(id: id, ring: .direct, angle: angle, hueDegrees: hue)
        }
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

    /// Currently reachable, IDENTIFIED peers (Phase 7a): known peers whose
    /// crypto identity is in the live identity-resolved presence set. Each peer
    /// appears at most once — the per-role double-count is collapsed upstream.
    private var reachablePeers: [Peer] {
        allPeers.filter { presence.isReachable($0.publicKeyData) }
    }

    /// Known peers not currently reachable over BLE — the complement of
    /// `reachablePeers` over everyone we've met.
    private var recentPeers: [Peer] {
        allPeers.filter { !presence.isReachable($0.publicKeyData) }
    }

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
                        reachability: isRecent ? .outOfRange : .direct,
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
