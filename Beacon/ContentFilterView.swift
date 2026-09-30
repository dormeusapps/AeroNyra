//
//  ContentFilterView.swift
//  Beacon
//
//  Settings › Safety & Support › Content filter (App Review Guideline 1.2).
//  The ON/OFF switch (default ON; one switch for both directions), the
//  user's own words on top of the bundled library, and the library's
//  attribution. The first open on this install shows a short explanation
//  (`ContentFilterIntro`); Erase resets it (DeviceResidueWipe).
//
//  Lives in Beacon/ (a synchronized folder), not Screens/ (a classic group:
//  a new file there is not compiled without a pbxproj edit).
//

import SwiftUI

/// "Show the explanation once per install."
enum ContentFilterIntro {

    /// Mirrored in DeviceResidueWipe, so Erase shows it again.
    static let shownKey = "aeronyra.contentFilter.introShown.v1"

    static let title = "Filtered words are on"
    static let message = "Messages with filtered words never reach you. They aren't shown, stored or notified. Messages you write with them aren't sent. You can turn this off or add your own words here."

    /// True the first time only; marks it shown.
    static func takeFirstShow(_ defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: shownKey) else { return false }
        defaults.set(true, forKey: shownKey)
        return true
    }
}

struct ContentFilterView: View {

    @Environment(\.dismiss) private var dismiss

    @AppStorage(ContentFilter.enabledKey) private var enabled = true
    @AppStorage(ContentFilter.wordsKey) private var userWords = ""
    @FocusState private var wordsFocused: Bool
    @State private var showIntro = false

    private var hairlineColor: Color { Stillwater.Palette.biolume.opacity(0.09) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(hairlineColor).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    SettingsGroup(
                        footer: "Checked on this phone only; nothing is sent anywhere. A message you receive with a filtered word never reaches you: it isn't shown, stored or notified, and turning the filter off won't bring it back. A message you write with one isn't sent. Text only — not photos, videos or voice notes."
                    ) {
                        SettingsRow {
                            Toggle(isOn: $enabled) {
                                Text("Filter offensive words")
                                    .font(Stillwater.Serif.regular(17))
                                    .foregroundStyle(Stillwater.Palette.foam)
                            }
                            .tint(Stillwater.Palette.biolume)
                        }
                    }
                    if enabled {
                        SettingsGroup(
                            header: "Your words",
                            footer: "Added on top of the built-in list, which can't be edited. Separate words with commas."
                        ) {
                            SettingsRow {
                                TextField(text: $userWords, axis: .vertical) {
                                    Text("your own words, comma-separated")
                                        .foregroundStyle(Stillwater.Palette.mistDim)
                                }
                                .textFieldStyle(.plain)
                                .font(Stillwater.Serif.regular(17))
                                .foregroundStyle(Stillwater.Palette.foam)
                                .tint(Stillwater.Palette.biolume)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .focused($wordsFocused)
                                .submitLabel(.done)
                                .onSubmit { wordsFocused = false }
                            }
                        }
                    }
                    Text("The built-in list includes “List of Dirty, Naughty, Obscene, and Otherwise Bad Words” (LDNOOBW), CC BY 4.0, with some words removed, plus AeroNyra's own additions.")
                        .font(Stillwater.Serif.italic(13))
                        .foregroundStyle(Stillwater.Palette.mistDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                }
                .padding(.top, 24)
                .padding(.bottom, 44)
            }
        }
        .background(Stillwater.Palette.abyss.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            if ContentFilterIntro.takeFirstShow() { showIntro = true }
        }
        .alert(ContentFilterIntro.title, isPresented: $showIntro) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(ContentFilterIntro.message)
        }
    }

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
            Text("Content filter").stillwaterSerif(17, weight: .medium, color: Stillwater.Palette.foam)
            Spacer()
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }
}

#Preview("Stillwater — Content filter") {
    ContentFilterView()
}
