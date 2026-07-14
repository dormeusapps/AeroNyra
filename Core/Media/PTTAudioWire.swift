//
//  PTTAudioWire.swift
//  Core/Media
//
//  The FROZEN on-wire layout of a sealed PTT audio frame's PAYLOAD (the bytes
//  inside the transport's [0x04][len] `.audioFrame` header):
//
//      [ seq: UInt64 big-endian (8) ] [ ciphertext (var) ] [ tag (16) ]
//
//  `seq` is FIRST so the receiver reads it pre-decrypt for the anti-replay
//  window check, and it doubles as the AEAD `aad` (BE64(seq)) so a tampered seq
//  fails authentication. The sender packs; the receiver unpacks. Both the BLE
//  transport (receive) and the capture layer (send, 4c-2) go through this one
//  place — pinned by BLEAudioTransportTests. Do NOT reorder or resize fields.
//

import Foundation

public enum PTTAudioWire {
    public static let seqBytes = 8
    public static let tagBytes = 16
    /// Minimum valid frame: seq + tag, with a zero-length ciphertext still legal.
    public static let minCount = seqBytes + tagBytes   // 24

    /// The AEAD `aad` for a frame — BE64(seq). Sealing and opening MUST use this
    /// same derivation, so it lives here to prevent drift.
    public static func aad(forSeq seq: UInt64) -> Data {
        var d = Data(capacity: seqBytes)
        withUnsafeBytes(of: seq.bigEndian) { d.append(contentsOf: $0) }
        return d
    }

    /// Assemble the wire payload from a seal's (counter, ciphertext, tag).
    public static func pack(seq: UInt64, ciphertext: Data, tag: Data) -> Data {
        var d = Data(capacity: seqBytes + ciphertext.count + tag.count)
        withUnsafeBytes(of: seq.bigEndian) { d.append(contentsOf: $0) }
        d.append(ciphertext)
        d.append(tag)
        return d
    }

    /// Parse the wire payload. Returns nil (safely — no out-of-bounds read) if
    /// it's shorter than seq+tag.
    public static func unpack(_ sealed: Data) -> (seq: UInt64, ciphertext: Data, tag: Data)? {
        guard sealed.count >= minCount else { return nil }
        let seq = sealed.prefix(seqBytes).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let tag = Data(sealed.suffix(tagBytes))
        let ciphertext = Data(sealed.dropFirst(seqBytes).dropLast(tagBytes))
        return (seq, ciphertext, tag)
    }
}
