//
//  NostrEvent.swift
//  Core/Nostr
//
//  A NIP-01 Nostr event: the signed JSON object every relay speaks. In 8c this
//  is the vehicle for the NIP-59 seal/gift-wrap that carries our libsignal
//  Envelope over the internet pillar.
//
//  The load-bearing piece is the CANONICAL SERIALIZATION used to compute the
//  event id. NIP-01 fixes it exactly:
//      [0, <pubkey lowercase hex>, <created_at>, <kind>, <tags>, <content>]
//  serialized as compact UTF-8 JSON with NO whitespace and ONLY these escapes:
//      \" \\ \n \r \t \b \f   (every other byte, incl. all unicode, verbatim).
//  Foundation's JSON encoders do NOT match this (slash/unicode escaping), so the
//  serializer here is hand-rolled and KAT-locked. id = sha256(serialization);
//  sig = BIP-340 schnorr over the id (Secp256k1.sign). Wire JSON for the full
//  event object uses Codable — its key order is irrelevant because the id is
//  always recomputed from the canonical form, not from the wire bytes.
//

import Foundation
import CryptoKit

struct NostrEvent: Codable, Equatable {
    let id: String          // 32-byte sha256, lowercase hex
    let pubkey: String      // 32-byte x-only public key, lowercase hex
    let createdAt: Int64    // unix seconds
    let kind: Int
    let tags: [[String]]
    let content: String
    let sig: String         // 64-byte BIP-340 schnorr signature, lowercase hex

    enum CodingKeys: String, CodingKey {
        case id, pubkey
        case createdAt = "created_at"
        case kind, tags, content, sig
    }

    // MARK: - Construction

    /// Build and sign an event from a secret key. Computes pubkey, the canonical
    /// id, and the schnorr signature. Returns nil if the secret is invalid or
    /// any curve op fails.
    static func signed(kind: Int,
                       content: String,
                       tags: [[String]],
                       createdAt: Int64,
                       secretKey: Data) -> NostrEvent? {
        guard let pub = Secp256k1.xOnlyPublicKey(fromSecretKey: secretKey) else { return nil }
        let pubkeyHex = hexEncode(pub)
        let id = computeID(pubkey: pubkeyHex,
                           createdAt: createdAt,
                           kind: kind,
                           tags: tags,
                           content: content)
        guard let idBytes = hexDecode(id),
              let sig = Secp256k1.sign(messageHash32: idBytes, secretKey: secretKey) else {
            return nil
        }
        return NostrEvent(id: id,
                          pubkey: pubkeyHex,
                          createdAt: createdAt,
                          kind: kind,
                          tags: tags,
                          content: content,
                          sig: hexEncode(sig))
    }

    // MARK: - Validation

    /// True iff the id matches the canonical serialization AND the schnorr
    /// signature verifies against the pubkey over that id.
    func isValid() -> Bool {
        let recomputed = NostrEvent.computeID(pubkey: pubkey,
                                              createdAt: createdAt,
                                              kind: kind,
                                              tags: tags,
                                              content: content)
        guard recomputed == id else { return false }
        guard let idBytes = hexDecode(id), idBytes.count == 32,
              let sigBytes = hexDecode(sig), sigBytes.count == 64,
              let pubBytes = hexDecode(pubkey), pubBytes.count == 32 else { return false }
        return Secp256k1.verify(signature64: sigBytes,
                                messageHash32: idBytes,
                                xOnlyPublicKey: pubBytes)
    }

    // MARK: - Canonical id

    /// The lowercase-hex event id: sha256 of the NIP-01 canonical serialization.
    static func computeID(pubkey: String,
                          createdAt: Int64,
                          kind: Int,
                          tags: [[String]],
                          content: String) -> String {
        let serialized = serializeForID(pubkey: pubkey,
                                        createdAt: createdAt,
                                        kind: kind,
                                        tags: tags,
                                        content: content)
        let digest = SHA256.hash(data: Data(serialized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The exact NIP-01 canonical serialization string (UTF-8 source for the id
    /// hash). Exposed for testing against known-answer vectors.
    static func serializeForID(pubkey: String,
                               createdAt: Int64,
                               kind: Int,
                               tags: [[String]],
                               content: String) -> String {
        var s = "[0,\""
        s += pubkey
        s += "\","
        s += String(createdAt)
        s += ","
        s += String(kind)
        s += ","
        s += serializeTags(tags)
        s += ",\""
        s += escape(content)
        s += "\"]"
        return s
    }

    private static func serializeTags(_ tags: [[String]]) -> String {
        var s = "["
        for (i, tag) in tags.enumerated() {
            if i > 0 { s += "," }
            s += "["
            for (j, element) in tag.enumerated() {
                if j > 0 { s += "," }
                s += "\""
                s += escape(element)
                s += "\""
            }
            s += "]"
        }
        s += "]"
        return s
    }

    /// NIP-01 string escaping: only the seven listed control/quote characters
    /// are escaped; everything else (including all multibyte unicode) is emitted
    /// verbatim.
    private static func escape(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.unicodeScalars.count + 8)
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""   // "
            case 0x5C: out += "\\\\"   // \
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: - Timestamp randomization (NIP-59)

    /// A back-dated timestamp for gift-wrap `created_at`: `now` minus a random
    /// offset in [0, maxBackdateSeconds] (NIP-59 suggests up to ~2 days) to blunt
    /// timing correlation on relays. Uses the system CSPRNG.
    static func randomizedTimestamp(now: Int64 = Int64(Date().timeIntervalSince1970),
                                    maxBackdateSeconds: Int64 = 2 * 24 * 60 * 60) -> Int64 {
        guard maxBackdateSeconds > 0 else { return now }
        return now - Int64.random(in: 0...maxBackdateSeconds)
    }
}

// MARK: - Wire JSON

extension NostrEvent {

    /// Encode the full event object to compact wire JSON (relay form / the
    /// payload a seal or gift wrap encrypts).
    func jsonData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try? encoder.encode(self)
    }

    /// Parse a full event object from wire JSON. Does NOT validate; call
    /// `isValid()` afterward.
    init?(jsonData: Data) {
        guard let decoded = try? JSONDecoder().decode(NostrEvent.self, from: jsonData) else {
            return nil
        }
        self = decoded
    }
}

// MARK: - Hex helpers

private func hexEncode(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

private func hexDecode(_ string: String) -> Data? {
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
