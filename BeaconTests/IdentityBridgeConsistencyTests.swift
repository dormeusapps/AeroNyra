//
//  IdentityBridgeConsistencyTests.swift
//  BeaconTests
//
//  THE LINCHPIN, ANCHORED ON-TOOLCHAIN. The closed-contact discovery layer
//  (ReconnectBeacon / BeaconRecognizer / DiscoverySecret) rides the RAW 32-byte
//  X25519 identity (Peer.publicKeyData). DiscoverySecret derives S_AB by DH-ing
//  our CryptoKit `agreement` private key against a peer's 32-byte public. That
//  S_AB is symmetric across two devices ONLY IF the 32-byte key each side stores
//  for the other equals the CryptoKit agreement public — i.e. only if:
//
//      strip-0x05( libsignal identity public )  ==  agreement.publicKey.rawRepresentation
//
//  SignalIdentityBridge maps the X25519 `agreement` scalar into libsignal, so by
//  construction the two should derive the SAME X25519 public. But that is a
//  CROSS-LIBRARY claim (libsignal vs CryptoKit), and project discipline is to
//  anchor representations to real output rather than to reasoning. If this
//  equality ever failed, nothing would throw — the 32 bytes would still be a
//  valid X25519 public — and the only symptom would be "two paired phones never
//  reconnect," chased on hardware. This test makes that impossible to ship
//  silently: it must be green before the 5d wiring trusts DH symmetry.
//

import XCTest
import CryptoKit
import LibSignalClient
@testable import Beacon

final class IdentityBridgeConsistencyTests: XCTestCase {

    /// Bridge level: strip-0x05(libsignal identity public) == CryptoKit agreement
    /// public. This is the equality that makes DiscoverySecret's DH symmetric.
    func testBridgedPublicEqualsAgreementPublic() throws {
        let kp = IdentityKeypair.generate()

        let serialized = Data(try kp.libsignalIdentityKeyPair().publicKey.serialize())
        XCTAssertEqual(serialized.count, 33, "libsignal identity public is 0x05 ‖ 32 bytes")
        XCTAssertEqual(serialized.first, 0x05, "Curve25519 serialized type byte")

        let stripped  = Data(serialized.dropFirst())            // 32 bytes
        let cryptoKit = kp.agreement.publicKey.rawRepresentation // 32 bytes

        XCTAssertEqual(stripped, cryptoKit,
            "strip-0x05(libsignal identity) must equal CryptoKit agreement public")
    }

    /// The real wiring seam: the 32-byte key the store hands out for OUR identity
    /// (`rawPublicKey(of: localIdentity)`) is definitionally what a peer stored for
    /// us at pairing — and is what 5d will emit as our own beacon `label`. It must
    /// equal the agreement public that DiscoverySecret DHs against, or our emitted
    /// beacon and the peer's recognition key off different bytes.
    func testStoreRawPublicKeyEqualsAgreementPublic() {
        let kp = IdentityKeypair.generate()
        let store = SignalSessionStore(appIdentity: kp)   // ephemeral in-memory init

        let raw = store.rawPublicKey(of: store.localIdentity)   // 32 bytes
        let cryptoKit = kp.agreement.publicKey.rawRepresentation

        XCTAssertEqual(raw, cryptoKit,
            "store.rawPublicKey(of: localIdentity) must equal CryptoKit agreement public")
    }

    /// The bridge's determinism claim (its own header): same app identity in ⇒
    /// same session identity out, so reconnection beacon labels are stable across
    /// launches rather than churning per process.
    func testBridgeIsDeterministic() throws {
        let kp = IdentityKeypair.generate()
        let a = Data(try kp.libsignalIdentityKeyPair().publicKey.serialize())
        let b = Data(try kp.libsignalIdentityKeyPair().publicKey.serialize())
        XCTAssertEqual(a, b, "bridging the same app identity twice yields one session identity")
    }

    /// End-to-end seam: feed the store-derived raw public straight into
    /// DiscoverySecret as a peer key and confirm it is accepted (right length,
    /// valid X25519 point) — i.e. the 32 bytes the discovery path circulates are
    /// directly usable as DH input without any reshaping.
    func testRawPublicIsUsableAsDiscoveryPeerKey() throws {
        let ours   = IdentityKeypair.generate()
        let theirs = IdentityKeypair.generate()
        let theirStore = SignalSessionStore(appIdentity: theirs)
        let theirRaw = theirStore.rawPublicKey(of: theirStore.localIdentity)

        XCTAssertNoThrow(
            try DiscoverySecret.derive(
                ourAgreementPrivate: ours.agreement,
                theirAgreementPublic: theirRaw),
            "a store-derived raw identity must be a valid DiscoverySecret peer key")
    }
}
