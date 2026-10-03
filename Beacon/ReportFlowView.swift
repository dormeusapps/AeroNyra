//
//  ReportFlowView.swift
//  Beacon
//
//  The report flow (App Review Guideline 1.2), one sheet, screen by screen:
//    who is this person → confirm → name (only if unnamed) → reason →
//    preview → Apple Mail's composer (or the share sheet) → result.
//  Nothing happens before Confirm. Confirm on a MESSAGE report hides that
//  message at once (as before). Only a SENT report reports, blocks and stops
//  the contact from ever pairing again (`ReportSendResult.appliesReport`);
//  cancelled, saved or failed changes nothing and offers a plain Block.
//
//  Everything typed here lives in this view's state only: never saved,
//  never logged, gone when the sheet closes. The email is built from the
//  same `ReportDraft` the preview shows. No images, no attachment.
//
//  Lives in Beacon/ (a synchronized folder), not Screens/ (a classic group).
//

import SwiftUI
import SwiftData

/// Fixed copy (the first screen is pinned by test).
enum ReportFlowCopy {
    static let whoTitle = "Who is this person?"
    static let whoBody = """
    AeroNyra has no accounts or phone numbers, so we can't tell who this person is from the app. You paired with them, so you may know. Please include anything that helps identify them: their name, phone number, email, social media, where you met, and how you got their invite.

    If a crime has happened or you're in danger, contact the police first. Reports to us help us spot patterns and improve AeroNyra's safety.
    """
    static let previewLead = "This is everything the email will contain. The developer will also see your email address."
    static let safetyLine = "Don't attach photos. Keep this chat; it stays in your app as evidence."
    static let previewFooter = "Photos, videos and voice notes are never included. The developer reviews every report within 24 hours."

    /// First line of a not-sent result. A message report hid its message at
    /// Confirm and that stays; a contact report has no message.
    static func notSentLead(name: String, isMessageReport: Bool) -> String {
        isMessageReport
            ? "The reported message stays hidden from your chat. Nothing else has changed for \(name)."
            : "Nothing has changed for \(name)."
    }
}

struct ReportFlowView: View {

    let peer: Peer
    /// The reported message (message report); nil for a contact report.
    let message: Message?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PairingService.self) private var pairing: PairingService?

    /// Same key as the chat's reported-message hiding (DeviceResidueWipe clears it).
    @AppStorage("aeronyra.reportedMessages.v1") private var reportedMessageIDs = ""

    private enum Step: Equatable {
        case who, confirm, name, reason, preview, result(ReportSendResult)
    }

    @State private var step: Step = .who
    @State private var nameDraft = ""
    @State private var reason: ReportReason = .other
    @State private var identity = ReportIdentityInfo()
    @State private var whatHappened = ""
    @State private var includesMessage = true
    @State private var reportedAt = Date()
    @State private var showMail = false
    @State private var showShare = false
    /// The report was sent but saving the block failed: retry offered.
    @State private var blockAfterSendFailed = false
    /// "Block [name]" on a not-sent result.
    @State private var plainBlockDone = false
    @State private var plainBlockFailed = false

    // MARK: Derived

    private var rawKey: Data { peer.publicKeyData }
    private var nickname: String? {
        let n = peer.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? nil : n
    }
    /// The name every screen uses (the name step guarantees one by the reason step).
    private var name: String { nickname ?? String(peer.userIDHex.prefix(6)).uppercased() }
    private var safety: ChatSafety { ChatSafety.of(rawKey, in: pairing?.blockedContacts ?? []) }

    private var draft: ReportDraft {
        var d = ReportDraft(reason: reason,
                            contactName: name,
                            contactCode: ReportDraft.contactCode(forRawKey: rawKey),
                            reportedMessageText: message.map {
                                ReportDraft.messageText(content: $0.content, mediaMimeRaw: $0.mediaMimeRaw)
                            },
                            appVersion: ReportMail.appVersion,
                            reportedAt: reportedAt)
        d.includesReportedMessage = includesMessage
        d.identity = identity
        d.whatHappened = whatHappened
        return d
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Stillwater.Palette.biolume.opacity(0.09)).frame(height: 1)
            ScrollView {
                content
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            footerButtons
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .background(Stillwater.Palette.abyss.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(step != .who)
        .sheet(isPresented: $showMail) {
            ReportMailComposeView(email: ReportEmail(draft: draft)) { result in
                showMail = false
                finish(result)
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showShare) {
            ReportShareSheet(email: ReportEmail(draft: draft)) { result in
                showShare = false
                finish(result)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { goBack() } label: {
                Text("‹")
                    .stillwaterSerif(20, color: Stillwater.Palette.biolume)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(canGoBack ? 1 : 0)
            .disabled(!canGoBack)
            .accessibilityLabel("Back")
            Spacer()
            Text("Report").stillwaterSerif(17, weight: .medium, color: Stillwater.Palette.foam)
            Spacer()
            Button { dismiss() } label: {
                Text(isResult ? "Done" : "Cancel")
                    .stillwaterSerif(15, color: Stillwater.Palette.mist)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    private var isResult: Bool { if case .result = step { return true }; return false }

    private var canGoBack: Bool {
        switch step {
        case .confirm, .name, .reason, .preview: return true
        case .who, .result: return false
        }
    }

    private func goBack() {
        switch step {
        case .confirm: step = .who
        case .name: step = .confirm
        case .reason: step = .confirm
        case .preview: step = .reason
        case .who, .result: break
        }
    }

    // MARK: Screens

    @ViewBuilder
    private var content: some View {
        switch step {
        case .who:
            page(title: ReportFlowCopy.whoTitle, paragraphs: [ReportFlowCopy.whoBody])
        case .confirm:
            page(title: "Report \(name)?", paragraphs: confirmParagraphs)
        case .name:
            namePage
        case .reason:
            reasonPage
        case .preview:
            previewPage
        case .result(let result):
            resultPage(result)
        }
    }

    private var confirmParagraphs: [String] {
        var out: [String] = []
        if message != nil { out.append("This message is removed from your chat now.") }
        out.append("If you send the report:")
        out.append(safety == .normal
                   ? "• \(name) is blocked. Their messages stop arriving, and they aren't told."
                   : "• \(name) stays blocked.")
        out.append("• Your chat stays in your chats, marked as reported, and you can still read it.")
        out.append("• \(name) can never pair with you again.")
        out.append("You'll see everything in the report before it's sent.")
        return out
    }

    private func page(title: String, paragraphs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(Stillwater.Serif.regular(26))
                .foregroundStyle(Stillwater.Palette.foam)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, p in
                Text(p)
                    .font(Stillwater.Serif.italic(16))
                    .foregroundStyle(Stillwater.Palette.mist)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
    }

    private var namePage: some View {
        VStack(alignment: .leading, spacing: 20) {
            page(title: "Name this contact", paragraphs: ["So your report and your chats say who this was."])
            SettingsGroup {
                SettingsRow {
                    TextField(text: $nameDraft) {
                        Text("name").foregroundStyle(Stillwater.Palette.mistDim)
                    }
                    .textFieldStyle(.plain)
                    .font(Stillwater.Serif.regular(17))
                    .foregroundStyle(Stillwater.Palette.foam)
                    .tint(Stillwater.Palette.biolume)
                    .submitLabel(.done)
                }
            }
        }
    }

    private var reasonPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            page(title: "Why are you reporting \(name)?", paragraphs: [])
            SettingsGroup {
                ForEach(ReportReason.allCases) { r in
                    Button {
                        reason = r
                        reportedAt = Date()
                        step = .preview
                    } label: {
                        SettingsRow {
                            HStack {
                                Text(r.label).font(Stillwater.Serif.regular(17)).foregroundStyle(Stillwater.Palette.foam)
                                Spacer(minLength: 12)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Stillwater.Palette.mistDim)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var previewPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            page(title: "Your report", paragraphs: [ReportFlowCopy.previewLead])

            SettingsGroup(header: "Report") {
                fixedRow("Reason", draft.reason.label)
                fixedRow("Contact", draft.contactName)
                fixedRow("Contact code", draft.contactCode, mono: true)
                fixedRow("App version", draft.appVersion)
                fixedRow("Time", reportedAt.formatted(date: .abbreviated, time: .shortened))
            }

            SettingsGroup(header: "What you know about this person", footer: "All optional. Only what you fill in is sent.") {
                field("Name", $identity.name)
                field("Phone", $identity.phone, keyboard: .phonePad)
                field("Email or social media", $identity.emailOrSocial, keyboard: .emailAddress)
                field("How you know them / where you met", $identity.howYouKnowThem)
                field("How you got their invite", $identity.howYouGotTheInvite)
            }

            SettingsGroup(header: "What happened") {
                field("Optional", $whatHappened, multiline: true)
            }

            if let text = draft.reportedMessageText {
                SettingsGroup(header: "Evidence") {
                    SettingsRow {
                        Toggle(isOn: $includesMessage) {
                            Text("Reported message text")
                                .font(Stillwater.Serif.regular(17))
                                .foregroundStyle(Stillwater.Palette.foam)
                        }
                        .tint(Stillwater.Palette.biolume)
                    }
                    if includesMessage {
                        SettingsRow {
                            Text(text)
                                .font(Stillwater.Serif.italic(15))
                                .foregroundStyle(Stillwater.Palette.mist)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(ReportFlowCopy.safetyLine)
                    .font(Stillwater.Serif.regular(15))
                    .foregroundStyle(Stillwater.Palette.foam)
                Text(ReportFlowCopy.previewFooter)
                    .font(Stillwater.Serif.italic(13))
                    .foregroundStyle(Stillwater.Palette.mistDim)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24)
        }
    }

    private func fixedRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        SettingsRow {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).font(Stillwater.Serif.regular(15)).foregroundStyle(Stillwater.Palette.mistDim)
                Spacer(minLength: 12)
                Text(value)
                    .font(mono ? Stillwater.Mono.regular(12) : Stillwater.Serif.regular(15))
                    .foregroundStyle(Stillwater.Palette.foam)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func field(_ label: String, _ text: Binding<String>,
                       keyboard: UIKeyboardType = .default, multiline: Bool = false) -> some View {
        SettingsRow {
            TextField(text: text, axis: multiline ? .vertical : .horizontal) {
                Text(label).foregroundStyle(Stillwater.Palette.mistDim)
            }
            .lineLimit(multiline ? 3...8 : 1...3)
            .textFieldStyle(.plain)
            .font(Stillwater.Serif.regular(16))
            .foregroundStyle(Stillwater.Palette.foam)
            .tint(Stillwater.Palette.biolume)
            .keyboardType(keyboard)
            .autocorrectionDisabled(keyboard != .default)
            .textInputAutocapitalization(keyboard == .default ? .sentences : .never)
        }
    }

    @ViewBuilder
    private func resultPage(_ result: ReportSendResult) -> some View {
        switch result {
        case .sent where blockAfterSendFailed:
            page(title: "Report sent",
                 paragraphs: ["\(name) couldn't be blocked on this phone. Try again."])
        case .sent:
            page(title: "Report sent",
                 paragraphs: ["\(name) is blocked and can never pair with you again. Your chat stays in your chats, marked as reported."])
        case .cancelled, .saved:
            page(title: "Report not sent", paragraphs: notSentParagraphs)
        case .failed:
            page(title: "Mail couldn't send the report", paragraphs: notSentParagraphs)
        }
    }

    private var notSentParagraphs: [String] {
        var out = [ReportFlowCopy.notSentLead(name: name, isMessageReport: message != nil)]
        if plainBlockDone { out.append("\(name) is blocked. You can unblock them in their contact settings.") }
        if plainBlockFailed { out.append("\(name) couldn't be blocked. Please try again.") }
        return out
    }

    // MARK: Buttons

    @ViewBuilder
    private var footerButtons: some View {
        switch step {
        case .who:
            primary("Continue") { step = .confirm }
        case .confirm:
            primary("Continue") { confirm() }
        case .name:
            primary("Continue", enabled: !nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                saveName()
            }
        case .reason:
            EmptyView()
        case .preview:
            primary(ReportComposer.canUseMail ? "Open in Mail" : "Share report…") { send() }
        case .result(let result):
            VStack(spacing: 10) {
                switch result {
                case .sent:
                    if blockAfterSendFailed { primary("Try again") { applyReport() } }
                    secondary("Done") { dismiss() }
                case .failed:
                    primary("Try again") { send() }
                    plainBlockButton
                    secondary("Done") { dismiss() }
                case .cancelled, .saved:
                    plainBlockButton
                    secondary("Done") { dismiss() }
                }
            }
        }
    }

    /// "Block [name]" after a report that wasn't sent: plain, reversible.
    /// Hidden when already blocked.
    @ViewBuilder
    private var plainBlockButton: some View {
        if safety == .normal && !plainBlockDone {
            secondary("Block \(name)") { plainBlock() }
        }
    }

    private func primary(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .stillwaterSerif(17, weight: .medium, color: Stillwater.Palette.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Stillwater.Palette.biolume))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .stillwaterSerif(17, weight: .medium, color: Stillwater.Palette.biolume)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Stillwater.Palette.biolume.opacity(0.5), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    /// Confirm: a message report hides that message now (Guideline 1.2:
    /// immediate removal from the feed); nothing else changes yet.
    private func confirm() {
        if let message {
            reportedMessageIDs = ReportedMessages.adding(message.id, to: reportedMessageIDs)
        }
        if nickname == nil {
            nameDraft = ""
            step = .name
        } else {
            step = .reason
        }
    }

    /// The name becomes the contact's local nickname (never sent to them).
    private func saveName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        peer.displayName = trimmed
        try? modelContext.save()
        step = .reason
    }

    private func send() {
        if ReportComposer.canUseMail { showMail = true } else { showShare = true }
    }

    private func finish(_ result: ReportSendResult) {
        RedactLog.event("report: composer finished", "\(result)")
        step = .result(result)
        if result.appliesReport { applyReport() }
    }

    /// Sent: report + block + never pair again, keyed on the identity key.
    private func applyReport() {
        guard let pairing else { blockAfterSendFailed = true; return }
        Task { @MainActor in
            do {
                try await pairing.reportAndBlock(rawKey: rawKey, petname: nickname)
                blockAfterSendFailed = false
                RedactLog.event("report: sent — contact reported and blocked", "")
            } catch {
                blockAfterSendFailed = true
                RedactLog.event("report: sent but block FAILED", "\(type(of: error))")
            }
        }
    }

    private func plainBlock() {
        guard let pairing else { plainBlockFailed = true; return }
        Task { @MainActor in
            do {
                try await pairing.block(rawKey: rawKey, petname: nickname)
                plainBlockDone = true
                plainBlockFailed = false
            } catch {
                plainBlockFailed = true
                RedactLog.event("block: FAILED", "\(type(of: error))")
            }
        }
    }
}
