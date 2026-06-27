//
//  PeerSettingsView.swift
//  Screens
//
//  Per-peer / per-conversation settings, reached by tapping the peer's
//  name in the Conversation header. Holds the user's local relationship
//  to this peer:
//
//   • Petname — what to call them (local-only; never transmitted)
//   • Fingerprint — full public-key identity, grouped for legibility;
//     the visible proof of who this peer really is, and what a future
//     QR safety-number verification flow will check against
//   • Read receipts — per-conversation toggle, OFF by default per the
//     Private posture (turning it on sends a small encrypted ack on
//     the radio every time a message is opened)
//
//  Future sections (each gets a slot as it lands):
//   • Safety-number / QR verification
//   • Block / forget peer
//

import SwiftUI
import SwiftData

struct PeerSettingsView: View {

    /// Bindable so the read-receipts toggle writes straight through to the
    /// persisted `readReceiptsEnabled` field; SwiftData autosaves the change.
    @Bindable var conversation: Conversation

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var petnameDraft: String = ""

    @FocusState private var petnameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    avatarBlock
                    fingerprintSection
                    petnameSection
                    readReceiptsSection
                }
                .padding(.bottom, 40)
            }
        }
        .background(Color.bgApp.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: loadFromConversation)
        .onChange(of: petnameDraft) { _, newValue in
            applyPetname(newValue)
        }
        .onDisappear { try? modelContext.save() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            backButton
            Spacer()
            Text("Peer")
                .font(Typography.headerName)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            // Symmetric placeholder; keeps the title visually centered
            // when a real trailing action lands here later.
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var backButton: some View {
        Button(action: { dismiss() }) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.brand)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Back")
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(height: 1)
    }

    // MARK: - Avatar block

    private var avatarBlock: some View {
        VStack(spacing: 14) {
            Circle()
                .fill(LinearGradient.avatarBrand)
                .hueRotation(.degrees(hueDegrees))
                .frame(width: 76, height: 76)
            Text(displayName)
                .font(.custom("Geist-Bold", size: 22))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
        .padding(.bottom, 28)
    }

    private var hueDegrees: Double {
        guard let peer = conversation.peer else { return 0 }
        return peer.avatarHue * 360
    }

    private var displayName: String {
        conversation.peer?.displayLabel ?? conversation.title ?? ""
    }

    // MARK: - Fingerprint section

    /// Full 64-hex-char public key, grouped 4 × 8 bytes for legibility.
    /// Display-only for now; future QR verification scans against this.
    private var fingerprintSection: some View {
        section(title: "Fingerprint") {
            Text(formattedFingerprint)
                .font(Typography.mono(.regular, size: 13))
                .foregroundStyle(Color.textSecondary)
                .textSelection(.enabled)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.bgSurface)
                )
        }
    }

    /// 4 rows × 8 byte-pairs, with a wider gap mid-row to break the line
    /// visually. Mono font renders it as a grid.
    private var formattedFingerprint: String {
        guard let peer = conversation.peer else { return "" }
        let hex = peer.publicKeyData.map { String(format: "%02x", $0) }
        var rows: [String] = []
        for rowStart in stride(from: 0, to: hex.count, by: 8) {
            let end = min(rowStart + 8, hex.count)
            let row = Array(hex[rowStart..<end])
            let left  = row.prefix(4).joined(separator: " ")
            let right = row.dropFirst(4).joined(separator: " ")
            rows.append("\(left)   \(right)")
        }
        return rows.joined(separator: "\n")
    }

    // MARK: - Petname section

    private var petnameSection: some View {
        section(title: "Petname") {
            TextField(text: $petnameDraft) {
                Text("set a local name…")
                    .foregroundStyle(Color.composerPlaceholder)
            }
            .textFieldStyle(.plain)
            .font(Typography.messageBody)
            .foregroundStyle(Color.textPrimary)
            .focused($petnameFocused)
            .submitLabel(.done)
            .onSubmit { petnameFocused = false }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.bgSurface)
            )

            caption("only visible to you — never sent to this peer.")
        }
    }

    // MARK: - Read receipts section

    private var readReceiptsSection: some View {
        section(title: "Read receipts") {
            HStack {
                Text("Show when you've read")
                    .font(Typography.messageBody)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Toggle("", isOn: $conversation.readReceiptsEnabled)
                    .tint(Color.brand)
                    .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.bgSurface)
            )

            caption("when on, a small encrypted ack is sent on the radio each time you open a message.")
        }
    }

    // MARK: - Section helpers

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .beaconEyebrow()
                .foregroundStyle(Color.textTertiary)
                .padding(.horizontal, 4)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 28)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Typography.headerPresence)
            .foregroundStyle(Color.textTertiary)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 4)
            .padding(.top, 4)
    }

    // MARK: - Persistence

    private func loadFromConversation() {
        petnameDraft = conversation.peer?.displayName ?? ""
        // Read-receipts state needs no loading — the toggle binds directly
        // to the persisted `conversation.readReceiptsEnabled`.
    }

    /// Apply the petname draft to the underlying Peer. SwiftData's
    /// autosave behavior carries it; we explicitly flush on disappear
    /// to be safe.
    private func applyPetname(_ raw: String) {
        guard let peer = conversation.peer else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        peer.displayName = trimmed.isEmpty ? nil : trimmed
    }
}
