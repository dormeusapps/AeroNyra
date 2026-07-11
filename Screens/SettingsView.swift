//
//  SettingsView.swift
//  Screens
//
//  The top-level Settings surface — YOUR profile (name + photo, local only), your
//  identity (fingerprint + "show my code"), and the emergency erase. Reached from
//  the gear on Home. Stillwater-native; reuses SettingsGroup / SettingsRow.
//
//  Your name + photo are @AppStorage (local, never transmitted, no account) — the
//  only sane home for cosmetic profile data in a serverless app. The erase runs
//  the composition root's crypto-erase via the `eraseEverything` environment
//  action (ContentView owns the wipe + the route back to onboarding).
//

import SwiftUI
import PhotosUI
import UIKit

struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(PairingService.self) private var pairing: PairingService?
    @Environment(\.eraseEverything) private var eraseEverything

    @AppStorage("aeronyra.displayName") private var myName = ""
    @AppStorage("aeronyra.selfPhoto") private var selfPhotoData = Data()
    @AppStorage("aeronyra.accentHex") private var accentHex = Int(Stillwater.Accent.defaultHex)

    @FocusState private var nameFocused: Bool
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showMyCode = false
    @State private var confirmErase = false

    private var hairlineColor: Color { Stillwater.Palette.biolume.opacity(0.09) }
    private var selfImage: UIImage? { selfPhotoData.isEmpty ? nil : UIImage(data: selfPhotoData) }
    private var eraseColor: Color { Color(hue: 0.02, saturation: 0.62, brightness: 0.86) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(hairlineColor).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    youSection
                    identitySection
                    appearanceSection
                    dangerSection
                }
                .padding(.top, 24)
                .padding(.bottom, 44)
            }
        }
        .background(Stillwater.Palette.abyss.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task { await applyPickedPhoto(item) }
        }
        .sheet(isPresented: $showMyCode) { PairingView() }
        .alert("Erase everything?", isPresented: $confirmErase) {
            Button("Erase", role: .destructive) { eraseEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This destroys your identity and every message on this device. It cannot be undone, there is no backup, and your contacts will have to re-pair with you.")
        }
    }

    // MARK: - Header
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
            Text("Settings").stillwaterSerif(17, weight: .medium, color: Stillwater.Palette.foam)
            Spacer()
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    // MARK: - You
    private var youSection: some View {
        VStack(spacing: 20) {
            PhotosPicker(selection: $pickedPhoto, matching: .images, photoLibrary: .shared()) {
                ZStack(alignment: .bottomTrailing) {
                    selfAvatar(size: 84)
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
            .accessibilityLabel("Set your photo")

            Text(myName.isEmpty ? "you" : myName)
                .stillwaterSerif(22, color: Stillwater.Palette.foam)
                .lineLimit(1)

            SettingsGroup(footer: "Your name and photo live only on this device and are never sent to anyone — just how the app greets you.") {
                SettingsRow {
                    HStack(spacing: 12) {
                        Text("Your name").font(Stillwater.Serif.regular(17)).foregroundStyle(Stillwater.Palette.foam)
                        Spacer(minLength: 12)
                        TextField(text: $myName) {
                            Text("set a name").foregroundStyle(Stillwater.Palette.mistDim)
                        }
                        .textFieldStyle(.plain)
                        .font(Stillwater.Serif.regular(17))
                        .foregroundStyle(Stillwater.Palette.foam)
                        .tint(Stillwater.Palette.biolume)
                        .multilineTextAlignment(.trailing)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit { nameFocused = false }
                    }
                }

                SettingsRow {
                    PhotosPicker(selection: $pickedPhoto, matching: .images, photoLibrary: .shared()) {
                        HStack(spacing: 12) {
                            Text("Photo").font(Stillwater.Serif.regular(17)).foregroundStyle(Stillwater.Palette.foam)
                            Spacer(minLength: 12)
                            Text(selfImage != nil ? "Custom" : "Default")
                                .font(Stillwater.Serif.regular(17)).foregroundStyle(Stillwater.Palette.mist)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Stillwater.Palette.mistDim)
                        }
                    }
                    .buttonStyle(.plain)
                }

                if selfImage != nil {
                    Button { selfPhotoData = Data() } label: {
                        SettingsRow {
                            Text("Remove photo")
                                .font(Stillwater.Serif.regular(17)).foregroundStyle(Stillwater.Palette.mistDim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func selfAvatar(size: CGFloat) -> some View {
        if let img = selfImage {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(width: size, height: size).clipShape(Circle())
        } else {
            Circle().fill(Stillwater.Palette.biolume.opacity(0.85))
                .frame(width: size, height: size)
                .overlay(selfInitial(size: size))
        }
    }

    @ViewBuilder
    private func selfInitial(size: CGFloat) -> some View {
        if let first = myName.trimmingCharacters(in: .whitespaces).first {
            Text(String(first).uppercased())
                .font(Stillwater.Serif.medium(size * 0.4))
                .foregroundStyle(Stillwater.Palette.onAccent)
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.42, weight: .regular))
                .foregroundStyle(Stillwater.Palette.onAccent.opacity(0.85))
        }
    }

    // MARK: - Identity
    private var identitySection: some View {
        SettingsGroup(
            header: "Your identity",
            footer: "Your public key — the only 'account' you have. Share your code to let someone add you; there is no username and no server."
        ) {
            SettingsRow {
                Text(formattedFingerprint)
                    .font(Stillwater.Mono.regular(12))
                    .foregroundStyle(Stillwater.Palette.mist)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { showMyCode = true } label: {
                SettingsRow {
                    HStack(spacing: 12) {
                        Text("Show my code").font(Stillwater.Serif.regular(17)).foregroundStyle(Stillwater.Palette.foam)
                        Spacer(minLength: 12)
                        Image(systemName: "qrcode")
                            .font(.system(size: 15, weight: .regular)).foregroundStyle(Stillwater.Palette.biolume)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Stillwater.Palette.mistDim)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var formattedFingerprint: String {
        guard let hex = pairing?.myFingerprint, !hex.isEmpty else { return "—" }
        let pairs = stride(from: 0, to: hex.count, by: 2).map { i -> String in
            let s = hex.index(hex.startIndex, offsetBy: i)
            let e = hex.index(s, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            return String(hex[s..<e])
        }
        var rows: [String] = []
        for rowStart in stride(from: 0, to: pairs.count, by: 8) {
            let end = min(rowStart + 8, pairs.count)
            let row = Array(pairs[rowStart..<end])
            let left  = row.prefix(4).joined(separator: " ")
            let right = row.dropFirst(4).joined(separator: " ")
            rows.append("\(left)   \(right)")
        }
        return rows.joined(separator: "\n")
    }

    // MARK: - Appearance (accent)
    private var appearanceSection: some View {
        SettingsGroup(
            header: "Appearance",
            footer: "The single light the whole app breathes with. Brightness still shows who's near — only the hue changes."
        ) {
            SettingsRow {
                // 8 swatches: tightened from 34/14 so the row fits the 375pt
                // phone floor without wrapping (8×30 + 7×8 = 296 ≤ 311 avail).
                HStack(spacing: 8) {
                    ForEach(Stillwater.Accent.presets, id: \.hex) { preset in
                        Button { accentHex = Int(preset.hex) } label: {
                            Circle()
                                .fill(Stillwater.Palette.hex(preset.hex))
                                .frame(width: 30, height: 30)
                                .overlay(
                                    Circle().strokeBorder(
                                        Stillwater.Palette.foam.opacity(accentHex == Int(preset.hex) ? 0.9 : 0),
                                        lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Danger
    private var dangerSection: some View {
        SettingsGroup(
            header: "Danger",
            footer: "There is no recovery. If you erase or lose this device, this identity is gone forever and your contacts must re-pair."
        ) {
            Button { confirmErase = true } label: {
                SettingsRow {
                    Text("Erase everything")
                        .font(Stillwater.Serif.regular(17))
                        .foregroundStyle(eraseColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Photo persistence
    @MainActor
    private func applyPickedPhoto(_ item: PhotosPickerItem) async {
        defer { pickedPhoto = nil }
        guard let raw = try? await item.loadTransferable(type: Data.self),
              let jpeg = Self.avatarSizedJPEG(from: raw) else { return }
        selfPhotoData = jpeg
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

// MARK: - Erase action (composition-root wipe, injected by ContentView)

private struct EraseEverythingKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Runs the composition root's crypto-erase and routes back to onboarding.
    /// Default is a no-op (previews); ContentView injects the real action.
    var eraseEverything: () -> Void {
        get { self[EraseEverythingKey.self] }
        set { self[EraseEverythingKey.self] = newValue }
    }
}

#Preview("Stillwater — Settings") {
    SettingsView()
}
