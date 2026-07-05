// MessageRouterNostrFallbackTests.swift
// BeaconTests
//
// Phase 8d-3b-i — Tier 2 of the 3-tier DM routing (BLE → Nostr → queue).
//
// When BLE reports no reachable peer, the router falls back to an addressed
// publish over the internet transport IF it knows the recipient's Nostr pubkey.
// These tests pin: fallback fires + reports .sent when a recipient is known;
// no fallback (→ .waitingForRange for Tier 3) when the recipient is unknown or
// the publish fails.
//

import XCTest
import os
@testable import Beacon

final class MessageRouterNostrFallbackTests: XCTestCase {

    private let recipient = Data((0..<32).map { UInt8($0) })
    private func anyEnvelope() -> Envelope { Envelope(ciphertext: Data([0x09])) }

    func testFallsBackToNostrWhenBLEOutOfRangeAndRecipientKnown() async {
        let nostr = RecordingAddressedTransport()
        let router = MessageRouter(transports: [FailingBLETransport(), nostr])

        let state = await router.send(anyEnvelope(), tracked: false, nostrRecipient: recipient)

        XCTAssertEqual(state, .cast)                 // handed to the relay
        XCTAssertEqual(nostr.publishedTo, [recipient])
    }

    func testNoFallbackWhenRecipientUnknown() async {
        let nostr = RecordingAddressedTransport()
        let router = MessageRouter(transports: [FailingBLETransport(), nostr])

        let state = await router.send(anyEnvelope(), tracked: false, nostrRecipient: nil)

        XCTAssertEqual(state, .waitingForRange)      // queues for Tier 3
        XCTAssertTrue(nostr.publishedTo.isEmpty)
    }

    func testPublishFailureQueuesForTier3() async {
        let nostr = RecordingAddressedTransport(shouldFail: true)
        let router = MessageRouter(transports: [FailingBLETransport(), nostr])

        let state = await router.send(anyEnvelope(), tracked: false, nostrRecipient: recipient)

        XCTAssertEqual(state, .waitingForRange)      // attempted, failed → Tier 3
        XCTAssertEqual(nostr.publishedTo, [recipient])
    }

    func testNoFallbackWhenNoAddressedTransportWired() async {
        // BLE-only router: nothing to fall back to.
        let router = MessageRouter(transports: [FailingBLETransport()])

        let state = await router.send(anyEnvelope(), tracked: false, nostrRecipient: recipient)

        XCTAssertEqual(state, .waitingForRange)
    }
}

// MARK: - Test doubles

/// A BLE transport that always reports no reachable peer, to drive the Tier-2
/// fallback branch.
private final class FailingBLETransport: MeshTransport, @unchecked Sendable {
    let kind: TransportKind = .ble
    let incoming: AsyncStream<(link: UUID, envelope: Envelope)>
    private let cont: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation

    init() {
        var c: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation!
        self.incoming = AsyncStream { c = $0 }
        self.cont = c
    }

    func start() async throws {}
    func stop() { cont.finish() }
    func send(_ envelope: Envelope) async throws { throw TransportError.noReachablePeers }
    func relay(_ envelope: Envelope, excludingLinks: Set<UUID>) async {}
}

/// An addressed (Nostr-like) transport that records every recipient it was asked
/// to publish to, and can be told to fail.
private final class RecordingAddressedTransport: MeshTransport, AddressedTransport, @unchecked Sendable {
    let kind: TransportKind = .internet
    let incoming: AsyncStream<(link: UUID, envelope: Envelope)>
    private let cont: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation

    private let shouldFail: Bool
    private let recipients = OSAllocatedUnfairLock(initialState: [Data]())
    var publishedTo: [Data] { recipients.withLock { $0 } }

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
        var c: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation!
        self.incoming = AsyncStream { c = $0 }
        self.cont = c
    }

    func start() async throws {}
    func stop() { cont.finish() }
    func send(_ envelope: Envelope) async throws { throw NostrTransportError.sendRequiresRecipient }
    func relay(_ envelope: Envelope, excludingLinks: Set<UUID>) async {}

    func publish(_ envelope: Envelope, to recipient: Data) async throws {
        recipients.withLock { $0.append(recipient) }
        if shouldFail { throw NostrTransportError.publishFailed }
    }
}
