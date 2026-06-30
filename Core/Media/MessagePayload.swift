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
// Phase 8d-0 adds a fifth kind — NOSTR IDENTITY — a tiny sealed announcement
// that hands a peer our raw 32-byte x-only secp256k1 public key. It is the
// npub-bootstrap (LOCKED): a peer's Nostr pubkey is NOT embedded in the
// libsignal PrekeyBundle; instead it is sent as its own payload over the
// already-established sealed channel, exactly like an ack. Once a peer's pubkey
// is learned this way, the router can address Nostr gift wraps to them. The
// body is the bare 32-byte x-only key — the same `Data` the crypto layer
// (`Secp256k1.ecdh`, `NIP44.conversationKey`, `NostrGiftWrap.wrap`) consumes
// directly — so no bech32 round-trip is needed on the wire.
//
// Phase 5d (Closed-Contact) adds a sixth kind — RECONNECT HELLO — the sealed
// "it's-me" of the reconnection auth handshake (RECONNECT_AUTH_WIRING_5d.md
// §2.2). After the cheap, replayable beacon layer NAMES which contact is on a
// fresh BLE link, the recognizer seals exactly one `.reconnectHello` under that
// contact's existing session and sends it link-local (never relayed). Opening
// it authenticates the peer (a stranger holds no session and produces nothing
// `openInbound` opens; a replay's message key is already spent), and that — not
// the beacon — is what admits the link. The body is a single 1-byte version tag
// (0x01): the content is irrelevant to auth, the ratchet does the work; the tag
// is cheap future-proofing. It is one of the SMALL padded kinds below, so 9b
// pads it to the smallest bucket and it is byte-indistinguishable on the wire
// from any short `.whisper` (e.g. a one-word text or an ack).
//
// SIZE NOTE: for a media chunk the body is already sized (via MediaChunker's
// `reservedBytes`) so that tag + chunk together still fill one PayloadBucket
// tier exactly — the tag costs no extra padding. For text, manifests, acks, and
// the nostr-identity announcement the body is far under a tier, so the tag is
// free there too.
//
// PADDING (Phase 9b): `sealedPlaintext()` is the bytes that actually get sealed.
// It pads the SMALL kinds (text / ack / nostrIdentity) up to a fixed
// `PayloadBucket` size via `PayloadPadding`, so their ciphertext length no
// longer leaks message length (THREAT_MODEL.md §7). MEDIA is exempt: a manifest
// or chunk is already bucket-shaped by MediaChunker, so padding it would only
// add a length header and spill it into the next tier. `decodeSealed(_:)` is the
// exact inverse on the receive side. NOTE: this changes the sealed-plaintext
// wire format — both peers must run a 9b-or-later build for text/ack/nostr to
// decode (media is unaffected). Sessions are untouched (padding is inside the
// seal, not the ratchet), so no re-handshake is needed.
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
    case nostrIdentity = 5   // npub bootstrap: 32-byte x-only secp256k1 pubkey
    case reconnectHello = 6  // closed-contact auth it's-me: 1-byte version tag
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
    case nostrIdentity(Data)   // npub bootstrap body: x-only pubkey (32 bytes)
    case reconnectHello(Data)  // closed-contact auth it's-me body: version(1)

    public var kind: WirePayloadKind {
        switch self {
        case .text:          return .text
        case .mediaManifest: return .mediaManifest
        case .mediaChunk:    return .mediaChunk
        case .ack:           return .ack
        case .nostrIdentity: return .nostrIdentity
        case .reconnectHello: return .reconnectHello
        }
    }

    /// The untagged body bytes.
    public var body: Data {
        switch self {
        case .text(let d),
             .mediaManifest(let d),
             .mediaChunk(let d),
             .ack(let d),
             .nostrIdentity(let d),
             .reconnectHello(let d):
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

    /// The exact bytes to hand to `session.seal` (Phase 9b). For the small kinds
    /// (text / ack / nostrIdentity) this pads `encoded()` up to a fixed
    /// `PayloadBucket` size so the sealed ciphertext length no longer leaks the
    /// message length. MEDIA (`mediaManifest` / `mediaChunk`) is returned as
    /// plain `encoded()`: MediaChunker already sizes each chunk to fill a bucket
    /// tier exactly, so padding it here would add a length header and spill it
    /// into the next (4×-larger) tier. The inverse is `decodeSealed(_:)`.
    public func sealedPlaintext() -> Data {
        switch self {
        case .mediaManifest, .mediaChunk:
            return encoded()                        // already bucket-shaped
        case .text, .ack, .nostrIdentity, .reconnectHello:
            return PayloadPadding.pad(encoded())    // collapse length to a bucket
        }
    }

    /// Parse an opened plaintext back into a tagged payload. Returns nil on an
    /// empty buffer or an unknown tag (a forward-compat guard: a future kind
    /// from a newer peer is ignored rather than misread).
    ///
    /// This is intentionally permissive about body LENGTH — it splits tag from
    /// body and nothing more. Per-kind body validation (e.g. the ack's fixed
    /// 17 bytes, or the nostr-identity's 32 bytes) lives in the dedicated
    /// parsers below, which run on the untrusted receive path.
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
        case .nostrIdentity: return .nostrIdentity(body)
        case .reconnectHello: return .reconnectHello(body)
        }
    }

    /// Inverse of `sealedPlaintext()` (Phase 9b): decode a plaintext that a
    /// 9b-or-later sender produced. Media kinds are unpadded — they are decoded
    /// directly; every other kind is `PayloadPadding`-wrapped and is unpadded
    /// first.
    ///
    /// Disambiguation is by the leading byte. A media payload starts with its
    /// kind tag — `mediaManifest` (2) or `mediaChunk` (3). A padded payload
    /// starts with the `PayloadPadding` length header's high byte, which is
    /// `0x00` for any realistic message size and therefore never 2 or 3. So a
    /// leading 2/3 means "media, decode as-is"; anything else means "unpad, then
    /// decode". A buffer whose length header runs past its end (e.g. an
    /// unpadded text from a pre-9b peer) fails `unpad` and returns nil, which the
    /// caller treats as an undecodable payload.
    public static func decodeSealed(_ plaintext: Data) -> MessagePayload? {
        if let first = plaintext.first,
           first == WirePayloadKind.mediaManifest.rawValue ||
           first == WirePayloadKind.mediaChunk.rawValue {
            return decode(plaintext)
        }
        guard let unpadded = PayloadPadding.unpad(plaintext) else { return nil }
        return decode(unpadded)
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

// MARK: - Nostr identity bootstrap body  (Phase 8d-0)

public extension MessagePayload {

    /// Byte length of a raw x-only secp256k1 public key — the entire body of a
    /// `.nostrIdentity` announcement. (NIP keys are 32-byte x-only.)
    static var nostrPubkeyByteCount: Int { 32 }

    /// Build a Nostr-identity bootstrap payload carrying our raw 32-byte x-only
    /// secp256k1 public key (e.g. `NostrIdentity.publicKeyBytes`). The body is
    /// the bare key — no bech32, no extra framing — because that is exactly the
    /// `Data` the crypto layer consumes when addressing a gift wrap.
    ///
    /// Named distinctly from the `.nostrIdentity` case (cf. `deliveryAck` vs
    /// `.ack`) so call sites read intent without colliding with the case label.
    static func nostrIdentityAnnounce(pubkey: Data) -> MessagePayload {
        .nostrIdentity(pubkey)
    }

    /// Parse a `.nostrIdentity` body back into the raw 32-byte x-only pubkey.
    /// Returns nil unless the body is exactly 32 bytes — the caller ignores a
    /// malformed announcement. This is the strict, untrusted-input boundary;
    /// `decode` deliberately does not length-check.
    static func parseNostrIdentity(_ body: Data) -> Data? {
        guard body.count == nostrPubkeyByteCount else { return nil }
        return body
    }
}

// MARK: - Reconnect hello body  (Phase 5d — Closed-Contact)

public extension MessagePayload {

    /// The current reconnect-hello version tag. The body of a `.reconnectHello`
    /// is exactly this one byte. Content is irrelevant to authentication — the
    /// ratchet does the work (RECONNECT_AUTH_WIRING_5d.md §2.2) — so the body is
    /// purely a version discriminator: cheap future-proofing for a later
    /// handshake revision. Bumping this is a wire-version change; add a
    /// `reconnectHelloV2()` builder rather than mutating call sites by hand.
    static var reconnectHelloVersion: UInt8 { 0x01 }

    /// Build the v1 reconnect-hello it's-me — the sealed authentication frame of
    /// the closed-contact reconnection handshake. Named distinctly from the
    /// `.reconnectHello` case (cf. `deliveryAck` vs `.ack`) so call sites read
    /// intent without colliding with the case label.
    ///
    /// The caller seals this under the recognized contact's existing session and
    /// sends it link-local via the 0x03 reconnect frame; opening it is what
    /// admits the link (Invariant #2 — never admit on a beacon match alone).
    static func reconnectHelloV1() -> MessagePayload {
        .reconnectHello(Data([reconnectHelloVersion]))
    }

    /// Parse a `.reconnectHello` body back into its version byte. Returns nil
    /// unless the body is exactly one byte — the strict, untrusted-input
    /// boundary, like `parseNostrIdentity`; `decode` deliberately does not
    /// length-check. A returned version the caller does not recognize is treated
    /// as an undecodable hello (forward-compat: reject, don't misread).
    static func parseReconnectHello(_ body: Data) -> UInt8? {
        guard body.count == 1 else { return nil }
        return body[body.startIndex]
    }
}
