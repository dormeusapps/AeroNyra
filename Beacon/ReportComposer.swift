//
//  ReportComposer.swift
//  Beacon
//
//  Sending a report (Guideline 1.2): Apple Mail's composer when Mail is set
//  up, otherwise the share sheet — TEXT ONLY either way. No attachment, no
//  image of any kind: `ReportEmail` carries strings and nothing else.
//
//  Only a SENT report changes anything for the contact (report + block +
//  never pair again). Cancelled, saved as a draft, or failed: nothing
//  happens (`ReportSendResult.appliesReport`).
//

import SwiftUI
import MessageUI
import UIKit

/// The whole email: recipient, subject, body. Strings only — there is no
/// attachment field, so no image can ride a report.
struct ReportEmail: Equatable, Sendable {
    let recipient: String
    let subject: String
    let body: String

    init(draft: ReportDraft) {
        recipient = ReportMail.address
        subject = draft.subject
        body = draft.body
    }

    /// What the share sheet carries: one plain-text item, address first.
    var shareText: String {
        "To: \(recipient)\nSubject: \(subject)\n\n\(body)"
    }
}

enum ReportSendResult: Equatable, Sendable {
    case sent
    case cancelled
    case saved
    case failed

    /// True only for a sent report: the one result that reports, blocks and
    /// stops the contact from ever pairing again.
    var appliesReport: Bool { self == .sent }

    init(mail result: MFMailComposeResult) {
        switch result {
        case .sent: self = .sent
        case .saved: self = .saved
        case .failed: self = .failed
        case .cancelled: self = .cancelled
        @unknown default: self = .failed
        }
    }

    /// The share sheet only says whether the share completed. Completed counts
    /// as sent; anything else changes nothing.
    init(shareCompleted: Bool, error: Error?) {
        if error != nil { self = .failed } else { self = shareCompleted ? .sent : .cancelled }
    }
}

enum ReportComposer {
    /// Apple Mail has an account set up.
    static var canUseMail: Bool { MFMailComposeViewController.canSendMail() }
}

/// Apple Mail's composer, pre-filled, no attachment.
struct ReportMailComposeView: UIViewControllerRepresentable {
    let email: ReportEmail
    let onFinish: (ReportSendResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([email.recipient])
        vc.setSubject(email.subject)
        vc.setMessageBody(email.body, isHTML: false)
        return vc
    }

    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (ReportSendResult) -> Void
        init(onFinish: @escaping (ReportSendResult) -> Void) { self.onFinish = onFinish }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish(ReportSendResult(mail: result))
        }
    }
}

/// The fallback when Mail isn't set up: the share sheet with the report text.
struct ReportShareSheet: UIViewControllerRepresentable {
    let email: ReportEmail
    let onFinish: (ReportSendResult) -> Void

    /// One plain-text item. Nothing else is ever shared.
    static func activityItems(for email: ReportEmail) -> [Any] { [email.shareText] }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: Self.activityItems(for: email),
                                          applicationActivities: nil)
        vc.completionWithItemsHandler = { _, completed, _, error in
            onFinish(ReportSendResult(shareCompleted: completed, error: error))
        }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
