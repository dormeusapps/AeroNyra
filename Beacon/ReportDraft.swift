//
//  ReportDraft.swift
//  Beacon
//
//  One report (App Review Guideline 1.2), as the user sees it in the preview
//  and exactly as the email carries it: the preview and the email are both
//  built from this value, so nothing reaches the email that the preview did
//  not show. Rules: ReportMail.swift's header.
//
//  Held in memory only, for as long as the report sheet is open. Never
//  saved, never logged.
//

import Foundation
import CryptoKit

enum ReportReason: String, CaseIterable, Identifiable, Sendable {
    case spam
    case harassment
    case explicit
    case threats
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spam: return "Spam"
        case .harassment: return "Harassment or bullying"
        case .explicit: return "Sexual or explicit content"
        case .threats: return "Threats or violence"
        case .other: return "Other"
        }
    }
}

/// What the reporter knows about the person. Every field is optional.
struct ReportIdentityInfo: Equatable, Sendable {
    var name = ""
    var phone = ""
    var emailOrSocial = ""
    var howYouKnowThem = ""
    var howYouGotTheInvite = ""

    /// (heading, value) for each filled field, in order.
    var filled: [(String, String)] {
        [("Name", name),
         ("Phone", phone),
         ("Email or social media", emailOrSocial),
         ("How you know them / where you met", howYouKnowThem),
         ("How you got their invite", howYouGotTheInvite)]
            .map { ($0.0, $0.1.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty }
    }
}

struct ReportDraft: Equatable, Sendable {
    var reason: ReportReason
    /// The reporter's local nickname for the contact.
    var contactName: String
    /// `ReportDraft.contactCode(forRawKey:)` — never the raw key.
    var contactCode: String
    /// The reported message's text, VERBATIM (message reports only; nil for
    /// a contact report). The content filter is never consulted.
    var reportedMessageText: String?
    /// The preview's "Reported message text" switch.
    var includesReportedMessage = true
    var identity = ReportIdentityInfo()
    var whatHappened = ""
    var appVersion: String
    var reportedAt: Date

    var subject: String { "\(ReportMail.subject) — \(reason.label)" }

    /// The email body. Each section only when it has content.
    var body: String {
        var lines = [
            "Reason: \(reason.label)",
            "Contact (your name for them): \(contactName)",
            "Contact code: \(contactCode)",
        ]
        let known = identity.filled
        if !known.isEmpty {
            lines += ["", "What you know about this person"]
            lines += known.map { "\($0.0): \($0.1)" }
        }
        let happened = whatHappened.trimmingCharacters(in: .whitespacesAndNewlines)
        if !happened.isEmpty {
            lines += ["", "What happened", happened]
        }
        if includesReportedMessage, let text = reportedMessageText {
            lines += ["", "Reported message", text]
        }
        lines += ["",
                  "App version: \(appVersion)",
                  "Reported at: \(ISO8601DateFormatter().string(from: reportedAt))"]
        return lines.joined(separator: "\n")
    }

    /// The reported message as the report carries it: a text message
    /// VERBATIM (the content filter is never consulted); a photo, video or
    /// voice note only as a placeholder — media never rides a report.
    static func messageText(content: String, mediaMimeRaw: String?) -> String {
        guard let mediaMimeRaw else { return content }
        switch MediaMimeType(rawValue: mediaMimeRaw) {
        case .jpeg: return "[photo]"
        case .mp4: return "[video]"
        case .m4a: return "[voice note]"
        case nil: return "[media]"
        }
    }

    /// A code that identifies a contact across reports without revealing
    /// their key: SHA-256 of a domain label and the raw 32-byte key, first 16
    /// bytes, as hex in groups of four. The same key always gives the same
    /// code; the code can't be turned back into the key.
    static func contactCode(forRawKey rawKey: Data) -> String {
        var input = Data("AeroNyra/report-contact/v1".utf8)
        input.append(rawKey)
        let hex = SHA256.hash(data: input).prefix(16).map { String(format: "%02x", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { i -> String in
            let s = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[s..<hex.index(s, offsetBy: 4)])
        }.joined(separator: " ")
    }
}
