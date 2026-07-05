//
//  MessageDeliveryState.swift
//  Beacon (working title)
//
//  The single source of truth for delivery status.
//
//  Build note §9 (DESIGN_TOKENS): "Map each state to a single enum
//  (MessageDeliveryState) so UI, persistence (SwiftData), and the BLE
//  layer share one vocabulary."
//
//  This enum is transport-neutral by design. The internet-fallback seam
//  (HANDOFF §4) depends on delivery state meaning the same thing no matter
//  which transport carried the message — so nothing here references BLE.
//

import Foundation

/// The lifecycle of an outbound message, from queued to confirmed (or failed).
///
/// These are the six states specified in DESIGN_TOKENS §4. The raw state is
/// kept deliberately small and Codable so it can be persisted with SwiftData
/// and reconstructed exactly. All *presentation* concerns (color, icon,
/// labels) are derived, not stored — see `DeliveryAppearance` below.
public enum MessageDeliveryState: Equatable, Hashable, Codable, Sendable {

    /// No peer is reachable yet; the message is held until range is regained.
    /// Token: status/relay (amber). Sublabel: "queued".
    case waitingForRange

    /// Handed to the local radio for transmission. Not yet acknowledged.
    /// Token: status/neutral. Sublabel: "handed to radio".
    case sent

    /// Cast over a Nostr relay for a peer who is out of BLE range. There is NO
    /// local ack deadline — the wrap sits at the relay until the recipient next
    /// connects and fetches it, at which point a real ack surfaces it to
    /// `.delivered`. Non-terminal. Distinct from `.sent` (a BLE radio handoff,
    /// which DOES carry a short stuck-send deadline). A `.cast` row is demoted to
    /// `.notDelivered` ONLY by a genuine failure ack (`confirmFailure`), never by
    /// a timer — no timer is ever armed for a cast commit. Token: status/neutral.
    /// Sublabel: "in the current".
    case cast

    /// Confirmed received by the recipient.
    /// Token: status/healthy — but rendered muted by default (the Quiet rule).
    /// Sublabel: "confirmed".
    case delivered

    /// Reached the recipient via one or more relay hops through the mesh.
    /// Token: status/relay (amber). Sublabel: "via mesh".
    /// - Parameter hops: number of intermediate relay nodes (>= 1).
    case relayed(hops: Int)

    /// In transit, actively searching for a route. Drives the Live-Transit
    /// widget (DESIGN_TOKENS §7) when a relay is active.
    /// Token: status/neutral text + pulsing dot. Sublabel: "in transit".
    case findingPath

    /// Could not be delivered. The only state that demands user action.
    /// Token: status/error (red). Sublabel: "tap to resend".
    case notDelivered
}

// MARK: - Quiet Rule

public extension MessageDeliveryState {

    /// DESIGN_TOKENS §0 — THE QUIET RULE.
    /// "Success is silent. Color is earned only by states that need a human
    /// to notice." A healthy/successful state renders in neutral gray in the
    /// default (Quiet) treatment; its true hue is revealed only in the
    /// receipt or in non-quiet themes.
    ///
    /// - `true`  for states that earn color: waiting, relayed, notDelivered.
    /// - `false` for quiet successes: sent, delivered, findingPath.
    var earnsColor: Bool {
        switch self {
        case .waitingForRange, .relayed, .notDelivered:
            return true
        case .sent, .cast, .delivered, .findingPath:
            return false
        }
    }

    /// Whether this state requires the user to act (drives the resend affordance).
    var requiresAction: Bool {
        if case .notDelivered = self { return true }
        return false
    }

    /// Whether this state is terminal (no further automatic transitions).
    var isTerminal: Bool {
        switch self {
        case .delivered, .relayed, .notDelivered:
            return true
        case .waitingForRange, .sent, .cast, .findingPath:
            return false
        }
    }
}

// MARK: - Semantic Color Tokens

/// The semantic status colors from DESIGN_TOKENS §1 (STATUS).
/// These name tokens, not hex values — the actual colors live in the asset
/// catalog (dark = ship, light = derived) so dark/light parity is handled
/// at the rendering layer, not here.
public enum StatusColorToken: String, Sendable {
    case healthy   // status/healthy   #45C496 | #1D9E75
    case relay     // status/relay     #E0A23B | #B57A12  (amber)
    case error     // status/error     #E5594E | #C0392E  (red)
    case neutral   // status/neutral   #6E7975 | #8A938F  (muted)
}

// MARK: - Presentation

/// The fully resolved visual treatment for a state in a given theme.
/// UI reads this rather than switching on the state itself, keeping the
/// design-token mapping in exactly one place.
public struct DeliveryAppearance: Equatable, Sendable {
    /// The color token to render the chip/label with.
    public let colorToken: StatusColorToken
    /// SF Symbol name for the state glyph.
    public let symbolName: String
    /// Mono sublabel shown beneath/after the state (DESIGN_TOKENS §4).
    public let sublabel: String
}

public extension MessageDeliveryState {

    /// Resolve the visual treatment for this state.
    ///
    /// - Parameter quiet: when `true` (the default conversation treatment),
    ///   healthy successes are muted to neutral per the Quiet rule. Pass
    ///   `false` for the receipt / non-quiet themes to reveal true hues.
    func appearance(quiet: Bool = true) -> DeliveryAppearance {
        switch self {
        case .waitingForRange:
            return .init(colorToken: .relay,
                         symbolName: "clock",
                         sublabel: "queued")

        case .sent:
            return .init(colorToken: .neutral,
                         symbolName: "checkmark",
                         sublabel: "handed to radio")

        case .cast:
            // Cast over a relay; no deadline. Quiet by design — it is neither a
            // success to celebrate nor a failure to flag, just "on its way, will
            // surface." Neutral token, directional glyph (sent outward, will land).
            return .init(colorToken: .neutral,
                         symbolName: "arrow.up.forward",
                         sublabel: "in the current")

        case .delivered:
            // Token is healthy, but Quiet renders it muted by default.
            return .init(colorToken: quiet ? .neutral : .healthy,
                         symbolName: "checkmark.circle.fill", // double-check feel
                         sublabel: "confirmed")

        case .relayed(let hops):
            let hopLabel = hops == 1 ? "1 hop" : "\(hops) hops"
            return .init(colorToken: .relay,
                         symbolName: "point.3.connected.trianglepath.dotted",
                         sublabel: "via mesh · \(hopLabel)")

        case .findingPath:
            return .init(colorToken: .neutral,
                         symbolName: "dot.radiowaves.left.and.right",
                         sublabel: "in transit")

        case .notDelivered:
            return .init(colorToken: .error,
                         symbolName: "exclamationmark.circle",
                         sublabel: "tap to resend")
        }
    }

    /// Short human-facing label for the state (the chip's primary text).
    var title: String {
        switch self {
        case .waitingForRange: return "Waiting for range"
        case .sent:            return "Sent"
        case .cast:            return "Cast"
        case .delivered:       return "Delivered"
        case .relayed(let h):  return h == 1 ? "Relayed · 1 hop" : "Relayed · \(h) hops"
        case .findingPath:     return "Finding a path"
        case .notDelivered:    return "Not delivered"
        }
    }
}

// MARK: - Codable

// `relayed(hops:)` has an associated value, so the synthesized Codable
// conformance encodes a discriminated form automatically. The explicit
// CodingKeys/representation below pins the on-disk shape so future enum
// edits don't silently break persisted history.
public extension MessageDeliveryState {

    private enum Kind: String, Codable {
        case waitingForRange, sent, cast, delivered, relayed, findingPath, notDelivered
    }

    private enum CodingKeys: String, CodingKey {
        case kind, hops
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .waitingForRange: self = .waitingForRange
        case .sent:            self = .sent
        case .cast:            self = .cast
        case .delivered:       self = .delivered
        case .relayed:
            let hops = try c.decode(Int.self, forKey: .hops)
            self = .relayed(hops: hops)
        case .findingPath:     self = .findingPath
        case .notDelivered:    self = .notDelivered
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .waitingForRange: try c.encode(Kind.waitingForRange, forKey: .kind)
        case .sent:            try c.encode(Kind.sent, forKey: .kind)
        case .cast:            try c.encode(Kind.cast, forKey: .kind)
        case .delivered:       try c.encode(Kind.delivered, forKey: .kind)
        case .relayed(let h):
            try c.encode(Kind.relayed, forKey: .kind)
            try c.encode(h, forKey: .hops)
        case .findingPath:     try c.encode(Kind.findingPath, forKey: .kind)
        case .notDelivered:    try c.encode(Kind.notDelivered, forKey: .kind)
        }
    }
}
