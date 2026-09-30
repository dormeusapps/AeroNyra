//
//  TermsContent.swift
//  Beacon
//
//  The Terms of Use copy (App Review Guideline 1.2) — the MASTER text; App
//  Store Connect's license agreement is matched to it at submission. One page
//  per section, each with its own explicit agreement.
//
//  Every sentence here must be true of the CURRENT build. Copy for features
//  that are not built yet sits beside the page in a `PENDING` comment, never
//  in a string, so nothing ships claiming what doesn't exist
//  (TermsPagerTests fails on "PENDING" or "[" in any page). When a step lands,
//  edit this file only.
//
//  Bump `TermsVersion.current` (TermsAcceptance.swift) when this text changes
//  materially, so every install is asked again.
//

import Foundation

struct TermsPage: Equatable, Sendable {
    let title: String
    let paragraphs: [String]
    /// The gate's button on this page.
    let agreeLabel: String
}

enum TermsContent {

    static let signature = "DORMEUSAPPS LLC"
    static let supportAddress = "support@dormeusapps.com"

    static let pages: [TermsPage] = [

        // 1 — Age.
        TermsPage(
            title: "For adults only.",
            paragraphs: [
                "AeroNyra is for people 18 and older. By continuing, you confirm that you are 18 or older.",
            ],
            agreeLabel: "I am 18 or older"
        ),

        // 2 — Objectionable content.
        TermsPage(
            title: "Zero tolerance for objectionable content.",
            paragraphs: [
                "You may not use AeroNyra to send content that is illegal, threatening, harassing, hateful, sexually explicit involving minors, or that promotes violence or abuse.",
                "This covers messages, photos, videos, voice notes and stories. There is no tolerance for objectionable content.",
            ],
            agreeLabel: "I agree"
        ),

        // 3 — Abusive users; blocking.
        // PENDING (never-pair step): replace "and they can't pair with you
        // again unless you unblock them" once a block can never be re-paired.
        TermsPage(
            title: "Zero tolerance for abusive users.",
            paragraphs: [
                "You may not use AeroNyra to harass, threaten or abuse anyone. There is no tolerance for abusive users.",
                "You can block any contact at any time from their contact settings. Blocking takes effect at once, and they are not told. Their messages stop arriving, and they can't pair with you again unless you unblock them.",
                "Your conversation is kept under Settings › Blocked contacts, in case you need it for a report.",
            ],
            agreeLabel: "I agree"
        ),

        // 4 — Reporting.
        // PENDING (report step): after "removed from your chat right away" add
        // "and the sender is blocked" (report also blocks + never-pair).
        // PENDING (report step): the report will carry a screenshot, the
        // message text, the contact's name and identity key, shown to the user
        // before sending — rewrite the "fills in only…" sentence to match.
        // Nothing about the developer removing content or ejecting users until
        // a step makes it true.
        TermsPage(
            title: "Report anything, any time.",
            paragraphs: [
                "Press and hold a message and tap Report, or tap Report contact in a contact's settings. A reported message is removed from your chat right away.",
                "A report is an email you send to the developer from your own mail app. The app fills in only the app version, the time, your nickname for the contact, and reference numbers, never message content or keys.",
                "The developer reviews every report within 24 hours. The developer runs no server and cannot read your messages. If a report involves illegal activity, also contact law enforcement.",
            ],
            agreeLabel: "I agree"
        ),

        // 5 — Filtering.
        // PENDING (filter step): filtered messages will never be displayed or
        // stored — drop "hidden behind a notice, and you can tap to see it".
        // PENDING (Safety & Support step): "Settings › Content filter" becomes
        // "Settings › Safety & Support" once the filter row moves there.
        TermsPage(
            title: "Filtered words stay hidden.",
            paragraphs: [
                "AeroNyra checks incoming text messages on your phone against a built-in list of slurs and any words you add. A message that matches is hidden behind a notice, and you can tap to see it if you choose.",
                "Nothing is sent anywhere. Filtering is on unless you turn it off. Add your own words in Settings › Content filter.",
            ],
            agreeLabel: "I agree"
        ),

        // 6 — Contact and support; the final Accept.
        // PENDING (Safety & Support step): "under Report a problem" becomes
        // "under Safety & Support" once the report row moves there.
        TermsPage(
            title: "We're here.",
            paragraphs: [
                "To report inappropriate activity or get help, email \(supportAddress). You can also reach it in Settings at any time, under Report a problem.",
                "You are responsible for what you send and for who you pair with.",
                "AeroNyra is provided as is, without warranty of any kind. The developer is not liable for damages arising from its use.",
            ],
            agreeLabel: "Accept & Continue"
        ),
    ]
}
