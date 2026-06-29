// MessageRouterRelayPolicyTests.swift
// BeaconTests
//
// Phase 8d-2 — the router's relay policy by source transport.
//
// LOCKED invariant: Nostr is not a flood mesh. An envelope that ARRIVES over the
// internet transport must reach the receiver but must NEVER be relayed/re-flooded
// onto the BLE mesh. These tests pin that two ways: the pure `shouldRelay`
// decision, and an integration test that proves it is actually wired into the
// inbound path (the source kind is threaded from `start()` into `handleInbound`).
//

import XCTest
import os
@testable import Beacon

final class MessageRouterRelayPolicyTests: XCTestCase {

    // MARK: - Pure policy

    func testShouldRelayOnlyForBLE() {
        XCTAssertTrue(MessageRouter.shouldRelay(from: .ble))
        XCTAssertFalse(MessageRouter.shouldRelay(from: .internet))
    }

    // MARK: - Wired: internet arrival is delivered but never relayed

    func testInternetInboundIsDeliveredButNeverRelayed() async throws {
        let nostr = RecordingTransport(kind: .internet)
        let delivered = expectation(description: "receiver got the envelope")
        let receiver = RecordingReceiver(onReceive: delivered)

        let router = MessageRouter(transports: [nostr])
        await router.setReceiver(receiver)
        try await router.start()

        nostr.inject(Envelope(ciphertext: Data([0x01, 0x02, 0x03])))

        // `receive` is the LAST step of handleInbound, so once it fires the relay
        // decision has already been made — asserting relayCount afterward is race-free.
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(nostr.relayCount, 0,
                       "a Nostr-arrived envelope must never be relayed")

        await router.stop()
    }
}

// MARK: - Test doubles

/// A minimal `MeshTransport` whose inbound stream the test drives directly and
/// which counts `relay` calls. The count lives in an `OSAllocatedUnfairLock`
/// (Sendable + async-safe scoped `withLock`): the router actor writes it from an
/// async context, the test reads it after a sync point.
private final class RecordingTransport: MeshTransport, @unchecked Sendable {
    let kind: TransportKind
    let incoming: AsyncStream<(link: UUID, envelope: Envelope)>
    private let cont: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation

    private let relayCounter = OSAllocatedUnfairLock(initialState: 0)
    var relayCount: Int { relayCounter.withLock { $0 } }

    init(kind: TransportKind) {
        self.kind = kind
        var c: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation!
        self.incoming = AsyncStream { c = $0 }
        self.cont = c
    }

    func inject(link: UUID = UUID(), _ envelope: Envelope) {
        cont.yield((link: link, envelope: envelope))
    }

    func start() async throws {}
    func stop() { cont.finish() }
    func send(_ envelope: Envelope) async throws {}
    func relay(_ envelope: Envelope, excludingLinks: Set<UUID>) async {
        relayCounter.withLock { $0 += 1 }
    }
}

/// A receiver that fulfills an expectation when an envelope reaches it.
private final class RecordingReceiver: EnvelopeReceiver, @unchecked Sendable {
    private let onReceive: XCTestExpectation
    init(onReceive: XCTestExpectation) { self.onReceive = onReceive }

    func receive(_ envelope: Envelope) async { onReceive.fulfill() }
    func relayExclusions(forSourceLink link: UUID) async -> Set<UUID> { [] }
}
