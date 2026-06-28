// MessagePayload.swift
// Core/Media
//
// The 1-byte type tag that prefixes every sealed plaintext.
//
// WHY THIS EXISTS: until media, every sealed Envelope's plaintext was raw UTF-8
// text, and the receiver could assume so. With photos and voice notes, an
// opened plaintext can be one of three things — a text message, a media
// MANIFEST (announcing an incoming blob), or a media CHUNK (one slice of it).
// They all travel the identical path (sealed → Envelope → mesh → opened), so
// the receiver needs one cheap, unambiguous way to tell them apart the instant
// it opens an envelope. That is this tag: a single leading byte, then the body.
//
// Phase 7b.2b adds a fourth kind — ACK — a tiny sealed delivery receipt the
// receiver sends back when it opens a data message. It rides the same sealed
// path (opaque to relays, forward-secret), and its body is a fixed 17 bytes:
// the acked message's 16-byte wire id followed by a 1-byte hop count.
//
// SIZE NOTE: for a media chunk the body is already sized (via MediaChunker's
// `reservedBytes`) so that tag + chunk together still fill one PayloadBucket
// tier exactly — the tag costs no extra padding. For text, manifests, and acks
// the body is far under a tier, so the tag is free there too.
//

import Foundation

// MARK: - WirePayloadKind

/// The kind of thing a sealed plaintext carries. Raw values are the on-wire tag
/// byte; never renumber these without a wire-version bump.
public enum WirePayloadKind: UInt8, Sendable, CaseIterable {
    case text          = 1
    case mediaManifest = 2
    case mediaChunk    = 3
    case ack           = 4   // delivery receipt: 16-byte wireID ‖ 1-byte hops
}

// MARK: - MessagePayload

/// A tagged plaintext: `[kind byte] ‖ body`. Sealed as a unit; the receiver
/// decodes the tag to route the body. Carrier-neutral — nothing here knows
/// about BLE, the internet, or the ratchet.
public enum MessagePayload: Sendable, Equatable {
    case text(Data)            // UTF-8 message text
    case mediaManifest(Data)   // JSON-encoded MediaManifest
    case mediaChunk(Data)      // one MediaChunker chunk (its own header inside)
    case ack(Data)             // delivery receipt body: wireID(16) ‖ hops(1)

    public var kind: WirePayloadKind {
        switch self {
        case .text:          return .text
        case .mediaManifest: return .mediaManifest
        case .mediaChunk:    return .mediaChunk
        case .ack:           return .ack
        }
    }

    /// The untagged body bytes.
    public var body: Data {
        switch self {
        case .text(let d), .mediaManifest(let d), .mediaChunk(let d), .ack(let d):
            return d
        }
    }

    /// Serialize to `[kind] ‖ body` for sealing.
    public func encoded() -> Data {
        var out = Data(capacity: 1 + body.count)
        out.append(kind.rawValue)
        out.append(body)
        return out
    }

    /// Parse an opened plaintext back into a tagged payload. Returns nil on an
    /// empty buffer or an unknown tag (a forward-compat guard: a future kind
    /// from a newer peer is ignored rather than misread).
    public static func decode(_ data: Data) -> MessagePayload? {
        guard let tag = data.first, let kind = WirePayloadKind(rawValue: tag) else {
            return nil
        }
        let body = Data(data.dropFirst())
        switch kind {
        case .text:          return .text(body)
        case .mediaManifest: return .mediaManifest(body)
        case .mediaChunk:    return .mediaChunk(body)
        case .ack:           return .ack(body)
        }
    }
}

// MARK: - Delivery ack body  (Phase 7b.2b)

public extension MessagePayload {

    /// Build a delivery-receipt payload for `wireID`, stamped with the hop count
    /// the acked message travelled (0 = direct, ≥1 = relayed). The body is the
    /// fixed layout `wireID.bytes (16) ‖ hops (1)`.
    static func deliveryAck(wireID: MessageID, hops: UInt8) -> MessagePayload {
        var b = Data(capacity: MessageID.byteCount + 1)
        b.append(contentsOf: wireID.bytes)
        b.append(hops)
        return .ack(b)
    }

    /// Parse an `.ack` body back into `(wireID, hops)`. Returns nil on the wrong
    /// length or a malformed id — the caller ignores a malformed receipt.
    static func parseDeliveryAck(_ body: Data) -> (wireID: MessageID, hops: UInt8)? {
        guard body.count == MessageID.byteCount + 1 else { return nil }
        let bytes = [UInt8](body)
        guard let id = MessageID(bytes: Array(bytes[0..<MessageID.byteCount])) else {
            return nil
        }
        return (id, bytes[MessageID.byteCount])
    }
}
