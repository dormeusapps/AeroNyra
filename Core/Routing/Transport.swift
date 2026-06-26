//
//  Transport.swift
//  Beacon (working title)
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
/// Inbound envelopes are delivered through `incoming`. Conformers are
/// reference-typed and `Sendable` — `MessageRouter` consumes them across
/// concurrency domains, so a conformer is expected to be an `actor` (or
/// otherwise internally synchronized) around the radio.
public protocol MeshTransport: AnyObject, Sendable {

    /// Which transport this is. v1: always `.ble`.
    var kind: TransportKind { get }

    /// A stream of envelopes received from the mesh (direct or relayed).
    /// The router consumes this; the transport produces it.
    var incoming: AsyncStream<Envelope> { get }

    /// Begin scanning/advertising and accepting connections.
    /// Throws if the radio is unavailable or permission is denied.
    func start() async throws

    /// Stop all radio activity and tear down connections.
    func stop()

    /// Transmit one envelope toward the mesh.
    ///
    /// For BLE this means handing the bytes to the radio for broadcast to
    /// reachable peers; it does not imply delivery. Delivery state is tracked
    /// above, by MessageRouter, from acknowledgements and relay receipts.
    ///
    /// - Throws: `TransportError.notStarted`, `.noReachablePeers`,
    ///   `.envelopeTooLarge`, or `.sendFailed`.
    func send(_ envelope: Envelope) async throws
}
