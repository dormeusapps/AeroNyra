//
//  NostrTransportInboundTests.swift
//  BeaconTests
//
//  v59 connection-leak fix · Stage 5 — the assertion Stage 1 could not make.
//
//  KAT §5 requires proof that NOTHING on the receive path reads the `p` tag.
//  The unwrap half was pinned in NostrInboxTagTests; the handler half was
//  inspection-only because `handleInboundEventLocked` is private. The
//  transport now exposes an internal seam that runs the REAL frame handler on
//  its queue, so this suite feeds relay-shaped EVENT frames whose `p` value is
//  an inbox tag, the recipient npub, garbage, or empty — and asserts the
//  identical envelope reaches `incoming` for each. It also pins what the
//  handler DOES gate on: kind (a non-1059 never surfaces) and the replay
//  ledger (the same event id surfaces once).
//
//  XCTest only (not Swift Testing), per project standard.
//

import XCTest
@testable import Beacon

// The seam this suite drives exists only in DEBUG builds (the Test action
// builds Debug). Compiling the suite out in any other configuration keeps a
// Release test run from failing on a symbol that, by design, is not there.
#if DEBUG
final class NostrTransportInboundTests: XCTestCase {

    private let ourSecret = Data((1...32).map { UInt8($0) })
    private let senderSecret = Data((0x40...0x5f).map { UInt8($0) })

    private func makeTransport() -> NostrTransport {
        let pub = Secp256k1.xOnlyPublicKey(fromSecretKey: ourSecret)!
        return NostrTransport(relayURLs: [URL(string: "wss://relay.invalid")!],
                              ourSecretKey: ourSecret, ourPublicKey: pub)
    }

    private func envelope(_ marker: UInt8) -> Envelope {
        Envelope(ciphertext: Data(repeating: marker, count: 40))
    }

    /// A relay-shaped `["EVENT", subid, {…}]` frame carrying a real wrap to us
    /// with the given `p` value.
    private func eventFrame(for envelope: Envelope, pTag: String, kind: Int? = nil) throws -> Data {
        let ourPub = try XCTUnwrap(Secp256k1.xOnlyPublicKey(fromSecretKey: ourSecret))
        var wrap = try NostrGiftWrap.wrap(envelope: envelope, senderSecret: senderSecret,
                                          peerPublicKey: ourPub, recipientTagHex: pTag)
        if let kind {
            // Re-mint a validly signed event of another kind with the same
            // content: the handler's kind guard must reject it before any
            // decryption is attempted.
            let ephemeral = Data((0x60...0x7f).map { UInt8($0) })
            wrap = try XCTUnwrap(NostrEvent.signed(kind: kind, content: wrap.content, tags: wrap.tags,
                                                   createdAt: wrap.createdAt, secretKey: ephemeral))
        }
        let obj = try JSONSerialization.jsonObject(with: try XCTUnwrap(wrap.jsonData()))
        return try JSONSerialization.data(withJSONObject: ["EVENT", "abcdef0123456789", obj])
    }

    /// Collect envelope ids that surface on `incoming` within a short window.
    private func collect(_ transport: NostrTransport, expecting count: Int) async -> [MessageID] {
        var seen: [MessageID] = []
        let deadline = ContinuousClock.now + .seconds(3)
        var iterator = transport.incoming.makeAsyncIterator()
        while seen.count < count, ContinuousClock.now < deadline {
            let next = await withTaskGroup(of: MessageID?.self) { group in
                group.addTask { await iterator.next()?.envelope.id }
                group.addTask { try? await Task.sleep(for: .milliseconds(300)); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            if let next { seen.append(next) }
        }
        return seen
    }

    // MARK: The assertion

    func testHandlerIgnoresThePTagValueEntirely() async throws {
        let transport = makeTransport()
        let ourPubHex = try XCTUnwrap(Secp256k1.xOnlyPublicKey(fromSecretKey: ourSecret))
            .map { String(format: "%02x", $0) }.joined()
        let envelopes = [envelope(0x01), envelope(0x02), envelope(0x03), envelope(0x04)]
        let pValues = [
            "b1c25406911c8c4c9f9b0b9c154018f81f2022ca5371eac1fb03b78849c49ba0",   // an inbox tag (KAT N1)
            ourPubHex,                                                            // the legacy npub
            "not-a-pubkey-at-all",                                                // garbage
            "",                                                                   // empty
        ]
        for (env, p) in zip(envelopes, pValues) {
            transport.injectInboundFrameForTesting(try eventFrame(for: env, pTag: p))
        }
        let ids = await collect(transport, expecting: 4)
        XCTAssertEqual(Set(ids), Set(envelopes.map(\.id)),
                       "every wrap must surface regardless of its p value — the handler never reads it")
        XCTAssertEqual(ids.count, 4)
    }

    func testHandlerGatesOnKindNotOnPTag() async throws {
        let transport = makeTransport()
        let good = envelope(0x11), bad = envelope(0x12)
        let tag = "b1c25406911c8c4c9f9b0b9c154018f81f2022ca5371eac1fb03b78849c49ba0"
        transport.injectInboundFrameForTesting(try eventFrame(for: bad, pTag: tag, kind: 1))   // wrong kind, valid p
        transport.injectInboundFrameForTesting(try eventFrame(for: good, pTag: "garbage"))     // right kind, junk p
        let ids = await collect(transport, expecting: 2)
        XCTAssertEqual(ids, [good.id], "kind gates; the p value does not")
    }

    func testReplayLedgerSurfacesAnEventOnce() async throws {
        let transport = makeTransport()
        let env = envelope(0x21)
        let frame = try eventFrame(for: env, pTag: "b1c25406911c8c4c9f9b0b9c154018f81f2022ca5371eac1fb03b78849c49ba0")
        transport.injectInboundFrameForTesting(frame)
        transport.injectInboundFrameForTesting(frame)
        let ids = await collect(transport, expecting: 2)
        XCTAssertEqual(ids, [env.id])
    }
}
#endif
