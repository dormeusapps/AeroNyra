//
//  PairingService.swift
//  Security/Session
//
//  The pairing FAÇADE for the UI (STEP 7d) — the one main-actor object the
//  pairing screen talks to, so no SwiftUI view touches the session store, the
//  coordinator, or the enrollment seam directly. It adds NO new crypto: every
//  method delegates to primitives already built + threat-noted —
//    • `SignalSessionStore.localPrekeyBundle()`  (a fresh bundle per call),
//    • `PairingPayload` framing                   (CONTACT_MODEL §6),
//    • `FirstContactCoordinator.onBundle(...)`     (establishment WITH the tie-break),
//    • `EnrollmentService.mintInvite / enroll`     (INVITE_7c2.md · ENROLLMENT_7c1.md).
//
//  FRESH PAYLOAD PER OPEN. `localPrekeyBundle()` draws a fresh one-time prekey
//  each call, so we build our payload on demand (never cache at launch) to keep
//  the one-time prekey one-time (forward secrecy across pairings in a session).
//
//  QR / INVITE ENCODING. Both are base64url under a scheme —
//    QR:     aeronyra://pair/<b64url(PairingPayload.wireData)>
//    invite: aeronyra://invite/<b64url(Invite.wireData)>
//  The QR is a STRING (not raw bytes) because AVFoundation hands back
//  `stringValue`; a binary QR doesn't round-trip through it (QRScannerView).
//
//  SCOPE. 7d-1 outbound halves (show our QR · mint an invite) + 7d-2 scan-to-pair
//  (establish via the coordinator's tie-break + enroll VERIFIED, since QR is
//  proximity-authenticated). It does NOT redeem an incoming invite / emit the echo
//  (7d-3, coupled to 7c-2 emit) or run the SAS confirm (7d-4). See PAIRING_7d.md.
//

import Foundation
import Observation

@MainActor
@Observable
final class PairingService {

    @ObservationIgnored private let sessionStore: SignalSessionStore
    @ObservationIgnored private let coordinator: FirstContactCoordinator
    @ObservationIgnored private let enrollment: EnrollmentService
    @ObservationIgnored private let ourNostrPublicKey: Data?
    /// The at-rest denylist (Guideline 1.2 Block). Optional so existing tests
    /// construct without one; nil makes `block`/`unblock` throw `.blocked`-
    /// adjacent errors rather than silently no-op. Production always passes it.
    @ObservationIgnored private let blockedStore: BlockedContactsStore?

    /// v59 Stage 4: registers the ONE-SHOT invite-echo tag on the Nostr
    /// transport for the minter's npub, keyed by the invite id, so the sealed
    /// echo — the one message routed before the minter is enrolled or learned
    /// on this side — has a `p` value that is not the npub. Called immediately
    /// before each RELAY publish of the echo (`relayInviteEcho`);
    /// the transport's serial queue orders the registration ahead of the
    /// publish. Wired by the composition root; nil until then — and while nil
    /// the post-wait fallback is skipped rather than published on a pair tag.
    @ObservationIgnored var registerInviteEchoTag: ((_ minterNostrPubkey: Data, _ inviteID: Data) -> Void)?

    /// v59 Stage 4: the matching clearance, deferred in `relayInviteEcho` so the
    /// registration never outlives the one publish it brackets.
    @ObservationIgnored var unregisterInviteEchoTag: ((_ minterNostrPubkey: Data) -> Void)?

    /// Option A, Part 2: how long a redeemer whose echo went out over BLE waits
    /// for the minter's BLE ack before publishing the same echo to the relay.
    /// Production 2 s: ~4x the slowest measured in-room ack (461 ms, 7 pairings,
    /// minter foreground and backgrounded). Injectable for tests.
    @ObservationIgnored private let inviteEchoAckTimeout: Duration

    /// Option (a): the pause before the ONE retry of an invite-echo relay
    /// publish that no socket took (`.waitingForRange` — the pre-reconnect
    /// window right after a resume, when iOS has reaped the suspended app's
    /// sockets). Production 2 s: the stale-link repro published OK at +2.05 s
    /// after the 1 s reconnect backoff. Injectable for tests.
    @ObservationIgnored private let inviteEchoRelayRetryDelay: Duration

    /// What a background invite-echo delivery ended as (logged; tests await it).
    public enum InviteEchoDelivery: Equatable, Sendable {
        case acked                  // minter acked over BLE — no relay
        case relayFallbackSent      // no ack: the same echo published to the relay
        case relayFallbackFailed    // no ack, and no relay took it
        case skippedWindowPassed    // resumed after the invite window closed
        case skippedNoHook          // echo-tag hook unwired: never publish on a pair tag
        case skippedNoNpub          // invite carried no npub: nothing to fall back to
        case cancelled              // erase began: publish nothing
    }

    /// Pending background deliveries, keyed by echo envelope id — so erase can
    /// cancel every one. Each removes itself when it finishes.
    @ObservationIgnored private var inviteEchoDeliveries: [MessageID: Task<InviteEchoDelivery, Never>] = [:]

    /// The most recently started delivery, for tests to await.
    @ObservationIgnored private(set) var lastInviteEchoDelivery: Task<InviteEchoDelivery, Never>?

    /// v59 Stage 5, MINTER side: tells the Nostr transport to listen for the
    /// redeemer's echo on this invite's echo tags until it expires. Called at
    /// mint; the boot seed from the persisted ledger is the composition root's.
    @ObservationIgnored var registerInviteEchoSubscription: ((_ inviteID: Data, _ expiresAtMillis: Int64) -> Void)?

    /// The live denylist — OBSERVABLE (deliberately not ignored) so HomeView's
    /// roster filter and the Blocked Contacts list repaint the moment a
    /// block/unblock lands. This @MainActor service is the single serializing
    /// owner of the set; every mutation is save-then-adopt against the store.
    private(set) var blockedContacts: [BlockedContact]

    /// STEP 7f (REACTIVITY) — the verified-state REPAINT SIGNAL, and deliberately
    /// the ONLY stored property here that is observable. `isVerified(_:)` reads a
    /// non-observable service, so on its own it registers no SwiftUI dependency —
    /// a SAS confirm repainted nothing until something unrelated invalidated the
    /// view (the field's stale verify-gate). Views touch this inside their
    /// verified checks to register the dependency, then STILL re-read
    /// `isVerified(_:)`: the epoch is never truth. A wrong bump can only cost a
    /// spurious repaint, never a wrong verified answer.
    private(set) var verificationEpoch = 0

    /// Minter identities whose invite is being redeemed right now (the
    /// double-redeem guard in `redeemInvite`).
    @ObservationIgnored private var redeemsInFlight: Set<Data> = []

    /// Bump the repaint signal. Called UNCONDITIONALLY on every non-throwing
    /// return of a mutation that MAY have changed verified state: the enrollment
    /// layer no-ops silently (not-enrolled / already-verified), so this façade
    /// cannot tell success from no-op — and a missed bump is the stale-gate bug,
    /// while a spurious one is a single repaint that re-reads truth.
    private func bumpVerificationEpoch() { verificationEpoch += 1 }

    init(sessionStore: SignalSessionStore,
         coordinator: FirstContactCoordinator,
         enrollment: EnrollmentService,
         ourNostrPublicKey: Data?,
         blockedStore: BlockedContactsStore? = nil,
         initialBlocked: [BlockedContact] = [],
         inviteEchoAckTimeout: Duration = .seconds(2),
         inviteEchoRelayRetryDelay: Duration = .seconds(2)) {
        self.sessionStore = sessionStore
        self.coordinator = coordinator
        self.enrollment = enrollment
        self.ourNostrPublicKey = ourNostrPublicKey
        self.blockedStore = blockedStore
        self.blockedContacts = initialBlocked
        self.inviteEchoAckTimeout = inviteEchoAckTimeout
        self.inviteEchoRelayRetryDelay = inviteEchoRelayRetryDelay
    }

    // MARK: - Block / Unblock (Guideline 1.2)

    public enum BlockError: Error {
        /// No denylist store was wired (previews/tests) — never silently no-op.
        case storeUnavailable
        /// A reported contact can never be unblocked.
        case reported
    }

    /// The blocked raw-key set (snapshot). Reading this in a view body
    /// registers the observation dependency via `blockedContacts`.
    var blockedKeys: Set<Data> { Set(blockedContacts.map(\.rawKey)) }

    func isBlocked(_ rawKey: Data) -> Bool {
        blockedContacts.contains { $0.rawKey == rawKey }
    }

    /// Reported: blocked for good (see `reportAndBlock`).
    func isReported(_ rawKey: Data) -> Bool {
        blockedContacts.contains { $0.rawKey == rawKey && $0.reported }
    }

    /// Block a contact. Order:
    ///  1. persist the denylist entry (save-then-adopt — durable FIRST, with a
    ///     petname + verified snapshot so unblock can restore exactly),
    ///  2. push the live drop set into the coordinator (inbound dies NOW),
    ///  3. revoke enrollment — the SHIPPED removal machinery drops the
    ///     identity from the reconnect recognizer, beacon emission set,
    ///     verified gate, and presence, so nothing is ever transmitted toward
    ///     them again (blocking is silent; they are never notified).
    /// Deliberately does NOT touch Peer/Conversation/Message rows — the
    /// history is preserved for the Blocked Contacts screen. Throws on any
    /// persist failure with nothing half-applied that the retry can't repair.
    func block(rawKey: Data, petname: String?) async throws {
        guard let blockedStore else { throw BlockError.storeUnavailable }
        // A reported entry is stronger than a block: never downgrade it.
        guard !isReported(rawKey) else { return }
        let entry = BlockedContact(rawKey: rawKey,
                                   blockedAt: Int64(Date().timeIntervalSince1970 * 1000),
                                   petname: petname,
                                   wasVerified: enrollment.isVerified(rawKey))
        var updated = blockedContacts.filter { $0.rawKey != rawKey }
        updated.append(entry)
        try blockedStore.save(updated)
        blockedContacts = updated
        await coordinator.setBlockedIdentities(blockedKeys)
        // Revoke may no-op (already removed) — that's fine; on a persist throw
        // the deny entry + drop set stay in force (blocked wins) and the UI
        // surfaces the failure for retry.
        try await enrollment.revoke(identity: rawKey)
        bumpVerificationEpoch()
    }

    /// Unblock: re-enroll from the snapshot (the libsignal session was never
    /// torn down, so messaging resumes on the existing ratchet), then remove
    /// the denylist entry and release the coordinator's drop set.
    func unblock(rawKey: Data) async throws {
        guard let blockedStore else { throw BlockError.storeUnavailable }
        guard let entry = blockedContacts.first(where: { $0.rawKey == rawKey }) else { return }
        // Reported = blocked for good: the contact can never pair again.
        guard !entry.reported else { throw BlockError.reported }
        try await enrollment.enroll(identity: rawKey, verified: entry.wasVerified)
        let updated = blockedContacts.filter { $0.rawKey != rawKey }
        try blockedStore.save(updated)
        blockedContacts = updated
        await coordinator.setBlockedIdentities(blockedKeys)
        bumpVerificationEpoch()
    }

    /// Report + block + never pair again (Guideline 1.2): called only once a
    /// report has been SENT. Order:
    ///  1. persist the denylist entry flagged `reported` (keeping the first
    ///     block's date and verified snapshot if already blocked),
    ///  2. push the live drop set into the coordinator (inbound dies NOW),
    ///  3. revoke enrollment (a no-op if a plain block already did),
    ///  4. delete the libsignal session — nothing can ever resume on it,
    ///     because `unblock` refuses a reported entry. Throws on failure; a
    ///     retry is safe (every step is idempotent).
    /// Like `block`, it does NOT touch Peer/Conversation/Message rows: the
    /// chat stays, marked reported, as the user's evidence.
    func reportAndBlock(rawKey: Data, petname: String?) async throws {
        guard let blockedStore else { throw BlockError.storeUnavailable }
        let existing = blockedContacts.first { $0.rawKey == rawKey }
        let entry = BlockedContact(rawKey: rawKey,
                                   blockedAt: existing?.blockedAt ?? Int64(Date().timeIntervalSince1970 * 1000),
                                   petname: petname ?? existing?.petname,
                                   wasVerified: existing?.wasVerified ?? enrollment.isVerified(rawKey),
                                   reported: true)
        var updated = blockedContacts.filter { $0.rawKey != rawKey }
        updated.append(entry)
        try blockedStore.save(updated)
        blockedContacts = updated
        await coordinator.setBlockedIdentities(blockedKeys)
        try await enrollment.revoke(identity: rawKey)
        defer { bumpVerificationEpoch() }
        guard rawKey.count == 32 else { return }   // `peerIdentity` traps otherwise
        try sessionStore.deleteSession(with: sessionStore.peerIdentity(fromRawKey: rawKey))
    }

    // MARK: - Our payload (QR / invite source)

    /// Build OUR pairing payload FRESH: a new prekey bundle (fresh one-time
    /// prekey) plus our Nostr key.
    func makeOurPayload() throws -> PairingPayload {
        PairingPayload(bundle: try sessionStore.localPrekeyBundle(),
                       nostrPublicKey: ourNostrPublicKey)
    }

    /// Our payload as wire bytes.
    func makeOurPayloadWire() throws -> Data {
        try makeOurPayload().wireData()
    }

    /// Our QR string: the payload as base64url under the pair scheme. A STRING so
    /// AVFoundation's `stringValue` round-trips it on the scanning side.
    func makeOurQRString() throws -> String {
        "aeronyra://pair/" + Self.base64URLEncode(try makeOurPayloadWire())
    }

    /// Our own identity fingerprint (hex of our X25519 identity key), for the
    /// Settings "your identity" row. Read-only; never transmitted here.
    var myFingerprint: String { sessionStore.localIdentity.userIDHex }

    // MARK: - SAS verification (7d-4)

    /// The 4-word SAS phrase for a paired peer. Deterministic from BOTH identity
    /// keys, so both phones show the SAME words — users read them aloud, and a
    /// match proves no key was swapped during pairing. Uses the canonical PGP list.
    func sasWords(forPeerRawKey raw: Data) throws -> [String] {
        let payload = try sessionStore.safetyNumberPayload(withPeerRawKey: raw)
        return SASWordPhrase.phrase(fromFingerprint: payload, wordCount: 4, using: .pgp)
    }

    /// Whether this contact is already verified (SAS confirmed, or QR-paired).
    func isVerified(_ rawKey: Data) -> Bool { enrollment.isVerified(rawKey) }

    /// Promote a paired contact to verified after the 4 words matched.
    func markVerified(_ rawKey: Data) async throws {
        try await enrollment.markVerified(identity: rawKey)
        bumpVerificationEpoch()
    }

    /// Remove a paired contact entirely (Remove Contact). Delegates to
    /// `EnrollmentService.revoke`: persists the allowlist removal (save-then-
    /// adopt), then drops the identity from the live reconnect AND verified
    /// gates — they cannot reconnect or message again without re-pairing.
    /// THEN deletes the libsignal session (trust first: only after the revoke
    /// is saved). A surviving session would be reused by a same-key re-pair —
    /// an old-ratchet message still opens — so a failed delete THROWS; a retry
    /// is safe (the revoke is then a no-op) and rewrites the file without it.
    /// Block is different on purpose: it keeps the session so unblock resumes.
    func revoke(_ rawKey: Data) async throws {
        try await enrollment.revoke(identity: rawKey)
        defer { bumpVerificationEpoch() }
        guard rawKey.count == 32 else { return }   // `peerIdentity` traps otherwise
        try sessionStore.deleteSession(with: sessionStore.peerIdentity(fromRawKey: rawKey))
    }

    // MARK: - SAS "Doesn't match" (CONTACT_MODEL §4.2 step 5)

    public enum DiscardError: Error {
        /// Not a 32-byte raw identity key (would trap in `peerIdentity`).
        case invalidKey
        /// The contact is VERIFIED: this path never removes a verified contact.
        case refusedVerified
    }

    /// The four words did not match: abort the pairing. Nothing is sent — in a
    /// real attack any notice would reach the attacker. Rows are NOT touched here:
    /// the UI deletes them only after the chat has left the screen.
    ///
    /// ORDER (each step runs only if every earlier one succeeded; a throw stops
    /// everything after it, and a retry is safe — each step is a no-op once done):
    ///  1. Refuse a malformed key or a VERIFIED contact. Trust only shrinks here,
    ///     and only for an unverified pairing.
    ///  2. Cancel EVERY open invite. Synchronous, so it completes before revoke's
    ///     first suspension: no `redeemEcho` can re-enroll anyone during the
    ///     revoke, the same key included.
    ///  3. Revoke: the allowlist is saved without the contact FIRST, then the
    ///     live reconnect + verified gates drop it.
    ///  4. Delete the libsignal session. THROWS rather than logging: a surviving
    ///     session is reused by a same-key re-pair (an old-ratchet message still
    ///     opens). A retry rewrites the file without it.
    ///  5. Repaint (once the revoke has succeeded, even if step 4 throws).
    func discardMismatchedPairing(_ rawKey: Data) async throws {
        guard rawKey.count == 32 else { throw DiscardError.invalidKey }
        guard !enrollment.isVerified(rawKey) else { throw DiscardError.refusedVerified }
        try enrollment.cancelAllInvites()
        try await enrollment.revoke(identity: rawKey)
        defer { bumpVerificationEpoch() }
        try sessionStore.deleteSession(with: sessionStore.peerIdentity(fromRawKey: rawKey))
        RedactLog.event("SAS mismatch: pairing discarded — invites cancelled, contact revoked, session deleted",
                        "")
    }

    // MARK: - Invite mint (remote pairing, outbound half)

    /// Mint a fresh single-use invite carrying our payload; return the shareable
    /// string. The invite is registered + persisted in the burn ledger before this
    /// returns (save-then-adopt).
    func mintInviteString(ttlMillis: Int64 = Invite.defaultTTLMillis) async throws -> String {
        let payload = try makeOurPayload()
        let invite = try await enrollment.mintInvite(payload: payload, ttlMillis: ttlMillis)
        // v59: start listening for the echo on the invite-echo tags NOW, before
        // the string is even shared — a fast redeemer must find us subscribed.
        registerInviteEchoSubscription?(invite.id, invite.expiresAt)
        return Self.encodeInvite(invite)
    }

    static func encodeInvite(_ invite: Invite) -> String {
        "aeronyra://invite/" + base64URLEncode(invite.wireData())
    }

    // MARK: - Scan to pair (7d-2, in-person -> VERIFIED)

    public enum PairError: Error {
        case unrecognized   // not an aeronyra://pair/... string / bad base64
        case malformed      // decoded bytes aren't a valid PairingPayload
        case selfScan       // it's our own code
        case expired        // an invite whose TTL has passed (redeem path)
        case blocked        // identity is on the denylist — unblock to pair again
        case reported       // identity was reported — never paired again, never unblocked
        case redeemInProgress // this minter's invite is already being redeemed
    }

    public struct PairResult: Sendable {
        /// The paired peer's raw 32-byte identity key.
        public let rawKey: Data
        /// A short human hint (first 6 hex of the key) for the success line.
        public let hint: String
    }

    /// What an invite redeem did. RETURNED, not thrown: `.alreadyPaired` is
    /// not a failure (a healthy pair re-opening its own link lands there), and
    /// callers switch on this exhaustively — no `default` — so a new call site
    /// cannot silently report one case as the other.
    public enum RedeemOutcome: Sendable {
        /// Session established, echo routed, minter enrolled unverified.
        case redeemed(PairResult)
        /// The minter was already enrolled: a NO-OP — nothing sent, nothing
        /// written (the read-compare-decide guard in `redeemInvite`).
        case alreadyPaired(hint: String)
    }

    /// Pair from a scanned QR string. Decodes the peer's payload, ESTABLISHES a
    /// session via the coordinator (which applies the higher-key-initiates
    /// tie-break, so both scanners don't cross-init the ratchets), and ENROLLS the
    /// peer VERIFIED — QR is proximity-authenticated, so no SAS is needed
    /// (CONTACT_MODEL section 4.1). The coordinator's `.established` event makes the
    /// peer a row on the initiator's side; the responder's row forms on the first
    /// message (X3DH: the initiator speaks first).
    ///
    /// Establishment reuses `onBundle` via a SYNTHETIC link — sanctioned by the
    /// coordinator header ("a bundle pasted from a QR code enters the SAME onBundle
    /// path"). The synthetic UUID is never in `reachableLinks`, so it adds no false
    /// presence; `noteReconnectContact` there and `addReconnectContact` from enroll
    /// both dedup, so the double-notify is harmless.
    @discardableResult
    func pairFromScanned(_ scanned: String) async throws -> PairResult {
        guard let b64 = Self.parsePairScheme(scanned),
              let wire = Self.base64URLDecode(b64) else {
            throw PairError.unrecognized
        }
        guard let payload = PairingPayload(wire: wire) else {
            throw PairError.malformed
        }

        let peer = try sessionStore.peerIdentity(from: payload.bundle)
        let rawKey = sessionStore.rawPublicKey(of: peer)

        guard rawKey != sessionStore.rawPublicKey(of: sessionStore.localIdentity) else {
            throw PairError.selfScan
        }

        // BLOCKED (Guideline 1.2) — a blocked identity is refused BEFORE any
        // enroll or establishment. Silent re-admission is exactly what Block
        // must prevent; the user unblocks first (Settings → Blocked Contacts).
        // A REPORTED identity is refused as such: it can never be unblocked.
        guard !isReported(rawKey) else { throw PairError.reported }
        guard !isBlocked(rawKey) else { throw PairError.blocked }

        // ORDER (Finding A): enroll FIRST — onBundle's 7e closed-contact gate
        // reads the live enrolled set, and its own header assumes pairing
        // enrolls before it runs. On a fresh install the old order dropped the
        // scanned bundle at that gate, then enrolled anyway: a verified
        // contact with no session and no way to ever get one. Establish
        // second, and roll the enrollment back if the bundle was dropped or
        // establishment failed, so that state is unreachable.
        try await enrollment.enroll(identity: rawKey, verified: true)
        bumpVerificationEpoch()

        switch await coordinator.onBundle(link: UUID(), data: payload.bundle.data) {
        case .initiated, .responder:
            break   // .responder is healthy: the higher-key peer initiates and
                    // our session forms on their first message.
        case .malformed, .droppedUnenrolled, .initiateFailed:
            try? await enrollment.revoke(identity: rawKey)
            bumpVerificationEpoch()   // the rollback un-verifies — repaint too
            throw PairError.malformed
        }

        // npub parity with redeemInvite: the scanned payload can carry the
        // peer's Nostr key. Without this, a QR-paired contact has no far path
        // until the BLE announce happens to fire on a later reconnect.
        if let npub = payload.nostrPublicKey {
            await coordinator.learnNostrIdentity(peerKey: rawKey, nostrPubkey: npub)
        }

        return PairResult(rawKey: rawKey, hint: String(peer.userIDHex.prefix(6)).uppercased())
    }

    // MARK: - Redeem an invite (7d-3, remote -> UNVERIFIED)

    /// Redeem a remote invite string (`aeronyra://invite/<b64url>`). Decodes the
    /// `Invite`, checks it's still live, then asks the coordinator to establish a
    /// session from the initiator's bundle AND seal the echo back (so the
    /// initiator burns the single-use id + enrolls us). Finally enrolls the
    /// initiator UNVERIFIED — the 4-word SAS confirm (PeerSettings) is the MITM
    /// defense; the TTL is only a blast-radius bound (per Invite.swift).
    /// Returns `.alreadyPaired` when the minter is already enrolled (see the
    /// read-compare-decide guard below): a no-op, reported distinctly.
    func redeemInvite(_ string: String) async throws -> RedeemOutcome {
        // Human-transport tolerance lives HERE and only here — the binary
        // layer (Invite / PairingPayload init?(wire:)) stays byte-strict.
        let cleaned = Self.normalizeInviteTransportString(string)
        guard let b64 = Self.parseInviteScheme(cleaned),
              let wire = Self.base64URLDecode(b64),
              let invite = Invite(wire: wire) else {
            throw PairError.unrecognized
        }

        let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
        guard invite.isLive(at: nowMillis) else { throw PairError.expired }

        let payload = invite.payload
        let peer = try sessionStore.peerIdentity(from: payload.bundle)
        let rawKey = sessionStore.rawPublicKey(of: peer)

        guard rawKey != sessionStore.rawPublicKey(of: sessionStore.localIdentity) else {
            throw PairError.selfScan   // our own invite
        }

        // BLOCKED (Guideline 1.2) — refuse an invite minted by a blocked
        // identity before any establishment/echo/enroll (see pairFromScanned).
        guard !isReported(rawKey) else { throw PairError.reported }
        guard !isBlocked(rawKey) else { throw PairError.blocked }

        // DOUBLE-REDEEM GUARD. The same invite can arrive twice at once — a
        // tapped link AND a paste, or two differently encoded URLs. Both would
        // pass the enrolled check below before either enrolls, both would
        // establish from the same bundle, and the second session would replace
        // the first: the minter opens echo 1, the redeemer keeps session 2, and
        // every message after fails silently. Keyed on the MINTER's identity,
        // checked and claimed synchronously on the main actor before the first
        // suspension, released on every exit.
        guard !redeemsInFlight.contains(rawKey) else { throw PairError.redeemInProgress }
        redeemsInFlight.insert(rawKey)
        defer { redeemsInFlight.remove(rawKey) }

        // READ-COMPARE-DECIDE (Finding B). The invite channel is explicitly
        // untrusted (CONTACT_MODEL §2) and the Invite envelope is
        // unauthenticated, so a REPLAYED invite — captured from a text thread
        // inside the TTL window — reaches this line. An identity we already
        // hold a pairing with must be a NO-OP: re-running enroll would replace
        // the allowlist record and silently downgrade an SAS-verified contact
        // to unverified — the exact downgrade redeemInviteEcho's minter side
        // refuses (CONTACT_MODEL §8: established pairs never re-pair). No
        // re-establish either: unauthenticated input never replaces a working
        // ratchet; the minter's unburned id just expires. Recovery for a peer
        // who lost state (reinstall) is Remove Contact → redeem, which routes
        // through revoke and lands below as unenrolled.
        //
        // KNOWN GAP, not compliance: a CHANGED key cannot be matched to "the
        // same contact" here — contact identity IS the key — so a key change
        // (or a MITM substitution) arrives as an unenrolled identity and takes
        // the path below, presenting as an unlabeled duplicate contact with
        // the same SAS prompt as any new pairing. CONTACT_MODEL §9's editor's
        // note concedes there is no session-layer detection surface, and the
        // KEYCHANGE_7c3.md it defers to does not exist on disk. Nothing marks
        // "this looks like an existing contact under a new key."
        //
        // REPORTED, NOT SILENT: this branch used to return the same PairResult
        // as a real redeem, so "invite redeemed" showed while nothing was sent
        // — indistinguishable from success, and a minter who never completed
        // stayed blank with no signal to either side. It now returns
        // `.alreadyPaired`. The no-op is unchanged: we return BEFORE the
        // echo-tag registration, the coordinator, and enroll below.
        if enrollment.contains(rawKey) {
            RedactLog.event("invite-redeem: already paired — no-op, nothing sent",
                            "")
            return .alreadyPaired(hint: String(peer.userIDHex.prefix(6)).uppercased())
        }

        // Option A, Part 2 — establish, then echo over BLE ONLY. The relay leg
        // is taken here, never inside the coordinator:
        //   • no BLE link  → publish the same echo to the relay NOW (the old
        //     Tier-2 path, same register → publish → unregister sequence);
        //   • BLE sent     → finish + enroll + return, then a background task
        //     waits for the minter's BLE ack and publishes to the relay only
        //     if none arrives in time.
        // The echo-tag registration brackets each relay publish and nothing
        // else, so it is never held across the ack wait — where the redeemer's
        // own announce reply could otherwise consume it.
        let send = try await coordinator.sendInviteEcho(bundle: payload.bundle,
                                                        inviteID: invite.id)
        if send.bleState != .sent {
            guard let minterNpub = payload.nostrPublicKey else {
                throw TransportError.sendFailed        // no link and no npub: nothing carries it
            }
            RedactLog.event("invite-echo: no BLE link — relay now", "")
            let windowEnd = invite.expiresAt + Invite.defaultSkewMillis
            let state = await relayInviteEcho(send.envelope, minterNpub: minterNpub,
                                              inviteID: invite.id,
                                              mayRetry: { Int64(Date().timeIntervalSince1970 * 1000) <= windowEnd })
            guard state == .sent || state == .cast else { throw TransportError.sendFailed }
        }
        // The echo left on at least one rail: make the minter a row.
        try await coordinator.finishInviteRedeem(bundle: payload.bundle,
                                                 nostrRecipient: payload.nostrPublicKey)
        // Remote pairing → unverified until the SAS words are confirmed.
        do {
            try await enrollment.enroll(identity: rawKey, verified: false)
        } catch {
            if send.bleState == .sent { await coordinator.forgetInviteEchoAck(send.envelope.id) }
            throw error
        }

        if send.bleState == .sent {
            startInviteEchoDelivery(send.envelope, minterNpub: payload.nostrPublicKey,
                                    inviteID: invite.id,
                                    windowEndMillis: invite.expiresAt + Invite.defaultSkewMillis)
        }
        return .redeemed(PairResult(rawKey: rawKey, hint: String(peer.userIDHex.prefix(6)).uppercased()))
    }

    // MARK: - Invite-echo relay leg (Option A, Part 2)

    /// Publish the echo to the relay, with ONE bounded retry (option (a)):
    /// attempts at 0 s and +`inviteEchoRelayRetryDelay`, and a retry ONLY when
    /// no socket took the first (`.waitingForRange`). `.notDelivered`
    /// (untaggable / no router) is terminal and `.cast` is never re-sent, so
    /// the echo is never published twice. `mayRetry` is checked AFTER the
    /// pause (erase cancelled? window closed?) and before the second attempt.
    private func relayInviteEcho(_ echo: Envelope, minterNpub: Data, inviteID: Data,
                                 mayRetry: () -> Bool) async -> MessageDeliveryState {
        let first = await relayInviteEchoOnce(echo, minterNpub: minterNpub, inviteID: inviteID)
        guard first == .waitingForRange else { return first }
        RedactLog.event("invite-echo: relay publish missed — retry 1/1 in 2s", "")
        try? await Task.sleep(for: inviteEchoRelayRetryDelay)
        guard mayRetry() else { return first }
        return await relayInviteEchoOnce(echo, minterNpub: minterNpub, inviteID: inviteID)
    }

    /// ONE publish under its ONE-SHOT echo tag: register → publish →
    /// unregister, and nothing in between. Each attempt is its own bracket (a
    /// failed attempt has already consumed its registration), so the tag is
    /// never held across the retry pause and no other message to the
    /// minter's npub can inherit it.
    private func relayInviteEchoOnce(_ echo: Envelope, minterNpub: Data,
                                     inviteID: Data) async -> MessageDeliveryState {
        registerInviteEchoTag?(minterNpub, inviteID)
        defer { unregisterInviteEchoTag?(minterNpub) }
        return await coordinator.publishInviteEchoOverRelay(echo, to: minterNpub)
    }

    /// Start the background ack wait for an echo BLE handed off. Returns at
    /// once; the redeem's caller never waits on it.
    private func startInviteEchoDelivery(_ echo: Envelope, minterNpub: Data?,
                                         inviteID: Data, windowEndMillis: Int64) {
        let task = Task { () -> InviteEchoDelivery in
            let outcome = await self.runInviteEchoDelivery(echo, minterNpub: minterNpub,
                                                           inviteID: inviteID,
                                                           windowEndMillis: windowEndMillis)
            self.inviteEchoDeliveries[echo.id] = nil
            return outcome
        }
        inviteEchoDeliveries[echo.id] = task
        lastInviteEchoDelivery = task
    }

    /// Wait for the ack; on none, publish the SAME echo to the relay — unless
    /// the task was cancelled (erase), the invite window has closed, or there is
    /// no safe way to tag it. Cancellation is checked after the (bounded) wait
    /// and BEFORE any registration or publish.
    private func runInviteEchoDelivery(_ echo: Envelope, minterNpub: Data?, inviteID: Data,
                                       windowEndMillis: Int64) async -> InviteEchoDelivery {
        guard let minterNpub else {
            await coordinator.forgetInviteEchoAck(echo.id)
            RedactLog.event("invite-echo: no npub — no relay fallback possible", "")
            return .skippedNoNpub
        }
        // The minter consumes only until expiry + skew: if less than the full
        // wait remains, don't wait — a later fallback would miss the window.
        let remaining = windowEndMillis - Int64(Date().timeIntervalSince1970 * 1000)
        let c = inviteEchoAckTimeout.components
        let timeoutMillis = c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000
        let wait: Duration = remaining > timeoutMillis ? inviteEchoAckTimeout : .zero
        RedactLog.event("invite-echo: waiting for ack (BLE sent)", "")

        if await coordinator.awaitInviteEchoAck(echo.id, timeout: wait) {
            RedactLog.event("invite-echo: acked — no relay", "")
            return .acked
        }
        if Task.isCancelled {
            RedactLog.event("invite-echo: no ack — cancelled, nothing published", "")
            return .cancelled
        }
        guard Int64(Date().timeIntervalSince1970 * 1000) <= windowEndMillis else {
            RedactLog.event("invite-echo: no ack — fallback skipped, window passed", "")
            return .skippedWindowPassed
        }
        guard registerInviteEchoTag != nil else {
            RedactLog.event("invite-echo: fallback skipped — echo tag hook not wired", "")
            return .skippedNoHook
        }
        let state = await relayInviteEcho(
            echo, minterNpub: minterNpub, inviteID: inviteID,
            // Before the retry: an erase cancels, and a closed window ends it.
            mayRetry: { !Task.isCancelled && Int64(Date().timeIntervalSince1970 * 1000) <= windowEndMillis })
        if state == .waitingForRange && Task.isCancelled {
            RedactLog.event("invite-echo: no ack — cancelled before the retry, nothing more published", "")
            return .cancelled
        }
        if state == .sent || state == .cast {
            RedactLog.event("invite-echo: no ack — relay fallback sent", "")
            return .relayFallbackSent
        }
        RedactLog.event("invite-echo: no ack — relay fallback failed", "")
        return .relayFallbackFailed
    }

    /// Erase path: cancel every pending invite-echo delivery before the wipe
    /// begins. A cancelled delivery finishes its bounded ack wait and then
    /// publishes nothing.
    func cancelInviteEchoDeliveries() {
        for task in inviteEchoDeliveries.values { task.cancel() }
    }

    // MARK: - base64url + scheme helpers

    /// Undo what email/text transports provably DO to a pasted invite — and
    /// nothing more: edge whitespace, one wrapping quote pair (incl. smart
    /// quotes), a percent-encoded scheme PREFIX, quoted-printable `=\r\n`
    /// soft breaks, and hard-wrap whitespace. Anything else left in the body
    /// is REJECTED downstream, never filtered: silently rewriting malformed
    /// input into well-formed different bytes would hand the structure checks
    /// input they were never meant to bless. Internal (not private) so the
    /// external KAT vectors drive this exact function.
    nonisolated static func normalizeInviteTransportString(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotePairs: [(Character, Character)] =
            [("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}")]
        for (open, close) in quotePairs
        where s.count >= 2 && s.first == open && s.last == close {
            s = String(s.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        s = Self.percentDecodeSchemePrefixOnly(s)
        // Quoted-printable soft breaks BEFORE bare-whitespace removal — the
        // `=` is only removable as part of the `=\r\n` sequence.
        s = s.replacingOccurrences(of: "=\r\n", with: "")
             .replacingOccurrences(of: "=\n", with: "")
        // Scalar-level, not Character-level: a mid-string CRLF is ONE grapheme
        // cluster equal to neither "\r" nor "\n", so a per-Character filter
        // walks right past a hard-wrapped line break.
        s.unicodeScalars.removeAll(where: {
            $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n"
        })
        return s
    }

    /// Percent-decode ONLY a percent-encoded scheme prefix
    /// ("aeronyra%3A%2F%2Finvite%2F…") and splice the body on VERBATIM. Never
    /// decode the body: a %XX escape mid-body must reach base64URLDecode's
    /// alphabet gate and reject there — decoding it would rewrite malformed
    /// input into different well-formed bytes. If the string already starts
    /// with the plain scheme, nothing is decoded at all.
    nonisolated private static func percentDecodeSchemePrefixOnly(_ s: String) -> String {
        let target = "aeronyra://invite/"
        guard !s.lowercased().hasPrefix(target),
              s.contains("%"),
              s.count >= target.count else { return s }
        for n in target.count...min(target.count * 3, s.count) {
            let head = String(s.prefix(n))
            guard head.contains("%"),
                  let decoded = head.removingPercentEncoding,
                  decoded.lowercased() == target else { continue }
            return decoded + String(s.dropFirst(n))
        }
        return s
    }

    private static func parsePairScheme(_ s: String) -> String? {
        let prefix = "aeronyra://pair/"
        guard s.hasPrefix(prefix) else { return nil }
        return String(s.dropFirst(prefix.count))
    }

    nonisolated static func parseInviteScheme(_ s: String) -> String? {
        let prefix = "aeronyra://invite/"
        guard s.count > prefix.count,
              s.prefix(prefix.count).lowercased() == prefix else { return nil }
        return String(s.dropFirst(prefix.count))
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func base64URLDecode(_ s: String) -> Data? {
        // Strict alphabet gate, BEFORE the re-pad loop: normalization removes
        // known transport artifacts; anything else must fail loudly here —
        // filtering at this layer would silently rewrite corrupt input.
        guard !s.isEmpty, s.allSatisfy({ ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_")
        }) else { return nil }
        var b = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        return Data(base64Encoded: b)
    }
}
