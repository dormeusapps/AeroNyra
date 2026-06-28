//
//  ConversationView.swift
//  Screens
//
//  The conversation transcript — the screen you see after opening a chat.
//
//  Three vertical regions, all built around the Calm + Alive + Private
//  posture:
//
//   1. HEADER — back chevron, tappable name (pushes Peer Settings),
//      PresenceChain + label underneath. The name and presence together
//      ARE the relationship; no avatar, no "online" status, no typing
//      indicator. The mesh's state IS the social state.
//
//   2. TRANSCRIPT — messages flow up from the bottom; newest at the
//      bottom. Each row composes MessageRow.
//
//   3. COMPOSER — quiet by default: a placeholder, no shouting. A muted
//      camera affordance leads; the trailing slot shows a mic when the
//      draft is empty (record a voice note) or the send button when there
//      is text. While recording, the whole row becomes a recording bar:
//      cancel · live metered waveform · elapsed · send.
//
//  Text send is wired through `MessageInbox` (optimistic persist → seal →
//  BLE). The camera picks an image, normalizes it to a mesh-sized JPEG, and
//  hands it to `inbox.sendMedia`. The mic records mono AAC via VoiceRecorder
//  and hands the .m4a to the same media path. All three are chunked + sealed
//  per-chunk by the coordinator.
//

import SwiftUI
import PhotosUI
import UIKit

struct ConversationView: View {

    let conversation: Conversation

    @Environment(\.dismiss) private var dismiss

    /// The main-actor persistence/send bridge, injected by ReadyView.
    @Environment(MessageInbox.self) private var inbox

    @State private var draft: String = ""

    /// The photo currently chosen in the system picker. Cleared back to nil
    /// after each send so the same image can be picked again immediately.
    @State private var pickedItem: PhotosPickerItem?

    /// The voice-note recorder driving the composer's recording state.
    @State private var recorder = VoiceRecorder()

    /// Shown when mic access has been denied.
    @State private var showMicDenied = false

    /// Presence with the peer. Stubbed to .outOfRange until the BLE
    /// transport exists and a real ReachabilityMonitor drives it.
    @State private var presence: PresenceChain.Reachability = .outOfRange

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            transcript
            composer
        }
        .background(Color.bgApp.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            backButton
            Spacer()
            peerCenter
            Spacer()
            // Symmetric placeholder for a future trailing action; keeps
            // the peer name visually centered without jumping later.
            Color.clear
                .frame(width: 32, height: 32)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
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

    /// Centered peer block. Tap pushes the Peer Settings screen.
    private var peerCenter: some View {
        NavigationLink {
            PeerSettingsView(conversation: conversation)
        } label: {
            VStack(spacing: 4) {
                Text(peerNameDisplay)
                    .font(Typography.headerName)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                presenceRow
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens peer settings")
    }

    /// The reachability chain + label, under the peer name. This is the
    /// "alive" surface of the header — the line that breathes with the
    /// state of the radio (once BLE lands).
    private var presenceRow: some View {
        HStack(spacing: 6) {
            PresenceChain(reachability: presence)
            Text(presenceLabel)
                .font(Typography.headerPresence)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
    }

    private var peerNameDisplay: String {
        switch conversation.kind {
        case .direct:
            return conversation.peer?.displayLabel
                ?? conversation.title
                ?? ""
        case .meshRoom:
            return conversation.title ?? "Mesh room"
        }
    }

    private var presenceLabel: String {
        switch presence {
        case .direct:     return "In range · direct"
        case .oneHop:     return "Reachable · 1 hop"
        case .twoHops:    return "Reachable · 2 hops"
        case .outOfRange: return "Out of range · searching…"
        }
    }

    // MARK: - Hairline

    private var hairline: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(height: 1)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 9) {
                ForEach(orderedMessages) { message in
                    MessageRow(message: message)
                        .id(message.id)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
    }

    /// Messages in chronological order, oldest first. SwiftData doesn't
    /// guarantee an order on a relationship; sort defensively here so
    /// the row order is stable.
    private var orderedMessages: [Message] {
        conversation.messages.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 0) {
            hairline
            Group {
                if recorder.isRecording {
                    recordingBar
                } else {
                    normalComposer
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .animation(.easeOut(duration: 0.18), value: recorder.isRecording)
        }
        .background(Color.bgApp)
        .alert("Microphone access needed", isPresented: $showMicDenied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable microphone access in Settings to record voice notes.")
        }
    }

    /// Idle composer: camera · text field · (send if text, else mic).
    private var normalComposer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            photoButton

            TextField(text: $draft, axis: .vertical) {
                Text("message…")
                    .foregroundStyle(Color.composerPlaceholder)
            }
            .textFieldStyle(.plain)
            .font(Typography.messageBody)
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1...5)
            .padding(.horizontal, 15)
            .padding(.vertical, 9)

            if hasText {
                sendButton
                    .transition(.scale.combined(with: .opacity))
            } else {
                micButton
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: hasText)
    }

    /// Recording bar: cancel · live metered waveform · elapsed · send.
    /// Tapping send stops AND sends in one tap; cancel discards.
    private var recordingBar: some View {
        HStack(spacing: 12) {
            Button { recorder.cancel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Cancel recording")

            RecordingWaveform(levels: recorder.levels)
                .frame(maxWidth: .infinity)
                .frame(height: 28)

            Text(timeString(recorder.elapsed))
                .font(Typography.deliveryChip)
                .foregroundStyle(Color.textSecondary)
                .monospacedDigit()

            Button { stopAndSend() } label: {
                Circle()
                    .fill(Color.brand)
                    .frame(width: 38, height: 38)
                    .overlay(
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    )
            }
            .accessibilityLabel("Send voice note")
        }
    }

    /// The camera affordance — always present, leading the composer. Muted
    /// per the Calm posture. Opens the system photo picker (library); the
    /// selection is handled in `onChange`.
    private var photoButton: some View {
        PhotosPicker(selection: $pickedItem,
                     matching: .images,
                     photoLibrary: .shared()) {
            Image(systemName: "camera")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Color.textSecondary)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Attach photo")
        .onChange(of: pickedItem) { _, newItem in
            guard let newItem else { return }
            Task { await sendPickedPhoto(newItem) }
        }
    }

    /// Trailing mic when the draft is empty — starts a voice-note recording.
    private var micButton: some View {
        Button {
            Task { await startRecording() }
        } label: {
            Image(systemName: "mic")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Color.textSecondary)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Record voice note")
    }

    private var sendButton: some View {
        Button {
            sendDraft()
        } label: {
            Circle()
                .fill(Color.brand)
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                )
        }
        .accessibilityLabel("Send")
    }

    private var hasText: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Actions

    /// Hand the draft to the MessageInbox: it persists an outbound Message
    /// immediately (optimistic — the row appears at once and is never lost),
    /// then seals it and hands the Envelope to the BLE transport. We clear the
    /// field right away so the composer feels instant; the inbox owns the rest.
    @MainActor
    private func sendDraft() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draft = ""
        // `Task` inherits the main actor here, so passing `conversation`
        // (a non-Sendable @Model) to the @MainActor inbox stays on-actor.
        Task { await inbox.send(trimmed, in: conversation) }
    }

    /// Load the picked image, normalize it to a mesh-sized JPEG, and hand it
    /// to the inbox's optimistic media path. The blob is deliberately small:
    /// a full-resolution photo would chunk into thousands of sealed envelopes
    /// and never finish over BLE. 1280px long-edge @ 0.7 quality lands around
    /// the "~40-chunk photo" the size model already assumes.
    @MainActor
    private func sendPickedPhoto(_ item: PhotosPickerItem) async {
        // Always release the selection so the same image can be re-picked.
        defer { pickedItem = nil }

        guard let raw = try? await item.loadTransferable(type: Data.self),
              let jpeg = Self.meshSizedJPEG(from: raw)
        else { return }

        await inbox.sendMedia(jpeg, mime: .jpeg, in: conversation)
    }

    /// Begin a voice-note recording. Surfaces the permission alert if denied.
    @MainActor
    private func startRecording() async {
        await recorder.start()
        if recorder.permissionDenied {
            showMicDenied = true
        }
    }

    /// Stop the recording and send the .m4a through the optimistic media path.
    @MainActor
    private func stopAndSend() {
        guard let data = recorder.stop() else { return }
        Task { await inbox.sendMedia(data, mime: .m4a, in: conversation) }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Decode arbitrary picked image data (HEIC/PNG/JPEG/…), correct for
    /// orientation, downscale the long edge to `maxDimension`, and re-encode
    /// as JPEG. Returns nil if the data isn't a decodable image.
    private static func meshSizedJPEG(from data: Data,
                                      maxDimension: CGFloat = 1280,
                                      quality: CGFloat = 0.7) -> Data? {
        guard let image = UIImage(data: data) else { return nil }

        let longEdge = max(image.size.width, image.size.height)
        let scale = longEdge > maxDimension ? maxDimension / longEdge : 1
        let target = CGSize(width: image.size.width * scale,
                            height: image.size.height * scale)

        // UIGraphicsImageRenderer.draw bakes in the orientation, so the
        // re-encoded JPEG is upright with no EXIF orientation dependency.
        let renderer = UIGraphicsImageRenderer(size: target)
        let normalized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return normalized.jpegData(compressionQuality: quality)
    }
}

// MARK: - Live recording waveform

/// A right-anchored strip of bars driven by the recorder's rolling level
/// buffer — the "alive" surface of the recording bar. Newest sample on the
/// right, so it reads as a live meter scrolling left as you speak.
private struct RecordingWaveform: View {

    let levels: [CGFloat]

    private static let barWidth: CGFloat = 2.5
    private static let barSpacing: CGFloat = 2
    private static let minBarHeight: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: Self.barSpacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Color.brand)
                        .frame(width: Self.barWidth,
                               height: max(Self.minBarHeight,
                                           level * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }
}
