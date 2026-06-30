// ContactAllowlist.swift
// Security/Session
//
// The closed-contact admission set (docs/CONTACT_MODEL.md §8): the identities
// this device has DELIBERATELY paired with. In the closed model, having the app
// and being in range is not enough to talk — only an identity in this set is
// ever admitted to a session. Strangers are dropped before any session work.
//
// This is the gate's pure LOGIC half: the paired set, enrollment/verification/
// revocation, and the admission decision. The ENFORCEMENT half — wiring this
// into the first-contact / inbound-open paths so unpaired peers are actually
// dropped — is a later sub-step, sequenced with the pairing enrollment flow so
// the live BLE path is never darkened before there is a way to enroll.
//
// Identities are the RAW 32-byte key form (`Peer.publicKeyData`, i.e.
// `store.rawPublicKey(of:)`) the coordinator already uses across its boundary —
// opaque here; this layer never interprets the bytes.
//
// VERIFIED vs ENROLLED: a QR pair is verified on the spot (physical auth); an
// invite pair is enrolled-but-unverified until the 4-word SAS confirm
// (SASWordPhrase). Both states live here; whether to WITHHOLD messaging until
// verified is a UX policy exposed as `admits(requireVerified:)`, not baked in.
//
// Pure value type, `now` injected — deterministic under test. Persistence
// (SwiftData / vault) is a later wiring concern.
//

import Foundation

public struct ContactAllowlist: Equatable, Sendable {

    /// One paired contact's admission record.
    public struct Entry: Equatable, Sendable {
        /// When the contact was paired (Unix ms).
        public let pairedAt: Int64
        /// Whether the pairing has been verified (QR physical auth, or SAS
        /// confirmation for the invite flow).
        public var verified: Bool

        public init(pairedAt: Int64, verified: Bool) {
            self.pairedAt = pairedAt
            self.verified = verified
        }
    }

    /// raw 32-byte identity → entry.
    private var entries: [Data: Entry] = [:]

    public init() {}

    /// Number of paired contacts.
    public var count: Int { entries.count }

    /// All paired identities.
    public var identities: Set<Data> { Set(entries.keys) }

    // MARK: - Enrollment

    /// Pair (enroll) an identity. Called on a successful pairing — QR scan
    /// (`verified: true`, physically authenticated) or invite redemption
    /// (`verified: false`, pending the SAS confirm). Re-enrolling an existing
    /// identity replaces its record (e.g. re-pair after a key change).
    public mutating func enroll(identity: Data, at now: Int64, verified: Bool) {
        entries[identity] = Entry(pairedAt: now, verified: verified)
    }

    /// Mark an already-enrolled identity as verified (the SAS confirmation
    /// landed). No-op if the identity isn't paired.
    public mutating func markVerified(identity: Data) {
        guard var e = entries[identity] else { return }
        e.verified = true
        entries[identity] = e
    }

    /// Remove a contact entirely — they can no longer be admitted.
    public mutating func revoke(identity: Data) {
        entries[identity] = nil
    }

    // MARK: - Queries

    /// Whether `identity` is paired (enrolled), regardless of verification.
    public func contains(identity: Data) -> Bool {
        entries[identity] != nil
    }

    /// Whether `identity` is paired AND verified.
    public func isVerified(identity: Data) -> Bool {
        entries[identity]?.verified ?? false
    }

    /// The full record for `identity`, if paired.
    public func entry(for identity: Data) -> Entry? {
        entries[identity]
    }

    // MARK: - Admission decision

    /// The gate: should `identity` be admitted to a session? Admits any paired
    /// identity by default; pass `requireVerified: true` to admit only
    /// SAS-/QR-verified contacts (the stricter policy — a UX choice made by the
    /// enforcement layer, not here).
    public func admits(identity: Data, requireVerified: Bool = false) -> Bool {
        guard let e = entries[identity] else { return false }
        return requireVerified ? e.verified : true
    }
}
