//
//  OnboardingView.swift
//  Screens
//
//  First-launch entry — the user's first contact with the app's posture, in the
//  Stillwater language. A few calm panels say plainly what AeroNyra is and, just
//  as plainly, what it CAN'T do (no recovery, ephemeral media, no screenshot
//  guarantee), then flow into generating the local identity.
//
//  No signup, no account, no email or phone. The identity is generated LOCALLY on
//  the final tap; it is the only credential and never leaves the device.
//
//  Tap anywhere to move forward — the same quiet, gesture-driven feel throughout.
//

import SwiftUI

struct OnboardingView: View {

    /// Called once a fresh identity has been generated. The parent persists it
    /// via IdentityStore and routes into the main app.
    let onComplete: (IdentityKeypair) -> Void

    @State private var step = 0
    @State private var isGenerating = false
    @State private var breathe = false

    private struct Panel {
        let eyebrow: String
        let title: String
        let body: String
    }

    private let panels: [Panel] = [
        Panel(eyebrow: "AERONYRA",
              title: "A quiet water for the people who matter.",
              body: "No account. No servers. No one in the middle. Nearby, your words travel phone-to-phone over Bluetooth; farther, through a relay — always sealed end-to-end."),
        Panel(eyebrow: "CLOSED BY DESIGN",
              title: "No strangers reach you.",
              body: "You add someone by trading a code in person, or a one-time invite you send yourself. Never a phone number, never a lookup — no one can message you just for having the app."),
        Panel(eyebrow: "THE TRADE",
              title: "Your identity lives only here.",
              body: "No server holds your messages, so nothing syncs and nothing restores: lose this phone and this identity — and its history — are gone, and your contacts simply re-pair. Voice notes fade once heard; photos and videos, after a day. And anyone can still photograph their own screen — no app can stop that."),
    ]

    /// Total steps = the intro panels plus the final "begin" panel.
    private var stepCount: Int { panels.count + 1 }
    private var isBeginStep: Bool { step == panels.count }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Stillwater.Palette.water, Stillwater.Palette.abyss, Stillwater.Palette.abyssDeep],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [Stillwater.Palette.biolume.opacity(0.10), .clear],
                center: .init(x: 0.5, y: 0.28), startRadius: 4, endRadius: 340
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer()

                if isBeginStep {
                    beginPanel
                } else {
                    introPanel(panels[step])
                }

                Spacer()
                Spacer()

                progressDots
                    .padding(.bottom, 18)
                tapHint
                    .padding(.bottom, 56)
            }
            .padding(.horizontal, 34)
            .frame(maxWidth: .infinity)
        }
        .preferredColorScheme(.dark)
        .contentShape(Rectangle())
        .onTapGesture { advance() }
        .onAppear { breathe = true }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - Intro panel

    private func introPanel(_ panel: Panel) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(panel.eyebrow)
                .stillwaterMono(10, trackingEm: 0.38, color: Stillwater.Palette.mistDim)
            Text(panel.title)
                .font(Stillwater.Serif.regular(30))
                .foregroundStyle(Stillwater.Palette.foam)
                .fixedSize(horizontal: false, vertical: true)
            Text(panel.body)
                .font(Stillwater.Serif.italic(17))
                .foregroundStyle(Stillwater.Palette.mist)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(step)   // fresh transition per panel
        .transition(.opacity)
    }

    // MARK: - Begin panel (the heart)

    private var beginPanel: some View {
        VStack(spacing: 30) {
            heart
            VStack(spacing: 10) {
                Text("Ready.")
                    .font(Stillwater.Serif.regular(30))
                    .foregroundStyle(Stillwater.Palette.foam)
                Text("Your identity is born on this tap — a key that never leaves this phone.")
                    .font(Stillwater.Serif.italic(15))
                    .foregroundStyle(Stillwater.Palette.mist)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .id(step)
        .transition(.opacity)
    }

    /// A single expanding/fading biolume ring around a solid dot — the "alive"
    /// signal, breathing at Stillwater's slow rhythm.
    private var heart: some View {
        ZStack {
            Circle()
                .stroke(Stillwater.Palette.biolume.opacity(0.4), lineWidth: 1)
                .frame(width: 64, height: 64)
                .scaleEffect(breathe ? 1.8 : 1.0)
                .opacity(breathe ? 0.0 : 0.6)
                .animation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true), value: breathe)
            Circle()
                .fill(Stillwater.Palette.biolume)
                .frame(width: 13, height: 13)
                .shadow(color: Stillwater.Palette.biolume.opacity(0.5), radius: 10)
        }
        .frame(width: 80, height: 80)
    }

    // MARK: - Progress + hint

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<stepCount, id: \.self) { i in
                Capsule()
                    .fill(i == step ? Stillwater.Palette.biolume : Stillwater.Palette.mist.opacity(0.25))
                    .frame(width: i == step ? 16 : 6, height: 6)
                    .animation(Stillwater.Motion.water(0.4), value: step)
            }
        }
    }

    private var tapHint: some View {
        Text(hintText)
            .stillwaterMono(8.5, trackingEm: 0.28, color: Stillwater.Palette.mistDim)
            .animation(.easeInOut(duration: 0.2), value: isGenerating)
    }

    private var hintText: String {
        if isGenerating { return "waking your identity…" }
        return isBeginStep ? "tap to begin" : "tap to continue"
    }

    // MARK: - Flow

    private func advance() {
        guard !isGenerating else { return }
        if isBeginStep {
            beginGeneration()
        } else {
            withAnimation(Stillwater.Motion.water(0.5)) { step += 1 }
        }
    }

    /// Generate the long-term identity. The brief delay lets the state change
    /// read as "something is happening"; the generation itself is microseconds.
    private func beginGeneration() {
        guard !isGenerating else { return }
        isGenerating = true
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            let identity = IdentityKeypair.generate()
            await MainActor.run { onComplete(identity) }
        }
    }
}

#Preview("Stillwater — Onboarding") {
    OnboardingView { _ in }
}
