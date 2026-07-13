//
//  ConversationView.swift
//  Screens
//
//  STILLWATER · Screen 02 — "The Stream" (Conversation). WIRED to real data.
//
//  Media is REAL now: inbound/outbound photos render inline (tap to expand) and
//  voice notes play through the existing VoicePlayer with a real waveform
//  (WaveformExtractor). Voice notes are EPHEMERAL — an inbound note self-destructs
//  2 minutes after the recipient finishes listening (mediaData wiped, row becomes
//  a "voice note · gone" tombstone; playability gated on `Message.listenedAt`).
//
//  "No bubbles — words sit on the dark. Read is a ripple. An undelivered message
//   waits on the water. A voice note is heard once, then the water takes it back."
//

import SwiftUI
import SwiftData
import UIKit
import PhotosUI
import AVFoundation   // Item 2: full-screen story viewer (AVPlayer / AVPlayerLayer)

struct StreamView: View {

    let peer: Peer

    @Environment(MessageInbox.self) private var inbox: MessageInbox?
    @Environment(MeshPresence.self) private var presence
    @Environment(PairingService.self) private var pairing: PairingService?
    /// N2 — while this stream is on screen, its peer key is the notifier's
    /// `activeConversationID`, so a message for the chat you are already
    /// reading never banners. Optional (like inbox/pairing) so previews render.
    @Environment(LocalNotifier.self) private var notifier: LocalNotifier?
    /// FaceTime v1 (P4): the app-wide call layer; nil until the boot task
    /// builds it (and in previews).
    @Environment(CallEngine.self) private var callEngine: CallEngine?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var draft: String = ""
    @FocusState private var composerFocused: Bool
    @State private var showSettings = false
    /// STEP 7f — presents the 4-word SAS sheet from the verify-gate composer.
    @State private var showVerify = false

    /// Multi-select delete: select mode + the chosen message rows.
    @State private var isSelecting = false
    @State private var selection = Set<PersistentIdentifier>()

    /// Media send (mirrors the old composer's proven pattern).
    @State private var recorder = VoiceRecorder()

    /// PTT (walkie-talkie): true while the hold-to-talk button is held. Gates
    /// the composer OUT of the tap-record `recordingBar` swap so the press
    /// gesture is never torn down mid-hold. `pttAutoPlay` serializes inbound
    /// PTT playback so two clips never overlap (ignore-if-busy).
    @State private var pttHolding = false
    @State private var pttAutoPlay = PTTAutoPlay()

    /// Full-screen "walkie mode" (globe surface) for this ONE peer. Rides the
    /// shipped async `isPushToTalk` path — presentation only, no new transport.
    @State private var showWalkie = false
    @State private var pickedItem: PhotosPickerItem?

    /// Plus-button intents: a plain tap presents the chat picker (the send
    /// path is unchanged); the long-press menu can instead open the story
    /// composer. The picker is presented programmatically so the tap and the
    /// "Send in chat" menu item share ONE picker + ONE routing path.
    @State private var showChatPicker = false
    @State private var showStoryComposer = false

    /// v1 video messages: the human-readable reason a picked clip was refused
    /// (length / weight), shown as an alert on the composer's picker.
    @State private var videoSendNotice: String?
    @State private var showMicDenied = false

    /// Observe the app-wide accent so the stream recolours on change.
    @AppStorage("aeronyra.accentHex") private var accentHex = Int(Stillwater.Accent.defaultHex)

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    // MARK: Derived state
    private var conversation: Conversation? {
        peer.conversations.first(where: { $0.kind == .direct })
    }
    private var sortedMessages: [Message] {
        (conversation?.messages ?? []).sorted { $0.timestamp < $1.timestamp }
    }
    private var tier: Stillwater.Presence {
        presence.isReachable(peer.publicKeyData) ? .near : .gone
    }
    /// STEP 7f — whether this contact has completed the 4-word SAS (or was QR-paired).
    /// Drives the composer: unverified shows the verify-gate instead. Reads through
    /// the PairingService façade; nil (no env, e.g. previews) reads as unverified.
    private var isVerified: Bool {
        pairing?.isVerified(peer.publicKeyData) ?? false
    }
    private var peerName: String {
        if let n = peer.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            return n
        }
        return String(peer.userIDHex.prefix(6)).uppercased()
    }

    // MARK: Body
    var body: some View {
        let _ = accentHex   // re-run body (recolour) when the accent changes
        ZStack {
            LinearGradient(
                colors: [Stillwater.Palette.water, Stillwater.Palette.abyssDeep],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                stream
                composer
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
            // Rebuild the coloured content when the accent changes, so memoized
            // message rows (whose Message input is unchanged) re-read `biolume`.
            // Sheets/alerts live on the ZStack below, so this never disturbs them.
            .id(accentHex)
        }
        .background(Stillwater.Palette.abyss)
        .navigationBarBackButtonHidden(true)
        .task { markInboundRead() }
        .onChange(of: sortedMessages.count) { markInboundRead() }
        // N2 — suppress banners for the conversation on screen. The clear is
        // guarded: navigating A → B can run B's onAppear before A's onDisappear,
        // and an unguarded nil-out would clobber B's freshly-set key.
        .onAppear { notifier?.activeConversationID = peer.publicKeyData }
        .onDisappear {
            if notifier?.activeConversationID == peer.publicKeyData {
                notifier?.activeConversationID = nil
            }
        }
        .sheet(isPresented: $showSettings) {
            PeerSettingsView(conversation: currentConversation())
        }
        .fullScreenCover(isPresented: $showWalkie) {
            // Step 2: the globe's hold-to-talk drives the SAME beginPTT/endPTT
            // the composer button uses — a release sends an `isPushToTalk` note
            // over the shipped media path. Peer inherited from this chat; no
            // picker; dismiss returns here.
            WalkieGlobeView(peerName: peerName,
                            onPressDown: { beginPTT() },
                            onPressUp: { endPTT() })
        }
        .sheet(isPresented: $showVerify) {
            SASVerifySheet(peerName: peerName,
                           rawKey: peer.publicKeyData,
                           pairing: pairing)
                .presentationDetents([.medium])
                .preferredColorScheme(.dark)
        }
        .alert("Microphone access needed", isPresented: $showMicDenied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable microphone access in Settings to send voice notes.")
        }
    }

    // MARK: Header
    private var header: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Text("‹").stillwaterSerif(15, color: Stillwater.Palette.mistDim)
            }
            .buttonStyle(.plain)

            ZStack {
                if tier == .near {
                    RippleRing(color: Stillwater.Palette.biolume, size: 22, duration: 3.4)
                    Circle().fill(Stillwater.Palette.biolume.opacity(0.6))
                        .frame(width: 10, height: 10)
                } else {
                    Circle().strokeBorder(Stillwater.Palette.goneRing, lineWidth: 1)
                        .frame(width: 10, height: 10)
                }
            }
            .frame(width: 22, height: 22)

            Button { showSettings = true } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(peerName).stillwaterSerif(22, color: Stillwater.Palette.foam)
                    Text(headerSublabel).stillwaterMono(8.5, trackingEm: 0.2, color: tier.labelColor)
                }
            }
            .buttonStyle(.plain)
            Spacer()

            // FaceTime v1 (P4): voice + video call. Same wire either way —
            // always audio+video; the camera just starts off for voice.
            if let callEngine {
                Button {
                    Task { await callEngine.startVoiceCall(peerKey: peer.publicKeyData) }
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Stillwater.Palette.biolume)
                }
                .buttonStyle(.plain)
                Button {
                    Task { await callEngine.startVideoCall(peerKey: peer.publicKeyData) }
                } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Stillwater.Palette.biolume)
                }
                .buttonStyle(.plain)
            }

            // Walkie mode (full-screen globe). NOT gated on callEngine — it
            // rides the shipped async push-to-talk path, not the call stack.
            Button { showWalkie = true } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Stillwater.Palette.biolume)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Walkie mode")
        }
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Stillwater.Palette.biolume.opacity(0.09)).frame(height: 1)
        }
    }

    private var headerSublabel: String {
        tier == .near ? "in the room · direct · alive" : "out of range · last felt \(relativeAge(peer.lastSeen))"
    }

    // MARK: Stream
    private var stream: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    if sortedMessages.isEmpty {
                        emptyWater
                    } else {
                        ForEach(streamItems) { item in
                            switch item {
                            case .day(let label):     dayMark(label)
                            case .message(let m):
                                if isSelecting {
                                    // Selection wins over every bubble gesture
                                    // (media open, voice play/seek, tap-to-resend):
                                    // hit testing is off, the whole row is the toggle.
                                    messageView(m)
                                        .allowsHitTesting(false)
                                        .overlay {
                                            if selection.contains(m.persistentModelID) {
                                                RoundedRectangle(cornerRadius: 10)
                                                    .strokeBorder(Stillwater.Palette.biolume.opacity(0.55),
                                                                  lineWidth: 1)
                                                    .padding(-7)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                        .onTapGesture { toggleSelection(m) }
                                } else {
                                    // Delete/Select are scoped to Message-backed rows
                                    // only — day marks are labels, not records.
                                    messageView(m)
                                        .contextMenu {
                                            Button("Select") {
                                                selection = [m.persistentModelID]
                                                isSelecting = true
                                            }
                                            Button("Delete", role: .destructive) {
                                                deleteMessage(m)
                                            }
                                        }
                                }
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded { composerFocused = false })
            .onChange(of: sortedMessages.count) {
                withAnimation(Stillwater.Motion.water(0.5)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onAppear { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        }
    }

    private static let bottomAnchor = "stillwater.stream.bottom"

    private var emptyWater: some View {
        Text("still water. cast the first stone.")
            .font(Stillwater.Serif.italic(16))
            .foregroundColor(Stillwater.Palette.mistDim)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 40)
    }

    // MARK: Composer
    private var composer: some View {
        Group {
            if isSelecting {
                selectionBar
            } else if !isVerified {
                verifyGate
            } else if recorder.isRecording && !pttHolding {
                // Tap-record shows the full recording bar. A PTT HOLD keeps the
                // normal composer mounted (so the hold gesture isn't torn down)
                // and shows its state on the PTT button itself.
                recordingBar
            } else {
                normalComposer
            }
        }
        .padding(.top, 16)
        .overlay(alignment: .top) {
            Rectangle().fill(Stillwater.Palette.biolume.opacity(0.09)).frame(height: 1)
        }
        .animation(.easeOut(duration: 0.18), value: recorder.isRecording)
    }

    /// STEP 7f — shown INSTEAD of the composer until this contact is verified. No
    /// text field, no mic, no photo: there is no way to even attempt a send to an
    /// unverified peer (the inbox backstop is the second line). Tapping opens the
    /// 4-word SAS sheet; once confirmed, `pairing.markVerified` flips `isVerified`
    /// and the real composer replaces this when the sheet dismisses.
    private var verifyGate: some View {
        Button { showVerify = true } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .strokeBorder(Stillwater.Palette.biolume.opacity(0.4), lineWidth: 1)
                        .frame(width: 34, height: 34)
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Stillwater.Palette.biolume)
                }
                Text("verify \(peerName.lowercased()) with four words to message")
                    .font(Stillwater.Serif.italic(15))
                    .foregroundColor(Stillwater.Palette.mist)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    /// Select-mode action bar — replaces the composer while selecting.
    private var selectionBar: some View {
        HStack {
            Button { exitSelectMode() } label: {
                Text("cancel")
                    .stillwaterMono(10, trackingEm: 0.22, color: Stillwater.Palette.mist)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            Spacer()

            Button(role: .destructive) { deleteSelected() } label: {
                Text("delete (\(selection.count))")
                    .stillwaterMono(10, trackingEm: 0.22, color: .red)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .disabled(selection.isEmpty)
            .opacity(selection.isEmpty ? 0.4 : 1)
        }
    }

    private var normalComposer: some View {
        HStack(spacing: 12) {
            photoButton

            ZStack(alignment: .leading) {
                if draft.isEmpty {
                    Text("write into the water…")
                        .font(Stillwater.Serif.italic(16))
                        .foregroundColor(Stillwater.Palette.mistDim)
                }
                TextField("", text: $draft)
                    .font(Stillwater.Serif.regular(16))
                    .foregroundColor(Stillwater.Palette.foam)
                    .tint(Stillwater.Palette.biolume)
                    .focused($composerFocused)
                    .submitLabel(.send)
                    .onSubmit(sendDraft)
            }

            Spacer(minLength: 8)

            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pttButton
                micButton
            } else {
                sendButton
            }
        }
    }

    private var photoButton: some View {
        // ONE attach point, two intents: a plain TAP is the Menu's
        // primaryAction and opens the library for photos AND videos exactly
        // as before (the picked item's content type routes it below); a
        // LONG-PRESS opens the send-in-chat / post-as-story menu.
        Menu {
            Button("Send in chat") { showChatPicker = true }
            Button("Post as story") { showStoryComposer = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Stillwater.Palette.mist)
                .frame(width: 34, height: 34)
                .overlay(Circle().strokeBorder(Stillwater.Palette.biolume.opacity(0.25)))
                .contentShape(Circle())
        } primaryAction: {
            showChatPicker = true
        }
        .photosPicker(isPresented: $showChatPicker,
                      selection: $pickedItem,
                      matching: .any(of: [.images, .videos]),
                      photoLibrary: .shared())
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task { await sendPicked(item) }
        }
        .fullScreenCover(isPresented: $showStoryComposer) {
            // The composer owns compose + send for ONE peer's conversation;
            // it can't exist without a live inbox (nil only in previews).
            if let inbox {
                StoryComposerView(inbox: inbox, conversation: currentConversation())
            }
        }
        .alert("can't carry this clip", isPresented: Binding(
            get: { videoSendNotice != nil },
            set: { if !$0 { videoSendNotice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(videoSendNotice ?? "")
        }
    }

    private var micButton: some View {
        Button { Task { await startRecording() } } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Stillwater.Palette.biolume)
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Hold-to-talk (walkie-talkie). Press begins capture; release sends the
    /// utterance as a PTT voice note (`isPushToTalk: true`) over the same
    /// `sendMedia(.m4a)` path — the router picks BLE-near / relay-apart. A
    /// zero-distance drag detects press/release; `pttHolding` keeps the normal
    /// composer mounted so the gesture is never torn down (see `composer`).
    private var pttButton: some View {
        ZStack {
            Circle()
                .fill(pttHolding ? Stillwater.Palette.biolume : Stillwater.Palette.biolume.opacity(0.14))
                .frame(width: 38, height: 38)
                .overlay(Circle().strokeBorder(Stillwater.Palette.biolume.opacity(pttHolding ? 0 : 0.35)))
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(pttHolding ? Stillwater.Palette.onAccent : Stillwater.Palette.biolume)
        }
        .scaleEffect(pttHolding ? 1.28 : 1.0)
        .animation(.easeOut(duration: 0.14), value: pttHolding)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pttHolding { beginPTT() } }
                .onEnded { _ in endPTT() }
        )
        .accessibilityLabel("Hold to talk")
    }

    @MainActor
    private func beginPTT() {
        pttHolding = true
        Task {
            await recorder.start()
            if recorder.permissionDenied {
                showMicDenied = true
                pttHolding = false
            }
        }
    }

    @MainActor
    private func endPTT() {
        guard pttHolding else { return }
        pttHolding = false
        // Release before start finished, or nothing captured → nothing to send.
        guard let data = recorder.stop(), let inbox else { return }
        let convo = currentConversation()
        Task { await inbox.sendMedia(data, mime: .m4a, in: convo, isPushToTalk: true) }
    }

    private var sendButton: some View {
        Button(action: sendDraft) {
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [Stillwater.Palette.shallow, Stillwater.Palette.water],
                        center: .init(x: 0.36, y: 0.32), startRadius: 1, endRadius: 26))
                    .frame(width: 38, height: 38)
                    .overlay(Circle().strokeBorder(Stillwater.Palette.biolume.opacity(0.22)))
                    .shadow(color: Stillwater.Palette.biolume.opacity(0.14), radius: 7)
                Circle().fill(Stillwater.Palette.biolume).frame(width: 6, height: 6)
            }
        }
        .buttonStyle(.plain)
    }

    /// Recording bar: cancel · live metered waveform · elapsed · send.
    private var recordingBar: some View {
        HStack(spacing: 12) {
            Button { recorder.cancel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Stillwater.Palette.mist)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            RecordingWaveform(levels: recorder.levels)
                .frame(maxWidth: .infinity)
                .frame(height: 26)

            Text(timeString(recorder.elapsed))
                .stillwaterMono(9, trackingEm: 0.15, color: Stillwater.Palette.mist)
                .monospacedDigit()

            Button { stopAndSend() } label: {
                Circle()
                    .fill(Stillwater.Palette.biolume)
                    .frame(width: 38, height: 38)
                    .overlay(
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Stillwater.Palette.onAccent)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Send / read / ephemeral writes
    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let inbox else { return }
        let convo = currentConversation()
        draft = ""
        composerFocused = false
        Task { await inbox.send(text, in: convo) }
    }

    private func currentConversation() -> Conversation {
        if let existing = conversation { return existing }
        let convo = Conversation(kind: .direct, peer: peer)
        modelContext.insert(convo)
        try? modelContext.save()
        return convo
    }

    private func markInboundRead() {
        guard let convo = conversation else { return }
        var changed = false
        for m in convo.messages where !m.isOutbound && !m.isRead {
            m.isRead = true
            changed = true
        }
        if changed {
            try? modelContext.save()
            // N2 — reading re-syncs the app badge to the store's true unread
            // total (same context the inbox counts over), so the count stamped
            // at arrival doesn't stick until the next message lands.
            inbox?.syncBadgeToUnreadTotal()
        }
    }

    /// Stamp when the recipient finished listening (arms the 2-min self-destruct).
    private func stampListened(_ m: Message) {
        guard !m.isDeleted, m.listenedAt == nil else { return }
        m.listenedAt = .now
        try? modelContext.save()
    }

    /// Wipe an ephemeral voice note's audio bytes. The row survives as a tombstone.
    /// The `isDeleted` guard covers the voice note's unstructured scheduleWipe
    /// task, which can fire after the user deleted the row from the context menu.
    private func wipeMedia(_ m: Message) {
        guard !m.isDeleted, m.mediaData != nil else { return }
        m.mediaData = nil
        try? modelContext.save()
    }

    /// Local delete of a single message (media bytes go with the row). The
    /// parent conversation's `lastActivity` is recomputed from the surviving
    /// messages so Home ordering doesn't ride a deleted timestamp; if nothing
    /// survives it is left unchanged (Conversation carries no creation stamp).
    /// KNOWN LIMITATION (accepted): the row's `wireIDData` is also the inbound
    /// dedup record, so a late relay replay of this message can resurface it.
    private func deleteMessage(_ m: Message) {
        let convo = m.conversation
        let deletedID = m.id
        modelContext.delete(m)
        if let convo,
           let newest = convo.messages
               .filter({ $0.id != deletedID })
               .map(\.timestamp).max() {
            convo.lastActivity = newest
        }
        try? modelContext.save()
    }

    // MARK: Multi-select delete

    private func toggleSelection(_ m: Message) {
        let id = m.persistentModelID
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func exitSelectMode() {
        selection.removeAll()
        isSelecting = false
    }

    /// Batch delete: same semantics as `deleteMessage`, with ONE `lastActivity`
    /// recompute for the whole batch. Pending media wipes are covered by the
    /// same `!m.isDeleted` guard in `wipeMedia`/`stampListened`. Same known
    /// limitation: deleted rows' `wireIDData` were the dedup records.
    private func deleteSelected() {
        guard !selection.isEmpty else { exitSelectMode(); return }
        let convo = conversation
        let doomed = sortedMessages.filter { selection.contains($0.persistentModelID) }
        for m in doomed { modelContext.delete(m) }
        if let convo {
            let deletedIDs = Set(doomed.map(\.id))
            if let newest = convo.messages
                .filter({ !deletedIDs.contains($0.id) })
                .map(\.timestamp).max() {
                convo.lastActivity = newest
            }
        }
        try? modelContext.save()
        exitSelectMode()
    }

    // MARK: Media send (photo · video · voice)

    /// One picker, two kinds: route the picked item by its content type —
    /// a movie takes the video path, anything else the photo path.
    @MainActor
    private func sendPicked(_ item: PhotosPickerItem) async {
        defer { pickedItem = nil }
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            await sendPickedVideo(item)
        } else {
            await sendPickedPhoto(item)
        }
    }

    @MainActor
    private func sendPickedPhoto(_ item: PhotosPickerItem) async {
        guard let inbox,
              let raw = try? await item.loadTransferable(type: Data.self),
              let jpeg = Self.meshSizedJPEG(from: raw) else { return }
        await inbox.sendMedia(jpeg, mime: .jpeg, in: currentConversation())
    }

    /// v1 video: duration-gate + transcode (VideoTranscoder), then the same
    /// send path a photo takes. The two refusals surface as distinct notices;
    /// the picker's temp copy is removed whichever way this exits.
    @MainActor
    private func sendPickedVideo(_ item: PhotosPickerItem) async {
        guard let inbox,
              let picked = try? await item.loadTransferable(type: PickedVideo.self) else { return }
        defer { try? FileManager.default.removeItem(at: picked.url) }
        do {
            let mp4 = try await VideoTranscoder.transcodeToMP4(from: picked.url)
            await inbox.sendMedia(mp4, mime: .mp4, in: currentConversation())
        } catch VideoTranscoderError.clipTooLong(let seconds) {
            videoSendNotice = "that clip runs \(Int(seconds))s — the water carries up to \(Int(VideoTranscoder.maxClipSeconds))s"
        } catch VideoTranscoderError.overBudget {
            videoSendNotice = "that clip is too heavy to carry, even compressed"
        } catch {
            videoSendNotice = "the clip couldn't be prepared"
        }
    }

    @MainActor
    private func startRecording() async {
        await recorder.start()
        if recorder.permissionDenied { showMicDenied = true }
    }

    @MainActor
    private func stopAndSend() {
        guard let data = recorder.stop(), let inbox else { return }
        let convo = currentConversation()
        Task { await inbox.sendMedia(data, mime: .m4a, in: convo) }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Downscale a picked image to a mesh-friendly JPEG: 1280px long edge @ 0.7,
    /// renderer pinned to scale 1 (points == pixels) so a Pro-Motion screen scale
    /// can't balloon the blob into thousands of BLE chunks. (Same discipline the
    /// old composer used — this is the SEND size, not the 256px avatar size.)
    /// Internal, not private: the story composer sends photos through this SAME
    /// downscale — one implementation, not a fork that could drift.
    static func meshSizedJPEG(from data: Data,
                                      maxDimension: CGFloat = 1280,
                                      quality: CGFloat = 0.7) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longEdge = max(image.size.width, image.size.height)
        let scale = longEdge > maxDimension ? maxDimension / longEdge : 1
        let target = CGSize(width: image.size.width * scale,
                            height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let normalized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return normalized.jpegData(compressionQuality: quality)
    }

    // MARK: Stream items
    private enum StreamItem: Identifiable {
        case day(String)
        case message(Message)
        var id: String {
            switch self {
            case .day(let s):     return "day-\(s)"
            case .message(let m): return "msg-\(m.id.uuidString)"
            }
        }
    }

    private var streamItems: [StreamItem] {
        var out: [StreamItem] = []
        var lastDay: String?
        for m in sortedMessages {
            let label = dayLabel(m.timestamp)
            if label != lastDay { out.append(.day(label)); lastDay = label }
            out.append(.message(m))
        }
        return out
    }

    // MARK: Message rendering
    @ViewBuilder
    private func messageView(_ m: Message) -> some View {
        if m.mediaMimeRaw != nil {
            mediaRow(m)
        } else if m.isOutbound {
            outbound(m)
        } else {
            theirLine(m)
        }
    }

    // MARK: Media rows (photo · voice)
    @ViewBuilder
    private func mediaRow(_ m: Message) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if m.isOutbound {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 5) {
                    mediaContent(m)
                    Text(mediaMeta(m))
                        .stillwaterMono(8.5, trackingEm: 0.18, color: Stillwater.Palette.mistDimmest)
                }
                Circle().fill(Stillwater.Palette.foam.opacity(0.85))
                    .frame(width: 5, height: 5).padding(.top, 6)
            } else {
                Circle().fill(Stillwater.Palette.biolume)
                    .frame(width: 5, height: 5).padding(.top, 6)
                VStack(alignment: .leading, spacing: 5) {
                    mediaContent(m)
                    Text(time(m))
                        .stillwaterMono(8.5, trackingEm: 0.18, color: Stillwater.Palette.mistDimmest)
                }
                Spacer(minLength: 40)
            }
        }
    }

    @ViewBuilder
    private func mediaContent(_ m: Message) -> some View {
        // ITEM 2: a STORY never renders inline (photo OR video) — it collapses
        // to a tap-to-view icon that opens the full-screen viewer, and (a)
        // stays re-viewable until the 8h reaper. Normal media below is
        // unchanged. Branches on `isStory` FIRST so a reaped story (blob gone)
        // still shows the story tombstone.
        if m.isStory {
            if m.mediaData != nil {
                StoryIconBubble(message: m, isOutbound: m.isOutbound, wipe: { wipeMedia(m) })
            } else {
                Text("story · gone")
                    .stillwaterMono(8.5, trackingEm: 0.2, color: Stillwater.Palette.mistDimmest)
            }
        } else {
            switch m.mediaMime {
            case .some(.jpeg):
                StillwaterPhoto(message: m, isOutbound: m.isOutbound, wipe: { wipeMedia(m) })
            case .some(.m4a):
                StillwaterVoiceNote(message: m,
                                    isOutbound: m.isOutbound,
                                    autoPlay: pttAutoPlay,
                                    stampListened: { stampListened(m) },
                                    wipe: { wipeMedia(m) })
            case .some(.mp4):
                if let data = m.mediaData {
                    VideoBubble(data: data, isOutbound: m.isOutbound)
                } else {
                    Text("— media —")
                        .font(Stillwater.Serif.italic(15))
                        .foregroundColor(Stillwater.Palette.mistDim)
                }
            default:
                Text("— media —")
                    .font(Stillwater.Serif.italic(15))
                    .foregroundColor(Stillwater.Palette.mistDim)
            }
        }
    }

    private func mediaMeta(_ m: Message) -> String {
        switch m.deliveryState {
        case .delivered:         return "\(time(m)) · surfaced"
        case .relayed(let h):    return "\(time(m)) · via mesh · \(h) hop\(h == 1 ? "" : "s")"
        case .sent:              return "\(time(m)) · sent"
        case .cast:              return "\(time(m)) · cast · will surface"
        case .findingPath:       return "\(time(m)) · finding a path…"
        case .notDelivered:      return "\(time(m)) · on the water"
        case .waitingForRange:   return "\(time(m)) · on the water"
        }
    }

    // MARK: Text lines
    private func theirLine(_ m: Message) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(Stillwater.Palette.biolume)
                .frame(width: 5, height: 5).padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                Text(m.content)
                    .font(Stillwater.Serif.regular(17))
                    .foregroundColor(Stillwater.Palette.foam)
                Text(time(m))
                    .stillwaterMono(8.5, trackingEm: 0.18, color: Stillwater.Palette.mistDimmest)
            }
            Spacer(minLength: 40)
        }
    }

    @ViewBuilder
    private func outbound(_ m: Message) -> some View {
        switch m.deliveryState {
        case .delivered:
            myLine(m, ripple: true,  meta: "\(time(m)) · surfaced for \(peerName)")
        case .relayed(let hops):
            myLine(m, ripple: true,  meta: "\(time(m)) · via mesh · \(hops) hop\(hops == 1 ? "" : "s")")
        case .sent:
            myLine(m, ripple: false, meta: "\(time(m)) · sent")
        case .cast:
            // Committed to a relay for an out-of-range peer. It went — it just
            // hasn't been picked up yet. NOT a WaitingLine: no "tap to resend",
            // because there is nothing to resend; it will surface when they arrive.
            myLine(m, ripple: false, meta: "\(time(m)) · cast · will surface")
        case .findingPath:
            myLine(m, ripple: false, meta: "\(time(m)) · finding a path…")
        case .waitingForRange:
            WaitingLine(text: m.content,
                        subtitle: "on the water — will hop when someone passes",
                        resendable: false, onResend: {})
        case .notDelivered:
            WaitingLine(text: m.content,
                        subtitle: "on the water · tap to resend",
                        resendable: true, onResend: { Task { await inbox?.resend(m) } })
        }
    }

    private func myLine(_ m: Message, ripple: Bool, meta: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 5) {
                Text(m.content)
                    .font(Stillwater.Serif.regular(17))
                    .foregroundColor(Stillwater.Palette.biolume.opacity(0.9))
                    .multilineTextAlignment(.trailing)
                Text(meta)
                    .stillwaterMono(8.5, trackingEm: 0.18, color: Stillwater.Palette.mistDimmest)
            }
            ZStack {
                if ripple { RippleRing(color: Stillwater.Palette.biolume, size: 14, duration: 4.0) }
                Circle().fill(Stillwater.Palette.foam.opacity(0.85))
                    .frame(width: 5, height: 5)
            }
            .frame(width: 14, height: 14)
            .padding(.top, 1)
        }
    }

    private func dayMark(_ text: String) -> some View {
        Text(text)
            .stillwaterMono(8.5, trackingEm: 0.28, color: Stillwater.Palette.mistDimmest)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: Formatting
    private func time(_ m: Message) -> String {
        Self.timeFormatter.string(from: m.timestamp)
    }

    private func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInYesterday(date) { return "yesterday" }
        let daysAgo = cal.dateComponents([.day], from: cal.startOfDay(for: date),
                                         to: cal.startOfDay(for: .now)).day ?? 0
        let f = DateFormatter()
        f.dateFormat = daysAgo < 7 ? "EEEE" : "MMM d"
        return f.string(from: date).lowercased()
    }

    private func relativeAge(_ date: Date) -> String {
        let seconds = max(0, Date.now.timeIntervalSince(date))
        if seconds < 60 { return "moments ago" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }
        return "\(hours / 24) d ago"
    }
}

// MARK: - Stillwater voice note (real waveform + ephemeral self-destruct)
/// PTT auto-play serializer — IGNORE-IF-BUSY, so two inbound walkie clips never
/// overlap. One claim at a time (keyed by message id); a PTT note that arrives
/// while another is auto-playing simply does not auto-play (the user can tap
/// it). Released when the holder's playback stops or it scrolls away.
@Observable final class PTTAutoPlay {
    private(set) var busyID: UUID?
    func claim(_ id: UUID) -> Bool {
        guard busyID == nil else { return false }
        busyID = id
        return true
    }
    func release(_ id: UUID) {
        if busyID == id { busyID = nil }
    }
}

private struct StillwaterVoiceNote: View {
    let message: Message
    let isOutbound: Bool
    /// PTT: the shared no-overlap serializer for inbound walkie auto-play.
    let autoPlay: PTTAutoPlay
    let stampListened: () -> Void
    let wipe: () -> Void

    @State private var player: VoicePlayer
    @State private var bars: [CGFloat]
    @State private var loadedBars = false
    @State private var expiredNow = false
    /// PTT auto-play bookkeeping: try once per view lifetime; track whether we
    /// hold the serializer claim so we release it when playback stops.
    @State private var autoPlayTried = false
    @State private var autoPlayClaimed = false

    private static let barCount = 30
    /// Listen-armed self-destruct window — shared with the MessageInbox reaper
    /// via MediaEphemeralityPolicy (SEC-6), so view and reaper can't drift.
    private static var listenWindow: TimeInterval { MediaEphemeralityPolicy.voiceListenWindow }

    init(message: Message, isOutbound: Bool, autoPlay: PTTAutoPlay,
         stampListened: @escaping () -> Void, wipe: @escaping () -> Void) {
        self.message = message
        self.isOutbound = isOutbound
        self.autoPlay = autoPlay
        self.stampListened = stampListened
        self.wipe = wipe
        _player = State(initialValue: VoicePlayer(data: message.mediaData ?? Data()))
        _bars = State(initialValue: Array(repeating: 0.12, count: Self.barCount))
    }

    private var expired: Bool {
        if expiredNow || message.mediaData == nil { return true }
        guard !isOutbound, let listened = message.listenedAt else { return false }
        return Date.now.timeIntervalSince(listened) >= Self.listenWindow
    }

    var body: some View {
        Group {
            if expired { tombstone } else { controls }
        }
        .task { await setup(); await maybeAutoPlay() }
        .onDisappear { releaseAutoPlay() }
    }

    private var tombstone: some View {
        Text(isOutbound
             ? (message.isPushToTalk ? "walkie · heard" : "voice note · heard")
             : (message.isPushToTalk ? "walkie · gone" : "voice note · gone"))
            .stillwaterMono(8.5, trackingEm: 0.2, color: Stillwater.Palette.mistDimmest)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Stillwater.Palette.onAccent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Stillwater.Palette.biolume))
            }
            .buttonStyle(.plain)

            // Walkie mark: a PTT note reads as radio, not a filed voice note.
            if message.isPushToTalk {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Stillwater.Palette.biolume.opacity(0.85))
            }

            waveform.frame(width: message.isPushToTalk ? 112 : 128, height: 26)

            Text(timeString)
                .stillwaterMono(8.5, trackingEm: 0.15, color: Stillwater.Palette.mistDim)
                .monospacedDigit()
        }
        .onChange(of: player.isPlaying) { _, playing in
            if !playing {
                releaseAutoPlay()   // free the serializer as soon as this clip stops
                if player.progress >= 0.99 { handleFinished() }
            }
        }
    }

    /// Auto-play an INBOUND PTT note that JUST arrived (in-thread walkie feel),
    /// once per view lifetime, and only if no other PTT clip is playing
    /// (ignore-if-busy via the shared serializer). Recency gate keeps scrolling
    /// through history from replaying old clips.
    @MainActor
    private func maybeAutoPlay() async {
        guard message.isPushToTalk, !isOutbound, !autoPlayTried, !expired,
              message.mediaData != nil else { return }
        autoPlayTried = true
        let justArrived = Date.now.timeIntervalSince(message.timestamp) < 12
        guard justArrived, autoPlay.claim(message.id) else { return }
        autoPlayClaimed = true
        player.play()
    }

    private func releaseAutoPlay() {
        if autoPlayClaimed {
            autoPlay.release(message.id)
            autoPlayClaimed = false
        }
    }

    private var waveform: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(bars.indices, id: \.self) { i in
                    Capsule()
                        .fill(barColor(i))
                        .frame(width: 2, height: max(2, bars[i] * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { value in
                    let fraction = geo.size.width > 0 ? value.location.x / geo.size.width : 0
                    player.seek(to: Double(fraction))
                }
            )
        }
    }

    private func barColor(_ i: Int) -> Color {
        let fraction = bars.isEmpty ? 0 : Double(i) / Double(bars.count)
        return fraction <= player.progress
            ? Stillwater.Palette.biolume
            : Stillwater.Palette.mist.opacity(0.35)
    }

    private var timeString: String {
        let seconds = player.progress > 0 ? player.progress * player.duration : player.duration
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func setup() async {
        if expired { wipe(); expiredNow = true; return }
        if !loadedBars, let data = message.mediaData {
            let count = Self.barCount
            let computed = await Task.detached { WaveformExtractor.bars(from: data, count: count) }.value
            bars = computed
            loadedBars = true
        }
        // Resume a self-destruct already in flight (listened, app relaunched mid-window).
        if !isOutbound, let listened = message.listenedAt {
            let remaining = Self.listenWindow - Date.now.timeIntervalSince(listened)
            if remaining > 0 { scheduleWipe(after: remaining) } else { wipe(); expiredNow = true }
        }
    }

    private func handleFinished() {
        guard !isOutbound, message.listenedAt == nil else { return }
        stampListened()
        scheduleWipe(after: Self.listenWindow)
    }

    private func scheduleWipe(after seconds: TimeInterval) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            wipe()
            expiredNow = true
        }
    }
}

// MARK: - Story mark (badge + countdown · both directions)
/// The one line under a live story bubble: "story · disappears in Xh".
/// Both directions on purpose — `reapExpiredMedia` admits OUTBOUND stories,
/// so the sender's own copy vanishes at 8h; unmarked, that reads as data
/// loss. Counts down from the same anchor the reaper uses
/// (`sentAt ?? timestamp` + `storyWindow`), refreshed each minute; the
/// composer never learns this view exists.
private struct StoryCaption: View {
    let message: Message

    private var expiry: Date {
        (message.sentAt ?? message.timestamp)
            .addingTimeInterval(MediaEphemeralityPolicy.storyWindow)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text("story · disappears in \(Self.remaining(to: expiry, from: context.date))")
                .stillwaterMono(8, trackingEm: 0.2, color: Stillwater.Palette.biolume.opacity(0.8))
        }
    }

    /// Coarse on purpose — a story clock, not a stopwatch: hours while ≥1h
    /// remains (rounded up, so a fresh story says "8h"), then minutes.
    private static func remaining(to expiry: Date, from now: Date) -> String {
        let s = expiry.timeIntervalSince(now)
        if s >= 3600 { return "\(Int((s / 3600).rounded(.up)))h" }
        if s >= 60 { return "\(Int((s / 60).rounded(.up)))m" }
        return "moments"
    }
}

// MARK: - Story icon bubble (Item 2 · tap to view, re-viewable until 8h)
/// A story renders as a compact tappable icon — never inline. Tap opens the
/// full-screen `StoryViewer`; on dismiss it collapses back here and stays
/// re-viewable (behavior a) until the shared 8h reaper wipes it. Owns the
/// in-view boundary wipe (both directions, from the `sentAt` anchor) that the
/// inline story render used to; the reaper covers off-screen rows. A subtle
/// "seen" state dims the ring after the first open.
private struct StoryIconBubble: View {
    let message: Message
    let isOutbound: Bool
    let wipe: () -> Void

    @State private var showViewer = false
    @State private var seen = false
    @State private var expiredNow = false
    /// First-frame preview for a VIDEO story, so its icon shows an image in
    /// the ring just like a photo story (generated once, off the blob).
    @State private var videoThumb: UIImage?

    private var expired: Bool {
        if expiredNow || message.mediaData == nil { return true }
        return MediaEphemeralityPolicy.isExpired(isStory: true,
                                                 mime: message.mediaMime,
                                                 timestamp: message.timestamp,
                                                 sentAt: message.sentAt,
                                                 listenedAt: message.listenedAt,
                                                 now: .now)
    }

    var body: some View {
        Group {
            if expired {
                Text("story · gone")
                    .stillwaterMono(8.5, trackingEm: 0.2, color: Stillwater.Palette.mistDimmest)
            } else {
                Button {
                    seen = true
                    showViewer = true
                } label: { iconRow }
                .buttonStyle(.plain)
            }
        }
        // 8h boundary wipe, both directions — same anchor the reaper uses; a
        // conversation left open across the deadline tombstones in place.
        .task {
            let remaining = MediaEphemeralityPolicy.storyWindow
                - Date.now.timeIntervalSince(message.sentAt ?? message.timestamp)
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
            }
            if message.mediaData != nil { wipe() }
            expiredNow = true
        }
        // Generate the video story's ring preview once, off the blob.
        .task {
            guard message.mediaMime == .mp4, videoThumb == nil,
                  let data = message.mediaData else { return }
            videoThumb = await Self.firstFrame(from: data)
        }
        .fullScreenCover(isPresented: $showViewer) {
            StoryViewer(message: message)
        }
    }

    private var expiry: Date {
        (message.sentAt ?? message.timestamp)
            .addingTimeInterval(MediaEphemeralityPolicy.storyWindow)
    }

    /// The image shown inside the ring: a photo story's own bytes, or a video
    /// story's first frame once generated. Nil until a video thumb is ready.
    private var ringPreview: UIImage? {
        if message.mediaMime == .jpeg, let data = message.mediaData {
            return UIImage(data: data)
        }
        return videoThumb
    }

    /// First frame of a video story's blob for the ring preview — transform-
    /// applied (upright), small, temp file cleaned up. nil on any failure.
    private static func firstFrame(from data: Data) async -> UIImage? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("storythumb-\(UUID().uuidString).mp4")
        guard (try? data.write(to: url)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 120, height: 120)
        guard let cg = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Thin glowing ring (kin to the presence dots) + a small play triangle,
    /// and ONE quiet caps line "story · {countdown}". No heavy tile, no
    /// container fill, no redundant "tap to view"/duplicate "story". Seen dims
    /// the ring and the line.
    private var iconRow: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .strokeBorder(Stillwater.Palette.biolume.opacity(seen ? 0.3 : 0.7), lineWidth: 1.5)
                    .frame(width: 40, height: 40)
                if let preview = ringPreview {
                    // Photo: the image itself. Video: its first frame, with a
                    // small play glyph so the ring still reads as a video.
                    Image(uiImage: preview)
                        .resizable().scaledToFill()
                        .frame(width: 33, height: 33)
                        .clipShape(Circle())
                        .opacity(seen ? 0.7 : 1)
                    if message.mediaMime == .mp4 {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white)
                            .shadow(color: .black.opacity(0.5), radius: 1)
                            .opacity(seen ? 0.7 : 1)
                    }
                } else {
                    // No preview yet (video thumb still generating, or decode
                    // failed): the quiet play triangle.
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Stillwater.Palette.biolume.opacity(seen ? 0.5 : 0.95))
                }
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text("story · \(Self.remaining(to: expiry, from: context.date))")
                    .stillwaterMono(8.5, trackingEm: 0.22,
                                    color: Stillwater.Palette.biolume.opacity(seen ? 0.5 : 0.8))
            }
        }
        .padding(.vertical, 3)
    }

    /// Coarse story clock (matches StoryCaption): hours rounded up while ≥1h,
    /// then minutes, then "moments".
    private static func remaining(to expiry: Date, from now: Date) -> String {
        let s = expiry.timeIntervalSince(now)
        if s >= 3600 { return "\(Int((s / 3600).rounded(.up)))h" }
        if s >= 60 { return "\(Int((s / 60).rounded(.up)))m" }
        return "moments"
    }
}

// MARK: - Story viewer (Item 2 · full-screen; manages audio for video-with-sound)
/// Full-screen story presentation. Photo: fit-to-screen, tap to dismiss.
/// Video: `VideoPlayer`, auto-plays once; if the clip carries audio the viewer
/// ACTIVATES `.playback` on open and DEACTIVATES with
/// `.notifyOthersOnDeactivation` on dismiss (so Music/Spotify/podcast resumes)
/// — the same managed-session pattern as the calling + trim-preview fixes, via
/// AVAudioSession directly (never the call layer's RTCAudioSession). Dismiss
/// returns to the chat; the icon stays re-viewable.
private struct StoryViewer: View {
    let message: Message

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var tempURL: URL?
    @State private var audioActive = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if message.mediaMime == .jpeg, let data = message.mediaData,
               let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable().scaledToFit()
                    .ignoresSafeArea()
                    .onTapGesture { dismiss() }
            } else if let player {
                // No default player controls — Apple's control bar (with the
                // audio/route button) would sit above and swallow the close
                // tap. We drive playback (auto-play on open) and dismiss via
                // our own close button + tap-to-dismiss, so close always wins.
                StoryVideoSurface(player: player)
                    .ignoresSafeArea()
                    .onTapGesture { dismiss() }
            }

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Text("close")
                            .stillwaterMono(9, trackingEm: 0.24, color: Color.white)
                    }
                    .padding(20)
                }
                Spacer()
            }
        }
        .task { await stageVideoIfNeeded() }
        .onDisappear { teardown() }
    }

    @MainActor
    private func stageVideoIfNeeded() async {
        guard message.mediaMime == .mp4, let data = message.mediaData, player == nil else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("story-\(UUID().uuidString).mp4")
        guard (try? data.write(to: url)) != nil else { return }
        tempURL = url
        // Managed audio only for a clip that actually has sound.
        if await Self.hasAudioTrack(url) { activateAudio() }
        let p = AVPlayer(url: url)
        player = p
        p.play()
    }

    private func teardown() {
        player?.pause()
        player = nil
        deactivateAudio()
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
        tempURL = nil
    }

    private func activateAudio() {
        guard !audioActive else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        audioActive = true
    }

    private func deactivateAudio() {
        guard audioActive else { return }
        audioActive = false
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private static func hasAudioTrack(_ url: URL) async -> Bool {
        let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        return tracks?.isEmpty == false
    }
}

// MARK: - Story video surface (Item 2 · bare AVPlayerLayer, NO default controls)
/// Hosts the story video with no playback control layer, so Apple's control
/// bar (play/scrub/audio-route) can't intercept the close tap. Playback is
/// driven by `StoryViewer`; dismissal is its close button + tap-to-dismiss.
private struct StoryVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.playerLayer.player = player
    }
}

// MARK: - Stillwater photo (inline · inbound self-destructs after 24h · story 8h BOTH ways)
private struct StillwaterPhoto: View {
    let message: Message
    let isOutbound: Bool
    let wipe: () -> Void

    @State private var expanded = false
    @State private var expiredNow = false

    /// Inbound photos disappear 24h after they arrive (received-time, no view
    /// tracking) — the window is MediaEphemeralityPolicy.photoWindow, shared
    /// with the MessageInbox reaper (SEC-6) so view and reaper can't drift.
    /// Outbound photos you sent are never expired here — EXCEPT stories,
    /// which die `storyWindow` after the send anchor on BOTH ends (the
    /// stories-only SEC-6 reversal).
    private static var photoWindow: TimeInterval { MediaEphemeralityPolicy.photoWindow }

    private var expired: Bool {
        if message.isStory {
            // STORIES: one rule, BOTH directions — literally the reaper's own
            // pure decision, so view and reaper cannot drift.
            if expiredNow || message.mediaData == nil { return true }
            return MediaEphemeralityPolicy.isExpired(isStory: true,
                                                     mime: message.mediaMime,
                                                     timestamp: message.timestamp,
                                                     sentAt: message.sentAt,
                                                     listenedAt: message.listenedAt,
                                                     now: .now)
        }
        guard !isOutbound else { return false }
        if expiredNow || message.mediaData == nil { return true }
        return Date.now.timeIntervalSince(message.timestamp) >= Self.photoWindow
    }

    var body: some View {
        Group {
            if expired {
                Text(message.isStory ? "story · gone" : "photo · gone")
                    .stillwaterMono(8.5, trackingEm: 0.2, color: Stillwater.Palette.mistDimmest)
            } else if let data = message.mediaData, let image = UIImage(data: data) {
                if message.isStory {
                    // The mark that makes a story READ as a story: without it,
                    // the sender's own 8h disappearance looks like data loss.
                    VStack(alignment: isOutbound ? .trailing : .leading, spacing: 5) {
                        photo(image)
                        StoryCaption(message: message)
                    }
                } else {
                    photo(image)
                }
            } else {
                Text("— photo unavailable —")
                    .font(Stillwater.Serif.italic(15))
                    .foregroundColor(Stillwater.Palette.mistDim)
            }
        }
        // Past the window already: wipe the bytes now (the render is gated on
        // `expired`, so it's a tombstone regardless). Otherwise schedule the
        // boundary wipe for the REMAINING interval, so a conversation left open
        // across the window's edge tombstones without needing a re-render (the
        // same treatment the voice note's scheduleWipe gives its 2-min window).
        // Stories schedule from the SEND anchor, both directions; non-story
        // photos keep the inbound-only 24h-from-arrival rule.
        // Riding the view's own .task means the sleep is cancelled on
        // disappear — the isCancelled guard stops a cancellation from wiping
        // EARLY; an off-screen row is the reaper's job instead.
        .task {
            if expired {
                if message.mediaData != nil { wipe() }
                expiredNow = true
                return
            }
            let remaining: TimeInterval
            if message.isStory {
                remaining = MediaEphemeralityPolicy.storyWindow
                    - Date.now.timeIntervalSince(message.sentAt ?? message.timestamp)
            } else {
                guard !isOutbound else { return }
                remaining = Self.photoWindow - Date.now.timeIntervalSince(message.timestamp)
            }
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            wipe()
            expiredNow = true
        }
    }

    private func photo(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(maxWidth: 220, maxHeight: 260)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Stillwater.Palette.biolume.opacity(0.15))
            )
            .onTapGesture { expanded = true }
            .fullScreenCover(isPresented: $expanded) {
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: image).resizable().scaledToFit().ignoresSafeArea()
                    VStack {
                        HStack {
                            Spacer()
                            Button { expanded = false } label: {
                                Text("close").stillwaterMono(9, trackingEm: 0.24, color: Color.white)
                            }
                            .padding(20)
                        }
                        Spacer()
                    }
                }
            }
    }
}

// MARK: - Waiting on the water (undelivered — breathing, tap-to-resend)
private struct WaitingLine: View {
    let text: String
    let subtitle: String
    let resendable: Bool
    let onResend: () -> Void

    @State private var breathing = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Spacer(minLength: 40)
                Text(text)
                    .font(Stillwater.Serif.regular(17))
                    .foregroundColor(Stillwater.Palette.biolume.opacity(0.36))
                    .multilineTextAlignment(.trailing)
                Circle()
                    .strokeBorder(Stillwater.Palette.mistDim, lineWidth: 1)
                    .frame(width: 5, height: 5).padding(.top, 6)
            }
            Text(subtitle)
                .stillwaterMono(8.5, trackingEm: 0.18, color: Stillwater.Palette.mistDimmest)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .opacity(breathing ? 0.62 : 0.38)
        .animation(.easeInOut(duration: 5).repeatForever(autoreverses: true), value: breathing)
        .onAppear { breathing = true }
        .contentShape(Rectangle())
        .onTapGesture { if resendable { onResend() } }
    }
}

// MARK: - Ripple ring (presence + read receipt)
private struct RippleRing: View {
    let color: Color
    var size: CGFloat = 22
    let duration: Double
    @State private var expanded = false

    var body: some View {
        Circle()
            .strokeBorder(color.opacity(0.5), lineWidth: 1)
            .frame(width: size, height: size)
            .scaleEffect(expanded ? 1.0 : 0.4)
            .opacity(expanded ? 0.0 : 0.8)
            .animation(.easeOut(duration: duration).repeatForever(autoreverses: false), value: expanded)
            .onAppear { expanded = true }
    }
}

// MARK: - Live recording waveform (composer)
private struct RecordingWaveform: View {
    let levels: [CGFloat]

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Stillwater.Palette.biolume)
                        .frame(width: 2.5, height: max(2, level * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - Preview
#Preview("Stillwater — Conversation") {
    let container = try! ModelContainer(
        for: Peer.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let ctx = container.mainContext

    let maya = Peer(publicKeyData: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                    displayName: "Maya", lastSeen: .now)
    ctx.insert(maya)
    let convo = Conversation(kind: .direct, peer: maya)
    ctx.insert(convo)

    let a = Message(content: "the power's out on my whole street again", isOutbound: false,
                    deliveryState: .delivered, isRead: true)
    let b = Message(content: "I can see your light from here. literally", isOutbound: true,
                    deliveryState: .delivered)
    let c = Message(content: "bringing candles", isOutbound: true, deliveryState: .notDelivered)
    for m in [a, b, c] { ctx.insert(m); m.conversation = convo }

    let presence = MeshPresence()
    presence.reachablePeerKeys = [maya.publicKeyData]

    return NavigationStack { StreamView(peer: maya) }
        .modelContainer(container)
        .environment(presence)
}

// MARK: - Walkie mode (full-screen globe · Step 2: hold-to-talk wired)
/// A full-screen "walkie mode" surface for the ONE peer this conversation is
/// bound to. Idle globe (Step 1) + hold-to-talk (Step 2): pressing the orb
/// drives the SAME `beginPTT()`/`endPTT()` the composer button uses, so a
/// release sends an ordinary `isPushToTalk: true` voice note over the shipped
/// media path. This view adds NO recorder, transport, or send code — it only
/// forwards press-down / release. The audio-reactive pulse (recorder/player
/// meters) is still Steps 3–4; the held state here is a fixed transmit
/// brightness.
private struct WalkieGlobeView: View {
    let peerName: String
    /// Forwarded to StreamView's `beginPTT`/`endPTT`. The globe never touches
    /// the recorder or the wire — it only reports press-down and release.
    let onPressDown: () -> Void
    let onPressUp: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Idle breathing driver — a single accent, brightness/scale only (never a
    /// second hue), per the design language. Held static under reduce-motion.
    @State private var breathing = false
    /// True while the orb is pressed — drives the transmit brightness and swaps
    /// the hint to "transmitting…". Purely local; the send is StreamView's.
    @State private var holding = false

    var body: some View {
        ZStack {
            Stillwater.Palette.abyss.ignoresSafeArea()

            globe

            VStack {
                header
                Spacer()
                Text(holding ? "transmitting…" : "hold to talk")
                    .stillwaterMono(8.5, trackingEm: 0.28,
                                    color: holding ? Stillwater.Palette.biolume
                                                   : Stillwater.Palette.mistDimmest)
                    .padding(.bottom, 54)
                    .animation(.easeOut(duration: 0.16), value: holding)
            }
        }
        .onAppear {
            guard !reduceMotion else { breathing = true; return }   // static, mid-brightness
            withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }

    // MARK: Header — who you're aimed at + exit
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(peerName)
                    .stillwaterSerif(22, color: Stillwater.Palette.foam)
                Text("walkie")
                    .stillwaterMono(8.5, trackingEm: 0.3, color: Stillwater.Palette.mistDim)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Stillwater.Palette.mistDim)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 26)
        .padding(.top, 18)
    }

    // MARK: The globe — idle breathing (Step 1) + hold-to-talk (Step 2)
    /// Held brightens/enlarges the orb as a fixed transmit state (the meter-
    /// driven pulse is Step 3). `holding` overrides the idle breathing values.
    private var globe: some View {
        ZStack {
            // Soft outer glow — the "field" the globe sits in.
            Circle()
                .fill(RadialGradient(
                    colors: [Stillwater.Palette.biolume.opacity(0.22), .clear],
                    center: .center, startRadius: 2, endRadius: 190))
                .frame(width: 340, height: 340)
                .blur(radius: 26)
                .opacity(holding ? 1.0 : (breathing ? 0.9 : 0.55))

            // Core body — a translucent bioluminescent sphere.
            Circle()
                .fill(RadialGradient(
                    colors: [Stillwater.Palette.biolume.opacity(holding ? 0.6 : 0.35),
                             Stillwater.Palette.biolume.opacity(0.04)],
                    center: .init(x: 0.42, y: 0.38), startRadius: 4, endRadius: 150))
                .frame(width: 210, height: 210)
                .scaleEffect(holding ? 1.12 : (breathing ? 1.06 : 1.0))

            // Rim — the crisp edge that reads as an orb, not a blob.
            Circle()
                .strokeBorder(Stillwater.Palette.biolume.opacity(holding ? 0.95 : (breathing ? 0.7 : 0.4)),
                              lineWidth: holding ? 2 : 1.5)
                .frame(width: 210, height: 210)
                .scaleEffect(holding ? 1.12 : (breathing ? 1.06 : 1.0))
        }
        // The whole orb is the push-to-talk button. Zero-distance drag detects
        // press/release (matches the composer `pttButton`); release sends.
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !holding { holding = true; onPressDown() } }
                .onEnded { _ in holding = false; onPressUp() }
        )
        .animation(.easeOut(duration: 0.16), value: holding)
        .accessibilityLabel("Hold to talk")
        .accessibilityHint("Press and hold to send a walkie-talkie voice note")
    }
}
