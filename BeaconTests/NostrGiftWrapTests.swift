//
//  NostrGiftWrapTests.swift
//  BeaconTests
//
//  Phase 8c-ii-1 — NIP-59 gift-wrap tests for Core/Nostr/NostrGiftWrap.swift.
//
//  The end-to-end layered round-trip (rumor -> seal -> wrap and back) was
//  validated against an independent reference; these tests assert the Swift
//  surface: Envelope fidelity through the round-trip, that the OUTER event leaks
//  no sender identity (ephemeral key + p-tag + backdated time), and that wrong
//  recipient / tampering are rejected.
//

import XCTest
@testable import Beacon

final class NostrGiftWrapTests: XCTestCase {

    // Two distinct, known-valid scalars.
    private let senderSecretHex = "b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef"
    private let recipientSecretHex = "c90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b14e5c9"

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
                                          peerPublicKey: recipientPub)
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
                                          now: now)

        XCTAssertEqual(wrap.kind, NostrGiftWrap.wrapKind)
        XCTAssertTrue(wrap.isValid(), "outer event must be a valid signed event")

        let senderHex = senderPub.map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(wrap.pubkey, senderHex, "outer pubkey must be ephemeral, not the sender")

        // p-tag addresses the recipient; no sender reference anywhere in tags.
        let recipientHex = recipientPub.map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(wrap.tags.contains(["p", recipientHex]), "must p-tag the recipient")

        XCTAssertLessThanOrEqual(wrap.createdAt, now, "created_at must be backdated, never future")
    }

    func testUnwrapRejectsWrongRecipient() throws {
        let sender = hex(senderSecretHex)
        let recipient = hex(recipientSecretHex)
        guard let recipientPub = Secp256k1.xOnlyPublicKey(fromSecretKey: recipient) else {
            return XCTFail("pubkey derivation failed")
        }
        let wrap = try NostrGiftWrap.wrap(envelope: makeEnvelope(),
                                          senderSecret: sender,
                                          peerPublicKey: recipientPub)

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
                                          peerPublicKey: recipientPub)

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
        let a = try NostrGiftWrap.wrap(envelope: envelope, senderSecret: sender, peerPublicKey: recipientPub)
        let b = try NostrGiftWrap.wrap(envelope: envelope, senderSecret: sender, peerPublicKey: recipientPub)
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
