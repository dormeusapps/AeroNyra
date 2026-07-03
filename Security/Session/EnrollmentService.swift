//
//  EnrollmentService.swift
//  Security/Session
//
//  THE single owner of the live closed-contact admission set AND the single-use
//  invite ledger (STEP 7c-1 admission · 7c-2 ledger · GROUND_TRUTH §3.4/§3.5/§3.6
//  · ENROLLMENT_7c1.md · INVITE_7c2.md).
//
//  WHY THIS EXISTS. `ContactAllowlistStore` and `PendingInvitesStore` are both
//  WHOLE-BLOB load/save — every save writes the entire set as one sealed file. Two
//  concurrent mutations that each did load→mutate→save would race: the second
//  overwrites the first, silently dropping a contact (or an invite id) from a
//  security-relevant set with no error. This service is the one owner that
//  serializes every mutation. It is `@MainActor`, holds the live `ContactAllowlist`
//  AND the live `PendingInvites` in memory (loaded ONCE at construction), and
//  re-persists the whole blob on each mutation. Actor confinement makes
//  read-modify-write atomic; no concurrent save can race.
//
//  WRITE ORDERING — SAVE-THEN-ADOPT (decided, §3/§6 of the threat notes). Every
//  mutation: build a mutated COPY → `store.save(copy)` FIRST → only on success
//  adopt the copy as the live set → only then notify anyone downstream. If the save
//  throws, the live set, the persisted file, and any downstream state are ALL
//  unchanged, and the error propagates for the caller to retry. This guarantees the
//  live sets only ever reflect what is durably on disk.
//
//  INVITE REDEEM ORDER (INVITE_7c2.md §6). redeemEcho does consume → persist the
//  burn FIRST → adopt → THEN enroll(verified:false). A crash can never leave a
//  consumed id re-consumable, and the unverified contact only appears once the burn
//  is durable. The identity is validated BEFORE the burn, so a malformed identity
//  never spends an invite. If the (separate) allowlist save then fails, the invite
//  is spent but the contact isn't added — a wasted invite, retried with a fresh
//  one; NOT a security hole. The reverse order WOULD be one (a live, replayable
//  invite), so this ordering is deliberate.
//
//  TRANSITIONS (§4). QR pair → enroll(verified: true) (proximity authenticates).
//  Invite mint → mintInvite (no enrollment yet). Invite redeem (valid echo) →
//  enroll(verified: false) (pending the SAS). SAS match → markVerified. An invite
//  can NEVER self-verify; verified: true is only ever set by an explicit QR enroll
//  or a SAS markVerified.
//
//  SCOPE. This is the data layer of "add a contact" AND the owner of the single-use
//  invite ledger (mint/redeem, save-then-adopt against PendingInvitesStore). It
//  does NOT build pairing UI (7d), wire the echo transport (7c-2 step 5 — a sealed
//  MessagePayload routed here by MessageRouter), raise the key-change alert (7c-3),
//  or flip the admission gate (7e). Live revoke-from-reconnect is deferred (the
//  coordinator has no reconnect-removal method yet; a revoked contact stops
//  reconnecting after relaunch, authoritative at 7e).
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
    /// STEP 7e: drop a revoked identity from the LIVE reconnect/admission set so
    /// the gate stops admitting them immediately (not only after a relaunch).
    func removeReconnectContact(rawIdentity: Data) async
}

/// The narrow contract the coordinator's receive-path needs to redeem an invite
/// echo: burn the echoed id single-use and, on a valid burn, enroll the redeemer
/// (unverified). Twin of `ReconnectEnrolling`, in the other direction — the
/// coordinator holds THIS weakly (it already holds the router weakly for the same
/// reason), so there is no retain cycle with the service, which holds the
/// coordinator strongly via `ReconnectEnrolling`. `EnrollmentService.redeemEcho`
/// satisfies it; the seam depends on this, not the concrete service, so the
/// coordinator stays decoupled and is testable with a spy.
public protocol InviteRedeeming: AnyObject, Sendable {
    func redeemEcho(inviteID: Data, redeemerIdentity: Data) async throws -> Bool
}

@MainActor
public final class EnrollmentService {

    /// Errors surfaced to the caller (the pairing flow, 7d).
    public enum EnrollmentError: Error {
        /// The identity handed in wasn't the expected raw 32-byte key form.
        case nonStandardIdentity(Int)
        /// Persisting a mutated set failed; NOTHING was adopted — the live set, the
        /// disk file, and any downstream state are all unchanged. Retryable.
        case persistFailed(underlying: Error)
    }

    /// The persisted at-rest allowlist store (whole-blob). The SAME instance the
    /// composition root holds; `save`/`load` go through it.
    private let store: ContactAllowlistStore

    /// The persisted at-rest invite ledger store (whole-blob). Same instance the
    /// composition root constructs; `save` goes through it on mint/redeem.
    private let pendingStore: PendingInvitesStore

    /// The reconnect layer to notify on a successful enroll, so a newly-paired
    /// contact reconnects immediately (no relaunch). Depends on the narrow
    /// `ReconnectEnrolling` contract, not the concrete coordinator.
    private let coordinator: ReconnectEnrolling

    /// The live admission set — the in-memory source of truth after construction.
    /// Re-persisted whole on every mutation via save-then-adopt.
    private var allowlist: ContactAllowlist

    /// The live single-use invite ledger — the in-memory source of truth after
    /// construction. Re-persisted whole on mint/redeem via save-then-adopt.
    private var pending: PendingInvites

    /// "Now" as Unix MILLISECONDS (matching `ContactAllowlist.enroll(at:)`, the
    /// codec's `pairedAt`, and `Invite`'s mint/expiry). Injected so tests are
    /// deterministic. The ONE place the ms conversion lives — a seconds/ms slip here
    /// would silently write a wrong timestamp into a security record.
    private let nowMillis: @Sendable () -> Int64

    /// - Parameters:
    ///   - store: the at-rest allowlist store (shared with the composition root).
    ///   - pendingStore: the at-rest invite-ledger store (shared with the root).
    ///   - coordinator: the reconnect layer to notify on enroll (the concrete
    ///     `FirstContactCoordinator` in production; a spy in tests).
    ///   - initialAllowlist: the already-loaded paired set (the composition root
    ///     loads it once at startup to seed reconnect; pass that same value so we
    ///     don't re-read the file). Defaults to empty for tests that start clean.
    ///   - initialPending: the already-loaded invite ledger (the root loads it once;
    ///     pass that value). Pruned in RAM at construction against `nowMillis()` so
    ///     the live ledger is bounded from the first mutation; expired ids are inert
    ///     to `consume`/`isPending` regardless, and the next mint persists the
    ///     pruned ledger, so no eager disk write is needed here. Defaults to empty.
    ///   - nowMillis: injectable clock in Unix ms.
    public init(store: ContactAllowlistStore,
                pendingStore: PendingInvitesStore,
                coordinator: ReconnectEnrolling,
                initialAllowlist: ContactAllowlist = ContactAllowlist(),
                initialPending: PendingInvites = PendingInvites(),
                nowMillis: @escaping @Sendable () -> Int64 = {
                    Int64(Date().timeIntervalSince1970 * 1000)
                }) {
        self.store = store
        self.pendingStore = pendingStore
        self.coordinator = coordinator
        self.allowlist = initialAllowlist
        self.nowMillis = nowMillis

        // Prune expired invites in RAM at construction (bounded from launch).
        var seeded = initialPending
        seeded.prune(at: nowMillis())
        self.pending = seeded
    }

    // MARK: - Read (allowlist)

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

    // MARK: - Read (invite ledger)

    /// The number of invites currently registered (live-or-expired-until-pruned).
    public var pendingInviteCount: Int {
        pending.count
    }

    /// Whether `id` is a currently-live pending invite at `now`.
    public func isInvitePending(_ id: Data) -> Bool {
        pending.isPending(id: id, at: nowMillis())
    }

    // MARK: - Mutations: allowlist (save-then-adopt)

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
    /// landed). Short-circuits if not paired or already verified to avoid a
    /// pointless whole-blob write. Save-then-adopt; does not call the coordinator
    /// (verification adds no reconnect identity — enroll already did).
    public func markVerified(identity: Data) async throws {
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
        // Persisted — adopt as the live set, THEN drop from the live gate. Order
        // matches enroll: durable first, live-effect second (STEP 7e). A revoked
        // contact is no longer admitted or present immediately, not after relaunch.
        allowlist = updated
        await coordinator.removeReconnectContact(rawIdentity: identity)
    }

    // MARK: - Mutations: invite ledger (save-then-adopt)

    /// Mint a fresh single-use invite for `payload`, register it in the burn ledger,
    /// and persist the ledger BEFORE returning it. Save-then-adopt: build a pruned
    /// copy with the new id → `pendingStore.save` FIRST → adopt on success → return
    /// the invite for 7d to share over any channel. No coordinator notify — nothing
    /// is enrolled at mint. On a persist failure NOTHING changes and `persistFailed`
    /// is thrown (no in-RAM id that isn't on disk, so single-use accounting can't be
    /// silently lost by a crash).
    public func mintInvite(payload: PairingPayload,
                           ttlMillis: Int64 = Invite.defaultTTLMillis) async throws -> Invite {
        let now = nowMillis()
        let invite = Invite.mint(payload: payload, now: now, ttlMillis: ttlMillis)

        var updated = pending
        updated.prune(at: now)            // opportunistic bound on every mint
        updated.register(invite)

        do {
            try pendingStore.save(updated)
        } catch {
            throw EnrollmentError.persistFailed(underlying: error)
        }
        pending = updated
        return invite
    }

    /// Redeem an invite-echo: burn the echoed id EXACTLY ONCE and, on a valid burn,
    /// enroll the redeemer as an UNVERIFIED contact (pending the SAS). Returns
    /// whether the echo was valid — an unknown / replayed / expired id returns
    /// `false` and changes nothing. A malformed redeemer identity THROWS before any
    /// burn (so it can never spend an invite). A persist failure (of the burn or the
    /// subsequent enroll) THROWS.
    ///
    /// Order (INVITE_7c2.md §6): validate identity → consume → persist the burn FIRST
    /// → adopt → THEN enroll(verified:false). Keeps the burn durable before the
    /// contact is added; a crash can never leave a consumed id re-consumable.
    public func redeemEcho(inviteID: Data, redeemerIdentity: Data) async throws -> Bool {
        guard redeemerIdentity.count == 32 else {
            throw EnrollmentError.nonStandardIdentity(redeemerIdentity.count)
        }

        let now = nowMillis()
        var updated = pending
        guard updated.consume(id: inviteID, at: now) else {
            return false            // unknown / replay / expired — no-op, no enroll
        }

        do {
            try pendingStore.save(updated)
        } catch {
            throw EnrollmentError.persistFailed(underlying: error)
        }
        pending = updated           // burn is now durable

        // Only after the burn is on disk do we add the contact (unverified, pending
        // the SAS). enroll runs its own save-then-adopt against the allowlist store.
        try await enroll(identity: redeemerIdentity, verified: false)
        return true
    }
}

// MARK: - InviteRedeeming conformance (STEP 7c-2)
//
// `redeemEcho(inviteID:redeemerIdentity:)` above already matches the protocol
// requirement. From OUTSIDE the main actor the method is implicitly async — the
// caller awaits, hopping onto the main actor — so a `@MainActor` method satisfies
// the nonisolated `async throws` requirement, and an empty conformance is enough.
extension EnrollmentService: InviteRedeeming {}
