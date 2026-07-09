//
//  SASVerifySheet.swift
//  Screens
//
//  The 4-word SAS confirm sheet (7d-4). Extracted from PeerSettingsView (STEP 7f)
//  so BOTH the contact-settings screen AND the Stream's verify-gate (shown instead
//  of the composer for an unverified contact) present the SAME sheet directly.
//
//  The words are deterministic from BOTH identity keys, so both phones show the
//  same four; users read them aloud and a match proves no key was swapped during
//  pairing. Tapping "These match" calls `pairing.markVerified`, which persists the
//  verified flag AND opens the live verified gate (EnrollmentService → coordinator
//  addVerifiedContact) — so the caller's composer/presence flip on dismiss with no
//  relaunch. Local-only: nothing here is transmitted.
//

import SwiftUI

struct SASVerifySheet: View {
    let peerName: String
    let rawKey: Data
    let pairing: PairingService?

    @Environment(\.dismiss) private var dismiss

    @State private var words: [String] = []
    @State private var failed = false
    @State private var confirming = false

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text("verify \(peerName.lowercased())")
                    .stillwaterMono(9, trackingEm: 0.3, color: Stillwater.Palette.mistDim)
                    .padding(.top, 22)
                Text("Read these four words aloud together.")
                    .font(Stillwater.Serif.italic(16))
                    .foregroundStyle(Stillwater.Palette.mist)
                    .multilineTextAlignment(.center)
            }

            if failed {
                Text("Couldn't build the words yet — try again after your first message with them.")
                    .font(Stillwater.Serif.italic(15))
                    .foregroundStyle(Stillwater.Palette.mistDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                        Text(word)
                            .stillwaterSerif(26, color: Stillwater.Palette.biolume)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }

            Spacer(minLength: 0)

            if !failed {
                Button { confirm() } label: {
                    Text(confirming ? "…" : "These match")
                        .stillwaterSerif(17, weight: .medium, color: Stillwater.Palette.onAccent)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(RoundedRectangle(cornerRadius: 26).fill(Stillwater.Palette.biolume))
                }
                .buttonStyle(.plain)
                .disabled(words.isEmpty || confirming)
                .opacity(words.isEmpty ? 0.4 : 1.0)
            }

            Button { dismiss() } label: {
                Text("not now")
                    .stillwaterMono(8.5, trackingEm: 0.24, color: Stillwater.Palette.mistDim)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
        .background(Stillwater.Palette.abyss.ignoresSafeArea())
        .task { load() }
    }

    private func load() {
        guard words.isEmpty, !failed else { return }
        if let computed = try? pairing?.sasWords(forPeerRawKey: rawKey), !computed.isEmpty {
            words = computed
        } else {
            failed = true
        }
    }

    private func confirm() {
        guard let pairing else { return }
        confirming = true
        Task {
            do {
                try await pairing.markVerified(rawKey)
            } catch {
                RedactLog.event("SAS: markVerified threw", "\(type(of: error))")
            }
            if pairing.isVerified(rawKey) {
                dismiss()
            } else {
                // Verification did not take (peer not enrolled, or a persist
                // failure — see the enroll log). Keep the sheet open so it isn't
                // silently broken; the button stays tappable.
                print("SAS: verify DID NOT TAKE — still unverified after markVerified")
                confirming = false
            }
        }
    }
}
