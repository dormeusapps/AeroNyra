//
//  PersistentModels.swift
//  Core/Models
//
//  THE SwiftData PERSISTENCE LAYER (Peer · Conversation · Message).
//
//  These are the app's durable store, distinct from the WIRE models in
//  Envelope.swift. The router moves opaque `Envelope`s; this layer is what the
//  UI binds to and what survives a relaunch.
//
//  Design fidelity (locked tokens):
//   • Message persists the existing six-state `MessageDeliveryState` enum — it
//     does NOT reinvent states. SwiftData can't store an enum with an associated
//     value (`.relayed(hops:)`), so it is decomposed into `deliveryStateRaw` +
//     `relayHops`, bridged by the computed `deliveryState`. This keeps state
//     queryable (e.g. fetch all `.notDelivered` for resend) and is the single
//     vocabulary shared with the router and BLE layer.
//   • Peer's avatar color is DERIVED deterministically from the public key
//     (DESIGN_TOKENS §11) — same person, same color on every screen, every
//     launch. Stored as nothing; computed as a stable hue. Swift's `Hasher` is
//     per-process seeded and unusable here, so the hue is SHA256-derived.
//   • Conversation.kind carries the direct (1:1, E2EE) vs. mesh-room (public,
//     NOT E2EE) distinction — load-bearing for the amber PUBLIC badge.
//
//  AT-REST PROTECTION (open ledger item — wired when the app entry point exists):
//  content is stored as plaintext here; the at-rest defense is the OS Data
//  Protection class (NSFileProtectionComplete) on the store file plus the vault,
//  configured at ModelContainer setup — NOT per-row encryption. That belongs in
//  the composition root, which doesn't exist yet.
//

import Foundation
import SwiftData
import CryptoKit

// MARK: - Peer

/// A remote identity we've encountered. The 32-byte public key is the permanent
/// user ID (there is no server, no account); everything else is local.
@Model
public final class Peer {

    /// The X25519 public key — the canonical user ID. Unique across the store.
    @Attribute(.unique) public var publicKeyData: Data

    /// Local, user-assigned (or first-contact) display name. Offline: names are
    /// never authoritative, only a local convenience.
    public var displayName: String?

    public var firstSeen: Date
    public var lastSeen: Date

    /// Whether the safety number has been confirmed out-of-band (§3.5).
    /// Trust-on-first-use defaults this to false until the user verifies.
    public var isVerified: Bool

    @Relationship(deleteRule: .nullify, inverse: \Conversation.peer)
    public var conversations: [Conversation]

    public init(publicKeyData: Data,
                displayName: String? = nil,
                firstSeen: Date = .now,
                lastSeen: Date = .now,
                isVerified: Bool = false) {
        self.publicKeyData = publicKeyData
        self.displayName = displayName
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.isVerified = isVerified
        self.conversations = []
    }

    /// Lowercase hex of the user ID — for display/debug, never a security boundary.
    public var userIDHex: String {
        publicKeyData.map { String(format: "%02x", $0) }.joined()
    }

    /// Deterministic avatar hue in 0...1, derived from the public key
    /// (DESIGN_TOKENS §11). The DesignSystem maps this hue into the locked
    /// gradient treatment — one source of truth for identity color.
    public var avatarHue: Double {
        let digest = Array(SHA256.hash(data: publicKeyData))
        let value = (UInt16(digest[0]) << 8) | UInt16(digest[1])
        return Double(value) / Double(UInt16.max)
    }
}

// MARK: - Conversation

/// A thread. Either a DIRECT 1:1 channel (end-to-end encrypted) or the public
/// MESH ROOM (NOT E2EE — marked with the amber PUBLIC badge).
public enum ConversationKind: String, Codable, Sendable {
    case direct
    case meshRoom
}

@Model
public final class Conversation {

    public var id: UUID

    /// Stored raw; bridged by `kind`. (SwiftData stores the String.)
    public var kindRaw: String

    /// Mesh-room name. Direct conversations derive their title from the peer.
    public var title: String?

    /// Drives chats-list ordering.
    public var lastActivity: Date

    /// The other party for a DIRECT conversation; nil for the mesh room.
    public var peer: Peer?

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    public var messages: [Message]

    public init(kind: ConversationKind,
                peer: Peer? = nil,
                title: String? = nil,
                lastActivity: Date = .now,
                id: UUID = UUID()) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.peer = peer
        self.title = title
        self.lastActivity = lastActivity
        self.messages = []
    }

    public var kind: ConversationKind {
        get { ConversationKind(rawValue: kindRaw) ?? .direct }
        set { kindRaw = newValue.rawValue }
    }

    /// True for direct conversations (E2EE), false for the public mesh room.
    /// The UI uses this to show the PUBLIC badge and the not-encrypted treatment.
    public var isEncrypted: Bool { kind == .direct }
}

// MARK: - Message

@Model
public final class Message {

    public var id: UUID

    /// Plaintext content. At-rest protection is the store's Data Protection +
    /// vault, not per-row encryption (see file header).
    public var content: String

    /// Sent by us (true) vs. received (false).
    public var isOutbound: Bool

    public var timestamp: Date

    /// The wire `MessageID` (16 bytes) this message was sent under, so router
    /// `DeliveryUpdate`s (keyed by MessageID) can be matched back to this row.
    /// Nil until an outbound message is sealed/sent.
    public var wireIDData: Data?

    /// Decomposed delivery state (bridged by `deliveryState`). Stored so it's
    /// queryable; `relayHops` carries the associated value of `.relayed`.
    public var deliveryStateRaw: String
    public var relayHops: Int

    public var conversation: Conversation?

    public init(content: String,
                isOutbound: Bool,
                deliveryState: MessageDeliveryState = .sent,
                wireID: MessageID? = nil,
                timestamp: Date = .now,
                id: UUID = UUID()) {
        self.id = id
        self.content = content
        self.isOutbound = isOutbound
        self.timestamp = timestamp
        self.wireIDData = wireID.map { Data($0.bytes) }
        // Initialize the decomposed fields, then route through the bridge.
        self.deliveryStateRaw = "sent"
        self.relayHops = 0
        self.deliveryState = deliveryState
    }

    /// The wire id as a `MessageID`, if this message has been sent.
    public var wireID: MessageID? {
        guard let wireIDData else { return nil }
        return MessageID(bytes: [UInt8](wireIDData))
    }

    /// Bridge to the canonical six-state enum. The associated `hops` of
    /// `.relayed` lives in `relayHops`; all other states leave it 0.
    public var deliveryState: MessageDeliveryState {
        get {
            switch deliveryStateRaw {
            case "waitingForRange": return .waitingForRange
            case "sent":            return .sent
            case "findingPath":     return .findingPath
            case "delivered":       return .delivered
            case "relayed":         return .relayed(hops: relayHops)
            case "notDelivered":    return .notDelivered
            default:                return .sent
            }
        }
        set {
            switch newValue {
            case .waitingForRange: deliveryStateRaw = "waitingForRange"; relayHops = 0
            case .sent:            deliveryStateRaw = "sent";            relayHops = 0
            case .findingPath:     deliveryStateRaw = "findingPath";     relayHops = 0
            case .delivered:       deliveryStateRaw = "delivered";       relayHops = 0
            case .relayed(let h):  deliveryStateRaw = "relayed";         relayHops = h
            case .notDelivered:    deliveryStateRaw = "notDelivered";    relayHops = 0
            }
        }
    }
}
