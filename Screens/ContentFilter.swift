//
//  ContentFilter.swift
//  Screens
//
//  Local, on-device content filter (App Review Guideline 1.2). Inbound text is
//  checked AT RENDER TIME only, on the recipient's device, against a small
//  built-in list plus the user's own words. Nothing is transmitted and nothing
//  is written to the model — `Message.content` is NEVER mutated, because
//  `MessageInbox.resend` transmits directly from the persisted row, so a
//  placeholder written into the model could go over the wire. Because the
//  check runs at render, it sits far downstream of the delivery ack in
//  `FirstContactCoordinator.receive` — a filtered message still acks, so the
//  sender never strands at the 45 s `.notDelivered` timeout.
//
//  Storage is `@AppStorage` (UserDefaults) under
//  `aeronyra.contentFilter.enabled.v1` / `aeronyra.contentFilter.words.v1` —
//  literals at the view call sites, constants in `DeviceResidueWipe`, which
//  MUST clear both on crypto-erase: a user-authored word list is
//  fingerprinting residue.
//

import Foundation

/// Pure matching logic for the filter. @MainActor because the compiled-regex
/// cache is unsynchronized state and every caller is a view.
@MainActor
enum ContentFilter {

    /// The built-in list: a deliberately small set of unambiguous slurs with
    /// essentially no innocent word-boundary use in ordinary text. Kept short
    /// because every entry is a false-positive surface; the user adds their
    /// own words in Settings. A match hides the message behind a one-tap
    /// reveal — never a deletion, never a modification.
    static let defaultWords: [String] = [
        "nigger", "nigga", "faggot", "kike", "spic",
        "wetback", "tranny", "gook", "beaner", "raghead",
    ]

    /// True when `text` contains any filtered word. Word-boundary and
    /// case-insensitive to limit false positives; a trailing "s" is tolerated
    /// so bare plurals still match. `userWords` is the raw comma-separated
    /// string from Settings.
    static func matches(_ text: String, userWords: String) -> Bool {
        guard !text.isEmpty, let regex = regex(for: userWords) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    // One compiled regex per distinct user-word string (the built-in list is
    // fixed); render calls hit the cache.
    private static var cachedUserWords: String?
    private static var cachedRegex: NSRegularExpression?

    private static func regex(for userWords: String) -> NSRegularExpression? {
        if userWords == cachedUserWords { return cachedRegex }
        let extras = userWords
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let alternation = (defaultWords + extras)
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        cachedUserWords = userWords
        cachedRegex = try? NSRegularExpression(pattern: "\\b(?:\(alternation))s?\\b",
                                               options: [.caseInsensitive])
        return cachedRegex
    }
}
