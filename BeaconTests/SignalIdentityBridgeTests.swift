//
//  SignalIdentityBridgeTests.swift
//  BeaconTests
//
//  Proves the PASS 2, Option A identity bridge: the app's Enclave-bound
//  Curve25519 identity maps to a libsignal identity whose public key MATCHES,
//  and a store built from a given app identity is deterministically tied to it.
//
//  Unlike SignalSessionTests (which deliberately names only Beacon), this file
//  IS about the libsignal boundary, so it imports CryptoKit + LibSignalClient to
//  assert byte-level correspondence directly. If byte compatibility between
//  CryptoKit X25519 and libsignal's Curve25519 ever breaks, THIS test pinpoints
//  it, rather than surfacing as a confusing downstream handshake failure.
//

import XCTest
import CryptoKit
import LibSignalClient
@testable import Beacon

final class SignalIdentityBridgeTests: XCTestCase {

    /// The bridged libsignal public key must equal the app's X25519 public key,
    /// byte for byte. `PublicKey.keyBytes` is libsignal's RAW 32-byte form (no
    /// type prefix), directly comparable to CryptoKit's `rawRepresentation`.
    func testBridgedPublicKeyMatchesAppIdentity() throws {
        let app = IdentityKeypair.generate()

        let ls = try app.libsignalIdentityKeyPair()

        let appPub = app.agreement.publicKey.rawRepresentation        // 32 bytes
        let lsPub = ls.publicKey.keyBytes                             // 32 bytes, raw

        XCTAssertEqual(lsPub, appPub,
                       "Bridged libsignal identity key must match the app's X25519 key")
    }

    /// The bridge must be deterministic: same app identity in -> same libsignal
    /// identity out. (A fresh random key each call would silently break identity
    /// continuity across launches.)
    func testBridgeIsDeterministic() throws {
        let app = IdentityKeypair.generate()

        let a = try app.libsignalIdentityKeyPair()
        let b = try app.libsignalIdentityKeyPair()

        XCTAssertEqual(a.publicKey.keyBytes, b.publicKey.keyBytes)
    }

    /// A store built from a specific app identity must expose THAT identity as
    /// its `localIdentity` (the user ID), tying the session identity to the
    /// app's permanent key rather than a throwaway.
    func testStoreLocalIdentityDerivesFromAppIdentity() throws {
        let app = IdentityKeypair.generate()
        let ls = try app.libsignalIdentityKeyPair()

        let store = SignalSessionStore(appIdentity: app)

        // The store represents identities as libsignal's serialized identity key.
        XCTAssertEqual(store.localIdentity.userID, ls.publicKey.serialize())
    }

    /// Two stores built from the SAME app identity must present the same user ID
    /// — the property that makes "session identity == app identity" observable.
    func testSameAppIdentityYieldsSameUserID() throws {
        let app = IdentityKeypair.generate()

        let s1 = SignalSessionStore(appIdentity: app)
        let s2 = SignalSessionStore(appIdentity: app)

        XCTAssertEqual(s1.localIdentity.userID, s2.localIdentity.userID)
    }
}
