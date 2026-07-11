// CallICEConfig.swift
// Core/Calls
//
// THE config seam for call ICE servers (FaceTime v1, P2). One place, pure
// values, no WebRTC import — the operator fills these in; the app never
// hardcodes a server. THREAT_MODEL posture: whichever hosts appear here learn
// both parties' call-time IPs and call timing, so they must be
// infrastructure WE control (own coturn), never a third-party relay.
//
// TIERS (graceful degradation, decided by what's filled in):
//   • TURN + STUN — calls connect over the internet including symmetric
//     NAT / CGNAT (cellular). The intended production shape.
//   • STUN only — most internet NAT pairs connect; symmetric NAT fails as
//     `.connectFailed` ("try joining the same WiFi").
//   • Nothing — host candidates only: same-network calls still work, so a
//     fresh checkout builds and LAN-tests without any infrastructure.
//

import Foundation

/// ICE server configuration for call media. Value type, Equatable, pure —
/// the WebRTC mapping lives in WebRTCCallMedia, so this stays unit-testable
/// without the framework.
public struct CallICEConfig: Equatable, Sendable {

    /// e.g. ["stun:stun.yourdomain.org:3478"]
    public var stunURLs: [String]

    /// e.g. ["turn:turn.yourdomain.org:3478?transport=udp",
    ///       "turn:turn.yourdomain.org:443?transport=tcp"]
    public var turnURLs: [String]

    /// coturn long-term credentials. Both must be non-empty for TURN to be
    /// offered; a TURN URL without credentials is ignored (tier drops to
    /// STUN-only) rather than sent broken.
    public var turnUsername: String
    public var turnCredential: String

    public init(stunURLs: [String] = [],
                turnURLs: [String] = [],
                turnUsername: String = "",
                turnCredential: String = "") {
        self.stunURLs = stunURLs
        self.turnURLs = turnURLs
        self.turnUsername = turnUsername
        self.turnCredential = turnCredential
    }

    // ────────────────────────────────────────────────────────────────────
    // OPERATOR CONFIG — fill these in. Empty = that tier absent (see the
    // header). This is the ONLY place server addresses live.
    // ────────────────────────────────────────────────────────────────────
    public static let operatorSupplied = CallICEConfig(
        stunURLs: [],
        turnURLs: [],
        turnUsername: "",
        turnCredential: "")

    /// TURN is offered only when fully configured.
    public var hasTURN: Bool {
        !turnURLs.isEmpty && !turnUsername.isEmpty && !turnCredential.isEmpty
    }

    public var hasSTUN: Bool { !stunURLs.isEmpty }
}
