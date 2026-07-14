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
// STEP 7c-2 (Closed-Contact remote invite) adds a seventh kind — INVITE ECHO —
// the sealed reply a redeemer sends the initiator after redeeming a remote
// invite (INVITE_7c2.md §5). Remote pairing is the not-in-BLE-range case, so the
// echo rides the RELAYABLE sealed path (not a link-local frame): the redeemer
// establishes a session from the invite's prekey bundle and sends this as its
// first sealed message, over Nostr. The body is the bare 16-byte invite id — and
// ONLY that. The redeemer's identity is NOT in the body; the receiver takes it
// from the X3DH-authenticated session, so it cannot be self-asserted. Opening it,
// the initiator burns the invite single-use and enrolls the redeemer (unverified,
// pending the SAS). It is a SMALL padded kind, so it is wire-indistinguishable
// from a short text / ack / hello.
//
// SIZE NOTE: for a media chunk the body is already sized (via MediaChunker's
// `reservedBytes`) so that tag + chunk together still fill one PayloadBucket
// tier exactly — the tag costs no extra padding. For text, manifests, acks, and
// the nostr-identity announcement the body is far under a tier, so the tag is
// free there too.
//
// PADDING (Phase 9b): `sealedPlaintext()` is the bytes that actually get sealed.
// It pads the SMALL kinds (text / ack / nostrIdentity / reconnectHello /
// inviteEcho) up to a fixed `PayloadBucket` size via `PayloadPadding`, so their
// ciphertext length no longer leaks message length (THREAT_MODEL.md §7). MEDIA is
// exempt: a manifest or chunk is already bucket-shaped by MediaChunker, so padding
// it would only add a length header and spill it into the next tier.
// `decodeSealed(_:)` is the exact inverse on the receive side. NOTE: this changes
// the sealed-plaintext wire format — both peers must run a 9b-or-later build for
// text/ack/nostr to decode (media is unaffected). Sessions are untouched (padding
// is inside the seal, not the ratchet), so no re-handshake is needed.
//

import Foundation
import Security   // SecRandomCopyBytes (pttID CSPRNG mint)

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
    case inviteEcho    = 7   // remote-invite echo: 16-byte invite id
    case callRequest   = 8   // call signaling: callID(16) ‖ complete SDP offer
    case callAnswer    = 9   // call signaling: callID(16) ‖ complete SDP answer
    case callDecline   = 10  // call signaling: callID(16) — decline / cancel-before-connect
    case inviteEchoV2  = 11  // remote-invite echo v2: inviteID(16) ‖ redeemer npub(32)
    case pttOpen       = 12  // PTT session open: pttID(16) ‖ S(32) — 32-byte session-secret handover
    case pttClose      = 13  // PTT session close: pttID(16)
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
    case inviteEcho(Data)      // remote-invite echo body: invite id (16 bytes)
    case callRequest(Data)     // call signaling body: callID(16) ‖ SDP offer
    case callAnswer(Data)      // call signaling body: callID(16) ‖ SDP answer
    case callDecline(Data)     // call signaling body: callID(16)
    case inviteEchoV2(Data)    // remote-invite echo v2: inviteID(16) ‖ npub(32)
    case pttOpen(Data)         // PTT open: pttID(16) ‖ S(32) — session-secret handover
    case pttClose(Data)        // PTT close: pttID(16)

    public var kind: WirePayloadKind {
        switch self {
        case .text:          return .text
        case .mediaManifest: return .mediaManifest
        case .mediaChunk:    return .mediaChunk
        case .ack:           return .ack
        case .nostrIdentity: return .nostrIdentity
        case .reconnectHello: return .reconnectHello
        case .inviteEcho:    return .inviteEcho
        case .callRequest:   return .callRequest
        case .callAnswer:    return .callAnswer
        case .callDecline:   return .callDecline
        case .inviteEchoV2:  return .inviteEchoV2
        case .pttOpen:       return .pttOpen
        case .pttClose:      return .pttClose
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
             .reconnectHello(let d),
             .inviteEcho(let d),
             .callRequest(let d),
             .callAnswer(let d),
             .callDecline(let d),
             .inviteEchoV2(let d),
             .pttOpen(let d),
             .pttClose(let d):
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
    /// (text / ack / nostrIdentity / reconnectHello / inviteEcho) this pads
    /// `encoded()` up to a fixed `PayloadBucket` size so the sealed ciphertext
    /// length no longer leaks the message length. MEDIA (`mediaManifest` /
    /// `mediaChunk`) is returned as plain `encoded()`: MediaChunker already sizes
    /// each chunk to fill a bucket tier exactly, so padding it here would add a
    /// length header and spill it into the next (4×-larger) tier. The inverse is
    /// `decodeSealed(_:)`.
    public func sealedPlaintext() -> Data {
        switch self {
        case .mediaManifest, .mediaChunk:
            return encoded()                        // already bucket-shaped
        case .text, .ack, .nostrIdentity, .reconnectHello, .inviteEcho,
             .inviteEchoV2, .callRequest, .callAnswer, .callDecline,
             .pttOpen, .pttClose:
            return PayloadPadding.pad(encoded())    // collapse length to a bucket
        }
    }

    /// Parse an opened plaintext back into a tagged payload. Returns nil on an
    /// empty buffer or an unknown tag (a forward-compat guard: a future kind
    /// from a newer peer is ignored rather than misread).
    ///
    /// This is intentionally permissive about body LENGTH — it splits tag from
    /// body and nothing more. Per-kind body validation (e.g. the ack's fixed
    /// 17 bytes, the nostr-identity's 32 bytes, or the invite-echo's 16 bytes)
    /// lives in the dedicated parsers below, which run on the untrusted receive
    /// path.
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
        case .inviteEcho:    return .inviteEcho(body)
        case .callRequest:   return .callRequest(body)
        case .callAnswer:    return .callAnswer(body)
        case .callDecline:   return .callDecline(body)
        case .inviteEchoV2:  return .inviteEchoV2(body)
        // pttOpen/pttClose are the ONE deviation from this switch's otherwise
        // length-permissive contract: a `.pttOpen` carries the raw 32-byte session
        // secret S, so a malformed handover is rejected at the EARLIEST boundary
        // (reject bodies ≠ 48 / 16) rather than deferred to a parser. parsePTTOpen /
        // parsePTTClose re-check and split the fields.
        case .pttOpen:
            guard body.count == pttOpenBodyByteCount else { return nil }
            return .pttOpen(body)
        case .pttClose:
            guard body.count == pttIDByteCount else { return nil }
            return .pttClose(body)
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

// MARK: - Invite echo body  (STEP 7c-2 — Closed-Contact remote invite)

public extension MessagePayload {

    /// Byte length of an invite id — the entire body of an `.inviteEcho`. Matches
    /// `Invite.idByteCount` (16).
    static var inviteEchoIDByteCount: Int { 16 }

    /// Build an invite-echo payload carrying the redeemed invite's 16-byte id.
    ///
    /// The body is the bare id — and ONLY the id. The redeemer's identity is
    /// deliberately NOT carried here: on the receive side the initiator takes it
    /// from the X3DH-authenticated session (INVITE_7c2.md §5), so it cannot be
    /// self-asserted by the sender. Named distinctly from the `.inviteEcho` case
    /// (cf. `deliveryAck` vs `.ack`) so call sites read intent.
    ///
    /// EMIT (7d): the redeemer builds this after establishing a session from the
    /// invite's prekey bundle, and sends it as its first sealed message over the
    /// relay — driven by the redeem action, which holds the invite id.
    static func inviteEchoV1(inviteID: Data) -> MessagePayload {
        .inviteEcho(inviteID)
    }

    /// Parse an `.inviteEcho` body back into the 16-byte invite id. Returns nil
    /// unless the body is exactly 16 bytes — the strict, untrusted-input boundary,
    /// like `parseNostrIdentity`; `decode` deliberately does not length-check.
    static func parseInviteEcho(_ body: Data) -> Data? {
        guard body.count == inviteEchoIDByteCount else { return nil }
        return body
    }

    // MARK: - Invite echo v2  (npub-bootstrap over pure Nostr)

    /// Byte length of an `.inviteEchoV2` body: inviteID(16) ‖ redeemer npub(32).
    /// The npub rides the echo because a PURE-NOSTR pair has no BLE rail for the
    /// lazy `announceNostrIdentity` — without it the minter can never address
    /// the redeemer over the relay. V1 (id-only, tag 7) remains the form a
    /// redeemer with no Nostr identity seals, and stays decodable forever.
    static var inviteEchoV2ByteCount: Int { inviteEchoIDByteCount + nostrPubkeyByteCount }

    /// Build a v2 invite-echo: the burned invite id plus OUR x-only npub, so
    /// the minter learns the redeemer's Nostr address at echo-receipt.
    static func inviteEchoV2(inviteID: Data, redeemerNostrPubkey: Data) -> MessagePayload {
        .inviteEchoV2(inviteID + redeemerNostrPubkey)
    }

    /// Parse an `.inviteEchoV2` body back into its halves. Returns nil unless
    /// the body is EXACTLY 48 bytes — same strict untrusted-input discipline as
    /// `parseInviteEcho` / `parseNostrIdentity`; `decode` does not length-check.
    static func parseInviteEchoV2(_ body: Data)
        -> (inviteID: Data, redeemerNostrPubkey: Data)? {
        guard body.count == inviteEchoV2ByteCount else { return nil }
        return (Data(body.prefix(inviteEchoIDByteCount)),
                Data(body.suffix(nostrPubkeyByteCount)))
    }
}

// MARK: - PTT handshake body  (PTT Part A — open/close + session-secret S handover)

public extension MessagePayload {

    /// Byte length of a PTT session id — 16 CSPRNG bytes, the SAME 16-byte shape as
    /// `CallSignal.callID` / a mediaID, minted fresh per PTT session by the
    /// initiator and carried in both the `.pttOpen` and its matching `.pttClose`.
    static var pttIDByteCount: Int { 16 }

    /// Byte length of the session secret S handed over in a `.pttOpen`. 32 bytes —
    /// the input keying material for `PTTSessionCrypto.directionalKeys`.
    static var pttSecretByteCount: Int { PTTSessionCrypto.keyByteCount }

    /// Byte length of a `.pttOpen` body: pttID(16) ‖ S(32) = 48.
    static var pttOpenBodyByteCount: Int { pttIDByteCount + pttSecretByteCount }

    /// Mint a fresh 16-byte PTT session id (CSPRNG) — same pattern as the caller's
    /// callID mint (`SecRandomCopyBytes`, `CallSignal.callIDByteCount`).
    static func newPTTID() -> Data {
        var bytes = [UInt8](repeating: 0, count: pttIDByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "CSPRNG (SecRandomCopyBytes) failed")
        return Data(bytes)
    }

    /// Build a `.pttOpen`: the session-secret handover. Body = pttID(16) ‖ S(32).
    ///
    /// SECURITY: `secret` is the raw 32-byte session secret S. This payload is
    /// sealed under the existing VERIFIED Signal session (the ONLY path S ever
    /// travels — never the link-local reconnect route) and S is NEVER logged.
    /// Named distinctly from the `.pttOpen` case (cf. `deliveryAck` vs `.ack`) so
    /// call sites read intent without colliding with the case label.
    static func pttOpenV1(pttID: Data, secret: Data) -> MessagePayload {
        .pttOpen(pttID + secret)
    }

    /// Build a `.pttClose` carrying the SAME pttID as its `.pttOpen`. Body = pttID(16).
    static func pttCloseV1(pttID: Data) -> MessagePayload {
        .pttClose(pttID)
    }

    /// Parse a `.pttOpen` body into `(pttID, S)`. Returns nil unless EXACTLY 48
    /// bytes. Unlike the other kinds here, `decode()` ALSO length-checks pttOpen
    /// (S is security-critical), but this parser re-checks and is what SPLITS the
    /// two fields. S is returned as raw `Data` — the crypto layer wraps it in a
    /// `SymmetricKey` for `PTTSessionCrypto.directionalKeys`.
    static func parsePTTOpen(_ body: Data) -> (pttID: Data, secret: Data)? {
        guard body.count == pttOpenBodyByteCount else { return nil }
        return (Data(body.prefix(pttIDByteCount)),
                Data(body.suffix(pttSecretByteCount)))
    }

    /// Parse a `.pttClose` body into its pttID. Returns nil unless EXACTLY 16 bytes.
    static func parsePTTClose(_ body: Data) -> Data? {
        guard body.count == pttIDByteCount else { return nil }
        return body
    }
}
