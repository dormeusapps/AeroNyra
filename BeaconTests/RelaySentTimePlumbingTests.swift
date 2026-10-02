//
//  RelaySentTimePlumbingTests.swift
//  BeaconTests
//
//  Pins the relay send-time plumbing (v68 §5a, commit C3 — carried, not yet
//  read): a relay copy reaches `EnvelopeReceiver.receive` with its INNER
//  rumor `created_at` in Unix seconds (the sender's real clock; the outer gift
//  wrap is back-dated at random), and a Bluetooth frame reaches it with nil.
//  Both run the transports' REAL inbound handlers through the DEBUG seams,
//  then a router.
//

import XCTest
@testable import Beacon

#if DEBUG
final class RelaySentTimePlumbingTests: XCTestCase {

    private let ourSecret = Data((1...32).map { UInt8($0) })
    private let senderSecret = Data((0x40...0x5f).map { UInt8($0) })
    private let tagHex = String(repeating: "ab", count: 32)
    private let fixedNow: Int64 = 1_700_000_000

    private func envelope(_ marker: UInt8) -> Envelope {
        Envelope(ciphertext: Data(repeating: marker, count: 40))
    }

    private func wrap(_ envelope: Envelope, now: Int64) throws -> NostrEvent {
        let ourPub = try XCTUnwrap(Secp256k1.xOnlyPublicKey(fromSecretKey: ourSecret))
        return try NostrGiftWrap.wrap(envelope: envelope, senderSecret: senderSecret,
                                      peerPublicKey: ourPub, recipientTagHex: tagHex, now: now)
    }

    private func eventFrame(_ wrap: NostrEvent) throws -> Data {
        let obj = try JSONSerialization.jsonObject(with: try XCTUnwrap(wrap.jsonData()))
        return try JSONSerialization.data(withJSONObject: ["EVENT", "abcdef0123456789", obj])
    }

    /// The next element a transport yields, or nil after 3 s.
    private func next(
        _ stream: AsyncStream<(link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)>
    ) async -> (link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)? {
        var iterator = stream.makeAsyncIterator()
        return await withTaskGroup(of: (link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)?.self) { group in
            group.addTask { await iterator.next() }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Feeds one transport element through a real `MessageRouter` and returns
    /// what `receive` was handed.
    private func routed(
        _ element: (link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?),
        kind: TransportKind
    ) async throws -> TimeRecordingReceiver.Received? {
        let transport = InjectingTransport(kind: kind)
        let receiver = TimeRecordingReceiver()
        let router = MessageRouter(transports: [transport])
        await router.setReceiver(receiver)
        try await router.start()
        transport.inject(element)
        let got = await receiver.first()
        await router.stop()
        return got
    }

    // MARK: - Known answer: the inner time is exact, the outer one is not

    func testUnwrapDetailedReturnsTheExactRumorTimeAndTheOuterTimeIsRandomised() throws {
        var outerTimes: [Int64] = []
        for i in 0..<20 {
            let env = envelope(UInt8(i))
            let w = try wrap(env, now: fixedNow)
            let opened = try NostrGiftWrap.unwrapDetailed(giftWrap: w, mySecret: ourSecret)
            XCTAssertEqual(opened.rumorCreatedAtSeconds, fixedNow, "wrap \(i): the inner time is exact")
            XCTAssertEqual(opened.envelope.wireData(), env.wireData())
            XCTAssertLessThanOrEqual(w.createdAt, fixedNow)
            XCTAssertGreaterThanOrEqual(w.createdAt, fixedNow - 2 * 24 * 60 * 60)
            outerTimes.append(w.createdAt)
        }
        // Each outer time is now minus a random 0…172,800 s, so a single one can
        // equal `now` (p = 1/172,801). Over 20 wraps: at most one may, and they
        // must not all be the same.
        XCTAssertLessThanOrEqual(outerTimes.filter { $0 == fixedNow }.count, 1,
                                 "the outer wrap's time must differ from the rumor's")
        XCTAssertGreaterThan(Set(outerTimes).count, 1, "the outer time is randomised")
    }

    func testUnwrapStillReturnsTheSameEnvelopeAndSender() throws {
        let env = envelope(0x11)
        let w = try wrap(env, now: fixedNow)
        let plain = try NostrGiftWrap.unwrap(giftWrap: w, mySecret: ourSecret)
        let detailed = try NostrGiftWrap.unwrapDetailed(giftWrap: w, mySecret: ourSecret)
        XCTAssertEqual(plain.envelope.wireData(), detailed.envelope.wireData())
        XCTAssertEqual(plain.senderPublicKey, detailed.senderPublicKey)
    }

    // MARK: - Transport → router → receive

    func testRelayInboundCarriesRumorTime() async throws {
        let ourPub = try XCTUnwrap(Secp256k1.xOnlyPublicKey(fromSecretKey: ourSecret))
        let nostr = NostrTransport(relayURLs: [URL(string: "wss://relay.invalid")!],
                                   ourSecretKey: ourSecret, ourPublicKey: ourPub)
        let env = envelope(0x22)
        nostr.injectInboundFrameForTesting(try eventFrame(try wrap(env, now: fixedNow)))

        let element = try await XCTUnwrapAsync(await next(nostr.incoming), "the relay copy surfaced")
        XCTAssertEqual(element.relaySentAtSeconds, fixedNow, "the transport yields the rumor time")

        let received = try await XCTUnwrapAsync(try await routed(element, kind: .internet),
                                                "the router handed it to receive")
        XCTAssertEqual(received.id, env.id)
        XCTAssertEqual(received.relaySentAtSeconds, fixedNow, "receive gets the rumor time")
    }

    func testBLEInboundCarriesNoRelayTime() async throws {
        let ble = BLEMeshTransport()
        let env = envelope(0x33)
        ble._testDispatchEnvelopeFrame(env.wireData(), from: UUID())

        let element = try await XCTUnwrapAsync(await next(ble.incoming), "the Bluetooth frame surfaced")
        XCTAssertNil(element.relaySentAtSeconds, "Bluetooth has no send time")

        let received = try await XCTUnwrapAsync(try await routed(element, kind: .ble),
                                                "the router handed it to receive")
        XCTAssertEqual(received.id, env.id)
        XCTAssertNil(received.relaySentAtSeconds, "receive gets nil")
    }

    private func XCTUnwrapAsync<T>(_ value: T?, _ message: String) async throws -> T {
        try XCTUnwrap(value, message)
    }
}

// MARK: - Test doubles

/// Re-yields exactly the element it is given, so the router sees what the real
/// transport produced.
private final class InjectingTransport: MeshTransport, @unchecked Sendable {
    let kind: TransportKind
    let incoming: AsyncStream<(link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)>
    private let cont: AsyncStream<(link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)>.Continuation

    init(kind: TransportKind) {
        self.kind = kind
        var c: AsyncStream<(link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)>.Continuation!
        self.incoming = AsyncStream { c = $0 }
        self.cont = c
    }

    func inject(_ element: (link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)) {
        cont.yield(element)
    }

    func start() async throws {}
    func stop() { cont.finish() }
    func send(_ envelope: Envelope) async throws {}
    func relay(_ envelope: Envelope, excludingLinks: Set<UUID>) async {}
}

/// Records the first `receive` call's envelope id and relay time.
private actor TimeRecordingReceiver: EnvelopeReceiver {
    struct Received: Sendable {
        let id: MessageID
        let relaySentAtSeconds: Int64?
    }
    private var received: Received?
    private var waiter: CheckedContinuation<Received?, Never>?

    func receive(_ envelope: Envelope, relaySentAtSeconds: Int64?) async {
        let r = Received(id: envelope.id, relaySentAtSeconds: relaySentAtSeconds)
        guard received == nil else { return }
        received = r
        waiter?.resume(returning: r)
        waiter = nil
    }

    func relayExclusions(forSourceLink link: UUID) async -> Set<UUID> { [] }

    /// The first received envelope, or nil after 3 s.
    func first() async -> Received? {
        if let received { return received }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await self?.expire()
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { waiter = $0 }
    }

    private func expire() {
        waiter?.resume(returning: nil)
        waiter = nil
    }
}
#endif
