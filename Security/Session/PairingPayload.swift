// PairingPayload.swift
// Security/Session
//
// The container exchanged at first contact (docs/CONTACT_MODEL.md §6): the bytes
// a QR code encodes, or that an invite carries. It frames exactly two opaque
// pieces:
//
//   • the carrier-neutral prekey bundle (PrekeyBundle.data — already produced by
//     SecureSessionStore.localPrekeyBundle / BundleWire), which lets the peer
//     establish a libsignal session; and
//   • the device's raw 32-byte x-only secp256k1 Nostr public key, so the peer
//     can reach it over the Nostr far-path from the first message. OPTIONAL — a
//     device with no Nostr identity yet still produces a valid payload (the key
//     is absent, length 0), mirroring the coordinator's `ourNostrPublicKey?`.
//
// This is a DUMB container: it never inspects the bundle's internals (that is
// BundleWire's job) and carries no expiry or single-use accounting — that is the
// INVITE's job (step 3), which wraps a PairingPayload rather than replacing it.
// Pure Foundation, no libsignal, fully unit-testable; mirrors Envelope's
// `wireData()` / `init?(wire:)` idiom.
//
// WIRE LAYOUT:
//
//     byte 0          version (UInt8) = 1
//     bytes 1..5      bundle length   (UInt32, big-endian)
//     bytes 5..       bundle bytes
//     next 4 bytes    nostr-key length (UInt32, big-endian; 0 = absent, else 32)
//     next N bytes    nostr-key bytes
//
// QR NOTE: the bundle includes a post-quantum Kyber prekey, so the payload runs
// to roughly 1.5–2 KB. That fits a dense QR but is chunky; QR rendering density
// is a later UI concern, not this codec's.
//

import Foundation

public struct PairingPayload: Equatable, Sendable {

    /// Wire-format version. Bump on any breaking layout change.
    public static let currentVersion: UInt8 = 1

    /// Byte length of a raw x-only secp256k1 public key (when present).
    public static let nostrKeyByteCount = 32

    /// The peer's prekey bundle (opaque at this layer).
    public let bundle: PrekeyBundle

    /// The peer's raw 32-byte x-only Nostr public key, or nil if the device has
    /// no Nostr identity yet.
    public let nostrPublicKey: Data?

    public init(bundle: PrekeyBundle, nostrPublicKey: Data?) {
        self.bundle = bundle
        self.nostrPublicKey = nostrPublicKey
    }
}

// MARK: - Wire format

public extension PairingPayload {

    /// Serialize to the versioned, length-prefixed binary layout above.
    func wireData() -> Data {
        var d = Data()
        d.append(Self.currentVersion)
        Self.appendBlob(&d, bundle.data)
        Self.appendBlob(&d, nostrPublicKey ?? Data())
        return d
    }

    /// Parse from the binary layout. Returns nil on a malformed buffer: wrong
    /// version, truncation, trailing junk, or a present-but-wrong-length Nostr
    /// key (must be exactly `nostrKeyByteCount`, or absent). This is the
    /// untrusted-input boundary, so it is strict.
    init?(wire data: Data) {
        let bytes = [UInt8](data)
        var i = 0

        guard bytes.count >= 1, bytes[0] == Self.currentVersion else { return nil }
        i = 1

        guard let bundleBlob = Self.readBlob(bytes, &i),
              let nostrBlob = Self.readBlob(bytes, &i) else { return nil }
        guard i == bytes.count else { return nil }   // reject trailing junk

        let nostrKey: Data?
        switch nostrBlob.count {
        case 0:                       nostrKey = nil
        case Self.nostrKeyByteCount:  nostrKey = nostrBlob
        default:                      return nil      // present but wrong length
        }

        self.init(bundle: PrekeyBundle(data: bundleBlob), nostrPublicKey: nostrKey)
    }

    // MARK: Framing helpers

    private static func appendBlob(_ d: inout Data, _ blob: Data) {
        var len = UInt32(blob.count).bigEndian
        withUnsafeBytes(of: &len) { d.append(contentsOf: $0) }
        d.append(blob)
    }

    /// Read a 4-byte big-endian length then that many bytes, advancing `i`.
    /// Returns nil if either runs past the buffer.
    private static func readBlob(_ bytes: [UInt8], _ i: inout Int) -> Data? {
        guard i + 4 <= bytes.count else { return nil }
        let len = (Int(bytes[i]) << 24) | (Int(bytes[i + 1]) << 16)
                | (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
        i += 4
        guard len >= 0, i + len <= bytes.count else { return nil }
        let blob = Data(bytes[i ..< i + len])
        i += len
        return blob
    }
}
