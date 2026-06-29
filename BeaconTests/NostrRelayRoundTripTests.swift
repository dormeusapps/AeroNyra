// NostrRelayRoundTripTests.swift
// BeaconTests
//
// LIVE integration test (Phase 8d) — proves a gift wrap round-trips through a
// REAL relay: publish an Envelope addressed to our OWN pubkey, and confirm the
// SAME envelope comes back via our subscription, unwrapped. This exercises the
// whole transport loop (wrap → ["EVENT"] → relay → ["EVENT"] back → unwrap →
// incoming) with NO libsignal session and NO second device — the Nostr layer
// treats the Envelope as opaque bytes.
//
// SKIPPED BY DEFAULT so it never hits the network during a normal `Cmd+U`.
// To run it: edit the scheme → Test → Arguments → Environment Variables, add
//   NOSTR_LIVE = 1
// then run this test (or the whole suite). Without that var it reports "skipped".
//

import XCTest
import os
@testable import Beacon

final class NostrRelayRoundTripTests: XCTestCase {

    func testGiftWrapRoundTripsThroughLiveRelay() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NOSTR_LIVE"] == "1",
                          "live relay test — set NOSTR_LIVE=1 in the scheme to run")

        // A fresh ephemeral identity — no Keychain, no first-contact needed.
        let secret = Data((1...32).map { UInt8($0) })            // valid scalar
        let pub = try XCTUnwrap(Secp256k1.xOnlyPublicKey(fromSecretKey: secret))
        let url = try XCTUnwrap(URL(string: "wss://relay.damus.io"))
        let transport = NostrTransport(relayURL: url, ourSecretKey: secret, ourPublicKey: pub)

        // The opaque payload we want to see survive the trip. Tagged unique so a
        // stray event from another run can't accidentally satisfy us.
        let marker = "nostr-roundtrip-\(UUID().uuidString)"
        let original = Envelope(ciphertext: Data(marker.utf8))

        let returned = expectation(description: "our envelope returns via the relay")
        let consumer = Task {
            for await (_, env) in transport.incoming where env.id == original.id {
                returned.fulfill()
                break
            }
        }

        try await transport.start()

        // Let the REQ register (EOSE) and tolerate the occasional cold-connect
        // retry before publishing; retry the publish if the socket is mid-reconnect.
        try await Task.sleep(for: .seconds(4))
        try await publishWithRetry(transport, original, to: pub, attempts: 3)

        await fulfillment(of: [returned], timeout: 25)

        consumer.cancel()
        transport.stop()
    }

    /// Publish, retrying on a transient `.notConnected` (the cold-connect -1011
    /// we sometimes see triggers a 1s reconnect before the socket is ready).
    private func publishWithRetry(_ transport: NostrTransport,
                                  _ envelope: Envelope,
                                  to pubkey: Data,
                                  attempts: Int) async throws {
        var lastError: Error?
        for _ in 0..<attempts {
            do {
                try await transport.publish(envelope, to: pubkey)
                return
            } catch {
                lastError = error
                try? await Task.sleep(for: .seconds(1))
            }
        }
        throw lastError ?? NostrTransportError.publishFailed
    }
}
