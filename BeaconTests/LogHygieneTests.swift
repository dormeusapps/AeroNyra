//
//  LogHygieneTests.swift
//  BeaconTests
//
//  NO IDENTIFIERS IN LOGS. Scans the app's Swift sources (Core, Security,
//  Beacon, Screens) for every log call — `RedactLog.event(`, a Logger
//  `.info/.error/.debug/.notice/.warning/.fault(`, or a bare `print(` — and
//  fails if one interpolates an identifier: an identity key or its hex, a
//  Bluetooth peripheral/central identifier, a link id, a message / envelope /
//  event id, an npub, or a whole `\(error)` (whose rendering can carry them).
//  Balanced-paren aware, so multi-line calls are covered.
//
//  Reads the sources via #filePath (tests run on the Mac that built them).
//

import XCTest

final class LogHygieneTests: XCTestCase {

    private static let roots = ["Core", "Security", "Beacon", "Screens"]
    private static let callStart = try! NSRegularExpression(
        pattern: #"(RedactLog\.event\(|\blog\.(info|error|debug|notice|warning|fault)\(|(?<![\w.])print\()"#)
    /// A name that identifies someone or something on the wire.
    private static let identifier = try! NSRegularExpression(
        pattern: #"\b(userIDHex|identifier|link|id|wireID|envID|echoID|envelopeID|eventID|idPrefix|npubHex|pttIDLog|rawKey|identity|peerKey|publicKeyData)\b"#)
    /// `\(error)` alone renders the whole value (associated data included).
    private static let wholeError = try! NSRegularExpression(pattern: #"^\s*error\s*$"#)

    /// Every `\( … )` interpolation in `args`, balanced-paren extracted, so a
    /// name nested at any depth (`\(String(event.id.prefix(12)))`) is seen.
    static func interpolations(in args: String) -> [String] {
        let ns = args as NSString
        var out: [String] = []
        var i = 0
        while i < ns.length - 1 {
            if ns.character(at: i) == 92, ns.character(at: i + 1) == 40 {   // \(
                var j = i + 2, depth = 1
                while depth > 0 && j < ns.length {
                    let c = ns.character(at: j)
                    if c == 40 { depth += 1 } else if c == 41 { depth -= 1 }
                    j += 1
                }
                out.append(ns.substring(with: NSRange(location: i + 2, length: max(0, j - 1 - (i + 2)))))
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Every offending call as "path:line  args".
    static func offenders(in source: String, file: String) -> [String] {
        let ns = source as NSString
        var found: [String] = []
        for m in callStart.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            var i = m.range.location + m.range.length
            var depth = 1
            while depth > 0 && i < ns.length {
                let c = ns.character(at: i)
                if c == 40 { depth += 1 } else if c == 41 { depth -= 1 }
                i += 1
            }
            let argsRange = NSRange(location: m.range.location + m.range.length,
                                    length: max(0, i - 1 - (m.range.location + m.range.length)))
            let args = ns.substring(with: argsRange)
            let bad = interpolations(in: args).contains { piece in
                let r = NSRange(location: 0, length: (piece as NSString).length)
                return identifier.firstMatch(in: piece, range: r) != nil
                    || wholeError.firstMatch(in: piece, range: r) != nil
            }
            if bad {
                let line = ns.substring(to: m.range.location).components(separatedBy: "\n").count
                found.append("\(file):\(line)  \(args.split(whereSeparator: \.isWhitespace).joined(separator: " "))")
            }
        }
        return found
    }

    func testNoLogCallInterpolatesAnIdentifier() throws {
        var all: [String] = []
        var scanned = 0
        for root in Self.roots {
            let dir = repoRoot.appendingPathComponent(root)
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
                return XCTFail("source folder not found: \(dir.path)")
            }
            for case let url as URL in e where url.pathExtension == "swift" {
                scanned += 1
                all += Self.offenders(in: try String(contentsOf: url, encoding: .utf8),
                                      file: url.path.replacingOccurrences(of: repoRoot.path + "/", with: ""))
            }
        }
        XCTAssertGreaterThan(scanned, 100, "precondition: the sources were actually scanned")
        XCTAssertEqual(all, [], "log calls must not interpolate identifiers:\n" + all.joined(separator: "\n"))
    }

    /// The scanner itself catches each shape it must (so an empty result above means something).
    func testScannerCatchesKnownShapes() {
        let bad = [
            #"RedactLog.event("x", "from \(peer.userIDHex.prefix(16))…")"#,
            #"log.info("connected to \(peripheral.identifier)")"#,
            "RedactLog.event(\"x\",\n    \"link \\(link)\")",
            #"print("failed: \(error)")"#,
            #"log.debug("skip \(String(event.id.prefix(12)), privacy: .public)")"#,
        ]
        for s in bad { XCTAssertEqual(Self.offenders(in: s, file: "t").count, 1, s) }
        let ok = [
            #"RedactLog.event("x", "\(type(of: error))")"#,
            #"log.info("RX \(n) bytes @ \(host, privacy: .public)")"#,
        ]
        for s in ok { XCTAssertEqual(Self.offenders(in: s, file: "t"), [], s) }
    }
}
