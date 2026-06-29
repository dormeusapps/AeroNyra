//
//  Bech32.swift
//  Core/Nostr
//
//  NIP-19 identity encoding for the Nostr pillar (Phase 8).
//
//  Nostr identities are shown and shared as human-readable strings — `npub1…`
//  for a public key, `nsec1…` for a secret key — rather than raw hex. That
//  encoding is bech32 (BIP-173): an HRP ("npub"/"nsec"), a separator "1", the
//  payload regrouped from 8-bit bytes into 5-bit symbols, and a 6-symbol
//  checksum. This file is the pure codec — no secp256k1, no networking, no
//  keys of its own. It just moves bytes ⇄ strings, so it can be written and
//  proven correct on its own (see Bech32Tests) before the keypair exists.
//
//  SCOPE: npub / nsec only (32-byte x-only pubkey, 32-byte seckey). The TLV
//  forms (nprofile / nevent / naddr) are not needed yet and are deliberately
//  omitted; the low-level `Bech32` codec below is general enough to add them
//  later without change. NIP-19 uses bech32 (not bech32m), checksum const 1.
//

import Foundation

// MARK: - Bech32 (BIP-173)

/// The general bech32 string codec: `hrp ‖ "1" ‖ data5bit ‖ checksum`.
/// Case-insensitive but never mixed-case. Pure value math — no allocations
/// beyond the output, no dependencies.
public enum Bech32 {

    /// The 32-symbol alphabet; index == the 5-bit value it encodes.
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    /// BCH generator coefficients for the bech32 checksum.
    private static let generator: [UInt32] = [
        0x3b6a_57b2, 0x2650_8e6d, 0x1ea1_19fa, 0x3d42_33dd, 0x2a14_62b3,
    ]

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        var chk: UInt32 = 1
        for v in values {
            let top = chk >> 25
            chk = ((chk & 0x1ff_ffff) << 5) ^ UInt32(v)
            for i in 0..<5 where ((top >> UInt32(i)) & 1) != 0 {
                chk ^= generator[i]
            }
        }
        return chk
    }

    private static func hrpExpand(_ hrp: String) -> [UInt8] {
        let bytes = Array(hrp.utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2 + 1)
        for c in bytes { out.append(c >> 5) }
        out.append(0)
        for c in bytes { out.append(c & 31) }
        return out
    }

    private static func verifyChecksum(hrp: String, data: [UInt8]) -> Bool {
        polymod(hrpExpand(hrp) + data) == 1
    }

    private static func createChecksum(hrp: String, data: [UInt8]) -> [UInt8] {
        let values = hrpExpand(hrp) + data + [0, 0, 0, 0, 0, 0]
        let mod = polymod(values) ^ 1
        return (0..<6).map { UInt8((mod >> (5 * (5 - UInt32($0)))) & 31) }
    }

    /// Encode 5-bit `data` under `hrp` into a bech32 string (checksum appended).
    public static func encode(hrp: String, data: [UInt8]) -> String {
        let combined = data + createChecksum(hrp: hrp, data: data)
        var s = hrp + "1"
        s.reserveCapacity(s.count + combined.count)
        for d in combined { s.append(charset[Int(d)]) }
        return s
    }

    /// Decode a bech32 string into `(hrp, data5bit)` with the 6-symbol checksum
    /// already verified and stripped. nil on any structural or checksum error,
    /// or on mixed-case input. (NIP-19 lifts BIP-173's 90-char cap, so length
    /// is not bounded here.)
    public static func decode(_ str: String) -> (hrp: String, data: [UInt8])? {
        let lower = str.lowercased()
        let upper = str.uppercased()
        guard str == lower || str == upper else { return nil }   // no mixed case
        let s = lower
        guard let sep = s.lastIndex(of: "1") else { return nil }

        let hrp = String(s[s.startIndex..<sep])
        let dataPart = s[s.index(after: sep)...]
        guard !hrp.isEmpty, dataPart.count >= 6 else { return nil }

        var data = [UInt8]()
        data.reserveCapacity(dataPart.count)
        for c in dataPart {
            guard let idx = charset.firstIndex(of: c) else { return nil }
            data.append(UInt8(idx))
        }
        guard verifyChecksum(hrp: hrp, data: data) else { return nil }
        return (hrp, Array(data.dropLast(6)))
    }

    /// Regroup a byte stream between bit-widths (8⇄5), MSB-first. `pad` appends
    /// a final partial group when encoding (8→5); decoding (5→8) must NOT pad,
    /// and rejects a non-zero remainder. nil on an out-of-range symbol.
    public static func convertBits(_ data: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var acc = 0
        var bits = 0
        var out = [UInt8]()
        let maxv = (1 << to) - 1
        let maxAcc = (1 << (from + to - 1)) - 1
        for value in data {
            let v = Int(value)
            if v < 0 || (v >> from) != 0 { return nil }
            acc = ((acc << from) | v) & maxAcc
            bits += from
            while bits >= to {
                bits -= to
                out.append(UInt8((acc >> bits) & maxv))
            }
        }
        if pad {
            if bits > 0 { out.append(UInt8((acc << (to - bits)) & maxv)) }
        } else if bits >= from || ((acc << (to - bits)) & maxv) != 0 {
            return nil
        }
        return out
    }
}

// MARK: - NIP-19 (npub / nsec)

/// The Nostr-specific identity strings, built on the bech32 codec above.
/// A pubkey/seckey is exactly 32 bytes; these wrap the 8→5 regroup + HRP.
public enum NIP19 {

    /// Encode a 32-byte x-only public key as `npub1…`. nil if not 32 bytes.
    public static func npub(fromPublicKey key: Data) -> String? {
        encode32(key, hrp: "npub")
    }

    /// Encode a 32-byte secret key as `nsec1…`. nil if not 32 bytes.
    public static func nsec(fromSecretKey key: Data) -> String? {
        encode32(key, hrp: "nsec")
    }

    /// Decode an `npub1…` back to its 32 raw bytes. nil on a wrong HRP, a bad
    /// checksum, or a payload that isn't 32 bytes.
    public static func publicKey(fromNpub s: String) -> Data? {
        decode32(s, hrp: "npub")
    }

    /// Decode an `nsec1…` back to its 32 raw bytes.
    public static func secretKey(fromNsec s: String) -> Data? {
        decode32(s, hrp: "nsec")
    }

    // MARK: -

    private static func encode32(_ key: Data, hrp: String) -> String? {
        guard key.count == 32,
              let five = Bech32.convertBits([UInt8](key), from: 8, to: 5, pad: true)
        else { return nil }
        return Bech32.encode(hrp: hrp, data: five)
    }

    private static func decode32(_ s: String, hrp expected: String) -> Data? {
        guard let (hrp, data) = Bech32.decode(s), hrp == expected,
              let bytes = Bech32.convertBits(data, from: 5, to: 8, pad: false),
              bytes.count == 32
        else { return nil }
        return Data(bytes)
    }
}
