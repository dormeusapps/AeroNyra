//
//  Envelope.swift
//  Beacon (working title)
//
//  The transport-agnostic unit of transmission.
//
//  HANDOFF §4.1: "Noise + Double Ratchet produce a transport-AGNOSTIC
//  encrypted Envelope. Any future transport just carries the same ciphertext
//  — so a future internet relay/server still sees NOTHING but opaque bytes."
//
//  This type lives in Core and knows nothing about BLE, the internet, or the
//  crypto that produced its `ciphertext`. It is the contract between the
//  Security layer (which seals/opens it) and the Transport layer (which
//  moves it). Relays handle only this type and never see plaintext.
//

import Foundation
import Security   // SecRandomCopyBytes (CSPRNG — HANDOFF §3.1)

// MARK: - MessageID

/// A random, per-message identifier.
///
/// Used by the routing layer for seen-ID dedup and as one half of replay
/// rejection (HANDOFF §3.4: "replays rejected by ratchet counters +
/// message-ID dedup"). It is deliberately random and carries no identity —
/// a passive observer learns nothing linkable from it.
public struct MessageID: Hashable, Sendable, Codable, CustomStringConvertible {

    public static let byteCount = 16   // 128-bit

    public let bytes: [UInt8]

    /// Wrap exactly `byteCount` bytes. Returns nil on wrong length.
    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.byteCount else { return nil }
        self.bytes = bytes
    }

    /// Generate a fresh ID from the system CSPRNG.
    public static func random() -> MessageID {
        var b = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &b)
        precondition(status == errSecSuccess, "CSPRNG (SecRandomCopyBytes) failed")
        return MessageID(bytes: b)!   // length is guaranteed
    }

    public var hex: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { hex }
}

// MARK: - Payload padding buckets

/// Fixed-size padding buckets (HANDOFF §3.6: "Fixed-size PADDING on payloads
/// to defeat length analysis").
///
/// The Security/Sealing layer pads *plaintext* up to the smallest bucket that
/// fits before encrypting, so observed ciphertext lengths collapse to a small
/// set of sizes. This is advisory metadata at the Core layer — the invariant
/// is enforced where sealing happens, not here — but the bucket sizes are
/// defined in one place so both layers agree.
public enum PayloadBucket {
    public static let sizes: [Int] = [256, 1024, 4096, 16384]

    /// Smallest bucket that fits `length`, or nil if it exceeds the largest.
    public static func bucket(forContentLength length: Int) -> Int? {
        sizes.first { $0 >= length }
    }
}

// MARK: - Envelope

/// An opaque, authenticated, sealed message as it travels the mesh.
///
/// Cleartext fields (`version`, `ttl`, `id`) are the *routing minimum* — the
/// least a relay needs to forward, dedup, and bound hop count. Everything that
/// could identify sender, recipient, or content lives inside `ciphertext`,
/// which is AEAD-sealed and includes the sealed-sender header (HANDOFF §3.6).
/// A relay — or a future internet pipe — sees only these three small fields
/// plus opaque bytes, and can neither read, attribute, nor forge the message.
///
/// Note on routing: there is intentionally **no destination field**. The mesh
/// uses flooding with a hop limit; only the holder of the right session keys
/// can open an envelope addressed to them. Omitting a destination is what lets
/// relays stay dumb and unable to target or attribute traffic. If a future
/// routing optimization ever needs a recipient hint, it must be an unlinkable
/// rotating tag — never an identity — and that decision belongs in Security,
/// not here.
public struct Envelope: Equatable, Hashable, Sendable {

    /// Current wire-format version. Bump on any breaking layout change.
    public static let currentVersion: UInt8 = 1

    /// Maximum hops a message may take before relays drop it (HANDOFF §0, §5).
    public static let maxHops: UInt8 = 7

    /// Fixed cleartext header size in bytes: version(1) + ttl(1) + id(16).
    public static let headerSize = 1 + 1 + MessageID.byteCount

    /// Protocol version this envelope was built with.
    public let version: UInt8

    /// Remaining hops. Starts at `<= maxHops`; each relay decrements by one
    /// and drops the envelope when it reaches zero.
    public let ttl: UInt8

    /// Random per-message identifier (dedup / replay).
    public let id: MessageID

    /// The sealed payload. Opaque at this layer — produced and consumed only
    /// by the Security layer. Expected to already be padded to a
    /// `PayloadBucket` size before sealing.
    public let ciphertext: Data

    public init(version: UInt8 = Envelope.currentVersion,
                ttl: UInt8 = Envelope.maxHops,
                id: MessageID = .random(),
                ciphertext: Data) {
        self.version = version
        self.ttl = min(ttl, Envelope.maxHops)
        self.id = id
        self.ciphertext = ciphertext
    }
}

// MARK: - Relay semantics

public extension Envelope {

    /// Whether this envelope may still be relayed onward.
    var canRelay: Bool { ttl > 0 }

    /// A copy with the hop budget decremented, ready to rebroadcast.
    /// Returns nil if the envelope has exhausted its TTL and must be dropped.
    ///
    /// The relay never alters `id` or `ciphertext` — it only spends a hop.
    func forwarded() -> Envelope? {
        guard ttl > 0 else { return nil }
        return Envelope(version: version,
                        ttl: ttl - 1,
                        id: id,
                        ciphertext: ciphertext)
    }
}

// MARK: - Wire format

public extension Envelope {

    /// Serialize to the compact binary layout carried in a BLE packet:
    ///
    ///     byte 0        version
    ///     byte 1        ttl
    ///     bytes 2..<18  id (16 bytes)
    ///     bytes 18..    ciphertext (remainder)
    ///
    /// Fragmentation and reassembly across BLE MTUs are the transport's
    /// responsibility, below this layer — one `wireData()` is one logical
    /// envelope.
    func wireData() -> Data {
        var d = Data(capacity: Self.headerSize + ciphertext.count)
        d.append(version)
        d.append(ttl)
        d.append(contentsOf: id.bytes)
        d.append(ciphertext)
        return d
    }

    /// Parse from the binary layout above. Returns nil on a malformed or
    /// unknown-version buffer. An empty `ciphertext` is permitted (the
    /// Security layer decides whether that is meaningful).
    init?(wire data: Data) {
        guard data.count >= Self.headerSize else { return nil }
        let bytes = [UInt8](data)

        let version = bytes[0]
        guard version == Self.currentVersion else { return nil }

        let ttl = min(bytes[1], Self.maxHops)

        let idBytes = Array(bytes[2..<(2 + MessageID.byteCount)])
        guard let id = MessageID(bytes: idBytes) else { return nil }

        let ciphertext = Data(bytes[Self.headerSize...])

        self.init(version: version, ttl: ttl, id: id, ciphertext: ciphertext)
    }
}

// MARK: - Equatable / Hashable

public extension Envelope {
    /// Two envelopes are "the same message" when their ids match, regardless
    /// of remaining TTL. This is the identity the routing dedup relies on:
    /// the same message arriving via two relay paths (different ttl) must
    /// collapse to one.
    static func == (lhs: Envelope, rhs: Envelope) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
