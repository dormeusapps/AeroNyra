//
//  EnrollmentService.swift
//  Security/Session
//
//  THE single owner of the live closed-contact admission set (STEP 7c-1 ·
//  GROUND_TRUTH §3.5 / §3.6 · ENROLLMENT_7c1.md).
//
//  WHY THIS EXISTS. `ContactAllowlistStore` is WHOLE-BLOB load/save — every save
//  writes the entire allowlist as one sealed file. Two concurrent enrollments that
//  each did load→mutate→save would race: the second overwrites the first, silently
//  dropping a contact from a security admission set with no error. This service is
//  the one owner that serializes every mutation. It is `@MainActor`, holds the live
//  `ContactAllowlist` in memory (loaded ONCE at construction), and re-persists the
//  whole blob on each mutation. Actor confinement makes read-modify-write atomic;
//  no concurrent save can race.
//
//  WRITE ORDERING — SAVE-THEN-ADOPT (decided, §3 of the threat note). Every
//  mutation: build a mutated COPY → `store.save(copy)` FIRST → only on success
//  adopt the copy as the live set → only then tell the coordinator (enroll). If the
//  save throws, the live set, the persisted file, and the coordinator's reconnect
//  set are ALL unchanged, and the error propagates for the caller to retry. This
//  guarantees the live allowlist and the reconnect set only ever reflect what is
//  durably on disk — the coordinator is never told about a contact that failed to
//  persist (which would let reconnect admit a non-persisted identity: a security-
//  relevant split-brain).
//
//  TRANSITIONS (§4). QR pair → enroll(verified: true) (proximity authenticates).
//  Invite redeem → enroll(verified: false) (pending the SAS). SAS match →
//  markVerified. An invite can NEVER self-verify; verified: true is only ever set
//  by an explicit QR enroll or a SAS markVerified.
//
//  SCOPE. This is the data layer of "add a contact." It does NOT build pairing UI
//  (7d), persist PendingInvites (7c-2), raise the key-change alert (7c-3), or flip
//  the admission gate (7e). Live revoke-from-reconnect is deferred (the coordinator
//  has no reconnect-removal method yet; a revoked contact stops reconnecting after
//  relaunch, authoritative at 7e).
//

import Foundation

/// The one-method contract the enrollment layer needs from the coordinator: be
/// told about a newly-enrolled contact so it can be admitted to reconnect
/// immediately. `FirstContactCoordinator` conforms (its `addReconnectContact`
/// matches); the seam depends on THIS, not the coordinator's full surface, so the
/// enrollment layer stays decoupled from the session stack and is trivially
/// testable with a spy. (Dependency inversion: the seam declares what it needs.)
public protocol ReconnectEnrolling: Sendable {
    func addReconnectContact(rawIdentity: Data) async
}

@MainActor
public final class EnrollmentService {

    /// Errors surfaced to the caller (the pairing flow, 7d).
    public enum EnrollmentError: Error {
        /// The identity handed in wasn't the expected raw 32-byte key form.
        case nonStandardIdentity(Int)
        /// Persisting the mutated allowlist failed; NOTHING was adopted — the live
        /// set, the disk file, and the coordinator are all unchanged. Retryable.
        case persistFailed(underlying: Error)
    }

    /// The persisted at-rest store (whole-blob). The SAME instance the composition
    /// root holds; `save`/`load` go through it.
    private let store: ContactAllowlistStore

    /// The reconnect layer to notify on a successful enroll, so a newly-paired
    /// contact reconnects immediately (no relaunch). Depends on the narrow
    /// `ReconnectEnrolling` contract, not the concrete coordinator — the seam
    /// stays decoupled from the session stack. `FirstContactCoordinator`'s
    /// `addReconnectContact` is the permanent replacement for the transitional
    /// `noteReconnectContact` hook.
    private let coordinator: ReconnectEnrolling

    /// The live admission set — the in-memory source of truth after construction.
    /// Re-persisted whole on every mutation. Never mutated except through the
    /// save-then-adopt path below.
    private var allowlist: ContactAllowlist

    /// "Now" as Unix MILLISECONDS (matching `ContactAllowlist.enroll(at:)` and the
    /// codec's `pairedAt` field). Injected so tests are deterministic. The ONE place
    /// the ms conversion lives — a seconds/ms slip here would silently write a wrong
    /// timestamp into a security record.
    private let nowMillis: @Sendable () -> Int64

    /// - Parameters:
    ///   - store: the at-rest allowlist store (shared with the composition root).
    ///   - coordinator: the reconnect layer to notify on enroll (the concrete
    ///     `FirstContactCoordinator` in production; a spy in tests).
    ///   - initialAllowlist: the already-loaded paired set (the composition root
    ///     loads it once at startup to seed reconnect; pass that same value so we
    ///     don't re-read the file). Defaults to empty for tests that start clean.
    ///   - nowMillis: injectable clock in Unix ms.
    public init(store: ContactAllowlistStore,
                coordinator: ReconnectEnrolling,
                initialAllowlist: ContactAllowlist = ContactAllowlist(),
                nowMillis: @escaping @Sendable () -> Int64 = {
                    Int64(Date().timeIntervalSince1970 * 1000)
                }) {
        self.store = store
        self.coordinator = coordinator
        self.allowlist = initialAllowlist
        self.nowMillis = nowMillis
    }

    // MARK: - Read

    /// Whether an identity is currently paired (enrolled), regardless of verification.
    public func contains(_ identity: Data) -> Bool {
        allowlist.contains(identity: identity)
    }

    /// Whether an identity is paired AND verified.
    public func isVerified(_ identity: Data) -> Bool {
        allowlist.isVerified(identity: identity)
    }

    /// The current paired identity set (a snapshot copy).
    public var pairedIdentities: Set<Data> {
        allowlist.identities
    }

    /// The number of paired contacts.
    public var count: Int {
        allowlist.count
    }

    // MARK: - Mutations (save-then-adopt)

    /// Enroll (pair) an identity. QR pair → `verified: true` (proximity
    /// authenticates); invite redeem → `verified: false` (pending SAS). Re-enrolling
    /// an existing identity replaces its record (re-pair after a key change).
    ///
    /// Save-then-adopt: persists the whole mutated set FIRST; only on success adopts
    /// it and notifies the coordinator so the contact reconnects immediately. On a
    /// persist failure NOTHING changes and `persistFailed` is thrown.
    public func enroll(identity: Data, verified: Bool) async throws {
        guard identity.count == 32 else {
            throw EnrollmentError.nonStandardIdentity(identity.count)
        }

        var updated = allowlist
        updated.enroll(identity: identity, at: nowMillis(), verified: verified)

        do {
            try store.save(updated)
        } catch {
            throw EnrollmentError.persistFailed(underlying: error)
        }

        // Persisted — adopt as the live set, THEN tell the coordinator. Order
        // matters: the coordinator is only ever told about a contact that is
        // durably on disk.
        allowlist = updated
        await coordinator.addReconnectContact(rawIdentity: identity)
    }

    /// Promote an already-enrolled identity to verified (the SAS 4-word confirm
    /// landed). No-op on the underlying set if the identity isn't paired — but we
    /// still short-circuit here to avoid a pointless whole-blob write. Save-then-
    /// adopt; does not call the coordinator (verification adds no reconnect identity —
    /// enroll already did).
    public func markVerified(identity: Data) async throws {
        // Nothing to do if not paired, or already verified — avoid a needless write.
        guard allowlist.contains(identity: identity),
              !allowlist.isVerified(identity: identity) else { return }

        var updated = allowlist
        updated.markVerified(identity: identity)

        do {
            try store.save(updated)
        } catch {
            throw EnrollmentError.persistFailed(underlying: error)
        }
        allowlist = updated
    }

    /// Remove a contact entirely — they can no longer be admitted. Save-then-adopt.
    ///
    /// NOTE (§3): this persists the removal but does NOT remove the identity from the
    /// coordinator's live reconnect set this step (no reconnect-removal method exists
    /// yet). The reconnect set is rebuilt from the persisted allowlist on next
    /// launch, so a revoked contact stops reconnecting after relaunch; the
    /// authoritative live effect lands with the gate flip (7e).
    public func revoke(identity: Data) async throws {
        guard allowlist.contains(identity: identity) else { return }

        var updated = allowlist
        updated.revoke(identity: identity)

        do {
            try store.save(updated)
        } catch {
            throw EnrollmentError.persistFailed(underlying: error)
        }
        allowlist = updated
    }
}
