//
//  Transport.swift
//  Core/Routing
//
//  THE SEAM (HANDOFF §4).
//
//  "Transport protocol: send(Envelope) / onReceive(Envelope). v1 ships exactly
//   ONE implementation: BLEMeshTransport. The crypto/session layer sits ABOVE
//   transport." (§4.1)
//
//  This protocol is the entire cost of the internet-fallback story. Because
//  the crypto layer produces transport-agnostic Envelopes (see Envelope.swift)
//  and everything above speaks only to this protocol, a second transport can
//  be added later WITHOUT touching crypto or UI. The seam is an architectural
//  boundary, not dormant networking code (§4.3) — v1 has zero networking.
//

import Foundation

// MARK: - TransportKind

/// Identifies which transport carried (or will carry) a message.
///
/// v1 has exactly one real case. `.internet` is the reserved seam (§4.1:
/// "reserve a `.internet` case for later"): its presence lets MessageRouter
/// switch exhaustively over transports with the future door already framed,
/// while no internet implementation ships. Any attempt to use it in v1
/// surfaces as `TransportError.unsupported`.
public enum TransportKind: String, Sendable, CaseIterable {
    case ble

    /// RESERVED — designed-for, not built (HANDOFF §4). No implementation in v1.
    case internet
}

// MARK: - TransportError

public enum TransportError: Error, Equatable {
    /// `send` was called before `start()` completed.
    case notStarted
    /// No peer is currently reachable; the caller should queue and retry
    /// (this is the `.waitingForRange` delivery state, not a hard failure).
    case noReachablePeers
    /// The envelope exceeds what this transport can carry in one logical unit.
    case envelopeTooLarge(maxBytes: Int)
    /// The transport accepted the envelope but transmission failed.
    case sendFailed
    /// The requested transport has no implementation in this build
    /// (e.g. `.internet` in v1).
    case unsupported(TransportKind)
}

// MARK: - MeshTransport

/// A pipe that carries opaque `Envelope`s between this device and the mesh.
///
/// Conformers are responsible only for moving bytes: discovery, connection,
/// fragmentation/reassembly, and rebroadcast live here. They never inspect or
/// mutate `ciphertext`, and they apply relay semantics (TTL, dedup) only via
/// the `Envelope` API — a transport is dumb by design (HANDOFF §3.1).
///
/// Inbound envelopes are delivered through `incoming`, each tagged with the
/// SOURCE LINK it arrived on so the router can apply split-horizon. Conformers
/// are reference-typed and `Sendable` — `MessageRouter` consumes them across
/// concurrency domains, so a conformer is expected to be an `actor` (or
/// otherwise internally synchronized) around the radio.
public protocol MeshTransport: AnyObject, Sendable {

    /// Which transport this is. v1: always `.ble`.
    var kind: TransportKind { get }

    /// A stream of envelopes received from the mesh (direct or relayed), each
    /// paired with the ephemeral SOURCE LINK id it arrived on. The router
    /// consumes this; the transport produces it. The link lets the router (via
    /// the receiver) exclude the source peer when forwarding — Phase 7b.1a.
    var incoming: AsyncStream<(link: UUID, envelope: Envelope)> { get }

    /// Begin scanning/advertising and accepting connections.
    /// Throws if the radio is unavailable or permission is denied.
    func start() async throws

    /// Stop all radio activity and tear down connections.
    func stop()

    /// Transmit one envelope toward the mesh — broadcast to ALL reachable links.
    /// Used for messages WE originate; delivery is not implied.
    ///
    /// For BLE this means handing the bytes to the radio for broadcast to
    /// reachable peers. Delivery state is tracked above, by MessageRouter, from
    /// acknowledgements and relay receipts.
    ///
    /// - Throws: `TransportError.notStarted`, `.noReachablePeers`,
    ///   `.envelopeTooLarge`, or `.sendFailed`.
    func send(_ envelope: Envelope) async throws

    /// Forward an inbound envelope onward, EXCLUDING the given links — every
    /// link belonging to the peer the envelope arrived from (split-horizon,
    /// Phase 7b.1a). Best-effort and non-throwing: if nothing is left to
    /// forward to, it does nothing. Unlike `send`, "no reachable peers" is not
    /// an error here — a relay with no onward hop is a normal, silent no-op.
    func relay(_ envelope: Envelope, excludingLinks: Set<UUID>) async
}

// MARK: - AddressedTransport

/// A transport that delivers to a SPECIFIC recipient rather than broadcasting
/// to whoever is reachable (Phase 8d). The BLE mesh is broadcast — you hand it
/// bytes and the flood finds the peer — so it does NOT adopt this. Nostr is the
/// opposite: a gift wrap is built FOR one recipient pubkey (NIP-59), so its
/// recipient-blind `MeshTransport.send` throws and this is the real send path.
///
/// Kept SEPARATE from `MeshTransport` on purpose: forcing an addressed face onto
/// BLE would mean a meaningless no-op there. The router checks for this
/// capability (`as? AddressedTransport`) only on the Tier-2 fallback leg, so the
/// broadcast and addressed worlds stay cleanly distinct.
public protocol AddressedTransport: AnyObject, Sendable {
    /// Deliver `envelope` to exactly `recipient` (a raw 32-byte x-only pubkey,
    /// the peer's bootstrapped `nostrPubkey`). Throws if the addressed send
    /// fails — the router treats that as "not delivered here" and queues for
    /// Tier 3 rather than reporting success.
    func publish(_ envelope: Envelope, to recipient: Data) async throws
}
