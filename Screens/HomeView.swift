//
//  HomeView.swift
//  Screens
//
//  STILLWATER · Screen 01 — "The Water" (Home / root).
//
//  WIRED to real data. The static placeholder peers are gone; the roster is now
//  the SwiftData `Peer` store (@Query) and reachability is the live `MeshPresence`
//  injected by ContentView. Depth = reachability, exactly as the design says.
//
//  "The root is not a list of conversations — it is a cross-section of the pool,
//   and DEPTH IS REACHABILITY. You are the surface: one luminous line. People
//   sort downward by how the mesh can actually reach them. Nothing is sorted by
//   recency; the water sorts by physics."
//
//  GROUND-TRUTH NOTE — the tier surface MeshPresence actually exposes.
//  MeshPresence is BINARY per identity: `reachablePeerKeys` (reachable over BLE
//  right now) + `isReachable(key)`. It carries NO hop-depth and NO Nostr-far
//  signal. So only two of Stillwater's four tiers have a real source today:
//     • .near — key is in `reachablePeerKeys` (direct BLE, right now)
//     • .gone — a known contact not currently reachable
//  `.throughOthers` (multi-hop) and `.relay` (over Nostr, far) are left UNSOURCED
//  rather than fabricated — their zones stay empty (and hidden) until the mesh
//  exposes a real depth signal and Nostr reachability is surfaced. The four-zone
//  scaffold is kept so lighting them up later is just supplying those peers.
//  The unread "a stone waits" ripple comes from the message store and wires with
//  the Stream pass; it is omitted here (seam kept in `peerRow`).
//

import SwiftUI
import SwiftData
import CryptoKit

struct HomeView: View {

    /// The durable contact roster. Reachability is layered on top of it below;
    /// this is every identity we know, named or not.
    @Query private var peers: [Peer]

    /// Live identity-resolved BLE reachability, mirrored here by ReadyView from
    /// the coordinator's `reachablePeers` stream. Reading it in `body` (via the
    /// tier partitions) is what makes the zones re-sort as peers come and go.
    @Environment(MeshPresence.self) private var presence
    /// STEP 7f — read verified state so unverified contacts never read as "near".
    @Environment(PairingService.self) private var pairing: PairingService?
    /// Deletes flow through here (Clear History on a peer row).
    @Environment(\.modelContext) private var modelContext

    /// Presents the pairing sheet from "let someone in".
    @State private var showPairing = false

    /// Remove Contact: the peer awaiting the confirm dialog (nil = none).
    @State private var peerPendingRemoval: Peer?

    /// Your local display name (Settings) — greets you on the surface line.
    @AppStorage("aeronyra.displayName") private var myName = ""
    @State private var showSettings = false

    /// Observe the app-wide accent so Home recolours the instant it changes.
    @AppStorage("aeronyra.accentHex") private var accentHex = Int(Stillwater.Accent.defaultHex)

    // ─────────────────────────────────────────────────────────────
    // MARK: Roster → depth tiers (the honest two-tier mapping)
    // ─────────────────────────────────────────────────────────────

    /// Stable within-zone order. NOT recency — the water sorts by physics
    /// (which zone), and inside a zone we sort by name so it doesn't jitter.
    private var sortedPeers: [Peer] {
        peers.sorted {
            displayName(for: $0).localizedCaseInsensitiveCompare(displayName(for: $1)) == .orderedAscending
        }
    }

    /// STEP 7f — "near" means VERIFIED + reachable. An unverified contact (even one
    /// physically in BLE range) never reads as near: presence is hidden until BOTH
    /// sides finish the SAS, matching the coordinator's presence gate.
    private var nearPeers: [Peer] {
        sortedPeers.filter { isVerified($0) && presence.isReachable($0.publicKeyData) }
    }
    /// Everyone else: verified-but-out-of-range AND all unverified contacts. Both
    /// stay listed + tappable (an unverified row is the path to its SAS sheet); the
    /// sublabel distinguishes "last felt…" from "unverified · verify to connect".
    private var gonePeers: [Peer] {
        sortedPeers.filter { !(isVerified($0) && presence.isReachable($0.publicKeyData)) }
    }

    private struct Zone {
        let title: String
        let accentLine: Double
        let dim: Bool
        let presence: Stillwater.Presence
        let peers: [Peer]
    }

    /// STEP 7f — two honest zones only: reachable (verified + in range) vs not.
    /// The through-others / beyond-the-water mesh-relay tiers are gone (this model
    /// never relays through non-contacts, and Nostr-far presence isn't surfaced).
    private var zones: [Zone] {
        [
            Zone(title: "near", accentLine: 0.10, dim: false, presence: .near, peers: nearPeers),
            Zone(title: "dark", accentLine: 0.04, dim: true,  presence: .gone, peers: gonePeers),
        ]
    }
    /// Only zones that actually hold peers render — an empty pool shows just the
    /// surface + "let someone in", which is the correct fresh-install state.
    private var activeZones: [Zone] { zones.filter { !$0.peers.isEmpty } }

    var body: some View {
        let _ = accentHex   // re-run body (recolour) when the accent changes
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

                        statusLine

                        surface
                            .padding(.top, 22)
                            .padding(.bottom, 26)

                        ForEach(activeZones, id: \.title) { z in
                            zone(z)
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(accentHex)
                }

                // Pinned to the bottom — the peer list scrolls above it, this stays put.
                pairingEntry
                    .padding(.horizontal, 26)
                    .padding(.top, 14)
                    .padding(.bottom, 30)
            }
        }
        .background(Stillwater.Palette.abyss)
        .sheet(isPresented: $showPairing) {
            PairingView()
        }
        .confirmationDialog(
            "Remove \(peerPendingRemoval.map { displayName(for: $0) } ?? "contact")?",
            isPresented: Binding(
                get: { peerPendingRemoval != nil },
                set: { if !$0 { peerPendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: peerPendingRemoval
        ) { peer in
            Button("Remove", role: .destructive) { removeContact(peer) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You'll need to pair again in person to reconnect.")
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: The status line ("the water is calm · two near")
    // ─────────────────────────────────────────────────────────────
    private var statusLine: some View {
        let n = nearPeers.count
        let prefix = n == 0 ? "the water is still · " : "the water is calm · "
        let tail   = n == 0 ? "no one near" : "\(spell(n)) near"
        return (Text(prefix)
                    .font(Stillwater.Serif.italic(19))
                    .foregroundColor(Stillwater.Palette.mist)
                + Text(tail)
                    .font(Stillwater.Serif.italic(19))
                    .foregroundColor(Stillwater.Palette.foam))
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
                // Stillwater gate: the key light breathes only when someone is
                // actually near (identity-resolved set, same as the zones) and
                // sits still at its rest value when alone.
                BreathingDot(color: Stillwater.Palette.biolume, size: 5, glow: 8,
                             duration: 4.0, delay: 0, accent: accentHex,
                             breathing: !nearPeers.isEmpty)
                Text("key alive")
                    .stillwaterMono(8.5, trackingEm: 0.22, color: Stillwater.Palette.mistDim)
            }
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Stillwater.Palette.mistDim)
                    .padding(.leading, 12)
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: The surface = you (one luminous line)
    // ─────────────────────────────────────────────────────────────
    private var surface: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(myName.isEmpty ? "you" : myName) — the surface")
                .stillwaterMono(8, trackingEm: 0.3, color: Stillwater.Palette.mistDim)
            // Stillwater gate: the surface pulses only when someone is near
            // (same identity-resolved set as the zones); still water when alone.
            SurfaceLine(accent: accentHex, breathing: !nearPeers.isEmpty)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: A depth zone (label + hairline + its peers)
    // ─────────────────────────────────────────────────────────────
    private func zone(_ z: Zone) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(z.title)
                    .stillwaterMono(8.5, trackingEm: 0.3,
                                    color: z.dim ? Stillwater.Palette.mistDimmest : Stillwater.Palette.mistDim)
                Rectangle()
                    .fill(Stillwater.Palette.biolume.opacity(z.accentLine))
                    .frame(height: 1)
            }
            .padding(.bottom, 10)

            ForEach(z.peers, id: \.publicKeyData) { peer in
                NavigationLink {
                    StreamView(peer: peer)
                } label: {
                    // The menu rides the INNER cell — on the NavigationLink
                    // itself the link swallows the long-press and no menu shows.
                    peerRow(peer, presence: z.presence)
                        .contextMenu {
                            // "Clear History" — the contact (and its verification
                            // state) survives; only the conversation goes.
                            Button("Clear History", role: .destructive) {
                                clearHistory(for: peer)
                            }
                            // "Remove Contact" — peer + conversation + crypto
                            // trust all go, behind a confirm dialog.
                            Button("Remove Contact", role: .destructive) {
                                peerPendingRemoval = peer
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 14)
    }

    private func peerRow(_ peer: Peer, presence tier: Stillwater.Presence) -> some View {
        HStack(spacing: 18) {
            PresenceLight(presence: tier, breath: breath(for: peer), delay: delay(for: peer), accent: accentHex)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(for: peer))
                    .stillwaterSerif(21, color: tier.nameColor)
                Text(sublabel(for: peer, tier: tier))
                    .stillwaterMono(9, trackingEm: 0.18, color: tier.labelColor)
            }

            Spacer()

            // STEP A1 — "a stone waits": an unread ripple on the trailing edge.
            // A stone was cast into your water and hasn't been answered; a still
            // biolume point with a slow ripple spreading from it. Shows in BOTH
            // zones (a verified-but-dark peer can carry unread too). Cleared when
            // you open the Stream (StreamView.markInboundRead flips the same
            // `!isOutbound && !isRead` rows this counts, and the @Model read here
            // re-renders the row on that flip / on a fresh inbound arrival).
            let unread = unreadCount(for: peer)
            if unread > 0 {
                UnreadStone(count: unread, accent: accentHex)
            }
        }
        .padding(.vertical, 10)
    }

    /// STEP A1 — unread inbound count for a peer's direct conversation. Mirrors
    /// the EXACT predicate `StreamView.markInboundRead` clears (`!isOutbound &&
    /// !isRead`), so casting into the Stream zeroes this on return. Inbound text
    /// AND media both persist `isRead: false`, so both count until viewed.
    /// Traverses the @Model relationship graph inside `body`, which registers
    /// SwiftData observation on the exact Message rows — a new arrival or a
    /// read-flip re-evaluates this row without any explicit trigger.
    private func unreadCount(for peer: Peer) -> Int {
        guard let convo = peer.conversations.first(where: { $0.kind == .direct })
        else { return 0 }
        return convo.messages.reduce(0) { $0 + ((!$1.isOutbound && !$1.isRead) ? 1 : 0) }
    }

    /// Clear History: deletes the peer's direct conversation — the .cascade
    /// rule removes its Messages, the .nullify rule detaches (not deletes) the
    /// Peer, so the row stays and the contact remains messageable: StreamView
    /// resolves its conversation lazily and `currentConversation()` recreates
    /// one on the next send.
    /// KNOWN LIMITATION (accepted): the deleted rows' `wireIDData` were the
    /// inbound dedup records, so late relay replays can resurface messages.
    private func clearHistory(for peer: Peer) {
        guard let convo = peer.conversations.first(where: { $0.kind == .direct })
        else { return }
        modelContext.delete(convo)
        try? modelContext.save()
    }

    /// Remove Contact: full removal — crypto trust FIRST, rows second.
    /// `pairing.revoke` persists the allowlist removal and drops the identity
    /// from the live reconnect + verified gates (EnrollmentService.revoke →
    /// coordinator.removeReconnectContact/removeVerifiedContact). If that
    /// persist throws, STOP with the rows intact: better a visible row with
    /// trust intact than a vanished row with a live pairing left behind.
    /// The .direct conversation is deleted explicitly (Peer→Conversation is
    /// .nullify, so deleting the peer alone would orphan it), then the Peer;
    /// the `peers` @Query drops the row on save.
    private func removeContact(_ peer: Peer) {
        let rawKey = peer.publicKeyData
        Task {
            do { try await pairing?.revoke(rawKey) } catch { return }
            if let convo = peer.conversations.first(where: { $0.kind == .direct }) {
                modelContext.delete(convo)
            }
            modelContext.delete(peer)
            try? modelContext.save()
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Row content derived from the real Peer
    // ─────────────────────────────────────────────────────────────

    /// Name if the user (or first contact) set one; otherwise a short key stub
    /// so an unnamed-but-known peer is still identifiable pre-pairing-UI.
    private func displayName(for peer: Peer) -> String {
        if let n = peer.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            return n
        }
        return String(peer.userIDHex.prefix(6)).uppercased()
    }

    private func sublabel(for peer: Peer, tier: Stillwater.Presence) -> String {
        switch tier {
        case .near:          return "in the room · direct"
        case .throughOthers: return "through the mesh · multi-hop"
        case .relay:         return "over the relay · far"
        case .gone:
            // 7f — an out-of-range VERIFIED contact shows its last-seen; an
            // unverified one shows the call to action that opens its SAS sheet.
            return isVerified(peer)
                ? "last felt \(relativeAge(peer.lastSeen))"
                : "unverified · verify to connect"
        }
    }

    /// STEP 7f — verified state for a peer (nil env → unverified, e.g. previews).
    private func isVerified(_ peer: Peer) -> Bool {
        pairing?.isVerified(peer.publicKeyData) ?? false
    }

    /// Compact "3 h ago" style age from a Date, matching the mockup's whisper.
    private func relativeAge(_ date: Date) -> String {
        let seconds = max(0, Date.now.timeIntervalSince(date))
        if seconds < 60 { return "moments ago" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }
        let days = hours / 24
        return "\(days) d ago"
    }

    /// A small integer spelled for the status line (falls back to digits).
    private func spell(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six",
                     "seven", "eight", "nine", "ten", "eleven", "twelve"]
        return (n >= 0 && n < words.count) ? words[n] : "\(n)"
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Per-peer breath desync — derived, so it needs no data field
    // ─────────────────────────────────────────────────────────────
    //
    // Same idea as Peer.avatarHue: a stable SHA-256 of the key gives every
    // person a fixed-but-distinct breath tempo + phase, so the lights don't
    // pulse in lockstep and stay consistent across launches.

    private func breath(for peer: Peer) -> Double {
        let b = Double(digestByte(peer.publicKeyData, 0)) / 255.0
        return Stillwater.Motion.breathFast
             + b * (Stillwater.Motion.breathSlow - Stillwater.Motion.breathFast)  // 4.0 … 6.5
    }
    private func delay(for peer: Peer) -> Double {
        Double(digestByte(peer.publicKeyData, 1)) / 255.0 * 1.5                     // 0 … 1.5s
    }
    private func digestByte(_ data: Data, _ index: Int) -> UInt8 {
        let digest = Array(SHA256.hash(data: data))
        return index < digest.count ? digest[index] : 0
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: Pairing entry ("let someone in")
    // ─────────────────────────────────────────────────────────────
    private var pairingEntry: some View {
        Button { showPairing = true } label: {
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
        .buttonStyle(.plain)
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - A peer's presence light (breathing / rippling by depth)
// ─────────────────────────────────────────────────────────────
private struct PresenceLight: View {
    let presence: Stillwater.Presence
    let breath: Double
    let delay: Double
    var accent: Int = 0

    var body: some View {
        let _ = accent
        ZStack {
            switch presence {
            case .near:
                BreathingDot(color: presence.light, size: 13, glow: 20,
                             duration: breath, delay: delay, accent: accent)
            case .throughOthers:
                RippleRing(color: Stillwater.Palette.biolume, duration: 3.4, accent: accent)
                BreathingDot(color: presence.light, size: 11, glow: 14,
                             duration: breath, delay: delay, accent: accent)
            case .relay:
                BreathingDot(color: presence.light, size: 10, glow: 0,
                             duration: breath, delay: delay, dim: true, accent: accent)
            case .gone:
                Circle()
                    .strokeBorder(Stillwater.Palette.goneRing, lineWidth: 1)
                    .frame(width: 10, height: 10)
            }
        }
    }
}

// A soft light that breathes: opacity + scale on a sine-eased loop, desynced.
//
// GATED (Stillwater): the loop runs only while `breathing` is true — motion
// means presence. The on/off is driven by explicit `withAnimation` transactions
// in `onChange(initial:)`, NOT the old `.animation(value:) + .onAppear` flip:
// that pattern raced view insertion (the flip could commit inside the insertion
// transaction and never arm — the intermittent frozen/pulsing wipe-launch bug).
// An explicit transaction attaches the animation to the mutation itself, so
// arming is deterministic in both directions.
private struct BreathingDot: View {
    let color: Color
    let size: CGFloat
    let glow: CGFloat
    let duration: Double
    var delay: Double = 0
    var dim: Bool = false
    var accent: Int = 0
    /// Presence gate. Defaults true: the per-peer `PresenceLight` dots exist
    /// only while their peer IS present, so they always breathe; the wordmark
    /// key light passes the real near-gate.
    var breathing: Bool = true

    /// rest = false … peak = true. Never set outside the transactions below.
    @State private var phase = false

    var body: some View {
        let _ = accent
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: glow > 0 ? color.opacity(0.35) : .clear, radius: glow)
            .scaleEffect(phase ? 1.0 : (dim ? 0.92 : 0.9))
            .opacity(phase ? (dim ? 0.6 : 1.0) : (dim ? 0.3 : 0.55))
            .onChange(of: breathing, initial: true) { _, isNear in
                if isNear {
                    // Ease IN: the loop starts from rest, so the first breath's
                    // own sine rise is the fade-in — no snap on arrival.
                    withAnimation(Stillwater.Motion.breathe(duration).delay(delay)) {
                        phase = true
                    }
                } else {
                    // Ease OUT: retarget from the current presentation value and
                    // settle to the calm REST value (never frozen mid-pulse).
                    withAnimation(Stillwater.Motion.water(1.0)) {
                        phase = false
                    }
                }
            }
    }
}

// An expanding ring — "reachable through others" / an unread ripple.
private struct RippleRing: View {
    let color: Color
    let duration: Double
    var accent: Int = 0
    @State private var expanded = false

    var body: some View {
        let _ = accent
        Circle()
            .strokeBorder(color.opacity(0.55), lineWidth: 1)
            .frame(width: 30, height: 30)
            .scaleEffect(expanded ? 1.0 : 0.45)
            .opacity(expanded ? 0.0 : 0.8)
            .animation(.easeOut(duration: duration).repeatForever(autoreverses: false), value: expanded)
            .onAppear { expanded = true }
    }
}

// A stone waits on the water: the Home-row unread-inbound marker (STEP A1).
// A still biolume point with a slow ripple spreading from it — cast, unanswered.
// A hairline mono count rides alongside only when MORE THAN ONE waits, so a
// single unread stays quiet and a burst stays legible. Resolves to this file's
// private `RippleRing` (color/duration/accent), matching the accent-rebuild
// pattern of every other animated light on this screen.
private struct UnreadStone: View {
    let count: Int
    var accent: Int = 0

    var body: some View {
        let _ = accent
        HStack(spacing: 8) {
            if count > 1 {
                Text("\(count)")
                    .stillwaterMono(9, trackingEm: 0.14, color: Stillwater.Palette.foam)
            }
            ZStack {
                RippleRing(color: Stillwater.Palette.biolume, duration: 3.0, accent: accent)
                Circle()
                    .fill(Stillwater.Palette.biolume)
                    .frame(width: 7, height: 7)
                    .shadow(color: Stillwater.Palette.biolume.opacity(0.5), radius: 6)
            }
            .frame(width: 22, height: 22)
        }
    }
}

// You — the surface: one luminous line. Pulses slowly while someone is near;
// still water (rest opacity) when alone. Same deterministic gate discipline as
// BreathingDot — explicit transactions, no onAppear arming race.
private struct SurfaceLine: View {
    var accent: Int = 0
    /// Presence gate: `!nearPeers.isEmpty` from HomeView (identity-resolved).
    var breathing: Bool = false

    /// rest = false … bright = true. Never set outside the transactions below.
    @State private var alive = false

    var body: some View {
        let _ = accent
        LinearGradient(
            colors: [.clear,
                     Stillwater.Palette.biolume, Stillwater.Palette.biolume,
                     .clear],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(height: 1)
        .shadow(color: Stillwater.Palette.biolume.opacity(0.45), radius: 6)
        .opacity(alive ? 1.0 : 0.5)
        .onChange(of: breathing, initial: true) { _, isNear in
            if isNear {
                // Ease IN: first rise of the 5s breath is the fade-in.
                withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) {
                    alive = true
                }
            } else {
                // Ease OUT: settle to rest (0.5) over the water curve — the
                // last peer leaving calms the surface, it doesn't snap it.
                withAnimation(Stillwater.Motion.water(1.0)) {
                    alive = false
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Preview (in-memory store so @Query renders on the canvas)
// ─────────────────────────────────────────────────────────────
#Preview("Stillwater — Home") {
    let container = try! ModelContainer(
        for: Peer.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let ctx = container.mainContext

    let theo = Peer(publicKeyData: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                    displayName: "Theo", lastSeen: .now)
    let priya = Peer(publicKeyData: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                     displayName: "Priya", lastSeen: .now)
    let sana = Peer(publicKeyData: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                    displayName: "Sana", lastSeen: .now.addingTimeInterval(-3 * 3600))
    ctx.insert(theo); ctx.insert(priya); ctx.insert(sana)

    // Give Theo an unread inbound message so the "a stone waits" indicator
    // renders on canvas (two unread → the hairline count also shows).
    let convo = Conversation(kind: .direct, peer: theo)
    ctx.insert(convo)
    for text in ["are you seeing this too", "the whole block just went dark"] {
        let m = Message(content: text, isOutbound: false, deliveryState: .delivered, isRead: false)
        ctx.insert(m); m.conversation = convo
    }

    let presence = MeshPresence()
    presence.reachablePeerKeys = [theo.publicKeyData, priya.publicKeyData]  // two near, Sana dark

    return HomeView()
        .modelContainer(container)
        .environment(presence)
}
