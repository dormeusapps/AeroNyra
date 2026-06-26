//
//  SecureSession.swift
//  Security/Session
//
//  THE CRYPTO BOUNDARY.
//
//  The entire app talks to this protocol; the underlying cryptographic
//  implementation (libsignal's Triple Ratchet — Double Ratchet + Sparse
//  Post-Quantum Ratchet, PQXDH handshake) sits BEHIND it as a thin adapter.
//
//  Why a boundary at all:
//   • Durability — the app never depends on libsignal's API directly, so its
//     churn ("APIs subject to change without notice") is absorbed by one small
//     adapter, not scattered through the codebase. This is what makes "build
//     the security once, don't keep editing it" actually true.
//   • Swappability — if the cryptographic landscape shifts again, the engine
//     changes; the app does not.
//   • Testability — behavior (round-trip, out-of-order, replay rejection) is
//     verified against THIS contract, independent of the implementation.
//
//  This supersedes HANDOFF §3.3–3.4 (Noise_XX + Double Ratchet). The Signal
//  stack subsumes everything those aimed for — mutual auth, identity hiding,
//  forward secrecy, post-compromise security — and adds post-quantum
//  resistance (defense against harvest-now-decrypt-later), which a Noise_XX
//  build could not provide without a later rewrite.
//
//  Scope: this is the WIRE layer only. At-rest protection (Data Protection +
//  an Enclave-wrapped, app-lock-gated vault) is a separate, orthogonal layer —
//  it is what defends the unlocked-device scenario, which no wire crypto can.
//

import Foundation

// MARK: - State

/// Lifecycle of a session with one peer.
public enum SecureSessionState: Equatable, Sendable {
    /// No keys established; nothing can be sealed or opened yet.
    case uninitialized
    /// A handshake is in progress (PQXDH exchange under way).
    case establishing
    /// Keys established; the session can seal and open messages.
    case established
}

// MARK: - SafetyNumber

/// A human-verifiable fingerprint over BOTH peers' identities (HANDOFF §3.5).
///
/// Two peers compare these out-of-band — read the digits aloud or scan the QR —
/// to confirm no man-in-the-middle sits between them. Because there is no
/// server, verification is strictly peer-to-peer; the number is the only
/// authority.
public struct SafetyNumber: Equatable, Sendable {
    /// The displayable number (Signal-style grouped digits).
    public let displayString: String
    /// A scannable QR payload encoding the same fingerprint.
    public let qrPayload: Data

    public init(displayString: String, qrPayload: Data) {
        self.displayString = displayString
        self.qrPayload = qrPayload
    }
}

// MARK: - PrekeyBundle

/// A carrier-neutral bundle of PUBLIC key material that lets a peer start an
/// encrypted session with this device.
///
/// In Signal's normal deployment a prekey bundle is fetched from a server. Beacon
/// has no server (HANDOFF §3.3), so the same bundle is exchanged DIRECTLY between
/// devices — advertised over BLE, shown as a QR code, or (if an internet
/// transport is ever added) carried over that. The bytes are identical no matter
/// the carrier; which carrier delivered them is not the crypto layer's concern.
///
/// The contents are opaque at this layer — only the `SecureSessionStore`
/// implementation knows the format. Nothing secret is inside: a bundle is public
/// key material plus signatures, safe to broadcast.
public struct PrekeyBundle: Equatable, Sendable {
    public let data: Data
    public init(data: Data) { self.data = data }
}

// MARK: - Errors

public enum SecureSessionError: Error {
    /// Tried to seal/open before the session was established.
    case notEstablished
    /// The peer's identity key changed since this session was verified — a
    /// possible MITM, or the peer reinstalled. Must be surfaced to the user,
    /// never silently accepted.
    case identityChanged
    /// A received message could not be authenticated/decrypted (tampered,
    /// replayed beyond the window, or for a different session).
    case openFailed
    /// Sealing failed (should be rare; indicates an internal/state error).
    case sealFailed
    /// The underlying engine raised an error not otherwise classified.
    case engine(underlying: Error)
}

// MARK: - SecureSession

/// A post-quantum, end-to-end encrypted channel to a single peer.
///
/// Implementations wrap a vetted protocol implementation and own the ratchet
/// state for this peer. Callers see only `seal`/`open` and the verification
/// fingerprint — never keys, nonces, or ratchet internals.
public protocol SecureSession: AnyObject {

    /// The peer this session talks to.
    var peer: PublicIdentity { get }

    /// Current session lifecycle state.
    var state: SecureSessionState { get }

    /// Seal application plaintext into an opaque payload for transport.
    ///
    /// The returned bytes are what go into `Envelope.ciphertext`. They are
    /// already padded (HANDOFF §3.6) and authenticated. Throws
    /// `.notEstablished` if no session exists yet.
    func seal(_ plaintext: Data) throws -> Data

    /// Open an opaque payload received from the peer.
    ///
    /// May advance `state` — e.g. an initial inbound handshake message can
    /// complete establishment as a side effect of the first `open`. Throws
    /// `.openFailed` on an unauthenticatable message, or `.identityChanged`
    /// if the peer's identity key no longer matches a verified one.
    func open(_ payload: Data) throws -> Data

    /// The stable safety number for out-of-band verification (§3.5).
    func safetyNumber() throws -> SafetyNumber
}

// MARK: - SecureSessionStore

/// Establishes, vends, and persists `SecureSession`s.
///
/// The implementation owns the local identity, the handshake/prekey machinery,
/// and the durable ratchet state for every peer. It is the single object the
/// app's messaging layer asks for sessions — and the single place the
/// emergency wipe reaches to destroy them.
public protocol SecureSessionStore: AnyObject, Sendable {

    /// The local device's public identity (the X25519 user ID + signing key).
    var localIdentity: PublicIdentity { get }

    /// Produce THIS device's prekey bundle, to advertise over BLE or render as a
    /// QR code. Calling this also generates and stores the matching PRIVATE
    /// prekeys, so the device is armed to receive a first message from anyone who
    /// picks up the bundle. The store replenishes one-time prekeys as they are
    /// consumed. (This replaces Signal's "upload prekeys to a server" step with a
    /// direct, offline exchange — HANDOFF §3.3.)
    func localPrekeyBundle() throws -> PrekeyBundle

    /// INITIATOR path: establish a session with a peer from their bundle,
    /// received over any carrier. The peer's identity is read from the bundle.
    /// After this returns, the session can `seal` — its first sealed message
    /// carries the handshake the peer needs to establish their side.
    ///
    /// RESPONDER path: there is no matching call — a peer's first inbound message
    /// completes establishment as a side effect of `SecureSession.open`, using
    /// the private prekeys this device stored when it produced its own bundle.
    ///
    /// Trust note: establishment is trust-on-first-use. The returned session is
    /// usable immediately, but is UNVERIFIED until the two sides compare
    /// `safetyNumber()` out of band (in person, or over QR) per §3.5.
    func establishSession(from bundle: PrekeyBundle) throws -> SecureSession

    /// Return the session for a peer, establishing a new one if needed.
    func session(with peer: PublicIdentity) throws -> SecureSession

    /// Whether an established session already exists for a peer.
    func hasSession(with peer: PublicIdentity) -> Bool

    /// Forget a single peer's session (e.g. after an identity change the user
    /// chooses not to trust).
    func deleteSession(with peer: PublicIdentity) throws

    /// Destroy ALL session state. Part of crypto-erase (HANDOFF §3.7): once
    /// ratchet state is gone, stored ciphertext for those sessions is
    /// unrecoverable even on this device.
    func deleteAllSessions() throws
}
