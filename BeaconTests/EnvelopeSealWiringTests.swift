//
//  EnvelopeSealWiringTests.swift
//  BeaconTests
//
//  Pins EnvelopeSeal as WIRED into the session layer:
//   • what a RELAYING phone sees of a first-contact (prekey) message: the
//     seal version byte and random-looking bytes — never the sender's
//     identity key, never the libsignal `.preKey` type byte;
//   • FLAG DAY: plain (unsealed) libsignal bytes are refused, and a refusal
//     consumes nothing (the real sealed message still opens afterwards);
//   • a message sealed to someone else is refused;
//   • an envelope this phone CANNOT unseal is still RELAYED — unseal failure
//     never affects forwarding (the router forwards before it hands off);
//   • the seal key IS the identity key (the raw key a peer seals to).
//

import XCTest
import CryptoKit
import os
@testable import Beacon

final class EnvelopeSealWiringTests: XCTestCase {

    // MARK: Fixtures

    private struct Party {
        let keys: IdentityKeypair
        let store: SignalSessionStore
        var raw: Data { store.rawPublicKey(of: store.localIdentity) }
    }
    private func party() -> Party {
        let k = IdentityKeypair.generate()
        return Party(keys: k, store: SignalSessionStore(appIdentity: k))
    }

    /// Bob's FIRST message to Alice: a prekey message, sealed.
    private func firstContact(from bob: Party, to alice: Party) throws -> Data {
        let s = try bob.store.establishSession(from: try alice.store.localPrekeyBundle())
        return try s.seal(Data("hello".utf8))
    }

    // MARK: What a relaying phone sees

    func testRelayerSeesNeitherTheSenderIdentityKeyNorThePreKeyMarker() throws {
        let alice = party(), bob = party()
        let wire = try firstContact(from: bob, to: alice)

        XCTAssertEqual(wire.first, EnvelopeSeal.version, "every session message starts with the seal version")
        XCTAssertNil(wire.range(of: bob.raw), "the sender's raw identity key must not appear")
        XCTAssertNil(wire.range(of: Data([0x05]) + bob.raw), "nor its serialized form")

        // It WAS a first-contact message: inside the seal, libsignal's type byte is prekey (3).
        let inner = try EnvelopeSeal.open(wire, with: alice.keys.agreement)
        XCTAssertEqual(inner.first, 3, "precondition: the inner message is a prekey message")
        XCTAssertNotNil(inner.range(of: bob.raw), "precondition: the key IS inside, only hidden")

        let opened = try alice.store.openInbound(wire)
        XCTAssertEqual(opened.plaintext, Data("hello".utf8))
        XCTAssertEqual(alice.store.rawPublicKey(of: opened.peer), bob.raw)
    }

    // MARK: Flag day

    func testPlainUnsealedLibsignalBytesAreRefusedAndConsumeNothing() throws {
        let alice = party(), bob = party()
        let wire = try firstContact(from: bob, to: alice)
        let plain = try EnvelopeSeal.open(wire, with: alice.keys.agreement)   // what an old build sends

        XCTAssertThrowsError(try alice.store.openInbound(plain)) {
            XCTAssertEqual($0 as? EnvelopeSeal.SealError, .notSealed)
        }
        XCTAssertThrowsError(try alice.store.session(with: bob.store.localIdentity).open(plain))
        // The refusal happened before libsignal: the prekey is still there.
        XCTAssertEqual(try alice.store.openInbound(wire).plaintext, Data("hello".utf8))
    }

    func testMessageSealedToSomeoneElseIsRefused() throws {
        let alice = party(), bob = party(), carol = party()
        let toCarol = try firstContact(from: bob, to: carol)
        XCTAssertThrowsError(try alice.store.openInbound(toCarol))
    }

    // MARK: The seal key is the identity key

    func testSealKeyIsTheIdentityKey() {
        let p = party()
        XCTAssertEqual(p.keys.agreement.publicKey.rawRepresentation, p.raw)
    }

    // MARK: Unseal failure never affects relaying

    func testEnvelopeWeCannotUnsealIsStillRelayed() async throws {
        let alice = party(), bob = party(), carol = party()
        let coordinator = FirstContactCoordinator(store: alice.store, transport: BLEMeshTransport())
        let ble = RelayCountingTransport()
        let router = MessageRouter(transports: [ble])
        let receiver = ForwardingReceiver(inner: coordinator)
        await router.setReceiver(receiver)
        try await router.start()

        // Sealed to Carol (not us) — and plain garbage. Neither opens here.
        let notForUs = Envelope(ciphertext: try firstContact(from: bob, to: carol))
        let garbage = Envelope(ciphertext: Data(repeating: 0x42, count: 120))
        ble.inject(notForUs)
        ble.inject(garbage)

        await receiver.waitForReceives(2)   // receive is the LAST step: relay already decided
        XCTAssertEqual(ble.relayed, [notForUs.id, garbage.id],
                       "an envelope we cannot unseal must still be forwarded")
        await router.stop()
    }
}

// MARK: - Test doubles

private final class RelayCountingTransport: MeshTransport, @unchecked Sendable {
    let kind: TransportKind = .ble
    let incoming: AsyncStream<(link: UUID, envelope: Envelope)>
    private let cont: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation
    private let relayLog = OSAllocatedUnfairLock(initialState: [MessageID]())
    var relayed: [MessageID] { relayLog.withLock { $0 } }

    init() {
        var c: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation!
        incoming = AsyncStream { c = $0 }
        cont = c
    }
    func inject(_ e: Envelope) { cont.yield((link: UUID(), envelope: e)) }
    func start() async throws {}
    func stop() { cont.finish() }
    func send(_ envelope: Envelope) async throws {}
    func relay(_ envelope: Envelope, excludingLinks: Set<UUID>) async {
        relayLog.withLock { $0.append(envelope.id) }
    }
}

/// Hands every envelope to the REAL coordinator (the real unseal path), then
/// counts it; `waitForReceives` returns once `n` have fully passed through.
private actor ForwardingReceiver: EnvelopeReceiver {
    let inner: FirstContactCoordinator
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    init(inner: FirstContactCoordinator) { self.inner = inner }

    func receive(_ envelope: Envelope) async {
        await inner.receive(envelope)
        count += 1
        waiters.removeAll { n, c in
            if count >= n { c.resume(); return true }
            return false
        }
    }
    func relayExclusions(forSourceLink link: UUID) async -> Set<UUID> {
        await inner.relayExclusions(forSourceLink: link)
    }
    func waitForReceives(_ n: Int) async {
        if count >= n { return }
        await withCheckedContinuation { waiters.append((n, $0)) }
    }
}
