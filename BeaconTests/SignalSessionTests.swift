//
//  SignalSessionTests.swift
//  BeaconTests
//
//  Proves the libsignal adapter works end-to-end through the `SecureSession`
//  boundary. Deliberately imports ONLY Beacon — not LibSignalClient — so the
//  test exercises the abstraction, not the implementation. libsignal does the
//  real cryptography underneath; these tests never name it.
//
//  PASS 1 (in-memory) scope: this validates the handshake + ratchet + bundle
//  plumbing. Persistence and single-identity unification are PASS 2.
//
//  Flow modeled (asymmetric, like real use):
//    1. Both sides publish a prekey bundle.
//    2. Alice (initiator) establishes from Bob's bundle and seals — her first
//       message is a session-establishing "prekey" message.
//    3. Bob opens it (his side establishes as a side effect), then replies.
//

import XCTest
@testable import Beacon

final class SignalSessionTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }
    private func string(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

    // MARK: Full handshake + bidirectional round-trip

    func testHandshakeAndRoundTrip() throws {
        let alice = SignalSessionStore()
        let bob = SignalSessionStore()

        // Bob publishes his bundle; Alice establishes a session from it.
        let bobBundle = try bob.localPrekeyBundle()
        let aliceToBob = try alice.establishSession(from: bobBundle)
        XCTAssertEqual(aliceToBob.peer.userID, bob.localIdentity.userID)

        // Alice -> Bob (first message is a prekey message that establishes Bob's side).
        let ct1 = try aliceToBob.seal(data("hello bob"))
        let bobToAlice = try bob.session(with: alice.localIdentity)
        let pt1 = try bobToAlice.open(ct1)
        XCTAssertEqual(string(pt1), "hello bob")

        // Bob -> Alice (reply, now a normal ratchet message).
        let ct2 = try bobToAlice.seal(data("hi alice"))
        let pt2 = try aliceToBob.open(ct2)
        XCTAssertEqual(string(pt2), "hi alice")

        // A few more turns each way to exercise the ratchet advancing.
        let ct3 = try aliceToBob.seal(data("how are you"))
        XCTAssertEqual(string(try bobToAlice.open(ct3)), "how are you")
        let ct4 = try bobToAlice.seal(data("good, you?"))
        XCTAssertEqual(string(try aliceToBob.open(ct4)), "good, you?")

        XCTAssertEqual(aliceToBob.state, .established)
        XCTAssertEqual(bobToAlice.state, .established)
    }

    // MARK: Out-of-order delivery (the mesh reality)

    func testOutOfOrderDelivery() throws {
        let alice = SignalSessionStore()
        let bob = SignalSessionStore()

        let aliceToBob = try alice.establishSession(from: try bob.localPrekeyBundle())

        // First message must arrive first — it establishes Bob's side.
        let first = try aliceToBob.seal(data("m1"))
        let bobToAlice = try bob.session(with: alice.localIdentity)
        XCTAssertEqual(string(try bobToAlice.open(first)), "m1")

        // Now three more, delivered to Bob OUT OF ORDER. The Double Ratchet's
        // skipped-message-keys handle this — exactly what a multi-hop mesh needs.
        let m2 = try aliceToBob.seal(data("m2"))
        let m3 = try aliceToBob.seal(data("m3"))
        let m4 = try aliceToBob.seal(data("m4"))

        XCTAssertEqual(string(try bobToAlice.open(m4)), "m4")   // newest first
        XCTAssertEqual(string(try bobToAlice.open(m2)), "m2")   // then older
        XCTAssertEqual(string(try bobToAlice.open(m3)), "m3")
    }

    // MARK: Safety number agreement (§3.5)

    func testSafetyNumbersMatchOnBothSides() throws {
        let alice = SignalSessionStore()
        let bob = SignalSessionStore()

        let aliceToBob = try alice.establishSession(from: try bob.localPrekeyBundle())
        // Drive one message so Bob forms his session/peer identity view.
        let ct = try aliceToBob.seal(data("verify me"))
        let bobToAlice = try bob.session(with: alice.localIdentity)
        _ = try bobToAlice.open(ct)

        let aliceView = try aliceToBob.safetyNumber()
        let bobView = try bobToAlice.safetyNumber()

        // The fingerprint is order-independent: both parties must see the SAME
        // number. If this fails, the identity handshake is wired wrong.
        XCTAssertEqual(aliceView.displayString, bobView.displayString)
        XCTAssertFalse(aliceView.displayString.isEmpty)
        XCTAssertFalse(aliceView.qrPayload.isEmpty)
    }

    // MARK: Tamper rejection

    func testTamperedMessageRejected() throws {
        let alice = SignalSessionStore()
        let bob = SignalSessionStore()

        let aliceToBob = try alice.establishSession(from: try bob.localPrekeyBundle())
        let first = try aliceToBob.seal(data("m1"))
        let bobToAlice = try bob.session(with: alice.localIdentity)
        _ = try bobToAlice.open(first)

        // Bob replies so Alice's session leaves the prekey phase and ratchets to
        // normal (whisper) messages — the same state a real conversation reaches.
        let reply = try bobToAlice.seal(data("ack"))
        _ = try aliceToBob.open(reply)

        // Now a normal ratchet message, tampered in the body.
        var tampered = try aliceToBob.seal(data("trust me"))
        // Flip a byte past the 1-byte type prefix, inside the message body, so the
        // corruption lands in the authenticated ciphertext rather than a tolerant
        // trailing field.
        let target = tampered.count / 2
        tampered[target] ^= 0xFF

        XCTAssertThrowsError(try bobToAlice.open(tampered))
    }
    // MARK: A third party cannot read

    func testThirdPartyCannotDecrypt() throws {
        let alice = SignalSessionStore()
        let bob = SignalSessionStore()
        let eve = SignalSessionStore()

        let aliceToBob = try alice.establishSession(from: try bob.localPrekeyBundle())
        let ct = try aliceToBob.seal(data("for bob only"))

        // Eve tries to open a message that wasn't sealed for her.
        let eveToAlice = try eve.session(with: alice.localIdentity)
        XCTAssertThrowsError(try eveToAlice.open(ct))
    }

    // MARK: id-1 prekey longevity (bundle production must not rotate shared keys)

    /// The field bug as a test: Alice establishes from Bob's bundle A, Bob then
    /// draws bundle B (re-opened pairing screen, re-minted invite — any redraw),
    /// and only THEN does Alice's prekey message arrive. It pins bundle A's
    /// id-1 keys, so it must still open.
    func testPrekeyMessageStillOpensAfterLaterBundleDraw() throws {
        let alice = SignalSessionStore()
        let bob = SignalSessionStore()

        let bundleA = try bob.localPrekeyBundle()
        let aliceToBob = try alice.establishSession(from: bundleA)
        let ct = try aliceToBob.seal(data("redeemed your invite"))

        // Bob redraws his bundle BEFORE the message lands.
        _ = try bob.localPrekeyBundle()

        let (peer, pt) = try bob.openInbound(ct)
        XCTAssertEqual(peer.userID, alice.localIdentity.userID)
        XCTAssertEqual(string(pt), "redeemed your invite")
    }
}
