//
//  EULAView.swift
//  Screens
//
//  The Terms of Use surface (App Review Guideline 1.2). Two modes:
//   • Gate (onAccept != nil) — first launch on this device. Scrollable terms
//     with a pinned, explicit Accept action; there is no other way forward.
//     ContentView holds the computed BootRoute until the action fires.
//   • Read-only (onAccept == nil) — re-viewable from Settings ("Terms of
//     Use"), presented as a sheet with a dismiss header and no Accept bar.
//
//  Acceptance is a UserDefaults record (version + date). It deliberately
//  SURVIVES crypto-erase — accepting the terms is a legal fact about the
//  person, not identifying residue — so the key is NOT in DeviceResidueWipe.
//  Deleting the app clears UserDefaults, so a true reinstall re-prompts.
//

import SwiftUI

/// Acceptance record for the current Terms of Use. Bump `currentVersion`
/// when the terms materially change to re-prompt existing users.
enum EULA {

    static let currentVersion = 1

    /// UserDefaults key. Named here and nowhere else. Deliberately absent
    /// from DeviceResidueWipe's allowlist (see file header).
    static let defaultsKey = "aeronyra.eulaAccepted.v1"

    static var isAccepted: Bool {
        let record = UserDefaults.standard.dictionary(forKey: defaultsKey)
        return (record?["version"] as? Int ?? 0) >= currentVersion
    }

    static func recordAcceptance() {
        UserDefaults.standard.set(
            ["version": currentVersion, "acceptedAt": Date()],
            forKey: defaultsKey
        )
    }

    // MARK: - The terms (verbatim)

    struct Section {
        let heading: String
        let body: String
    }

    static let title = "AeroNyra Terms of Use"
    static let preamble = "By using AeroNyra, you agree to these terms."
    static let signature = "DORMEUSAPPS LLC"

    static let sections: [Section] = [
        Section(
            heading: "Zero tolerance for objectionable content and abusive behavior.",
            body: "You may not use AeroNyra to send content that is illegal, threatening, harassing, hateful, sexually explicit involving minors, or that promotes violence or abuse. You may not use it to harass, threaten, or abuse any person. There is no tolerance for objectionable content or abusive users."
        ),
        Section(
            heading: "How AeroNyra works.",
            body: "AeroNyra is end-to-end encrypted and has no servers. Messages are exchanged directly between devices. The developer cannot read your messages, cannot see who you communicate with, and does not collect your data. There are no accounts."
        ),
        Section(
            heading: "You control who can reach you.",
            body: "No one can contact you unless you personally pair with them by scanning their code or accepting a one-time invite and confirming a matching four-word phrase. There is no directory, search, or discovery. Strangers cannot reach you."
        ),
        Section(
            heading: "Blocking and reporting.",
            body: "You can block any contact at any time. Blocking immediately removes their conversation from your chat list and permanently prevents further contact. Your message history with them is preserved and remains readable in Settings, so you keep any record you may need. You can report a contact or a message to the developer at support@dormeusapps.com. Reports are reviewed and responded to within 24 hours. Because AeroNyra is encrypted and serverless, the developer cannot see message content or identify users — you may include any information you choose in your report. Where a report indicates illegal activity, you should contact law enforcement, and the developer will assist to the extent technically possible."
        ),
        Section(
            heading: "Content filtering.",
            body: "AeroNyra can hide messages containing offensive language on your device. You can adjust this in Settings."
        ),
        Section(
            heading: "Your responsibility.",
            body: "You are responsible for the content you send and for the people you choose to pair with. Violation of these terms may result in loss of access to the app."
        ),
        Section(
            heading: "No warranty.",
            body: "AeroNyra is provided as is, without warranty of any kind. The developer is not liable for any damages arising from its use."
        ),
    ]
}

struct EULAView: View {

    /// Gate mode when non-nil: the explicit Accept action is the only way
    /// forward. Read-only (Settings sheet) when nil.
    let onAccept: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    init(onAccept: (() -> Void)? = nil) {
        self.onAccept = onAccept
    }

    private var hairlineColor: Color { Stillwater.Palette.biolume.opacity(0.09) }

    var body: some View {
        VStack(spacing: 0) {
            if onAccept == nil {
                header
                Rectangle().fill(hairlineColor).frame(height: 1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    titleBlock
                    termsGroup
                    Text(EULA.signature)
                        .stillwaterMono(9, trackingEm: 0.3, color: Stillwater.Palette.mistDim)
                        .padding(.horizontal, 20)
                }
                .padding(.top, 24)
                .padding(.bottom, 32)
            }

            if let onAccept {
                acceptBar(onAccept)
            }
        }
        .background(Stillwater.Palette.abyss.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: - Header (read-only mode)

    private var header: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Text("‹")
                    .stillwaterSerif(20, color: Stillwater.Palette.biolume)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Terms of Use").stillwaterSerif(17, weight: .medium, color: Stillwater.Palette.foam)
            Spacer()
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    // MARK: - Content

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(EULA.title)
                .stillwaterSerif(26, color: Stillwater.Palette.foam)
                .fixedSize(horizontal: false, vertical: true)
            Text(EULA.preamble)
                .font(Stillwater.Serif.italic(15))
                .foregroundStyle(Stillwater.Palette.mist)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
    }

    private var termsGroup: some View {
        SettingsGroup {
            ForEach(EULA.sections.indices, id: \.self) { i in
                SettingsRow {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(EULA.sections[i].heading)
                            .font(Stillwater.Serif.medium(16))
                            .foregroundStyle(Stillwater.Palette.foam)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(EULA.sections[i].body)
                            .font(Stillwater.Serif.regular(14.5))
                            .foregroundStyle(Stillwater.Palette.mist)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Accept (gate mode)

    private func acceptBar(_ onAccept: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(hairlineColor).frame(height: 1)
            Button(action: onAccept) {
                Text("Accept & Continue")
                    .stillwaterSerif(17, weight: .medium, color: Stillwater.Palette.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Stillwater.Palette.biolume))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .background(Stillwater.Palette.abyss)
    }
}

#Preview("Stillwater — EULA gate") {
    EULAView(onAccept: {})
}

#Preview("Stillwater — EULA read-only") {
    EULAView()
}
