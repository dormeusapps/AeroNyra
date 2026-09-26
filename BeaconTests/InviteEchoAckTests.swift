//
//  InviteEchoAckTests.swift
//  BeaconTests
//
//  Option A, Part 1 — the MINTER acknowledges every invite echo it opens,
//  over BLE ONLY, whether or not the echo was accepted.
//
//  Pins, on a REAL minter FirstContactCoordinator fed a REAL sealed echo from a
//  REAL redeemer session:
//    • not accepted (V1 arm): exactly one BLE envelope, which the redeemer's
//      store opens as `.ack` carrying the echo's envelope id; zero relay publishes;
//    • accepted (V2 arm, real EnrollmentService + minted invite): the minter
//      enrolls the redeemer AND emits the identical ack — no outcome on the wire;
//    • no BLE link: the ack is attempted once, fails, and still reaches NO relay
//      although an addressed transport is wired — BLE-only by construction;
//    • blocked redeemer: nothing is emitted at all (blocking stays silent).
//
//  The minter has no Nostr identity set, so its own npub announce is a no-op and
//  the ack is the only frame it can emit.
//

import XCTest
import CryptoKit
import os
@testable import Beacon

@MainActor
final class InviteEchoAckTests: XCTestCase {

    // MARK: Fixtures

    private struct Minter {
        let coordinator: FirstContactCoordinator
        let store: SignalSessionStore
        let ble: RecordingBLETransport
        let nostr: RecordingAddressedTransport
    }

    private func makeMinter(bleFails: Bool = false) async -> Minter {
        let store = SignalSessionStore()
        let coordinator = FirstContactCoordinator(store: store, transport: BLEMeshTransport())
        await coordinator.enableReconnect(
            agreementPrivate: Curve25519.KeyAgreement.PrivateKey(),
            allowlistIdentities: [],
            verifiedIdentities: [])
        let ble = RecordingBLETransport(fails: bleFails)
        let nostr = RecordingAddressedTransport()
        await coordinator.setRouter(MessageRouter(transports: [ble, nostr]))
        return Minter(coordinator: coordinator, store: store, ble: ble, nostr: nostr)
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("invite-echo-ack.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A redeemer session established from the minter's bundle, sealing `payload`
    /// as its first (prekey) message — exactly what `redeemInvite` routes.
    private func makeEcho(from redeemer: SignalSessionStore,
                          minterBundle: PrekeyBundle,
                          payload: MessagePayload) throws -> Envelope {
        let session = try redeemer.establishSession(from: minterBundle)
        return Envelope(ciphertext: try session.seal(payload.sealedPlaintext()))
    }

    /// Open `envelope` on the redeemer and require it to be `.ack` for `echoID`
    /// from the minter.
    private func assertIsAck(_ envelope: Envelope, for echoID: MessageID,
                             openedBy redeemer: SignalSessionStore,
                             from minter: SignalSessionStore,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let (sender, plaintext) = try redeemer.openInbound(envelope.ciphertext)
        XCTAssertEqual(redeemer.rawPublicKey(of: sender),
                       minter.rawPublicKey(of: minter.localIdentity),
                       "the ack must come from the minter's session", file: file, line: line)
        guard case .ack(let body)? = MessagePayload.decodeSealed(plaintext) else {
            return XCTFail("expected an .ack payload", file: file, line: line)
        }
        let parsed = try XCTUnwrap(MessagePayload.parseDeliveryAck(body), file: file, line: line)
        XCTAssertEqual(parsed.wireID, echoID, "the ack names the echo's envelope id",
                       file: file, line: line)
    }

    // MARK: Not accepted (V1 arm) — ack still sent, BLE only

    func testUnacceptedV1EchoIsAckedOverBLEOnly() async throws {
        let m = await makeMinter()           // no invite redeemer wired → not accepted
        let redeemer = SignalSessionStore()
        let echo = try makeEcho(from: redeemer,
                                minterBundle: try m.store.localPrekeyBundle(),
                                payload: .inviteEchoV1(inviteID: Data(repeating: 0x11, count: 16)))

        await m.coordinator.receive(echo)

        XCTAssertEqual(m.ble.sent.count, 1, "exactly one BLE envelope: the ack")
        XCTAssertTrue(m.nostr.publishedTo.isEmpty, "the ack never reaches a relay")
        try assertIsAck(m.ble.sent[0], for: echo.id, openedBy: redeemer, from: m.store)
    }

    // MARK: Accepted (V2 arm) — identical ack, no outcome on the wire

    func testAcceptedV2EchoEnrollsAndIsAckedIdentically() async throws {
        let m = await makeMinter()
        let dir = try makeTempDirectory()
        let enrollment = EnrollmentService(
            store: try ContactAllowlistStore(
                directory: dir, dek: SymmetricKey(size: .bits256),
                keychainService: "test.echo-ack.\(UUID().uuidString)"),
            pendingStore: try PendingInvitesStore(
                directory: dir, dek: SymmetricKey(size: .bits256),
                keychainService: "test.echo-ack.pending.\(UUID().uuidString)"),
            coordinator: m.coordinator)
        await m.coordinator.setInviteRedeemer(enrollment)
        let invite = try await enrollment.mintInvite(
            payload: PairingPayload(bundle: try m.store.localPrekeyBundle(), nostrPublicKey: nil))

        let redeemer = SignalSessionStore()
        let redeemerRaw = redeemer.rawPublicKey(of: redeemer.localIdentity)
        let echo = try makeEcho(from: redeemer,
                                minterBundle: invite.payload.bundle,
                                payload: .inviteEchoV2(inviteID: invite.id,
                                                       redeemerNostrPubkey: Data(repeating: 0x22, count: 32)))

        await m.coordinator.receive(echo)

        XCTAssertTrue(enrollment.contains(redeemerRaw), "accepted: the minter enrolled the redeemer")
        XCTAssertEqual(m.ble.sent.count, 1, "exactly one BLE envelope: the ack")
        XCTAssertTrue(m.nostr.publishedTo.isEmpty, "the ack never reaches a relay")
        try assertIsAck(m.ble.sent[0], for: echo.id, openedBy: redeemer, from: m.store)
    }

    // MARK: No BLE link — attempted once, and still no relay

    func testNoBLELinkNeverFallsBackToRelay() async throws {
        let m = await makeMinter(bleFails: true)
        let redeemer = SignalSessionStore()
        let echo = try makeEcho(from: redeemer,
                                minterBundle: try m.store.localPrekeyBundle(),
                                payload: .inviteEchoV1(inviteID: Data(repeating: 0x33, count: 16)))

        await m.coordinator.receive(echo)

        XCTAssertEqual(m.ble.attempts, 1, "the ack was attempted on BLE")
        XCTAssertTrue(m.ble.sent.isEmpty)
        XCTAssertTrue(m.nostr.publishedTo.isEmpty,
                      "no BLE link must NOT fall back to a relay, though one is wired")
    }

    // MARK: Blocked redeemer — nothing emitted

    func testBlockedRedeemerGetsNoAck() async throws {
        let m = await makeMinter()
        let redeemer = SignalSessionStore()
        await m.coordinator.setBlockedIdentities([redeemer.rawPublicKey(of: redeemer.localIdentity)])
        let echo = try makeEcho(from: redeemer,
                                minterBundle: try m.store.localPrekeyBundle(),
                                payload: .inviteEchoV1(inviteID: Data(repeating: 0x44, count: 16)))

        await m.coordinator.receive(echo)

        XCTAssertEqual(m.ble.attempts, 0, "blocking is silent: no ack attempted")
        XCTAssertTrue(m.nostr.publishedTo.isEmpty)
    }
}

// MARK: - Test doubles

/// A BLE transport that records every send; in `fails` mode it counts the
/// attempt and throws `noReachablePeers`, as the real one does with no link.
private final class RecordingBLETransport: MeshTransport, @unchecked Sendable {
    let kind: TransportKind = .ble
    let incoming: AsyncStream<(link: UUID, envelope: Envelope)>
    private let cont: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation
    private let fails: Bool
    private let log = OSAllocatedUnfairLock(initialState: (attempts: 0, sent: [Envelope]()))
    var attempts: Int { log.withLock { $0.attempts } }
    var sent: [Envelope] { log.withLock { $0.sent } }

    init(fails: Bool) {
        self.fails = fails
        var c: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation!
        self.incoming = AsyncStream { c = $0 }
        self.cont = c
    }

    func start() async throws {}
    func stop() { cont.finish() }
    func send(_ envelope: Envelope) async throws {
        log.withLock { $0.attempts += 1 }
        if fails { throw TransportError.noReachablePeers }
        log.withLock { $0.sent.append(envelope) }
    }
    func relay(_ envelope: Envelope, excludingLinks: Set<UUID>) async {}
}

/// An addressed (relay) transport that records every recipient it publishes to.
private final class RecordingAddressedTransport: MeshTransport, AddressedTransport, @unchecked Sendable {
    let kind: TransportKind = .internet
    let incoming: AsyncStream<(link: UUID, envelope: Envelope)>
    private let cont: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation
    private let recipients = OSAllocatedUnfairLock(initialState: [Data]())
    var publishedTo: [Data] { recipients.withLock { $0 } }

    init() {
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
    }
}
