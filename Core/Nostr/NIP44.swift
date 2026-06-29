//
//  NIP44.swift
//  Core/Nostr
//
//  NIP-44 v2 payload encryption — the wire encryption Nostr uses for sealed
//  events (and, in 8c, for our gift-wrapped libsignal Envelope).
//
//  Scheme (v2):
//    conversation_key = HKDF-extract(salt = "nip44-v2", IKM = ecdh_shared_x)
//    message keys     = HKDF-expand(conversation_key, info = nonce, 76 bytes)
//                       -> chacha_key(32) || chacha_nonce(12) || hmac_key(32)
//    ciphertext       = ChaCha20(chacha_key, chacha_nonce, pad(plaintext))
//    mac              = HMAC-SHA256(hmac_key, nonce || ciphertext)
//    payload          = base64( 0x02 || nonce(32) || ciphertext || mac(32) )
//
//  Building blocks live elsewhere and stay behind their own surfaces:
//   - ecdh shared X  -> Secp256k1.ecdh (8c-i-0)
//   - ChaCha20       -> ChaCha20 (8c-i-1)
//   - HKDF / HMAC    -> CryptoKit (HMAC<SHA256>)
//
//  The 32-byte `nonce` here is the NIP-44 per-message nonce that seeds the key
//  expansion and rides in the payload. It is NOT the 12-byte ChaCha nonce,
//  which is derived. Decryption verifies the MAC (constant-time) BEFORE touching
//  the ciphertext, and validates the padding length against the canonical
//  padded size.
//

import Foundation
import Security
import CryptoKit

enum NIP44Error: Error, Equatable {
    case invalidConversationKey
    case invalidPlaintextLength      // plaintext must be 1...65535 bytes
    case randomGenerationFailed
    case invalidPayload              // base64 / length / version
    case invalidMAC                  // authentication failed
    case invalidPadding
    case curveFailed
}

enum NIP44 {

    static let version: UInt8 = 2
    private static let salt = Data("nip44-v2".utf8)

    // MARK: - Conversation key

    /// Derive the long-lived per-peer conversation key from our 32-byte secret
    /// and the peer's 32-byte x-only public key. Cacheable per peer.
    static func conversationKey(mySecret: Data, peerPublicKey: Data) throws -> Data {
        guard let sharedX = Secp256k1.ecdh(secretKey: mySecret,
                                           peerXOnlyPublicKey: peerPublicKey) else {
            throw NIP44Error.curveFailed
        }
        return hkdfExtract(salt: salt, ikm: sharedX)   // 32 bytes
    }

    // MARK: - Encrypt / decrypt

    /// Encrypt `plaintext` (1...65535 UTF-8 bytes) under `conversationKey`.
    /// `nonce` is the 32-byte per-message nonce; pass nil to draw a fresh one
    /// (production), or an explicit value to reproduce a known-answer vector.
    static func encrypt(plaintext: String,
                        conversationKey: Data,
                        nonce: Data? = nil) throws -> String {
        guard conversationKey.count == 32 else { throw NIP44Error.invalidConversationKey }

        let plaintextBytes = Data(plaintext.utf8)
        guard plaintextBytes.count >= 1, plaintextBytes.count <= 65535 else {
            throw NIP44Error.invalidPlaintextLength
        }

        let nonceData: Data
        if let nonce {
            guard nonce.count == 32 else { throw NIP44Error.invalidPayload }
            nonceData = nonce
        } else {
            var raw = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, 32, &raw) == errSecSuccess else {
                throw NIP44Error.randomGenerationFailed
            }
            nonceData = Data(raw)
        }

        let (chachaKey, chachaNonce, hmacKey) = messageKeys(conversationKey: conversationKey,
                                                            nonce: nonceData)
        let padded = pad(plaintextBytes)
        guard let ciphertext = ChaCha20.xor(padded, key: chachaKey, nonce: chachaNonce) else {
            throw NIP44Error.curveFailed
        }
        let mac = hmacSHA256(key: hmacKey, message: nonceData + ciphertext)

        var payload = Data([version])
        payload.append(nonceData)
        payload.append(ciphertext)
        payload.append(mac)
        return payload.base64EncodedString()
    }

    /// Decrypt a base64 NIP-44 v2 payload under `conversationKey`. Throws
    /// `.invalidMAC` on authentication failure (tamper/wrong key), and other
    /// `NIP44Error` cases on malformed input.
    static func decrypt(payload: String, conversationKey: Data) throws -> String {
        guard conversationKey.count == 32 else { throw NIP44Error.invalidConversationKey }
        guard let data = Data(base64Encoded: payload) else { throw NIP44Error.invalidPayload }

        let bytes = [UInt8](data)
        // version(1) + nonce(32) + ciphertext(>= 34) + mac(32)  ->  [99, 65603]
        guard bytes.count >= 99, bytes.count <= 65603 else { throw NIP44Error.invalidPayload }
        guard bytes[0] == version else { throw NIP44Error.invalidPayload }

        let nonce = Data(bytes[1..<33])
        let macStart = bytes.count - 32
        let ciphertext = Data(bytes[33..<macStart])
        let mac = Data(bytes[macStart..<bytes.count])

        let (chachaKey, chachaNonce, hmacKey) = messageKeys(conversationKey: conversationKey,
                                                            nonce: nonce)

        // Constant-time MAC check over (nonce || ciphertext) BEFORE decrypting.
        var authenticated = Data()
        authenticated.append(nonce)
        authenticated.append(ciphertext)
        guard HMAC<SHA256>.isValidAuthenticationCode(mac,
                                                     authenticating: authenticated,
                                                     using: SymmetricKey(data: hmacKey)) else {
            throw NIP44Error.invalidMAC
        }

        guard let padded = ChaCha20.xor(ciphertext, key: chachaKey, nonce: chachaNonce) else {
            throw NIP44Error.invalidPayload
        }
        let paddedBytes = [UInt8](padded)
        guard paddedBytes.count >= 2 else { throw NIP44Error.invalidPadding }

        let unpaddedLen = (Int(paddedBytes[0]) << 8) | Int(paddedBytes[1])
        guard unpaddedLen >= 1,
              2 + unpaddedLen <= paddedBytes.count,
              paddedBytes.count == 2 + calcPaddedLen(unpaddedLen) else {
            throw NIP44Error.invalidPadding
        }

        guard let text = String(data: Data(paddedBytes[2..<(2 + unpaddedLen)]), encoding: .utf8) else {
            throw NIP44Error.invalidPadding
        }
        return text
    }

    // MARK: - Padding

    /// NIP-44 v2 padded content length for an unpadded plaintext length.
    /// (The padded buffer is this value plus the 2-byte length prefix.)
    static func calcPaddedLen(_ unpadded: Int) -> Int {
        if unpadded <= 32 { return 32 }
        // floor(log2(unpadded-1)) + 1  ==  bit length of (unpadded-1)
        let bitLength = Int.bitWidth - (unpadded - 1).leadingZeroBitCount
        let nextPower = 1 << bitLength
        let chunk = nextPower <= 256 ? 32 : nextPower / 8
        return chunk * (((unpadded - 1) / chunk) + 1)
    }

    /// Prefix the big-endian u16 length, append plaintext, zero-pad to the
    /// canonical padded length.
    private static func pad(_ plaintext: Data) -> Data {
        let u = plaintext.count
        var out = Data()
        out.append(UInt8((u >> 8) & 0xff))
        out.append(UInt8(u & 0xff))
        out.append(plaintext)
        let zeros = calcPaddedLen(u) - u
        if zeros > 0 { out.append(Data(repeating: 0, count: zeros)) }
        return out
    }

    // MARK: - Key schedule (HKDF over HMAC-SHA256)

    private static func messageKeys(conversationKey: Data,
                                    nonce: Data) -> (chachaKey: Data, chachaNonce: Data, hmacKey: Data) {
        let k = [UInt8](hkdfExpand(prk: conversationKey, info: nonce, length: 76))
        return (Data(k[0..<32]), Data(k[32..<44]), Data(k[44..<76]))
    }

    private static func hkdfExtract(salt: Data, ikm: Data) -> Data {
        hmacSHA256(key: salt, message: ikm)
    }

    private static func hkdfExpand(prk: Data, info: Data, length: Int) -> Data {
        var output = Data()
        var t = Data()
        var counter: UInt8 = 1
        while output.count < length {
            var input = t
            input.append(info)
            input.append(counter)
            t = hmacSHA256(key: prk, message: input)
            output.append(t)
            counter &+= 1
        }
        return output.prefix(length)
    }

    private static func hmacSHA256(key: Data, message: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return Data(mac)
    }
}
