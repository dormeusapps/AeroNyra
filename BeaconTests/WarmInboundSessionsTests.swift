//
//  WarmInboundSessionsTests.swift
//  BeaconTests
//
//  Closed-Contact Step 5d-3 — SignalSessionStore.warmInboundSessions (Invariant
//  #1: warm the trial-decrypt cache from the allowlist at startup).
//
//  SCOPE OF THIS SUITE — read honestly. The LOAD-BEARING property of this method
//  ("a warmed wrapper opens a persisted .whisper against the on-disk ratchet
//  after relaunch") is a PERSISTENT-BACKEND property: the in-memory store is
//  discarded on relaunch and holds no on-disk ratchet, so that property cannot be
//  exercised here — it is the two-phone hardware test (§2.3 "validation owed").
//
//  What IS unit-testable against the in-memory backend, and what this suite pins:
//    • resilience — an empty list is a no-op; a malformed (non-32-byte) entry is
//      skipped rather than trapping; one bad entry never aborts the warm (the
//      launch path must not crash);
//    • the Invariant-#3 identity round-trip the warm depends on — the raw 32-byte
//      key the allowlist hands in is exactly the key the warmed session resolves
//      back to (rawPublicKey(of: peerIdentity(fromRawKey: raw)) == raw), so the
//      cache is keyed by the same identity the peer stored for us at pairing.
//
//  XCTest only.

import XCTest
@testable import Beacon

final class WarmInboundSessionsTests: XCTestCase {

    /// A deterministic, well-formed raw 32-byte identity (the allowlist form).
    /// The mapping under test prepends the 0x05 type byte; it does not validate
    /// the curve point, so deterministic bytes are sufficient here.
    private func rawKey(_ seed: UInt8) -> Data {
        Data((0..<32).map { UInt8(($0 + Int(seed)) & 0xFF) })
    }

    // MARK: Resilience (the launch path must not crash)

    func testWarmEmptyListIsNoOp() {
        let store = SignalSessionStore()           // ephemeral in-memory backend
        store.warmInboundSessions(for: [])         // must simply do nothing
    }

    func testWarmSkipsMalformedIdentitiesWithoutTrapping() {
        let store = SignalSessionStore()
        // A mix of valid 32-byte keys and malformed ones (would trap the
        // precondition in peerIdentity(fromRawKey:) if not guarded). The call
        // must return normally, warming the valid ones and skipping the rest.
        store.warmInboundSessions(for: [
            rawKey(1),
            Data(),               // empty
            Data(count: 31),      // short
            rawKey(2),
            Data(count: 33)       // long
        ])
        // Reaching here without a crash is the assertion.
    }

    // MARK: Invariant #3 — the warmed identity is the allowlist identity

    func testWarmedIdentityRoundTripsToRawKey() {
        let store = SignalSessionStore()
        let raw = rawKey(7)
        // The exact transform the warm loop applies before caching: raw → the
        // PublicIdentity that keys the session. Its raw form must equal the input,
        // i.e. the cache is keyed by the same 32 bytes the peer stored for us.
        let identity = store.peerIdentity(fromRawKey: raw)
        XCTAssertEqual(store.rawPublicKey(of: identity), raw,
                       "warm must key the cache by the allowlist's own raw identity (Invariant #3)")
    }

    // MARK: Wiring — a warmed identity is retrievable and peer-consistent

    func testWarmedIdentityIsRetrievableAndPeerConsistent() throws {
        let store = SignalSessionStore()
        let raw = rawKey(9)
        store.warmInboundSessions(for: [raw])

        // After warming, resolving the same identity yields a session whose peer
        // round-trips back to the original raw key — the warm path's identity is
        // consistent end to end (catches a peerIdentity/rawPublicKey misuse).
        let session = try store.session(with: store.peerIdentity(fromRawKey: raw))
        let resolved = try XCTUnwrap(session as? SignalSession,
                                     "expected the libsignal session adapter")
        XCTAssertEqual(store.rawPublicKey(of: resolved.peer), raw)
    }
}
