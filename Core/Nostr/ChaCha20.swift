//
//  ChaCha20.swift
//  Core/Nostr
//
//  RFC 8439 ChaCha20 stream cipher — 256-bit key, 96-bit nonce, 32-bit block
//  counter, 20 rounds. Dependency-free, pure Swift.
//
//  WHY HAND-ROLLED: NIP-44 v2 uses UNAUTHENTICATED ChaCha20 with a SEPARATE
//  HMAC-SHA256 (encrypt-then-MAC), not an AEAD. CryptoKit only exposes the AEAD
//  form (ChaChaPoly), which bakes in Poly1305 and won't produce NIP-44's wire
//  format. So we implement the bare stream cipher here, KAT-locked against the
//  RFC 8439 test vectors, keeping the Nostr crypto self-contained and auditable.
//
//  Encryption and decryption are the same operation: XOR the keystream with the
//  data. NIP-44 calls this with the default block counter 0.
//

import Foundation

enum ChaCha20 {

    /// XOR `data` with the RFC 8439 ChaCha20 keystream produced from `key`
    /// (32 bytes), `nonce` (12 bytes), and an initial block `counter`
    /// (default 0, as NIP-44 uses). Returns nil if key or nonce length is wrong.
    ///
    /// The same call both encrypts and decrypts. Output length equals input
    /// length (the final block is truncated to the remaining bytes).
    static func xor(_ data: Data, key: Data, nonce: Data, counter: UInt32 = 0) -> Data? {
        guard key.count == 32, nonce.count == 12 else { return nil }

        let k = [UInt8](key)
        let n = [UInt8](nonce)

        // Initial state: 4 constant words, 8 key words, 1 counter word, 3 nonce
        // words — all little-endian. Constants are the LE words of
        // "expand 32-byte k".
        let base: [UInt32] = [
            0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
            load32(k, 0),  load32(k, 4),  load32(k, 8),  load32(k, 12),
            load32(k, 16), load32(k, 20), load32(k, 24), load32(k, 28),
            counter,
            load32(n, 0),  load32(n, 4),  load32(n, 8),
        ]

        let input = [UInt8](data)
        var output = [UInt8](repeating: 0, count: input.count)

        var state = base
        var blockCounter = counter
        var offset = 0
        while offset < input.count {
            state[12] = blockCounter
            let keystream = block(state)
            let count = min(64, input.count - offset)
            for i in 0..<count {
                output[offset + i] = input[offset + i] ^ keystream[i]
            }
            offset += 64
            blockCounter = blockCounter &+ 1
        }

        return Data(output)
    }

    // MARK: - Core

    private static func load32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    private static func rotl(_ v: UInt32, _ c: UInt32) -> UInt32 {
        (v << c) | (v >> (32 - c))
    }

    private static func quarterRound(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 16)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 12)
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 8)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 7)
    }

    /// One 64-byte ChaCha20 block: 20 rounds (10 column + diagonal pairs), then
    /// add the original state and serialize each word little-endian.
    private static func block(_ initial: [UInt32]) -> [UInt8] {
        var w = initial
        for _ in 0..<10 {
            quarterRound(&w, 0, 4, 8, 12)
            quarterRound(&w, 1, 5, 9, 13)
            quarterRound(&w, 2, 6, 10, 14)
            quarterRound(&w, 3, 7, 11, 15)
            quarterRound(&w, 0, 5, 10, 15)
            quarterRound(&w, 1, 6, 11, 12)
            quarterRound(&w, 2, 7, 8, 13)
            quarterRound(&w, 3, 4, 9, 14)
        }

        var out = [UInt8](repeating: 0, count: 64)
        for i in 0..<16 {
            let v = w[i] &+ initial[i]
            out[4 * i]     = UInt8(v & 0xff)
            out[4 * i + 1] = UInt8((v >> 8) & 0xff)
            out[4 * i + 2] = UInt8((v >> 16) & 0xff)
            out[4 * i + 3] = UInt8((v >> 24) & 0xff)
        }
        return out
    }
}
