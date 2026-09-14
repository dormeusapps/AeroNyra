//
//  NostrGiftWrapTests.swift
//  BeaconTests
//
//  Phase 8c-ii-1 — NIP-59 gift-wrap tests for Core/Nostr/NostrGiftWrap.swift.
//
//  The end-to-end layered round-trip (rumor -> seal -> wrap and back) was
//  validated against an independent reference; these tests assert the Swift
//  surface: Envelope fidelity through the round-trip, that the OUTER event leaks
//  no sender identity (ephemeral key + backdated time) AND, since v59 Stage 4,
//  no recipient identity either (the `p` value is the caller's inbox tag,
//  never the npub — asserted as a NOT-EQUAL, not only as an equality, so a
//  future "use the npub as the tag" change fails here), and that wrong
//  recipient / tampering are rejected.
//

import XCTest
@testable import Beacon

final class NostrGiftWrapTests: XCTestCase {

    // Two distinct, known-valid scalars.
    private let senderSecretHex = "b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef"
    private let recipientSecretHex = "c90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b14e5c9"

    /// A representative inbox tag for the `p` slot (KAT N1). The wrap treats it
    /// as an opaque 64-char hex value; what matters here is that it is NOT the
    /// recipient npub.
    private let tagHex = "b1c25406911c8c4c9f9b0b9c154018f81f2022ca5371eac1fb03b78849c49ba0"

    private func makeEnvelope() -> Envelope {
        // Fixed id + ciphertext so we can assert full wire fidelity.
        let id = MessageID(bytes: Array(repeating: 0xAB, count: MessageID.byteCount))!
        let ciphertext = Data((0..<200).map { UInt8($0 & 0xff) })
        return Envelope(ttl: 5, id: id, ciphertext: ciphertext)
    }

    func testWrapUnwrapRoundTripPreservesEnvelope() throws {
        let sender = hex(senderSecretHex)
        let recipient = hex(recipientSecretHex)
        guard let recipientPub = Secp256k1.xOnlyPublicKey(fromSecretKey: recipient),
              let senderPub = Secp256k1.xOnlyPublicKey(fromSecretKey: sender) else {
            return XCTFail("pubkey derivation failed")
        }
        let envelope = makeEnvelope()

        let wrap = try NostrGiftWrap.wrap(envelope: envelope,
                                          senderSecret: sender,
                                          peerPublicKey: recipientPub,
                                          recipientTagHex: tagHex)
        let (recovered, authSender) = try NostrGiftWrap.unwrap(giftWrap: wrap, mySecret: recipient)

        XCTAssertEqual(recovered.wireData(), envelope.wireData(), "full envelope bytes must survive")
        XCTAssertEqual(recovered.id, envelope.id)
        XCTAssertEqual(authSender, senderPub, "unwrap must report the authenticated sender")
    }

    func testOuterEventLeaksNoSenderIdentity() throws {
        let sender = hex(senderSecretHex)
        let recipient = hex(recipientSecretHex)
        guard let recipientPub = Secp256k1.xOnlyPublicKey(fromSecretKey: recipient),
              let senderPub = Secp256k1.xOnlyPublicKey(fromSecretKey: sender) else {
            return XCTFail("pubkey derivation failed")
        }
        let now = Int64(Date().timeIntervalSince1970)
        let wrap = try NostrGiftWrap.wrap(envelope: makeEnvelope(),
                                          senderSecret: sender,
                                          peerPublicKey: recipientPub,
                                          recipientTagHex: tagHex,
                                          now: now)

        XCTAssertEqual(wrap.kind, NostrGiftWrap.wrapKind)
        XCTAssertTrue(wrap.isValid(), "outer event must be a valid signed event")

        let senderHex = senderPub.map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(wrap.pubkey, senderHex, "outer pubkey must be ephemeral, not the sender")

        // v59 Stage 4: the p value is the caller's inbox tag — and is NOT the
        // recipient npub, NOT the sender npub. The NOT-EQUALs are the guard
        // against a regression that reintroduces the npub as the tag.
        let recipientHex = recipientPub.map { String(format: "%02x", $0) }.joined()
        let pValues = wrap.tags.filter { $0.first == "p" }.compactMap { $0.dropFirst().first }
        XCTAssertEqual(pValues, [tagHex], "exactly one p tag, carrying the supplied inbox tag")
        XCTAssertFalse(wrap.tags.contains(["p", recipientHex]), "the p value must never be the recipient npub")
        XCTAssertFalse(wrap.tags.contains(["p", senderHex]), "the p value must never be the sender npub")
        XCTAssertFalse(wrap.tags.contains { $0.contains(recipientHex) }, "the recipient npub must not appear in any tag")

        XCTAssertLessThanOrEqual(wrap.createdAt, now, "created_at must be backdated, never future")
    }

    /// The tag is not a stable pseudonym either: the same recipient in two
    /// epochs wraps under two different p values, and neither is the npub.
    /// Uses the real table so the p values are the ones production would emit.
    func testPTagChangesAcrossEpochsAndIsNeverTheNpub() throws {
        let sender = hex(senderSecretHex)
        let recipient = hex(recipientSecretHex)
        guard let recipientPub = Secp256k1.xOnlyPublicKey(fromSecretKey: recipient) else {
            return XCTFail("pubkey derivation failed")
        }
        let table = NostrInboxTagTable(ourIdentity: Data(repeating: 0xAA, count: 32),
                                       rows: [.init(identity: Data(repeating: 0xBB, count: 32),
                                                    secret: Data((0...31).map { UInt8($0) }),
                                                    nostrPubkey: recipientPub)])
        let recipientHex = recipientPub.map { String(format: "%02x", $0) }.joined()
        var seen = Set<String>()
        for epoch: UInt64 in [20710, 20711] {
            let tag = try XCTUnwrap(table.publishTag(to: recipientPub, epoch: epoch)).hex
            let wrap = try NostrGiftWrap.wrap(envelope: makeEnvelope(), senderSecret: sender,
                                              peerPublicKey: recipientPub, recipientTagHex: tag)
            XCTAssertTrue(wrap.tags.contains(["p", tag]))
            XCTAssertNotEqual(tag, recipientHex)
            seen.insert(tag)
            // Still opens: the p value is not load-bearing on receive.
            XCTAssertNoThrow(try NostrGiftWrap.unwrap(giftWrap: wrap, mySecret: recipient))
        }
        XCTAssertEqual(seen.count, 2, "two epochs → two different p values")
    }

    func testUnwrapRejectsWrongRecipient() throws {
        let sender = hex(senderSecretHex)
        let recipient = hex(recipientSecretHex)
        guard let recipientPub = Secp256k1.xOnlyPublicKey(fromSecretKey: recipient) else {
            return XCTFail("pubkey derivation failed")
        }
        let wrap = try NostrGiftWrap.wrap(envelope: makeEnvelope(),
                                          senderSecret: sender,
                                          peerPublicKey: recipientPub,
                                          recipientTagHex: tagHex)

        // A third party (not the addressed recipient) cannot open it.
        let stranger = hex("0000000000000000000000000000000000000000000000000000000000000003")
        XCTAssertThrowsError(try NostrGiftWrap.unwrap(giftWrap: wrap, mySecret: stranger))
    }

    func testUnwrapRejectsTamperedWrap() throws {
        let sender = hex(senderSecretHex)
        let recipient = hex(recipientSecretHex)
        guard let recipientPub = Secp256k1.xOnlyPublicKey(fromSecretKey: recipient) else {
            return XCTFail("pubkey derivation failed")
        }
        let wrap = try NostrGiftWrap.wrap(envelope: makeEnvelope(),
                                          senderSecret: sender,
                                          peerPublicKey: recipientPub,
                                          recipientTagHex: tagHex)

        // Corrupt the encrypted content; the outer event id no longer matches,
        // so it fails validation before decryption is even attempted.
        let tampered = NostrEvent(id: wrap.id,
                                  pubkey: wrap.pubkey,
                                  createdAt: wrap.createdAt,
                                  kind: wrap.kind,
                                  tags: wrap.tags,
                                  content: wrap.content + "x",
                                  sig: wrap.sig)
        XCTAssertThrowsError(try NostrGiftWrap.unwrap(giftWrap: tampered, mySecret: recipient))
    }

    func testTwoWrapsOfSameEnvelopeDiffer() throws {
        let sender = hex(senderSecretHex)
        let recipient = hex(recipientSecretHex)
        guard let recipientPub = Secp256k1.xOnlyPublicKey(fromSecretKey: recipient) else {
            return XCTFail("pubkey derivation failed")
        }
        let envelope = makeEnvelope()
        let a = try NostrGiftWrap.wrap(envelope: envelope, senderSecret: sender, peerPublicKey: recipientPub, recipientTagHex: tagHex)
        let b = try NostrGiftWrap.wrap(envelope: envelope, senderSecret: sender, peerPublicKey: recipientPub, recipientTagHex: tagHex)
        // Fresh ephemeral key + nonces each time.
        XCTAssertNotEqual(a.pubkey, b.pubkey, "each wrap uses a new ephemeral key")
        XCTAssertNotEqual(a.content, b.content)
        // Both still open to the same envelope.
        XCTAssertEqual(try NostrGiftWrap.unwrap(giftWrap: a, mySecret: recipient).envelope.wireData(),
                       try NostrGiftWrap.unwrap(giftWrap: b, mySecret: recipient).envelope.wireData())
    }

    // MARK: Helpers

    private func hex(_ string: String) -> Data {
        var bytes = [UInt8]()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            bytes.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }
}
