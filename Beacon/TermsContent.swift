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

        // 3 — Abusive users; blocking (plain block reversible, report never).
        TermsPage(
            title: "Zero tolerance for abusive users.",
            paragraphs: [
                "You may not use AeroNyra to harass, threaten or abuse anyone. There is no tolerance for abusive users.",
                "You can block any contact at any time: press and hold the chat, or use their contact settings. Blocking takes effect at once, and they are not told. Their messages stop arriving, and they can't pair with you again unless you unblock them. If you report them, they can never pair with you again.",
                "A blocked or reported chat stays in your chats, marked as blocked or reported, so you can keep it as evidence.",
            ],
            agreeLabel: "I agree"
        ),

        // 4 — Reporting. Matches the built report (ReportMail.swift rules,
        // ReportFlowView). Nothing about the developer removing content or
        // ejecting users until a step makes it true.
        TermsPage(
            title: "Report anything, any time.",
            paragraphs: [
                "Press and hold the chat and tap Report, press and hold a message and tap Report, or tap Report contact in a contact's settings. A reported message is removed from your chat right away.",
                "A report is an email you send to the developer from your mail app. You can include what you know about the person, such as their name, phone number or how you met. Before it's sent you see everything in it: the reason, your name for the contact, a code that identifies them, the app version and time, what you added, and, unless you remove it, the reported message's text. Photos, videos and voice notes are never included.",
                "When the report is sent, the contact is blocked and can never pair with you again. The chat stays in your chats, marked as reported.",
                "If a crime has happened or you're in danger, contact the police first. The developer reviews every report within 24 hours.",
            ],
            agreeLabel: "I agree"
        ),

        // 5 — Filtering. Matches the built filter (receive drop, send block,
        // one switch, text only).
        TermsPage(
            title: "Filtered words never reach you.",
            paragraphs: [
                "AeroNyra checks text messages on your phone against a word list and any words you add. A message you receive with a filtered word is dropped: it is never shown, stored or notified, and turning the filter off later won't bring it back.",
                "A message you write with a filtered word isn't sent.",
                "The filter is on unless you turn it off in Settings › Safety & Support › Content filter, where you can also add your own words. It checks text only, not photos, videos or voice notes.",
            ],
            agreeLabel: "I agree"
        ),

        // 6 — Contact and support; the final Accept.
        TermsPage(
            title: "We're here.",
            paragraphs: [
                "To report inappropriate activity or get help, email \(supportAddress). You can also reach it in Settings at any time, under Safety & Support.",
                "You are responsible for what you send and for who you pair with.",
                "AeroNyra is provided as is, without warranty of any kind. The developer is not liable for damages arising from its use.",
            ],
            agreeLabel: "Accept & Continue"
        ),
    ]
}
