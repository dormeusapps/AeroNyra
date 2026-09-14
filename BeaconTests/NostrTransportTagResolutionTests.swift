//
//  NostrTransportTagResolutionTests.swift
//  BeaconTests
//
//  v59 connection-leak fix · Stage 4 — the publish side resolves a tag BEFORE
//  it looks for a relay, and refuses loudly when it cannot.
//
//  Pins, without any socket (the transport is never started, so no relay is
//  live and the only reachable outcomes are the tag resolution and
//  `.notConnected`):
//    • no table → `.untaggableRecipient`, not `.notConnected`: the refusal is
//      distinct and comes first;
//    • a table with a row for the npub → tag resolved → `.notConnected` (the
//      value crossed onto the transport queue via setTagTable);
//    • a registered invite-echo tag is ONE-SHOT: first publish resolves it and
//      falls through to `.notConnected`, the second is untaggable again
//      (DOOR 3 — resolve-then-fail cannot leave a live entry);
//    • the echo registration wins over the table for that one publish;
//    • an UNCONSUMED registration is cleared by `unregisterInviteEchoTag`
//      (DOORS 1 and 2 — the echo went over BLE so the resolver never ran, or
//      the coordinator threw before routing). SEE THE NOTE ON THAT TEST: the
//      BLE-wins path itself is not exercisable here; what is tested is the
//      clearance primitive the defer in `PairingService.redeemInvite` calls.
//
//  XCTest only (not Swift Testing), per project standard.
//

import XCTest
import CryptoKit
@testable import Beacon

final class NostrTransportTagResolutionTests: XCTestCase {

    private let ourSecret = Data((1...32).map { UInt8($0) })   // a valid secp256k1 scalar
    private let LA = Data(repeating: 0xAA, count: 32)
    private let S1 = Data((0...31).map { UInt8($0) })
    /// A REAL x-only key: the wrap's NIP-44 layer derives a conversation key
    /// from it, so an arbitrary 32-byte value would fail inside the wrap
    /// (`.publishFailed`) and mask the tag-resolution outcome under test.
    private let recipientNpub = Secp256k1.xOnlyPublicKey(
        fromSecretKey: Data([0x10] + Array(repeating: 0x00, count: 30) + [0x01]))!
    private let envelope = Envelope(ciphertext: Data([0x09, 0x0a]))

    private func makeTransport() -> NostrTransport {
        let pub = Secp256k1.xOnlyPublicKey(fromSecretKey: ourSecret)!
        return NostrTransport(relayURLs: [URL(string: "wss://relay.invalid")!],
                              ourSecretKey: ourSecret, ourPublicKey: pub,
                              now: { 1_789_344_000 })
    }

    func testNoTableIsUntaggableBeforeAnyRelayCheck() async {
        let transport = makeTransport()
        do {
            try await transport.publish(envelope, to: recipientNpub)
            XCTFail("must throw")
        } catch let error as NostrTransportError {
            XCTAssertEqual(error, .untaggableRecipient)
        } catch { XCTFail("wrong error type: \(type(of: error))") }
    }

    func testTableRowResolvesAndFallsThroughToNotConnected() async {
        let transport = makeTransport()
        transport.setTagTable(NostrInboxTagTable(ourIdentity: LA,
                                                 rows: [.init(identity: Data(repeating: 0xBB, count: 32),
                                                              secret: S1, nostrPubkey: recipientNpub)]))
        do {
            try await transport.publish(envelope, to: recipientNpub)
            XCTFail("must throw")
        } catch let error as NostrTransportError {
            XCTAssertEqual(error, .notConnected, "tag resolved; the only remaining failure is no live relay")
        } catch { XCTFail("wrong error type: \(type(of: error))") }
        // An npub with no row is still refused, table or not.
        do {
            try await transport.publish(envelope, to: Secp256k1.xOnlyPublicKey(
                fromSecretKey: Data([0x20] + Array(repeating: 0x00, count: 30) + [0x01]))!)
            XCTFail("must throw")
        } catch let error as NostrTransportError {
            XCTAssertEqual(error, .untaggableRecipient)
        } catch { XCTFail("wrong error type: \(type(of: error))") }
    }

    /// DOORS 1 AND 2. A registration that was never consumed — because the
    /// echo went over BLE (the router tries the radio first, so the Nostr
    /// resolver never ran) or because the coordinator threw before routing —
    /// must be cleared by `unregisterInviteEchoTag`, which the `defer` in
    /// `PairingService.redeemInvite` calls on every exit. After clearance the
    /// next publish to that npub is untaggable (no table row here), NOT
    /// silently tagged with the invite-echo tag.
    ///
    /// COVERAGE NOTE, stated rather than implied: the BLE-wins path — door 1,
    /// the likeliest in the field — is NOT exercised by this test or any unit
    /// test. It needs a live BLE radio with the minter in range, which the
    /// simulator has not got, and the router's BLE-first branch
    /// (`MessageRouter.send`, the `ble.send` path) is only reachable through
    /// a real `BLEMeshTransport`. What this test proves is the clearance
    /// primitive; that the defer reaches it on the BLE-wins exit is covered by
    /// inspection of `PairingService.redeemInvite` (register → defer → route),
    /// and belongs in the Stage 5 two-phone gate as an explicit step: pair by
    /// invite with both phones IN RANGE, then message over Nostr out of range.
    func testUnconsumedEchoRegistrationIsClearedForDoorsOneAndTwo() async {
        let transport = makeTransport()
        transport.registerInviteEchoTag(forRecipient: recipientNpub, inviteID: Data((0...15).map { UInt8($0) }))
        // The echo never resolved over Nostr (BLE won, or the route threw):
        // the defer fires this.
        transport.unregisterInviteEchoTag(forRecipient: recipientNpub)
        do {
            try await transport.publish(envelope, to: recipientNpub)
            XCTFail("must throw")
        } catch let error as NostrTransportError {
            XCTAssertEqual(error, .untaggableRecipient,
                           "a cleared registration must not tag the next publish with the echo tag")
        } catch { XCTFail("wrong error type: \(type(of: error))") }
        // Clearing when nothing is registered is a harmless no-op (door 3's
        // defer after a consumed one-shot).
        transport.unregisterInviteEchoTag(forRecipient: recipientNpub)
        do {
            try await transport.publish(envelope, to: recipientNpub)
            XCTFail("must throw")
        } catch let error as NostrTransportError {
            XCTAssertEqual(error, .untaggableRecipient)
        } catch { XCTFail("wrong error type: \(type(of: error))") }
    }

    /// DOOR 3. Resolve-then-fail cannot leave a live entry: the one-shot is
    /// consumed at resolution, before any relay check.
    func testInviteEchoRegistrationIsOneShot() async {
        let transport = makeTransport()
        transport.registerInviteEchoTag(forRecipient: recipientNpub, inviteID: Data((0...15).map { UInt8($0) }))
        do {
            try await transport.publish(envelope, to: recipientNpub)
            XCTFail("must throw")
        } catch let error as NostrTransportError {
            XCTAssertEqual(error, .notConnected, "first publish consumed the echo tag")
        } catch { XCTFail("wrong error type: \(type(of: error))") }
        do {
            try await transport.publish(envelope, to: recipientNpub)
            XCTFail("must throw")
        } catch let error as NostrTransportError {
            XCTAssertEqual(error, .untaggableRecipient, "second publish: the one-shot is gone and there is no table row")
        } catch { XCTFail("wrong error type: \(type(of: error))") }
    }
}
