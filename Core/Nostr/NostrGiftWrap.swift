//
//  NostrGiftWrap.swift
//  Core/Nostr
//
//  NIP-59 gift wrap (Option A, LOCKED) — the metadata-protecting envelope that
//  carries our already-sealed libsignal `Envelope` over the Nostr pillar.
//
//  THREE LAYERS (outbound):
//    rumor  — UNSIGNED event (kind 20059, app-private) whose content is the
//             base64 of Envelope.wireData(). Never leaves clear; it is encrypted
//             into the seal.
//    seal   — kind 13 event, content = NIP-44(ourSecret -> peer) over the rumor
//             JSON, SIGNED BY OUR REAL KEY. Binds the rumor to us; only the peer
//             can open it.
//    wrap   — kind 1059 event, content = NIP-44(EPHEMERAL -> peer) over the seal
//             JSON, SIGNED BY A FRESH EPHEMERAL KEY, created_at randomized,
//             tagged ["p", peer]. The outer event carries NO link to our npub.
//
//  Unwrap reverses it and re-binds authenticity: the seal must be signed by the
//  same pubkey that authored the rumor, or the sender is not trusted. The
//  recovered bytes feed straight back into `Envelope(wire:)` — byte-identical to
//  what the mesh would deliver — so the Security layer opens it unchanged. That
//  identical-Envelope property is the whole point of the transport seam.
//
//  A single gift wrap carries ONE Envelope (one mesh-sized chunk); even the
//  largest payload bucket stays well under NIP-44's 65535-byte plaintext limit
//  after base64 + JSON, so no chunking is needed at this layer.
//

import Foundation
import Security

enum NostrGiftWrapError: Error, Equatable {
    case curveFailed
    case ephemeralKeyGenerationFailed
    case serializationFailed
    case wrongKind
    case invalidSignature
    case malformedInnerEvent
    case senderBindingFailed
    case malformedEnvelope
}

enum NostrGiftWrap {

    /// App-private rumor kind carrying a Beacon Envelope (distinct from NIP-17
    /// chat kind 14, so our traffic is internally distinguishable and carries no
    /// implied chat semantics).
    static let rumorKind = 20059
    static let sealKind = 13
    static let wrapKind = 1059

    // MARK: - Wrap

    /// Build the outer gift-wrap event for `envelope`, addressed to
    /// `peerPublicKey` (32-byte x-only), signed by a fresh ephemeral key. Ready
    /// to publish to a relay. Our real key never appears in the outer event.
    static func wrap(envelope: Envelope,
                     senderSecret: Data,
                     peerPublicKey: Data,
                     now: Int64 = Int64(Date().timeIntervalSince1970)) throws -> NostrEvent {

        guard let senderPub = Secp256k1.xOnlyPublicKey(fromSecretKey: senderSecret) else {
            throw NostrGiftWrapError.curveFailed
        }
        let senderPubHex = hex(senderPub)
        let peerPubHex = hex(peerPublicKey)

        // 1) Rumor — unsigned, content = base64(Envelope.wireData()). Its
        //    created_at is hidden (encrypted), so it can be the real time.
        let rumorContent = envelope.wireData().base64EncodedString()
        let rumorID = NostrEvent.computeID(pubkey: senderPubHex,
                                           createdAt: now,
                                           kind: rumorKind,
                                           tags: [],
                                           content: rumorContent)
        let rumor = NostrEvent(id: rumorID,
                               pubkey: senderPubHex,
                               createdAt: now,
                               kind: rumorKind,
                               tags: [],
                               content: rumorContent,
                               sig: "")
        guard let rumorJSON = rumor.jsonData().flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw NostrGiftWrapError.serializationFailed
        }

        // 2) Seal — NIP-44(our secret -> peer), signed by our real key.
        let sealKey = try NIP44.conversationKey(mySecret: senderSecret, peerPublicKey: peerPublicKey)
        let sealContent = try NIP44.encrypt(plaintext: rumorJSON, conversationKey: sealKey)
        guard let seal = NostrEvent.signed(kind: sealKind,
                                           content: sealContent,
                                           tags: [],
                                           createdAt: NostrEvent.randomizedTimestamp(now: now),
                                           secretKey: senderSecret) else {
            throw NostrGiftWrapError.curveFailed
        }
        guard let sealJSON = seal.jsonData().flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw NostrGiftWrapError.serializationFailed
        }

        // 3) Gift wrap — fresh ephemeral key, NIP-44(ephemeral -> peer), p-tag.
        guard let ephemeralSecret = randomScalar() else {
            throw NostrGiftWrapError.ephemeralKeyGenerationFailed
        }
        let wrapKey = try NIP44.conversationKey(mySecret: ephemeralSecret, peerPublicKey: peerPublicKey)
        let wrapContent = try NIP44.encrypt(plaintext: sealJSON, conversationKey: wrapKey)
        guard let giftWrap = NostrEvent.signed(kind: wrapKind,
                                               content: wrapContent,
                                               tags: [["p", peerPubHex]],
                                               createdAt: NostrEvent.randomizedTimestamp(now: now),
                                               secretKey: ephemeralSecret) else {
            throw NostrGiftWrapError.curveFailed
        }
        return giftWrap
    }

    // MARK: - Unwrap

    /// Open an inbound gift wrap addressed to us. Returns the sealed Envelope and
    /// the authenticated sender's x-only public key. Throws if any layer fails
    /// verification or the sender binding (seal author != rumor author).
    static func unwrap(giftWrap: NostrEvent,
                       mySecret: Data) throws -> (envelope: Envelope, senderPublicKey: Data) {

        guard giftWrap.kind == wrapKind else { throw NostrGiftWrapError.wrongKind }
        guard giftWrap.isValid() else { throw NostrGiftWrapError.invalidSignature }
        guard let wrapPub = hexDecode(giftWrap.pubkey), wrapPub.count == 32 else {
            throw NostrGiftWrapError.malformedInnerEvent
        }

        // Outer -> seal
        let wrapKey = try NIP44.conversationKey(mySecret: mySecret, peerPublicKey: wrapPub)
        let sealJSON = try NIP44.decrypt(payload: giftWrap.content, conversationKey: wrapKey)
        guard let seal = NostrEvent(jsonData: Data(sealJSON.utf8)),
              seal.kind == sealKind else {
            throw NostrGiftWrapError.malformedInnerEvent
        }
        guard seal.isValid() else { throw NostrGiftWrapError.invalidSignature }
        guard let sealPub = hexDecode(seal.pubkey), sealPub.count == 32 else {
            throw NostrGiftWrapError.malformedInnerEvent
        }

        // Seal -> rumor
        let sealKey = try NIP44.conversationKey(mySecret: mySecret, peerPublicKey: sealPub)
        let rumorJSON = try NIP44.decrypt(payload: seal.content, conversationKey: sealKey)
        guard let rumor = NostrEvent(jsonData: Data(rumorJSON.utf8)),
              rumor.kind == rumorKind else {
            throw NostrGiftWrapError.malformedInnerEvent
        }

        // Sender binding: the seal MUST be signed by the rumor's author, else a
        // relay/MITM could re-wrap someone else's rumor under their own seal.
        guard rumor.pubkey == seal.pubkey else { throw NostrGiftWrapError.senderBindingFailed }

        // Rumor content -> Envelope
        guard let wireBytes = Data(base64Encoded: rumor.content),
              let envelope = Envelope(wire: wireBytes) else {
            throw NostrGiftWrapError.malformedEnvelope
        }
        return (envelope, sealPub)
    }

    // MARK: - Ephemeral key

    /// A fresh, curve-valid 32-byte scalar for the gift-wrap's one-time outer
    /// key. Rejection-samples using the same validity rule as the identity key.
    private static func randomScalar() -> Data? {
        for _ in 0..<8 {
            var raw = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, 32, &raw) == errSecSuccess else { return nil }
            if NostrIdentity.isValidScalar(raw) { return Data(raw) }
        }
        return nil
    }

    // MARK: - Hex

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func hexDecode(_ string: String) -> Data? {
        guard string.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}
