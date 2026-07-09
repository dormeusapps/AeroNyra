// InviteTransportNormalizationTests.swift
// KATs for the human-transport string layer. Every expected value below was
// computed by an EXTERNAL Python generator (mint → mangle → expected), never
// by the code under test. The canonical fixture is a structurally valid
// Invite wire: 110 bytes,
// sha256 b0f9f3ec450c89fe531749e5c297e7b15ea5cabe33dc41f5be3d0907c81aa6fb.
//
// Layering under test:
//   • tolerance ONLY in normalizeInviteTransportString (edge whitespace, one
//     quote pair, percent-encoded scheme PREFIX, QP soft breaks, hard-wrap
//     whitespace);
//   • base64URLDecode REJECTS any residual non-alphabet char — never filters;
//   • Invite(wire:) stays byte-strict and is the structural backstop.

import XCTest
@testable import Beacon

final class InviteTransportNormalizationTests: XCTestCase {

    static let canonical = "aeronyra://invite/AQABAgMEBQYHCAkKCwwNDg8AAAGX6jF4AAAAAZfqOp_AAAAASQEAAAAg3q2-796tvu_erb7v3q2-796tvu_erb7v3q2-796tvu8AAAAgICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8"
    static let wireHex = "01000102030405060708090a0b0c0d0e0f00000197ea31780000000197ea3a9fc0000000490100000020deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef00000020202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"

    /// The exact production path: normalize → scheme parse → strict b64url.
    private func decodeViaProductionPath(_ input: String) -> Data? {
        let cleaned = PairingService.normalizeInviteTransportString(input)
        guard let b64 = PairingService.parseInviteScheme(cleaned) else { return nil }
        return PairingService.base64URLDecode(b64)
    }

    private var expectedWire: Data {
        var d = Data()
        var i = Self.wireHex.startIndex
        while i < Self.wireHex.endIndex {
            let j = Self.wireHex.index(i, offsetBy: 2)
            d.append(UInt8(Self.wireHex[i..<j], radix: 16)!)
            i = j
        }
        return d
    }

    /// Sanity: the fixture itself round-trips and parses as a real Invite.
    func testCanonicalFixture() {
        XCTAssertEqual(decodeViaProductionPath(Self.canonical), expectedWire)
        XCTAssertNotNil(Invite(wire: expectedWire))
    }

    // V1–V7: transport mangles that MUST recover the exact canonical bytes.
    func testAcceptVectors() {
        let c = Self.canonical
        let wrap76 = Self.chunked(c, every: 76).joined(separator: "\r\n")
        let qp72 = Self.chunked(c, every: 72).joined(separator: "=\r\n")
        let percentEncoded = "aeronyra%3A%2F%2Finvite%2F"
            + c.dropFirst("aeronyra://invite/".count)

        let vectors: [(String, String)] = [
            ("V1 trailing LF",      c + "\n"),
            ("V2 trailing CRLF",    c + "\r\n"),
            ("V3 76-col CRLF wrap", wrap76),
            ("V4 QP soft breaks",   qp72),
            ("V5 smart quotes",     "\u{201C}" + c + "\u{201D}"),
            ("V6 leading space",    " " + c),
            ("V7 percent-encoded scheme", percentEncoded),
        ]
        for (name, mangled) in vectors {
            XCTAssertEqual(PairingService.normalizeInviteTransportString(mangled),
                           c, "\(name): normalize must recover canonical")
            XCTAssertEqual(decodeViaProductionPath(mangled), expectedWire,
                           "\(name): bytes must equal the external-KAT wire")
        }
    }

    // N1: %2D injected mid-body. The scheme is already plain, so NOTHING is
    // percent-decoded; the '%' reaches the alphabet gate and rejects at the
    // STRING layer. (Whole-string percent-decoding here would silently
    // rewrite %2D → '-' — different well-formed bytes — which is exactly
    // what the prefix-only rule forbids.)
    func testInjectedPercentEscapeRejectsAtStringLayer() {
        let c = Self.canonical
        let cut = c.index(c.startIndex, offsetBy: 40)
        let mangled = String(c[..<cut]) + "%2D" + String(c[cut...])
        XCTAssertNil(decodeViaProductionPath(mangled))
    }

    // N2: '+' mid-body — outside the b64url alphabet, not a transport
    // artifact: rejected at the string layer, never filtered.
    func testForeignAlphabetCharacterRejectsAtStringLayer() {
        let c = Self.canonical
        let cut = c.index(c.startIndex, offsetBy: 40)
        XCTAssertNil(decodeViaProductionPath(String(c[..<cut]) + "+" + String(c[cut...])))
    }

    // N3: truncation — the string layer decodes (80 bytes) by design; the
    // byte-strict binary layer is the backstop that refuses it.
    func testTruncationIsCaughtAtBinaryLayer() {
        let truncated = String(Self.canonical.dropLast(40))
        guard let bytes = decodeViaProductionPath(truncated) else {
            return XCTFail("N3 decodes at the string layer by design")
        }
        XCTAssertNotEqual(bytes, expectedWire)
        XCTAssertNil(Invite(wire: bytes))
    }

    // Ordering pin: normalization strips transport artifacts BEFORE the % 4
    // re-pad loop. Under the wrong order (pad, then strip) V1 sees 148 chars
    // (%4 == 0, no padding added), strips to 147 unpadded, and decode fails.
    // testAcceptVectors is the real pin; this documents the property.
    func testNormalizationRunsBeforeRepadding() {
        XCTAssertEqual(decodeViaProductionPath(Self.canonical + "\n"), expectedWire)
    }

    private static func chunked(_ s: String, every n: Int) -> [String] {
        var out: [String] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: n, limitedBy: s.endIndex) ?? s.endIndex
            out.append(String(s[i..<j]))
            i = j
        }
        return out
    }
}
