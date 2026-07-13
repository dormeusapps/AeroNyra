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
    
    /// LOCAL contact customization (never transmitted). A photo the user picked
    /// for this peer, stored as a small normalized JPEG; nil → fall back to the
    /// key-derived gradient avatar. Optional so adding it is a lightweight
    /// SwiftData migration (existing rows read nil). Wiped on crypto-erase with
    /// the rest of the store.
    public var customAvatarData: Data?
    
    /// LOCAL contact customization (never transmitted). A user-chosen accent hue
    /// in 0...1 that overrides the deterministic `avatarHue`; nil → use the
    /// key-derived hue. Optional for the same lightweight-migration reason.
    public var customHue: Double?
    
    public var firstSeen: Date
    public var lastSeen: Date
    
    /// Whether the safety number has been confirmed out-of-band (§3.5).
    /// Trust-on-first-use defaults this to false until the user verifies.
    public var isVerified: Bool
    
    /// This peer's raw 32-byte x-only secp256k1 Nostr public key, learned over
    /// the established sealed channel via the npub-bootstrap (Phase 8d-0, a
    /// `.nostrIdentity` MessagePayload — NEVER from the libsignal PrekeyBundle).
    /// Nil until that announcement arrives. This is a DISTINCT key from
    /// `publicKeyData`: that one is the X25519 libsignal identity (the canonical
    /// user ID); this is what the router addresses a Nostr gift wrap to when the
    /// BLE path is out of range. Stored raw because that is exactly the `Data`
    /// the crypto layer (`Secp256k1.ecdh`, `NIP44.conversationKey`,
    /// `NostrGiftWrap.wrap`) consumes — no bech32 round-trip.
    public var nostrPubkey: Data?
    
    @Relationship(deleteRule: .nullify, inverse: \Conversation.peer)
    public var conversations: [Conversation]
    
    public init(publicKeyData: Data,
                displayName: String? = nil,
                customAvatarData: Data? = nil,
                customHue: Double? = nil,
                firstSeen: Date = .now,
                lastSeen: Date = .now,
                isVerified: Bool = false,
                nostrPubkey: Data? = nil) {
        self.publicKeyData = publicKeyData
        self.displayName = displayName
        self.customAvatarData = customAvatarData
        self.customHue = customHue
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.isVerified = isVerified
        self.nostrPubkey = nostrPubkey
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
    
    /// The hue the avatar should actually render in: the user's chosen
    /// `customHue` if set, otherwise the deterministic key-derived `avatarHue`.
    /// One accessor so every avatar surface resolves custom-over-default the
    /// same way.
    public var resolvedHue: Double {
        customHue ?? avatarHue
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
    
    /// Per-conversation read-receipt opt-in. OFF by default (the Private
    /// posture). When on, opening an inbound message emits a small encrypted
    /// ack over the radio — another envelope, another ratchet step, a presence
    /// cost — which is exactly why it's off until the user chooses otherwise.
    /// The PeerSettings toggle binds to this; the send path consults it before
    /// emitting an ack.
    public var readReceiptsEnabled: Bool
    
    /// The other party for a DIRECT conversation; nil for the mesh room.
    public var peer: Peer?
    
    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    public var messages: [Message]
    
    public init(kind: ConversationKind,
                peer: Peer? = nil,
                title: String? = nil,
                lastActivity: Date = .now,
                readReceiptsEnabled: Bool = false,
                id: UUID = UUID()) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.peer = peer
        self.title = title
        self.lastActivity = lastActivity
        self.readReceiptsEnabled = readReceiptsEnabled
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
    
    /// Whether an INBOUND message has been seen by the user. Outbound messages
    /// leave this false (it's meaningless for them). The chats-list unread dot
    /// lights when a conversation holds any inbound message with `isRead`
    /// false; opening the conversation clears them.
    public var isRead: Bool
    
    public var timestamp: Date
    
    /// EPHEMERAL VOICE NOTES: when the RECIPIENT finished listening to an inbound
    /// voice note. nil until then. The audio self-destructs 2 min after this
    /// instant — playability is gated on it and `mediaData` is wiped. Inbound m4a only.
    public var listenedAt: Date?
    
    /// The wire `MessageID` (16 bytes) this message was sent under, so router
    /// `DeliveryUpdate`s (keyed by MessageID) can be matched back to this row.
    /// Nil until an outbound message is sealed/sent.
    public var wireIDData: Data?
    
    /// Decomposed delivery state (bridged by `deliveryState`). Stored so it's
    /// queryable; `relayHops` carries the associated value of `.relayed`.
    public var deliveryStateRaw: String
    public var relayHops: Int

    /// ISSUE-3b idempotency (PERSISTED). Set once this media row has been re-driven
    /// over Nostr after a mid-burst BLE drop, enforcing a hard cap of ONE re-drive
    /// that SURVIVES a force-quit. An in-memory guard clears on relaunch, so a still-
    /// `.cast` row (or one whose re-drive already failed to `.notDelivered`) would be
    /// re-driven again on every launch, hammering the rate-limited relays. The inline
    /// `= false` default backfills existing rows with no schema work (lightweight,
    /// no-op migration), and lets the manual `init` omit it. Text rows never set it;
    /// only `redriveInFlightMedia` writes it.
    public var nostrRedriveDone: Bool = false
    
    /// Media payload, if this message is a photo or voice note rather than text.
    /// Nil for text messages. The blob is the reassembled, integrity-verified
    /// bytes (Phase 6b). At-rest protection is the store's Data Protection
    /// (Phase 5b), same as `content` — not per-row encryption.
    public var mediaData: Data?
    
    /// Raw `MediaMimeType` ("jpeg"/"m4a"/"mp4") when `mediaData` is set; nil
    /// for text.
    public var mediaMimeRaw: String?

    /// STORIES: true when this media row is a story — ephemeral on BOTH ends,
    /// self-destructing `MediaEphemeralityPolicy.storyWindow` after `sentAt`
    /// (the stories-only reversal of SEC-6's "outbound never expires" rule).
    /// The inline `= false` default backfills existing rows with no schema
    /// work (lightweight migration, same pattern as `nostrRedriveDone`).
    public var isStory: Bool = false

    /// PUSH-TO-TALK: true when this `.m4a` row is a walkie-talkie utterance, so
    /// the transcript renders/auto-plays it as PTT rather than a tap-to-play
    /// voice note. Additive metadata only — expiry and routing are identical to
    /// an ordinary voice note. Inline `= false` default backfills existing rows
    /// (lightweight migration, same pattern as `isStory`).
    public var isPushToTalk: Bool = false

    /// STORIES: when the SENDER first sent this media — the anchor the story
    /// expiry window counts from. Outbound: this row's `timestamp`, stamped at
    /// first send and REUSED on resend/re-drive so a retry can't extend the
    /// window. Inbound: the manifest's sender-asserted stamp CLAMPED to
    /// arrival time at persist (a future-dated stamp must not make a story
    /// immortal). nil for non-story and legacy rows.
    public var sentAt: Date?

    public var conversation: Conversation?

    public init(content: String,
                isOutbound: Bool,
                deliveryState: MessageDeliveryState = .sent,
                isRead: Bool = false,
                wireID: MessageID? = nil,
                mediaData: Data? = nil,
                mediaMimeRaw: String? = nil,
                listenedAt: Date? = nil,
                isStory: Bool = false,
                isPushToTalk: Bool = false,
                sentAt: Date? = nil,
                timestamp: Date = .now,
                id: UUID = UUID()) {
        self.id = id
        self.content = content
        self.isOutbound = isOutbound
        self.isRead = isRead
        self.timestamp = timestamp
        self.wireIDData = wireID.map { Data($0.bytes) }
        self.mediaData = mediaData
        self.mediaMimeRaw = mediaMimeRaw
        self.listenedAt = listenedAt
        self.isStory = isStory
        self.isPushToTalk = isPushToTalk
        self.sentAt = sentAt
        // Initialize the decomposed fields, then route through the bridge.
        self.deliveryStateRaw = "sent"
        self.relayHops = 0
        self.deliveryState = deliveryState
    }
    
    /// True when this message carries media (photo / voice note) rather than text.
    public var isMedia: Bool { mediaData != nil }
    
    /// The media kind, bridged from `mediaMimeRaw`.
    public var mediaMime: MediaMimeType? {
        get { mediaMimeRaw.flatMap(MediaMimeType.init(rawValue:)) }
        set { mediaMimeRaw = newValue?.rawValue }
    }
    
    /// The wire id as a `MessageID`, if this message has been sent.
    public var wireID: MessageID? {
        guard let wireIDData else { return nil }
        return MessageID(bytes: [UInt8](wireIDData))
    }
    
    /// Bridge to the canonical six-state enum. The associated `hops` of
    /// `.relayed` lives in `relayHops`; all other states leave it 0.
    ///
    /// NOTE: `MessageInbox.reconcileBootOrphans()` enumerates the NON-TERMINAL
    /// raw strings ("sent" / "waitingForRange" / "findingPath") in a store-side
    /// `#Predicate` — a new non-terminal state added to this bridge must be
    /// added to that predicate too, or its orphans become invisible after a
    /// relaunch ("cast" is excluded there deliberately; see that method).
    public var deliveryState: MessageDeliveryState {
        get {
            switch deliveryStateRaw {
            case "waitingForRange": return .waitingForRange
            case "sent":            return .sent
            case "cast":            return .cast
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
            case .cast:            deliveryStateRaw = "cast";            relayHops = 0
            case .findingPath:     deliveryStateRaw = "findingPath";     relayHops = 0
            case .delivered:       deliveryStateRaw = "delivered";       relayHops = 0
            case .relayed(let h):  deliveryStateRaw = "relayed";         relayHops = h
            case .notDelivered:    deliveryStateRaw = "notDelivered";    relayHops = 0
            }
        }
    }
}
