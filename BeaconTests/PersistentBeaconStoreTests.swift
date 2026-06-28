// PersistentBeaconStoreTests.swift
// BeaconTests
//
// Proves Phase 5a: libsignal state survives an app relaunch. Runs on the iOS
// Simulator with NO hardware. A fresh PersistentBeaconStore built over the same
// directory + key as a prior one is the unit-test stand-in for "force-quit and
// relaunch": same on-disk file, brand-new object graph.
//
// Coverage:
//   • per-record round-trip (prekey / signed / kyber / identity)
//   • registrationId is generated ONCE and reused (the bug the in-memory pass
//     had: random-per-launch silently broke every session)
//   • a removed one-time prekey STAYS removed after reload (forward secrecy)
//   • kyber replay defense (baseKeysSeen) persists — a reused base key is
//     rejected even across a reload
//   • wrong DEK loads as empty (crypto-erase semantics)
//   • CAPSTONE: a real two-party handshake driven to whisper steady-state; the
//     responder is destroyed mid-conversation, rebuilt from disk, and still
//     decrypts a NEW whisper — which uses only the session + identity stores, so
//     it can only pass if the session record, identity table, AND registrationId
//     all persisted.
//

import XCTest
import CryptoKit
import LibSignalClient
@testable import Beacon

final class PersistentBeaconStoreTests: XCTestCase {

    private let ctx = NullContext()
    private var scratch: [URL] = []

    override func tearDownWithError() throws {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch.removeAll()
    }

    // MARK: Helpers

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbstore-\(UUID().uuidString)", isDirectory: true)
        scratch.append(url)
        return url
    }

    private func freshKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func now() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

    private func makeStore(_ dir: URL, _ key: SymmetricKey,
                           identity: IdentityKeyPair) throws -> PersistentBeaconStore {
        try PersistentBeaconStore(identity: identity, directory: dir, key: key)
    }

    // MARK: Per-record round-trip

    func testPreKeySurvivesReload() throws {
        let dir = tempDir(); let key = freshKey(); let id = IdentityKeyPair.generate()

        let store = try makeStore(dir, key, identity: id)
        let rec = try PreKeyRecord(id: 7, privateKey: .generate())
        try store.storePreKey(rec, id: 7, context: ctx)
        let before = try store.loadPreKey(id: 7, context: ctx).serialize()

        let reloaded = try makeStore(dir, key, identity: id)
        let after = try reloaded.loadPreKey(id: 7, context: ctx).serialize()
        XCTAssertEqual(before, after, "prekey bytes must survive reload unchanged")
    }

    func testSignedAndKyberPreKeysSurviveReload() throws {
        let dir = tempDir(); let key = freshKey(); let id = IdentityKeyPair.generate()
        let store = try makeStore(dir, key, identity: id)

        let spPriv = PrivateKey.generate()
        let spSig = id.privateKey.generateSignature(message: spPriv.publicKey.serialize())
        let sp = try SignedPreKeyRecord(id: 1, timestamp: now(), privateKey: spPriv, signature: spSig)
        try store.storeSignedPreKey(sp, id: 1, context: ctx)

        let kyber = KEMKeyPair.generate()
        let kySig = id.privateKey.generateSignature(message: kyber.publicKey.serialize())
        let kp = try KyberPreKeyRecord(id: 1, timestamp: now(), keyPair: kyber, signature: kySig)
        try store.storeKyberPreKey(kp, id: 1, context: ctx)

        let reloaded = try makeStore(dir, key, identity: id)
        XCTAssertEqual(try reloaded.loadSignedPreKey(id: 1, context: ctx).serialize(), sp.serialize())
        XCTAssertEqual(try reloaded.loadKyberPreKey(id: 1, context: ctx).serialize(), kp.serialize())
    }

    func testIdentityTrustTableSurvivesReload() throws {
        let dir = tempDir(); let key = freshKey(); let id = IdentityKeyPair.generate()
        let store = try makeStore(dir, key, identity: id)

        let peer = IdentityKeyPair.generate().identityKey
        let addr = try ProtocolAddress(name: "peerhex", deviceId: 1)
        _ = try store.saveIdentity(peer, for: addr, context: ctx)

        let reloaded = try makeStore(dir, key, identity: id)
        XCTAssertEqual(try reloaded.identity(for: addr, context: ctx)?.serialize(),
                       peer.serialize(), "TOFU trust table must persist")
        // And trust must hold for the same key, reject a different one.
        XCTAssertTrue(try reloaded.isTrustedIdentity(peer, for: addr, direction: .sending, context: ctx))
        let imposter = IdentityKeyPair.generate().identityKey
        XCTAssertFalse(try reloaded.isTrustedIdentity(imposter, for: addr, direction: .sending, context: ctx))
    }

    // MARK: registrationId stability

    func testRegistrationIdStableAcrossReload() throws {
        let dir = tempDir(); let key = freshKey(); let id = IdentityKeyPair.generate()
        let first = try makeStore(dir, key, identity: id).localRegistrationId(context: ctx)
        let second = try makeStore(dir, key, identity: id).localRegistrationId(context: ctx)
        XCTAssertEqual(first, second, "registrationId must be generated once and reused")
    }

    // MARK: Forward-secrecy stickiness

    func testRemovedPreKeyStaysRemovedAfterReload() throws {
        let dir = tempDir(); let key = freshKey(); let id = IdentityKeyPair.generate()
        let store = try makeStore(dir, key, identity: id)

        try store.storePreKey(try PreKeyRecord(id: 9, privateKey: .generate()), id: 9, context: ctx)
        try store.removePreKey(id: 9, context: ctx)

        let reloaded = try makeStore(dir, key, identity: id)
        XCTAssertThrowsError(try reloaded.loadPreKey(id: 9, context: ctx),
            "a consumed one-time prekey must not reappear after relaunch")
    }

    func testKyberReplayDefensePersists() throws {
        let dir = tempDir(); let key = freshKey(); let id = IdentityKeyPair.generate()
        let store = try makeStore(dir, key, identity: id)

        let baseKey = PrivateKey.generate().publicKey
        try store.markKyberPreKeyUsed(id: 1, signedPreKeyId: 1, baseKey: baseKey, context: ctx)

        // After reload, replaying the SAME base key must still be rejected — the
        // baseKeysSeen map survived.
        let reloaded = try makeStore(dir, key, identity: id)
        XCTAssertThrowsError(
            try reloaded.markKyberPreKeyUsed(id: 1, signedPreKeyId: 1, baseKey: baseKey, context: ctx),
            "a replayed base key must be rejected across relaunch")
    }

    // MARK: Crypto-erase semantics

    func testWrongKeyLoadsEmpty() throws {
        let dir = tempDir(); let id = IdentityKeyPair.generate()
        let keyA = freshKey(); let keyB = freshKey()

        let store = try makeStore(dir, keyA, identity: id)
        try store.storePreKey(try PreKeyRecord(id: 3, privateKey: .generate()), id: 3, context: ctx)

        // Opening the same file under a different DEK must not surface the data.
        let wiped = try makeStore(dir, keyB, identity: id)
        XCTAssertThrowsError(try wiped.loadPreKey(id: 3, context: ctx),
            "a wrong/missing DEK must load as empty (crypto-erase)")
    }

    // MARK: Capstone — real handshake survives a simulated relaunch

    func testSessionSurvivesRelaunch() throws {
        let aliceId = IdentityKeyPair.generate()
        let bobId = IdentityKeyPair.generate()

        let aliceDir = tempDir(); let aliceKey = freshKey()
        let bobDir = tempDir(); let bobKey = freshKey()

        let alice = try makeStore(aliceDir, aliceKey, identity: aliceId)
        var bob: PersistentBeaconStore? = try makeStore(bobDir, bobKey, identity: bobId)

        let aliceAddr = try ProtocolAddress(name: hex(aliceId.publicKey.serialize()), deviceId: 1)
        let bobAddr = try ProtocolAddress(name: hex(bobId.publicKey.serialize()), deviceId: 1)

        // --- Bob mints a prekey bundle and stores the private halves ---
        let pkPriv = PrivateKey.generate()
        try bob!.storePreKey(try PreKeyRecord(id: 1, privateKey: pkPriv), id: 1, context: ctx)

        let spPriv = PrivateKey.generate()
        let spSig = bobId.privateKey.generateSignature(message: spPriv.publicKey.serialize())
        try bob!.storeSignedPreKey(
            try SignedPreKeyRecord(id: 1, timestamp: now(), privateKey: spPriv, signature: spSig),
            id: 1, context: ctx)

        let kyber = KEMKeyPair.generate()
        let kySig = bobId.privateKey.generateSignature(message: kyber.publicKey.serialize())
        try bob!.storeKyberPreKey(
            try KyberPreKeyRecord(id: 1, timestamp: now(), keyPair: kyber, signature: kySig),
            id: 1, context: ctx)

        let bundle = try PreKeyBundle(
            registrationId: try bob!.localRegistrationId(context: ctx),
            deviceId: 1,
            prekeyId: 1, prekey: pkPriv.publicKey,
            signedPrekeyId: 1, signedPrekey: spPriv.publicKey, signedPrekeySignature: spSig,
            identity: bobId.identityKey,
            kyberPrekeyId: 1, kyberPrekey: kyber.publicKey, kyberPrekeySignature: kySig)

        // --- 1. Alice establishes and sends the first (PreKey) message ---
        try processPreKeyBundle(
            bundle, for: bobAddr, ourAddress: aliceAddr,
            sessionStore: alice, identityStore: alice, context: ctx)

        let m1 = try signalEncrypt(
            message: Data("hi".utf8), for: bobAddr, localAddress: aliceAddr,
            sessionStore: alice, identityStore: alice, context: ctx)
        XCTAssertEqual(m1.messageType, .preKey, "initiator's first message is a PreKey message")

        let out1 = try signalDecryptPreKey(
            message: try PreKeySignalMessage(bytes: m1.serialize()),
            from: aliceAddr, localAddress: bobAddr,
            sessionStore: bob!, identityStore: bob!,
            preKeyStore: bob!, signedPreKeyStore: bob!, kyberPreKeyStore: bob!, context: ctx)
        XCTAssertEqual(String(decoding: out1, as: UTF8.self), "hi")

        // --- 2. Bob REPLIES (whisper). This is what ratchets Alice forward so
        //        her subsequent messages become whisper messages. Also exercises
        //        the B->A direction, like the real two-phone proof. ---
        let m2 = try signalEncrypt(
            message: Data("hey".utf8), for: aliceAddr, localAddress: bobAddr,
            sessionStore: bob!, identityStore: bob!, context: ctx)
        XCTAssertEqual(m2.messageType, .whisper, "responder's reply is a whisper message")

        let out2 = try signalDecrypt(
            message: try SignalMessage(bytes: m2.serialize()),
            from: bobAddr, to: aliceAddr,
            sessionStore: alice, identityStore: alice, context: ctx)
        XCTAssertEqual(String(decoding: out2, as: UTF8.self), "hey")

        // --- 3. RELAUNCH Bob: drop the object, rebuild from the same file ---
        bob = nil
        let bobReloaded = try makeStore(bobDir, bobKey, identity: bobId)

        // --- 4. Alice sends a NEW whisper; reloaded Bob must decrypt it. A
        //        whisper decrypt touches only the session + identity stores, so
        //        success proves the SESSION RECORD itself persisted. ---
        let m3 = try signalEncrypt(
            message: Data("still here?".utf8), for: bobAddr, localAddress: aliceAddr,
            sessionStore: alice, identityStore: alice, context: ctx)
        XCTAssertEqual(m3.messageType, .whisper,
            "after a round-trip the initiator is in whisper mode")

        let out3 = try signalDecrypt(
            message: try SignalMessage(bytes: m3.serialize()),
            from: aliceAddr, to: bobAddr,
            sessionStore: bobReloaded, identityStore: bobReloaded, context: ctx)
        XCTAssertEqual(String(decoding: out3, as: UTF8.self), "still here?",
            "reloaded responder must decrypt new traffic with no fresh first-contact")
    }
}
