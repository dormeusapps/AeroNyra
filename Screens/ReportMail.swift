//
//  ReportMail.swift
//  Screens
//
//  Reports to the developer (App Review Guideline 1.2), by email from the
//  user's own mail app — no server, no upload. Two kinds:
//   • a REPORT about a contact or a message: `ReportDraft` (Beacon/), shown
//     in full in the report preview and sent through `ReportComposer`
//     (Apple Mail's composer, or the share sheet) — TEXT ONLY;
//   • "Report a problem" (Settings): the `mailto:` below, with only the app
//     version and the time; the user types the rest.
//
//  RULES — a report's email may contain ONLY:
//   • the reason the user chose;
//   • the user's LOCAL nickname for the contact (Peer.displayName, never the
//     key-derived short-fingerprint fallback some views display);
//   • the contact code (`ReportDraft.contactCode`): SHA-256 of a domain label
//     and the key, 16 bytes — a code, never the key;
//   • the app version and the time;
//   • what the user typed — the identity fields and "What happened" — exactly
//     as typed, each only when filled;
//   • the reported message's text, VERBATIM, only for a message report and
//     only while its preview switch is on (media only as "[photo]" /
//     "[video]" / "[voice note]").
//  The preview and the email are built from the SAME `ReportDraft`, so the
//  email never carries anything the preview did not show. The content filter
//  NEVER applies to report content.
//  FORBIDDEN — never add: the identity key or any part of it (publicKeyData,
//  userIDHex, however short), nostrPubkey, wire ids (wireIDData), local
//  reference numbers (Conversation / Message UUIDs), any media bytes, ANY
//  IMAGE OF ANY KIND (a report has no attachment at all), the reporter's own
//  key or code, or anything from another conversation.
//  Nothing in a report is stored on this device or logged.
//

import Foundation

enum ReportMail {

    static let address = "support@dormeusapps.com"
    static let subject = "AeroNyra report"

    /// The `mailto:` URL for a plain email to the developer. `contactNickname`
    /// nil is "Report a problem" (Settings): the body then carries only the
    /// app version and the time, and the user types the rest. Returns nil
    /// only if URL composition fails (never expected for this fixed shape).
    static func url(contactNickname: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body(contactNickname: contactNickname)),
        ]
        return components.url
    }

    /// See the file-header rules before touching this.
    static func body(contactNickname: String?, at date: Date = Date()) -> String {
        var lines: [String] = [
            "Describe what happened here. You can include any information you choose — the context below is everything the app adds.",
            "",
            "Reports are reviewed within 24 hours.",
            "",
            "— context added by the app (no message content, no keys) —",
            "App version: \(appVersion)",
            "Reported at: \(ISO8601DateFormatter().string(from: date))",
        ]
        if let nickname = contactNickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nickname.isEmpty {
            lines.append("Contact (your local nickname): \(nickname)")
        }
        return lines.joined(separator: "\n")
    }

    /// "1.0 (8)" — marketing version + build, from the generated Info.plist.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

/// Persisted "you reported this message" display state (Guideline 1.2: a
/// reported message must leave the feed immediately, and stay gone across
/// relaunch). The set of reported Message UUIDs lives in UserDefaults as a
/// comma-joined string — `@AppStorage("aeronyra.reportedMessages.v1")` at the
/// view call site, constant mirrored in `DeviceResidueWipe` (cleared on
/// crypto-erase). PRESENTATION ONLY, same contract as ContentFilter: the
/// model row is never mutated and never deleted — `MessageInbox.resend`
/// transmits from the persisted row, and the user may need the record —
/// so the hidden state lives BESIDE the row, not in it. UUIDs here are the
/// locally-minted SwiftData ids that correlate to nothing on the wire.
enum ReportedMessages {

    /// True when `id` is in the persisted set (`raw` is the stored string).
    static func contains(_ id: UUID, in raw: String) -> Bool {
        raw.split(separator: ",").contains(Substring(id.uuidString))
    }

    /// The stored string with `id` added. Idempotent — reporting the same
    /// message twice never duplicates the entry.
    static func adding(_ id: UUID, to raw: String) -> String {
        guard !contains(id, in: raw) else { return raw }
        return raw.isEmpty ? id.uuidString : "\(raw),\(id.uuidString)"
    }
}
