//
//  ReconnectResendIdentityTests.swift
//  BeaconTests
//
//  Closed-Contact STEP 0 (B2) — idempotency backstop for reconnect resend.
//
//  THE BUG THIS GUARDS AGAINST. After a reconnect, the sender's delivery timeout
//  can fire during the ack-vs-disconnect race and flip an already-delivered row
//  to .notDelivered. Auto-retry (flushUndelivered → resend) then re-seals it.
//  BEFORE B2 the re-seal minted a FRESH random envelope id, so the receiver's
//  dedup — which keys on the cleartext envelope id — saw a brand-new id and
//  stored the message a SECOND time. B2's fix: resend REUSES the wireID the row
//  was already sent under, so the re-sealed envelope carries the SAME id and the
//  receiver drops it as a duplicate.
//
//  WHAT THIS SUITE PROVES (Envelope-level — the layer the invariant lives at):
//    • the exact expression B2 introduces at the two mint sites
//      (`Envelope(id: reuseID ?? .random(), …)` in send, and
//      `(reuseID ?? .random()).bytes` in sendMedia) yields the REUSED id when one
//      is supplied and a fresh RANDOM id when it is nil (the first-send and
//      never-sealed paths);
//    • the reused id is a CLEARTEXT header field that survives the wire round
//      trip intact — so the 16 bytes the receiver dedups on are exactly the bytes
//      the sender reused; and
//    • two envelopes sharing an id are equal (and hash equal) regardless of TTL —
//      the routing identity the dedup relies on — so a resend carrying the reused
//      id is, by construction, a duplicate of the original.
//
//  WHAT THIS SUITE DELIBERATELY DOES NOT PROVE, and why (honest scope, matching
//  WarmInboundSessionsTests naming its load-bearing property as hardware-owed).
//  The coordinator-level plumbing — that FirstContactCoordinator.send/sendMedia
//  actually forward `reuseID` into these mint sites, and that resend threads
//  `message.wireID` through — is NOT exercised here. Constructing a
//  FirstContactCoordinator requires a CONCRETE `BLEMeshTransport` (its init takes
//  the concrete type, not a fakeable `MeshTransport` the way MessageRouter does),
//  and its send path additionally requires a sealable `SignalSession` plus a
//  wired `MessageRouter` returning `.sent` — machinery outside this target's
//  visible surface, and a real BLEMeshTransport would spin up CoreBluetooth in a
//  unit test. The full resend → dedup → NO-duplicate loop is therefore the
//  two-phone walk-out-and-back hardware check (SESSION_HANDOFF_v19, "AFTER THE
//  FIX"): reconnect ADMITTED both directions, sender shows DELIVERED, receiver
//  shows no duplicate.
//
//  XCTest only.
//

import XCTest
@testable import Beacon

final class ReconnectResendIdentityTests: XCTestCase {

    /// Some non-empty opaque ciphertext. Its content is irrelevant to the id
    /// invariants under test — only the cleartext `id` header matters here.
    private let ciphertext = Data([0xDE, 0xAD, 0xBE, 0xEF])

    // MARK: - The B2 mint expression: reuse when present, random when nil

    /// Resend path. A supplied reuseID becomes the envelope's id verbatim.
    /// Mirrors FirstContactCoordinator.send after B2:
    ///   let envelope = Envelope(id: reuseID ?? .random(), ciphertext: sealed)
    func testSuppliedReuseIDBecomesEnvelopeID() {
        let stored = MessageID.random()
        let reuseID: MessageID? = stored          // resend passes message.wireID (optional)
        let envelope = Envelope(id: reuseID ?? .random(), ciphertext: ciphertext)
        XCTAssertEqual(envelope.id, stored,
                       "a resend must carry the reused wireID, not a fresh one")
    }

    /// First-send / never-sealed path. A nil reuseID falls through to a fresh
    /// random id, and two such mints are distinct — a genuine new message and the
    /// never-sealed edge case each get their own id.
    func testNilReuseIDProducesFreshDistinctIDs() {
        let none: MessageID? = nil
        let first  = Envelope(id: none ?? .random(), ciphertext: ciphertext)
        let second = Envelope(id: none ?? .random(), ciphertext: ciphertext)
        XCTAssertNotEqual(first.id, second.id,
                          "a nil reuseID must mint a fresh random id each time")
    }

    /// The media mint site expresses the same rule over raw bytes.
    /// Mirrors FirstContactCoordinator.sendMedia after B2:
    ///   let idBytes = (reuseID ?? .random()).bytes
    func testMediaReuseIDBytesRoundTripToSameID() throws {
        let stored = MessageID.random()
        let reuse: MessageID? = stored            // typed exactly like the parameter
        let idBytes = (reuse ?? .random()).bytes
        let rebuilt = try XCTUnwrap(MessageID(bytes: idBytes))
        XCTAssertEqual(rebuilt, stored,
                       "the mediaID reused on resend must equal the row's wireID")
    }

    // MARK: - The reused id reaches the receiver intact (cleartext round-trip)

    /// The receiver dedups on the envelope id, which lives in the CLEARTEXT header
    /// (bytes 2..<18). If the reused id did not survive the wire round-trip, dedup
    /// could not catch the resend. This pins that it does.
    func testReusedIDSurvivesWireRoundTrip() throws {
        let reuseID = MessageID.random()
        let sent = Envelope(id: reuseID, ciphertext: ciphertext)
        let parsed = try XCTUnwrap(Envelope(wire: sent.wireData()),
                                   "a well-formed envelope must parse back")
        XCTAssertEqual(parsed.id, reuseID,
                       "the id the receiver dedups on must equal the reused id")
    }

    // MARK: - Same id ⇒ duplicate, regardless of hop budget

    /// Envelope equality/hash key ONLY on id (Envelope.swift), so a resend
    /// carrying the reused id is — by the mesh's own routing identity — the same
    /// message as the original, even after relays have spent its TTL and even
    /// though the resend's ciphertext differs. This is the property that makes the
    /// resend a dedup hit rather than a new row.
    func testSameIDEnvelopesAreEqualRegardlessOfTTLAndCiphertext() {
        let id = MessageID.random()
        let original = Envelope(ttl: Envelope.maxHops, id: id, ciphertext: ciphertext)
        let resent   = Envelope(ttl: 3,                id: id, ciphertext: Data([0x00]))
        XCTAssertEqual(original, resent,
                       "same id ⇒ same message: the resend must dedup against the original")
        XCTAssertEqual(original.hashValue, resent.hashValue,
                       "equal envelopes must hash equal so set-based dedup collapses them")
    }
}
