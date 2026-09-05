//
//  ReportMail.swift
//  Screens
//
//  The Report affordance (App Review Guideline 1.2): a pre-filled email to the
//  support address, composed as a `mailto:` URL and opened through the user's
//  own default mail client via `openURL`. No server, no upload — the report
//  leaves the device only when the user sends the email themselves.
//
//  PRIVACY CONTRACT — the pre-filled body may contain ONLY:
//   • app version + build (Bundle.main)
//   • an ISO-8601 timestamp
//   • the LOCAL, user-assigned nickname (Peer.displayName raw value — never
//     the key-derived short-fingerprint fallback some views display)
//   • the locally-minted SwiftData UUIDs (Conversation.id / Message.id),
//     which exist only on this device and correlate to nothing on the wire
//  FORBIDDEN — never add: publicKeyData / userIDHex (any prefix, however
//  short), nostrPubkey, wireIDData, Message.content, mediaData, or the
//  reporter's own fingerprint. Those identify people or content globally
//  and would break the app's "Data Not Collected" posture.
//

import Foundation

enum ReportMail {

    static let address = "support@dormeusapps.com"
    static let subject = "AeroNyra report"

    /// The complete `mailto:` URL for a report. `messageID` is nil when
    /// reporting a contact rather than a specific message; ALL THREE nil is
    /// the contact-less "Report a problem" variant (Settings) — the body then
    /// carries only version + timestamp and the user types the rest. Returns
    /// nil only if URL composition fails (never expected for this fixed shape).
    static func url(contactNickname: String?,
                    conversationID: UUID?,
                    messageID: UUID?) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body(contactNickname: contactNickname,
                                                   conversationID: conversationID,
                                                   messageID: messageID)),
        ]
        return components.url
    }

    /// See the file-header privacy contract before touching this.
    static func body(contactNickname: String?,
                     conversationID: UUID?,
                     messageID: UUID?) -> String {
        var lines: [String] = [
            "Describe what happened here. You can include any information you choose — the context below is everything the app adds.",
            "",
            "Reports are reviewed and answered within 24 hours.",
            "",
            "— context added by the app (no message content, no keys) —",
            "App version: \(appVersion)",
            "Reported at: \(ISO8601DateFormatter().string(from: Date()))",
        ]
        // The contact line only when the report is ABOUT a contact or message
        // (any context field present). The contact-less Settings variant
        // passes all nil, and "(no nickname set)" there would imply a contact
        // exists. Existing callers always pass a conversationID, so their
        // bodies are unchanged.
        if contactNickname != nil || conversationID != nil || messageID != nil {
            let nickname = contactNickname?.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("Contact (your local nickname): \((nickname?.isEmpty == false) ? nickname! : "(no nickname set)")")
        }
        if let conversationID {
            lines.append("Conversation ref: \(conversationID.uuidString)")
        }
        if let messageID {
            lines.append("Message ref: \(messageID.uuidString)")
        }
        return lines.joined(separator: "\n")
    }

    /// "1.0 (8)" — marketing version + build, from the generated Info.plist.
    private static var appVersion: String {
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
