//
//  PeerSettingsView.swift
//  Screens
//
//  Per-contact settings — reached by tapping the contact's name in the Stream
//  header. Holds the user's LOCAL relationship to this peer; nothing here is ever
//  transmitted. Re-skinned to the Stillwater design language.
//
//  SECTIONS:
//   • PROFILE — the avatar (tap to set a photo), nickname, photo, accent color,
//     reset. All local; wiped with the store on crypto-erase.
//   • IDENTITY — the full public-key fingerprint (the proof of who this peer is).
//
//  LOCAL-ONLY INVARIANT: petname, photo, and accent are things the USER assigns on
//  THIS device to a key already verified in pairing. A contact's own self-chosen
//  name/photo never flows over the wire — that would let an impostor spoof an
//  identity. The identity is the key; the presentation is yours.
//
//  PRESENCE vs IDENTITY colour: presence on Home is the single biolume accent
//  (brightness = reachability). The per-contact hue chosen here is IDENTITY colour,
//  used only for this contact's avatar/settings — the two never collide.
//

import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct PeerSettingsView: View {

    @Bindable var conversation: Conversation

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(PairingService.self) private var pairing: PairingService?

    @State private var petnameDraft: String = ""
    @FocusState private var petnameFocused: Bool
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showColorPicker = false
    @State private var showVerify = false

    private var hairlineColor: Color { Stillwater.Palette.biolume.opacity(0.09) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(hairlineColor).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    profileSection
                    verificationSection
                    identitySection
                }
                .padding(.top, 24)
                .padding(.bottom, 44)
            }
        }
        .background(Stillwater.Palette.abyss.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear(perform: loadFromConversation)
        .onChange(of: petnameDraft) { _, newValue in applyPetname(newValue) }
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task { await applyPickedPhoto(item) }
        }
        .onDisappear { try? modelContext.save() }
        .sheet(isPresented: $showColorPicker) {
            AccentPickerSheet(
                current: conversation.peer?.customHue,
                onPick: { hue in applyAccent(hue) },
                onReset: { applyAccent(nil) }
            )
            .presentationDetents([.height(340)])
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showVerify) {
            if let peer = conversation.peer {
                SASVerifySheet(
                    peerName: displayName,
                    rawKey: peer.publicKeyData,
                    pairing: pairing
                )
                .presentationDetents([.medium])
                .preferredColorScheme(.dark)
            }
        }
    }

    // MARK: - Header
    private var header: some View {
        HStack(spacing: 8) {
            Button(action: { dismiss() }) {
                Text("‹")
                    .stillwaterSerif(20, color: Stillwater.Palette.biolume)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Contact").stillwaterSerif(17, weight: .medium, color: Stillwater.Palette.foam)
            Spacer()
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    // MARK: - Profile
    private var profileSection: some View {
        VStack(spacing: 20) {
            avatarHeadline

            SettingsGroup(footer: "Only visible to you — a nickname, photo, and colour are yours alone and are never sent to this contact.") {
                SettingsRow {
                    HStack(spacing: 12) {
                        Text("Nickname").font(Stillwater.Serif.regular(17)).foregroundStyle(Stillwater.Palette.foam)
                        Spacer(minLength: 12)
                        TextField(text: $petnameDraft) {
                            Text(defaultNamePlaceholder).foregroundStyle(Stillwater.Palette.mistDim)
                        }
                        .textFieldStyle(.plain)
                        .font(Stillwater.Serif.regular(17))
                        .foregroundStyle(Stillwater.Palette.foam)
                        .tint(Stillwater.Palette.biolume)
                        .multilineTextAlignment(.trailing)
                        .focused($petnameFocused)
                        .submitLabel(.done)
                        .onSubmit { petnameFocused = false }
                    }
                }

                SettingsRow {
                    PhotosPicker(selection: $pickedPhoto, matching: .images, photoLibrary: .shared()) {
                        HStack(spacing: 12) {
                            Text("Photo").font(Stillwater.Serif.regular(17)).foregroundStyle(Stillwater.Palette.foam)
                            Spacer(minLength: 12)
                            Text(hasCustomPhoto ? "Custom" : "Default")
                                .font(Stillwater.Serif.regular(17)).foregroundStyle(Stillwater.Palette.mist)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Stillwater.Palette.mistDim)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Button { showColorPicker = true } label: {
                    SettingsRow {
                        HStack(spacing: 12) {
                            Text("Accent colour").font(Stillwater.Serif.regular(17)).foregroundStyle(Stillwater.Palette.foam)
                            Spacer(minLength: 12)
                            Circle().fill(contactColor).frame(width: 22, height: 22)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Stillwater.Palette.mistDim)
                        }
                    }
                }
                .buttonStyle(.plain)

                if isCustomized {
                    Button { resetCustomization() } label: {
                        SettingsRow {
                            Text("Reset to default")
                                .font(Stillwater.Serif.regular(17)).foregroundStyle(Stillwater.Palette.mistDim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var avatarHeadline: some View {
        VStack(spacing: 14) {
            PhotosPicker(selection: $pickedPhoto, matching: .images, photoLibrary: .shared()) {
                ZStack(alignment: .bottomTrailing) {
                    avatarDisc(size: 84)
                    Circle()
                        .fill(Stillwater.Palette.shallow)
                        .frame(width: 26, height: 26)
                        .overlay(
                            Image(systemName: "camera.fill")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(Stillwater.Palette.mist)
                        )
                        .overlay(Circle().strokeBorder(hairlineColor, lineWidth: 1))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Set contact photo")

            Text(displayName).stillwaterSerif(22, color: Stillwater.Palette.foam).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Avatar (inline, Stillwater)
    @ViewBuilder
    private func avatarDisc(size: CGFloat) -> some View {
        if let data = conversation.peer?.customAvatarData, let ui = UIImage(data: data) {
            Image(uiImage: ui).resizable().scaledToFill()
                .frame(width: size, height: size).clipShape(Circle())
        } else {
            Circle().fill(contactColor).frame(width: size, height: size)
                .overlay(avatarInitial(size: size))
        }
    }

    @ViewBuilder
    private func avatarInitial(size: CGFloat) -> some View {
        if let name = conversation.peer?.displayName?.trimmingCharacters(in: .whitespaces),
           !name.isEmpty, let first = name.first {
            Text(String(first).uppercased())
                .font(Stillwater.Serif.medium(size * 0.4))
                .foregroundStyle(Stillwater.Palette.onAccent)
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.42, weight: .regular))
                .foregroundStyle(Stillwater.Palette.onAccent.opacity(0.85))
        }
    }

    /// The contact's identity colour — chosen `customHue` or the key-derived hue.
    private var contactColor: Color {
        Color(hue: conversation.peer?.resolvedHue ?? 0.45, saturation: 0.45, brightness: 0.88)
    }

    // MARK: - Verification (SAS)
    private var verificationSection: some View {
        let verified = pairing?.isVerified(conversation.peer?.publicKeyData ?? Data()) ?? false
        return SettingsGroup(
            header: "Verification",
            footer: verified
                ? "You've confirmed the four words with this contact — their key is who you think it is. Tap to read the words again if they still need to verify you."
                : "Read four words aloud together. If they match, no one swapped keys during pairing."
        ) {
            if verified {
                Button { showVerify = true } label: {
                    SettingsRow {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(Stillwater.Palette.biolume)
                            Text("Verified")
                                .font(Stillwater.Serif.regular(17)).foregroundStyle(Stillwater.Palette.foam)
                            Spacer(minLength: 12)
                            Text("view words")
                                .stillwaterMono(8, trackingEm: 0.18, color: Stillwater.Palette.mistDim)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Stillwater.Palette.mistDim)
                        }
                    }
                }
                .buttonStyle(.plain)
            } else {
                Button { showVerify = true } label: {
                    SettingsRow {
                        HStack(spacing: 12) {
                            Text("Verify with four words")
                                .font(Stillwater.Serif.regular(17)).foregroundStyle(Stillwater.Palette.foam)
                            Spacer(minLength: 12)
                            Text("not verified")
                                .stillwaterMono(8, trackingEm: 0.18, color: Stillwater.Palette.mistDim)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Stillwater.Palette.mistDim)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Identity
    private var identitySection: some View {
        SettingsGroup(
            header: "Identity",
            footer: "This contact's full public key — the proof of who they are. A future QR check verifies against this."
        ) {
            SettingsRow {
                Text(formattedFingerprint)
                    .font(Stillwater.Mono.regular(12))
                    .foregroundStyle(Stillwater.Palette.mist)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

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

    // MARK: - Derived
    private var displayName: String {
        if let n = conversation.peer?.displayName?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
        return shortFingerprint
    }
    private var shortFingerprint: String {
        guard let hex = conversation.peer?.userIDHex else { return conversation.title ?? "contact" }
        return String(hex.prefix(6)).uppercased()
    }
    private var defaultNamePlaceholder: String { shortFingerprint }
    private var hasCustomPhoto: Bool { conversation.peer?.customAvatarData != nil }
    private var isCustomized: Bool {
        guard let peer = conversation.peer else { return false }
        return peer.customAvatarData != nil || peer.customHue != nil
    }

    // MARK: - Persistence
    private func loadFromConversation() {
        petnameDraft = conversation.peer?.displayName ?? ""
    }

    private func applyPetname(_ raw: String) {
        guard let peer = conversation.peer else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        peer.displayName = trimmed.isEmpty ? nil : trimmed
    }

    @MainActor
    private func applyPickedPhoto(_ item: PhotosPickerItem) async {
        defer { pickedPhoto = nil }
        guard let peer = conversation.peer,
              let raw = try? await item.loadTransferable(type: Data.self),
              let jpeg = Self.avatarSizedJPEG(from: raw) else { return }
        peer.customAvatarData = jpeg
        try? modelContext.save()
    }

    private func applyAccent(_ hue: Double?) {
        conversation.peer?.customHue = hue
        try? modelContext.save()
    }

    private func resetCustomization() {
        guard let peer = conversation.peer else { return }
        peer.customAvatarData = nil
        peer.customHue = nil
        try? modelContext.save()
    }

    private static func avatarSizedJPEG(from data: Data,
                                        edge: CGFloat = 256,
                                        quality: CGFloat = 0.8) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let target = CGSize(width: edge, height: edge)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let side = min(image.size.width, image.size.height)
        let cropOrigin = CGPoint(x: (image.size.width - side) / 2,
                                 y: (image.size.height - side) / 2)
        let normalized = renderer.image { _ in
            let scale = edge / side
            let drawSize = CGSize(width: image.size.width * scale,
                                  height: image.size.height * scale)
            let drawOrigin = CGPoint(x: -cropOrigin.x * scale,
                                     y: -cropOrigin.y * scale)
            image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
        }
        return normalized.jpegData(compressionQuality: quality)
    }
}

// MARK: - Accent picker sheet

private struct AccentPickerSheet: View {
    let current: Double?
    let onPick: (Double) -> Void
    let onReset: () -> Void

    @Environment(\.dismiss) private var dismiss

    private let hues: [Double] = stride(from: 0.0, to: 1.0, by: 1.0 / 12.0).map { $0 }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("accent colour")
                .stillwaterMono(9, trackingEm: 0.3, color: Stillwater.Palette.mistDim)
                .padding(.top, 20)

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(hues, id: \.self) { hue in
                    Button { onPick(hue); dismiss() } label: {
                        Circle()
                            .fill(Color(hue: hue, saturation: 0.45, brightness: 0.88))
                            .frame(width: 40, height: 40)
                            .overlay(
                                Circle().strokeBorder(
                                    Stillwater.Palette.foam.opacity(isSelected(hue) ? 0.9 : 0),
                                    lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Button { onReset(); dismiss() } label: {
                Text("use default colour")
                    .font(Stillwater.Serif.regular(16))
                    .foregroundStyle(Stillwater.Palette.biolume)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Stillwater.Palette.shallow))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Stillwater.Palette.abyss.ignoresSafeArea())
    }

    private func isSelected(_ hue: Double) -> Bool {
        guard let current else { return false }
        return abs(current - hue) < 0.0001
    }
}

// MARK: - Grouped-inset settings primitives (Stillwater tokens)
struct SettingsGroup<Content: View>: View {
    var header: String?
    var footer: String?
    @ViewBuilder let content: Content

    init(header: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header)
                    .stillwaterMono(9, trackingEm: 0.3, color: Stillwater.Palette.mistDim)
                    .padding(.horizontal, 20)
            }

            VStack(spacing: 0) {
                _VariadicView.Tree(DividedRows()) { content }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Stillwater.Palette.shallow))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Stillwater.Palette.biolume.opacity(0.09), lineWidth: 1))
            .padding(.horizontal, 16)

            if let footer {
                Text(footer)
                    .font(Stillwater.Serif.italic(12.5))
                    .foregroundStyle(Stillwater.Palette.mistDim)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 2)
            }
        }
    }
}

private struct DividedRows: _VariadicView.MultiViewRoot {
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last {
                Rectangle()
                    .fill(Stillwater.Palette.biolume.opacity(0.09))
                    .frame(height: 1)
                    .padding(.leading, 16)
            }
        }
    }
}

struct SettingsRow<Content: View>: View {
    @ViewBuilder let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
    }
}
