//
//  NostrTransportRefusalTests.swift
//  BeaconTests
//
//  2026-09-19 · Test A finding, pinned: the NIP-01 machine-readable CLOSED
//  prefixes were matched with a bare `hasPrefix`; relay.damus.io prefaces
//  them with `ERROR: `, so "ERROR: auth-required: …" was classed TRANSIENT and
//  the socket reconnected 133 times in ten minutes. `isPermanentRefusal` is a
//  pure classifier; the handler wiring is one line. The last test also leans
//  on `resetsReconnectBackoff` (NostrTransportBackoffResetTests), which lands
//  one commit earlier.
//  XCTest only (not Swift Testing), per project standard.
//

import XCTest
@testable import Beacon

final class NostrTransportRefusalTests: XCTestCase {

    // MARK: - Permanent refusal (NIP-01 CLOSED prefixes)

    /// The exact message relay.damus.io sent, byte for byte, on 2026-09-19.
    func testDamusErrorPrefacedAuthRequiredIsPermanent() {
        XCTAssertTrue(NostrTransport.isPermanentRefusal(
            "ERROR: auth-required: requested filter requires authentication"))
    }

    func testEveryStandardPrefixIsPermanent() {
        for prefix in NostrTransport.permanentRefusalPrefixes {
            XCTAssertTrue(NostrTransport.isPermanentRefusal("\(prefix) reason"), prefix)
            XCTAssertTrue(NostrTransport.isPermanentRefusal("ERROR: \(prefix) reason"), "ERROR: \(prefix)")
        }
    }

    func testMatchIsCaseAndWhitespaceTolerant() {
        XCTAssertTrue(NostrTransport.isPermanentRefusal("  Error:   Auth-Required: nope  "))
        XCTAssertTrue(NostrTransport.isPermanentRefusal("BLOCKED: you"))
    }

    func testTransientAndUnknownMessagesAreNotPermanent() {
        for msg in ["rate-limited: slow down",
                    "ERROR: rate-limited: slow down",
                    "ERROR: too many concurrent REQs",
                    "error: something else entirely",
                    "closing for restart",
                    "",
                    "ERROR:"] {
            XCTAssertFalse(NostrTransport.isPermanentRefusal(msg), msg)
        }
    }

    /// The prefix must LEAD the message (after the optional `error:`); a
    /// prefix word buried mid-sentence is not a machine-readable refusal.
    func testPrefixMustLeadTheMessage() {
        XCTAssertFalse(NostrTransport.isPermanentRefusal("closing: auth-required: later"))
        XCTAssertFalse(NostrTransport.isPermanentRefusal("ERROR: ERROR: auth-required: doubled"))
    }

    /// The real parser feeds the classifier: a damus-shaped CLOSED frame
    /// parses to `.closed` with the message intact (nothing strips `ERROR:`
    /// upstream), and that message is a permanent refusal.
    func testParsedDamusClosedFrameIsPermanentAndDoesNotResetBackoff() throws {
        let frame = Data(#"["CLOSED","81f65dad9c448613","ERROR: auth-required: requested filter requires authentication"]"#.utf8)
        let message = try XCTUnwrap(NostrTransport.parseRelayFrame(frame))
        guard case .closed(let sub, let msg) = message else { return XCTFail("expected .closed, got \(message)") }
        XCTAssertEqual(sub, "81f65dad9c448613")
        XCTAssertTrue(NostrTransport.isPermanentRefusal(msg))
        XCTAssertFalse(NostrTransport.resetsReconnectBackoff(message))
    }
}
