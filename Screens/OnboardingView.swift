//
//  OnboardingView.swift
//  Screens
//
//  First-launch entry — the user's first contact with the app's posture.
//
//  Per the Calm + Private + Alive direction, there is no signup, no
//  account creation, no email or phone, no avatar to upload, no contact
//  permission to grant. The app generates a cryptographic identity
//  LOCALLY when the user taps; that identity is the only credential and
//  never leaves the device.
//
//  The pulsing heart at center is the same "you" signal from the radar
//  in Nearby. It tells the user something is alive here before any data
//  has flowed — the radio's heartbeat made visible.
//

import SwiftUI

struct OnboardingView: View {

    /// Called once a fresh identity has been generated. The parent is
    /// responsible for persisting it via IdentityStore and routing the
    /// user into the main app.
    let onComplete: (IdentityKeypair) -> Void

    @State private var isGenerating = false
    @State private var breathe = false

    var body: some View {
        ZStack {
            Color.bgApp.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()
                appNameBlock
                Spacer()
                heart
                Spacer()
                Spacer()
                footer
                    .padding(.bottom, 64)
            }
            .frame(maxWidth: .infinity)
        }
        .preferredColorScheme(.dark)
        .contentShape(Rectangle())
        .onTapGesture { beginGeneration() }
        .onAppear { breathe = true }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - App name

    private var appNameBlock: some View {
        VStack(spacing: 14) {
            Text("AeroNyra")
                .font(.custom("Geist-Bold", size: 44))
                .foregroundStyle(Color.textPrimary)
            Text("encrypted · no account · no servers")
                .font(Typography.deliveryChip)
                .foregroundStyle(Color.textTertiary)
                .tracking(0.8)
        }
    }

    // MARK: - Heart

    /// A single expanding/fading ring around a solid dot, breathing at
    /// the same 2.4s rhythm as the radar's "you" signal. Same rhythm
    /// everywhere = one heartbeat across the app.
    private var heart: some View {
        ZStack {
            Circle()
                .stroke(Color.statusHealthy.opacity(0.4), lineWidth: 1)
                .frame(width: 60, height: 60)
                .scaleEffect(breathe ? 1.8 : 1.0)
                .opacity(breathe ? 0.0 : 0.6)
                .animation(
                    .easeInOut(duration: 2.4).repeatForever(autoreverses: true),
                    value: breathe
                )
            Circle()
                .fill(Color.statusHealthy)
                .frame(width: 12, height: 12)
        }
        .frame(width: 80, height: 80)
    }

    // MARK: - Footer

    private var footer: some View {
        Text(isGenerating ? "generating identity…" : "tap anywhere to begin")
            .font(Typography.deliveryChip)
            .foregroundStyle(Color.textSecondary)
            .animation(.easeInOut(duration: 0.2), value: isGenerating)
    }

    // MARK: - Generation

    /// Generate the long-term identity. The brief delay lets the user
    /// see the state change rather than getting a single-frame flash —
    /// honest acknowledgment that *something is happening here*. The
    /// generation itself (CryptoKit Curve25519 keys) is microseconds;
    /// the wait is purely for UX rhythm.
    private func beginGeneration() {
        guard !isGenerating else { return }
        isGenerating = true

        Task {
            try? await Task.sleep(for: .milliseconds(700))
            let identity = IdentityKeypair.generate()
            await MainActor.run {
                onComplete(identity)
            }
        }
    }
}
