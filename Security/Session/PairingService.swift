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

    init(sessionStore: SignalSessionStore,
         coordinator: FirstContactCoordinator,
         enrollment: EnrollmentService,
         ourNostrPublicKey: Data?) {
        self.sessionStore = sessionStore
        self.coordinator = coordinator
        self.enrollment = enrollment
        self.ourNostrPublicKey = ourNostrPublicKey
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
    }

    /// Remove a paired contact entirely (Remove Contact). Delegates to
    /// `EnrollmentService.revoke`: persists the allowlist removal (save-then-
    /// adopt), then drops the identity from the live reconnect AND verified
    /// gates — they cannot reconnect or message again without re-pairing.
    func revoke(_ rawKey: Data) async throws {
        try await enrollment.revoke(identity: rawKey)
    }

    // MARK: - Invite mint (remote pairing, outbound half)

    /// Mint a fresh single-use invite carrying our payload; return the shareable
    /// string. The invite is registered + persisted in the burn ledger before this
    /// returns (save-then-adopt).
    func mintInviteString(ttlMillis: Int64 = Invite.defaultTTLMillis) async throws -> String {
        let payload = try makeOurPayload()
        let invite = try await enrollment.mintInvite(payload: payload, ttlMillis: ttlMillis)
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
    }

    public struct PairResult: Sendable {
        /// The paired peer's raw 32-byte identity key.
        public let rawKey: Data
        /// A short human hint (first 6 hex of the key) for the success line.
        public let hint: String
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

        // ORDER (Finding A): enroll FIRST — onBundle's 7e closed-contact gate
        // reads the live enrolled set, and its own header assumes pairing
        // enrolls before it runs. On a fresh install the old order dropped the
        // scanned bundle at that gate, then enrolled anyway: a verified
        // contact with no session and no way to ever get one. Establish
        // second, and roll the enrollment back if the bundle was dropped or
        // establishment failed, so that state is unreachable.
        try await enrollment.enroll(identity: rawKey, verified: true)

        switch await coordinator.onBundle(link: UUID(), data: payload.bundle.data) {
        case .initiated, .responder:
            break   // .responder is healthy: the higher-key peer initiates and
                    // our session forms on their first message.
        case .malformed, .droppedUnenrolled, .initiateFailed:
            try? await enrollment.revoke(identity: rawKey)
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
    @discardableResult
    func redeemInvite(_ string: String) async throws -> PairResult {
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
        if enrollment.contains(rawKey) {
            return PairResult(rawKey: rawKey,
                              hint: String(peer.userIDHex.prefix(6)).uppercased())
        }

        // Establish from their bundle + echo back (Nostr-capable for a far peer).
        _ = try await coordinator.redeemInvite(bundle: payload.bundle,
                                               inviteID: invite.id,
                                               nostrRecipient: payload.nostrPublicKey)
        // Remote pairing → unverified until the SAS words are confirmed.
        try await enrollment.enroll(identity: rawKey, verified: false)

        return PairResult(rawKey: rawKey, hint: String(peer.userIDHex.prefix(6)).uppercased())
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
