//
//  NostrInboxTagTableOwner.swift
//  Core/Nostr
//
//  v59 connection-leak fix · Stage 4 · who builds the table and keeps it current.
//
//  MEMBERSHIP × JOIN. The table needs two things from two owners:
//    • membership — the ENROLLED set (`EnrollmentService.pairedIdentities`,
//      i.e. `ContactAllowlist.identities`). Block revokes, unblock re-enrolls,
//      remove-contact revokes: the same set the BLE recognizer and the 7f
//      gates already key on. Peer-row lifetime is the wrong key — a blocked
//      contact keeps its row for the Blocked Contacts screen.
//    • the join — each contact's npub, which lives ONLY on the Peer row
//      (`Peer.nostrPubkey`, written by `MessageInbox.handleLearnedNostrIdentity`).
//  Both are read through injected closures so this type has no SwiftData or
//  enrollment import and is unit-testable with dictionaries.
//
//  REBUILT WHOLE, SYNCHRONOUSLY, ON THE MAIN ACTOR. `rebuild()` reads live
//  state and pushes the finished value with NO suspension point between the
//  read and the write, so whichever rebuild executes last always reads the
//  newest state and writes the newest table — execution order cannot produce
//  a stale write. Two sources feed it and a whole rebuild is one X25519 derive
//  per contact (sub-millisecond for 60), so in-place mutation buys nothing and
//  would need a reference type shared across the main actor and the transport
//  queue.
//
//  ORDERING OF SCHEDULED REBUILDS — a GENERATION COUNTER, not an inline await.
//  Enrollment events arrive on the adapter from `EnrollmentService`, a plain
//  class whose callers interleave at suspension points (`PairingService` is
//  @MainActor; the coordinator calls `redeemEcho` from its own actor), so an
//  inline await would give no event ordering anyway and would put a SwiftData
//  fetch per contact on the pairing path. Instead every trigger bumps
//  `generation` and schedules one main-actor task; a task whose generation has
//  been superseded does nothing. Since each rebuild reads LIVE authoritative
//  state at execution, only the newest scheduled rebuild needs to run for the
//  table to be right, and a fast revoke-then-enroll cannot leave the loser's
//  stale table on the transport. `rebuild()` itself stays callable directly
//  for the boot seed, where ordering is trivially linear.
//
//  A THROW NEVER BREAKS ENROLLMENT AND NEVER ZEROES THE TABLE. The adapter's
//  `ReconnectEnrolling` methods cannot throw by signature; it forwards to the
//  coordinator FIRST (the live pairing path is unchanged), then schedules.
//  `DiscoverySecret.derive` can throw on a malformed identity; the builder is
//  spec'd to throw on ANY bad key, so this owner validates PER IDENTITY, drops
//  an offender with a loud log (count only, never the key), and builds from
//  the survivors. Compare the BLE side, which `try?`s its plan and silently
//  keeps a stale cache (`FirstContactCoordinator.refreshRecognizerCache`).
//
//  BOOT WINDOW. The transport connects in `mesh.start()`; the composition root
//  calls `rebuild()` BEFORE that, from a direct Peer fetch on the main context,
//  so no publish can precede a table. Later rebuilds come from the adapter
//  (enroll / revoke) and from the inbox hook (a learned or rotated npub).
//

import Foundation
import CryptoKit
import os

@MainActor
public final class NostrInboxTagTableOwner {

    private let ourAgreementPrivate: Curve25519.KeyAgreement.PrivateKey
    private let ourIdentity: Data
    private let identities: @MainActor () -> Set<Data>
    private let nostrPubkey: @MainActor (Data) -> Data?
    private let sink: @MainActor (NostrInboxTagTable) -> Void

    /// Bumped by every `scheduleRebuild`; a scheduled task runs only if it still
    /// holds the newest generation.
    private var generation: UInt64 = 0

    /// The last table pushed to the sink (nil before the first rebuild).
    public private(set) var current: NostrInboxTagTable?
    /// Identities dropped by the last rebuild for failing `DiscoverySecret.derive`.
    public private(set) var lastDroppedCount = 0
    /// How many rebuilds have actually executed (tests assert coalescing).
    public private(set) var rebuildCount = 0

    /// - Parameters:
    ///   - ourAgreementPrivate: our identity X25519 key-agreement private key
    ///     (`IdentityKeypair.agreement`), the same key `enableReconnect` receives.
    ///   - ourIdentity: our raw 32-byte identity (`store.rawPublicKey(of:)` for
    ///     our own identity) — the label on everything we publish.
    ///   - identities: the ENROLLED set, read live at each rebuild.
    ///   - nostrPubkey: the npub for a raw identity, or nil (subscribe-only row).
    ///   - sink: receives each rebuilt table (the transport's `setTagTable`).
    public init(ourAgreementPrivate: Curve25519.KeyAgreement.PrivateKey,
                ourIdentity: Data,
                identities: @escaping @MainActor () -> Set<Data>,
                nostrPubkey: @escaping @MainActor (Data) -> Data?,
                sink: @escaping @MainActor (NostrInboxTagTable) -> Void) {
        precondition(ourIdentity.count == NostrInboxTag.labelLength,
                     "ourIdentity must be a \(NostrInboxTag.labelLength)-byte raw identity key, got \(ourIdentity.count)")
        self.ourAgreementPrivate = ourAgreementPrivate
        self.ourIdentity = ourIdentity
        self.identities = identities
        self.nostrPubkey = nostrPubkey
        self.sink = sink
    }

    // MARK: Rebuild (synchronous — no suspension between read and write)

    /// Read live membership + joins, build the whole table, push it. Returns
    /// the table pushed. Identities whose key fails `DiscoverySecret.derive`
    /// are dropped and counted, never allowed to zero the table.
    @discardableResult
    public func rebuild() -> NostrInboxTagTable {
        var rows: [NostrInboxTagTable.Row] = []
        var dropped = 0
        // Sorted so a rebuild from the same set is byte-identical (Set order is
        // not stable); the table sorts its subscribe set anyway, this keeps
        // `rows` and therefore `==` deterministic too.
        for identity in identities().sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            do {
                let secret = try DiscoverySecret.derive(ourAgreementPrivate: ourAgreementPrivate,
                                                        theirAgreementPublic: identity)
                rows.append(NostrInboxTagTable.Row(identity: identity,
                                                   secret: DiscoverySecret.rawBytes(of: secret),
                                                   nostrPubkey: nostrPubkey(identity)))
            } catch {
                dropped += 1
            }
        }
        if dropped > 0 {
            RedactLog.event("inbox-tag: DROPPED \(dropped) contact(s) with an invalid identity key from the tag table", "")
        }
        let table = NostrInboxTagTable(ourIdentity: ourIdentity, rows: rows)
        lastDroppedCount = dropped
        rebuildCount += 1
        current = table
        sink(table)
        return table
    }

    /// Coalescing, order-independent trigger: bumps the generation and runs a
    /// rebuild on the main actor only if no newer trigger has arrived by then.
    public func scheduleRebuild() {
        generation &+= 1
        let mine = generation
        Task { @MainActor [weak self] in
            guard let self, self.generation == mine else { return }   // superseded
            self.rebuild()
        }
    }
}

// MARK: - Enrollment adapter

/// Sits between `EnrollmentService` and the coordinator on the live pairing
/// path. Forwards every `ReconnectEnrolling` call to the coordinator FIRST —
/// unchanged behavior — then schedules a table rebuild for the calls that
/// change MEMBERSHIP (enroll / revoke). Verified-state changes do not change
/// membership and only forward. Cannot throw by signature; the owner never
/// throws into it.
public final class NostrInboxTagEnrollmentAdapter: ReconnectEnrolling, @unchecked Sendable {

    private let coordinator: ReconnectEnrolling
    private let ownerLock = OSAllocatedUnfairLock<NostrInboxTagTableOwner?>(initialState: nil)

    public init(coordinator: ReconnectEnrolling) {
        self.coordinator = coordinator
    }

    /// Attach the owner once it exists. Events before attachment reach the
    /// coordinator only; the owner's first `rebuild()` reads the live set, so
    /// nothing is lost.
    public func attach(_ owner: NostrInboxTagTableOwner) {
        ownerLock.withLock { $0 = owner }
    }

    public func addReconnectContact(rawIdentity: Data) async {
        await coordinator.addReconnectContact(rawIdentity: rawIdentity)
        await scheduleRebuild()
    }

    public func removeReconnectContact(rawIdentity: Data) async {
        await coordinator.removeReconnectContact(rawIdentity: rawIdentity)
        await scheduleRebuild()
    }

    public func addVerifiedContact(rawIdentity: Data) async {
        await coordinator.addVerifiedContact(rawIdentity: rawIdentity)
    }

    public func removeVerifiedContact(rawIdentity: Data) async {
        await coordinator.removeVerifiedContact(rawIdentity: rawIdentity)
    }

    private func scheduleRebuild() async {
        guard let owner = ownerLock.withLock({ $0 }) else { return }
        await owner.scheduleRebuild()
    }
}
