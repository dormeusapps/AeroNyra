//
//  StoryComposerView.swift
//  Stories
//
//  STILLWATER · Stories composer (Plan B).
//
//  The full-screen home for composing a story: pick media, see it on the
//  editing canvas, post. On post the flat bytes go to the proven
//  `MessageInbox.sendMedia(isStory: true)` pipeline — the wire, the receiver,
//  expiry, and the bubble never learn there was an editing layer. Every
//  future tool (text next; more later) is a composer-side change only.
//
//  TEXT (E2 + h1, sticker model): the editor. A tool rail over the PHOTO
//  canvas — T adds a text block; MULTIPLE blocks, each independently
//  selectable (tap; ring is view-only, never burned), draggable ANYWHERE
//  (measured bounds clamped on-frame by the engine), two-finger rotatable,
//  alignable, deletable. Tap a selected block to edit its text; tap the
//  canvas to deselect. Geometry is the ENGINE's (StoryTextEngine): the
//  preview calls the same transform/clampedCenter/measuredBlockSize the burn
//  uses, with the preview frame instead of source pixels — fractions make
//  them the same place. On post ALL blocks are flattened at source
//  resolution and ride the proven photo path — or, for video (stage f),
//  burned by StoryVideoBurner (composite-THEN-transcode: trim → burn →
//  the untouched transcoder, gates on the true final bytes). The video
//  preview frames fractions against the transform-applied thumbnail, the
//  burn against the transform-applied render frame — the same frame.
//
//  The composer owns compose + send, nothing downstream: photos take the
//  SAME `StreamView.meshSizedJPEG` downscale the chat path ships, videos the
//  SAME `VideoTranscoder.transcodeToMP4` with its two gates (≤60s checked
//  before the encode, ≤16MiB on the exported bytes) surfaced here as the
//  chat path's own alert copy. One implementation each, not forks; everything
//  below `sendMedia` is the shipped SEC-6 machinery, untouched.
//

import SwiftUI
import UIKit
import PhotosUI
import AVFoundation

struct StoryComposerView: View {

    /// Both handed in by the presenting stream (a story goes to ONE peer per
    /// send, as shipped) — the composer never resolves peers or conversations
    /// itself. Non-optional on purpose: no media surface without a live inbox.
    let inbox: MessageInbox
    let conversation: Conversation

    @Environment(\.dismiss) private var dismiss

    /// What sits on the canvas. A video keeps its picker temp URL (the
    /// transcoder reads from disk) + a first-frame thumb for the preview;
    /// the URL is deleted on post, on replacement, and on dismiss.
    private enum CanvasMedia {
        case photo(raw: Data, image: UIImage)
        case video(url: URL, thumb: UIImage?)
    }

    @State private var pickedItem: PhotosPickerItem?
    @State private var media: CanvasMedia?

    /// Item 3a: in-composer camera capture. `showCamera` presents the capture
    /// surface; the option is only offered where a camera exists (hidden in
    /// the simulator), so `applyPhoto` stays the one convergence point for
    /// library AND camera photos.
    @State private var showCamera = false
    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    /// TRIM (T1): the scrubber's inputs + selection, populated on video load.
    /// Defaults keep the clip LEGAL — in = 0, out = min(duration, cap) — so a
    /// ≤60s source opens fully selected and posts exactly like stage d.
    /// Selecting past the cap is allowed; it only disables post + turns the
    /// readout (the transcoder's gates stay the backstop on the real bytes).
    @State private var videoDuration: Double = 0
    @State private var videoThumbs: [UIImage] = []
    @State private var trimSelection: ClosedRange<Double> = 0...0

    /// trim-preview: the composer owns the player + its periodic observer;
    /// the scrubber only draws the playhead and sends scrub/play intents.
    @State private var player: AVPlayer?
    @State private var playhead: Double?
    @State private var isPlaying = false
    @State private var timeObserver: Any?
    /// Whether the trim preview currently holds the shared audio session
    /// (video previews only). Gates activate/deactivate so a photo story — or
    /// merely opening the composer — never touches other apps' audio.
    @State private var previewAudioActive = false

    /// h1 — the text blocks. Geometry lives in each overlay's FRACTIONS;
    /// every placement/clamp call below is the engine's, never local math.
    /// `selectedOverlay` drives the per-block panel + selection ring (a view
    /// artifact — never burned); `editingIndex` is the block whose text is
    /// in the editor (nil = the T tool is adding a new one).
    @State private var overlays: [StoryTextOverlay] = []
    @State private var selectedOverlay: Int?
    @State private var editingIndex: Int?
    @State private var editingText = false
    @State private var draftText = ""
    @FocusState private var textFieldFocused: Bool
    /// Gesture baselines: fractional center / rotation at gesture start.
    @State private var dragStartCenter: CGPoint?
    @State private var rotationStart: CGFloat?
    /// Double-tap guard on the post pill. A photo post dismisses immediately
    /// (fire-and-forget, the optimistic row is the progress UI); a video post
    /// holds the sheet through the transcode so a gate refusal can surface
    /// here, then dismisses.
    @State private var posting = false
    /// The human-readable reason a picked clip was refused — the chat path's
    /// exact copy (`clipTooLong` / `overBudget` / export failure).
    @State private var videoNotice: String?

    var body: some View {
        ZStack {
            Stillwater.Palette.abyss.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 8)

                Spacer(minLength: 16)

                ZStack(alignment: .topTrailing) {
                    canvas
                    if media != nil, !editingText {
                        toolRail
                            .padding(.top, 12)
                            .padding(.trailing, 12)
                    }
                }
                .padding(.horizontal, 24)

                if case .video = media, videoDuration > 0 {
                    StoryTrimScrubber(thumbnails: videoThumbs,
                                      duration: videoDuration,
                                      legalCap: VideoTranscoder.maxClipSeconds,
                                      selection: $trimSelection,
                                      playhead: playhead,
                                      isPlaying: isPlaying,
                                      onScrub: { scrub(to: $0) },
                                      onPlayToggle: { togglePlay() })
                        .padding(.horizontal, 30)
                        .padding(.top, 14)
                        .disabled(posting)
                }

                if let sel = selectedOverlay, overlays.indices.contains(sel) {
                    selectedBlockPanel(sel)
                        .padding(.top, 14)
                }

                Spacer(minLength: 16)

                footer
                    .padding(.horizontal, 30)
                    .padding(.bottom, 30)
            }

            if editingText { textEditor }
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task { await loadPicked(item) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            // Item 3a/3b: the native camera offers photo OR video (its own
            // toggle); both converge on the same applyPhoto / applyVideo paths.
            StoryCameraCapture(
                onPhoto: { image in
                    showCamera = false
                    guard let raw = image.jpegData(compressionQuality: 0.95) else { return }
                    applyPhoto(raw: raw, image: image)
                },
                onVideo: { url in
                    showCamera = false
                    Task { await acceptCameraVideo(url) }
                },
                onCancel: { showCamera = false })
            .ignoresSafeArea()
        }
        .onDisappear { discardVideoIfAny() }   // idempotent: try? on a gone file
        .alert("can't carry this clip", isPresented: Binding(
            get: { videoNotice != nil },
            set: { if !$0 { videoNotice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(videoNotice ?? "")
        }
    }

    // MARK: Header
    private var header: some View {
        ZStack {
            HStack {
                Button { dismiss() } label: {
                    Text("close")
                        .stillwaterMono(9, trackingEm: 0.24, color: Stillwater.Palette.mistDim)
                }
                .buttonStyle(.plain)
                .padding(20)
                Spacer()
            }
            Text("Story")
                .stillwaterSerif(22, color: Stillwater.Palette.foam)
        }
    }

    // MARK: Canvas
    /// The editing canvas. Stage d renders the media alone; the text overlay
    /// layer (fractional geometry) grows HERE in stage e.
    @ViewBuilder
    private var canvas: some View {
        switch media {
        case .photo(_, let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .overlay {
                    // Preview overlay INSIDE the fitted image's own frame, so
                    // fractions here are fractions of the burn frame.
                    GeometryReader { geo in
                        overlayLayer(frame: geo.size)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture { selectedOverlay = nil }   // canvas tap = deselect
        case .video(_, let thumb):
            ZStack {
                if let player, let thumb {
                    // trim-preview: the live player, constrained to the
                    // thumb's (transform-applied) aspect so the surface's
                    // frame IS the display frame — text fractions previewed
                    // here land where the burn puts them.
                    StoryPlayerSurface(player: player)
                        .aspectRatio(thumb.size.width / thumb.size.height,
                                     contentMode: .fit)
                        .overlay {
                            GeometryReader { geo in
                                overlayLayer(frame: geo.size)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                } else if let thumb {
                    // The thumb is transform-APPLIED (firstFrame), so its
                    // frame IS the display frame the burn renders — text
                    // fractions previewed here land where the burn puts them.
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFit()
                        .overlay {
                            GeometryReader { geo in
                                overlayLayer(frame: geo.size)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                } else {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(Stillwater.Palette.biolume.opacity(0.25))
                        .overlay {
                            Text("video ready")
                                .stillwaterMono(9, trackingEm: 0.24, color: Stillwater.Palette.mistDimmest)
                        }
                }
                if !isPlaying {
                    Image(systemName: "play.fill")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Stillwater.Palette.foam.opacity(0.85))
                        .allowsHitTesting(false)   // text taps go to the blocks
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture { selectedOverlay = nil }   // canvas tap = deselect
        case nil:
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Stillwater.Palette.biolume.opacity(0.25))
                .overlay {
                    Text("pick a photo or video to begin")
                        .stillwaterMono(9, trackingEm: 0.24, color: Stillwater.Palette.mistDimmest)
                }
        }
    }

    // MARK: Footer
    @ViewBuilder
    private var footer: some View {
        if media == nil {
            // Source picker (Item 3a/4): Library AND Camera, side by side,
            // neither buried. Camera pill only where a camera exists.
            HStack(spacing: 12) {
                PhotosPicker(selection: $pickedItem,
                             matching: .any(of: [.images, .videos]),
                             photoLibrary: .shared()) {
                    outlinePill("library")
                }
                .buttonStyle(.plain)

                if cameraAvailable {
                    Button { showCamera = true } label: {
                        outlinePill("camera")
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            VStack(spacing: 12) {
                Button(action: post) {
                    pill(posting ? "posting…" : "post story")
                }
                .buttonStyle(.plain)
                .disabled(posting || selectionOverCap)
                .opacity(selectionOverCap ? 0.4 : 1.0)

                // Replace the current media — same two sources.
                HStack(spacing: 18) {
                    PhotosPicker(selection: $pickedItem,
                                 matching: .any(of: [.images, .videos]),
                                 photoLibrary: .shared()) {
                        Text("library")
                            .stillwaterMono(8, trackingEm: 0.22, color: Stillwater.Palette.mistDim)
                    }
                    .buttonStyle(.plain)
                    .disabled(posting)

                    if cameraAvailable {
                        Button { showCamera = true } label: {
                            Text("camera")
                                .stillwaterMono(8, trackingEm: 0.22, color: Stillwater.Palette.mistDim)
                        }
                        .buttonStyle(.plain)
                        .disabled(posting)
                    }
                }

                Text("vanishes for both of you \(Self.windowHours) hours after sending")
                    .stillwaterMono(7.5, trackingEm: 0.18, color: Stillwater.Palette.mistDimmest)
            }
        }
    }

    /// The 8h consequence, spoken from the ONE policy constant — copy and
    /// reaper cannot drift.
    private static let windowHours = Int(MediaEphemeralityPolicy.storyWindow / 3600)

    // MARK: Actions
    /// Route the picked item by content type — the same predicate the chat
    /// attach point uses (`StreamView.sendPicked`).
    @MainActor
    private func loadPicked(_ item: PhotosPickerItem) async {
        defer { pickedItem = nil }
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            guard let picked = try? await item.loadTransferable(type: PickedVideo.self) else { return }
            await applyVideo(url: picked.url)
        } else {
            guard let raw = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: raw) else { return }
            applyPhoto(raw: raw, image: image)
        }
    }

    /// The ONE place a video (library OR camera, Item 3b) becomes canvas media:
    /// thumbnail, duration + filmstrip, a LEGAL default trim window, and the
    /// looping preview player. Both sources converge here, so nothing
    /// downstream (trim/burn/send) forks.
    @MainActor
    private func applyVideo(url: URL) async {
        discardVideoIfAny()
        let thumb = await Self.firstFrame(of: url)
        media = .video(url: url, thumb: thumb)
        overlays = []                      // fresh canvas; no text-on-video until f
        selectedOverlay = nil
        let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        videoDuration = seconds
        trimSelection = 0...min(seconds, VideoTranscoder.maxClipSeconds)
        videoThumbs = await Self.filmstrip(of: url)
        // Only manage the audio session for a clip that actually HAS sound —
        // a silent video must never interrupt the user's music.
        let hasAudio = await Self.hasAudioTrack(url)
        setupPlayer(url: url, hasAudio: hasAudio)
    }

    /// Camera video (Item 3b): copy out of the picker's temp location to our
    /// own owned temp (deletable by `discardVideoIfAny`), then the SAME
    /// `applyVideo` path a library clip takes.
    @MainActor
    private func acceptCameraVideo(_ url: URL) async {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("cam-\(UUID().uuidString).mov")
        let sendURL = (try? FileManager.default.copyItem(at: url, to: dest)) != nil ? dest : url
        await applyVideo(url: sendURL)
    }

    /// The ONE place a photo (library OR camera, Item 3a) becomes canvas media.
    /// EXIF-normalize here: a camera portrait arrives as landscape pixels + an
    /// orientation flag; the engine flattens in raw pixel space, so the canvas
    /// image (preview frame AND burn base) must be `.up` at scale 1 or the burn
    /// lands on rotated pixels. Resets the video/trim state a photo doesn't use.
    @MainActor
    private func applyPhoto(raw: Data, image: UIImage) {
        discardVideoIfAny()
        media = .photo(raw: raw, image: Self.normalizedUp(image))
        overlays = []
        selectedOverlay = nil
        videoDuration = 0
        videoThumbs = []
        trimSelection = 0...0
    }

    /// TRIM pre-gate, display/gating only: post is disabled while the
    /// selected window exceeds the transcoder's duration cap. The gates
    /// themselves are untouched and still run on the trimmed file's bytes.
    private var selectionOverCap: Bool {
        guard case .video = media else { return false }
        return (trimSelection.upperBound - trimSelection.lowerBound)
            > VideoTranscoder.maxClipSeconds
    }

    /// First frame for the canvas preview. `appliesPreferredTrackTransform`
    /// so a portrait clip previews upright — the same trap the stage-f burn
    /// pass handles in the export path.
    private static func firstFrame(of url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        guard let cg = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Whether the clip carries any audio track — decides if the trim preview
    /// manages the shared audio session at all. A load failure returns false
    /// (treat as silent → never interrupt other apps' audio).
    private static func hasAudioTrack(_ url: URL) async -> Bool {
        let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        return tracks?.isEmpty == false
    }

    /// Post the canvas as a story through the proven paths. Photo: downscale +
    /// fire-and-forget, dismiss immediately (the optimistic row is the
    /// progress UI). Video: hold the sheet through the transcode so the two
    /// gates can refuse HERE with the chat path's copy, then hand the wire
    /// bytes to a detached send and dismiss.
    private func post() {
        guard let media, !posting else { return }
        posting = true
        switch media {
        case .photo(let raw, let image):
            Task { @MainActor in
                // E2: flatten via the ENGINE at source resolution, then the
                // proven downscale. No overlay → the raw bytes ride exactly
                // the stage-b path. With an overlay: PNG into the downscale
                // (lossless intermediate, ONE JPEG at the end — the fidelity
                // suite's Case 4 path), flattened on the SAME normalized
                // image the preview framed.
                let sendData = overlays.isEmpty
                    ? raw
                    : StoryTextEngine.flatten(base: image, overlays: overlays).pngData()
                guard let sendData,
                      let jpeg = StreamView.meshSizedJPEG(from: sendData) else { return }
                await inbox.sendMedia(jpeg, mime: .jpeg, in: conversation, isStory: true)
            }
            dismiss()
        case .video(let url, _):
            Task { @MainActor in
                do {
                    // TRIM: a full-clip selection skips the trim pass and
                    // posts exactly like stage d; a real trim is a LOSSLESS
                    // passthrough export of the selected range (no re-encode;
                    // the in-point snaps back to the previous keyframe),
                    // handed to the UNTOUCHED transcoder, whose gates fire on
                    // the trimmed file's true bytes.
                    let fullClip = trimSelection.lowerBound < 0.01
                        && trimSelection.upperBound > videoDuration - 0.01
                    let trimmedURL = fullClip
                        ? url
                        : try await Self.exportTrimmed(url: url, range: trimSelection)
                    // f: burn text into the TRIMMED source (trim → burn →
                    // transcode), so the gates fire on the true final bytes.
                    let sendURL = overlays.isEmpty
                        ? trimmedURL
                        : try await StoryVideoBurner.burn(url: trimmedURL, overlays: overlays)
                    let mp4 = try await VideoTranscoder.transcodeToMP4(from: sendURL)
                    if sendURL != trimmedURL { try? FileManager.default.removeItem(at: sendURL) }
                    if trimmedURL != url { try? FileManager.default.removeItem(at: trimmedURL) }
                    try? FileManager.default.removeItem(at: url)
                    Task { await inbox.sendMedia(mp4, mime: .mp4, in: conversation, isStory: true) }
                    dismiss()
                } catch VideoTranscoderError.clipTooLong(let seconds) {
                    videoNotice = "that clip runs \(Int(seconds))s — the water carries up to \(Int(VideoTranscoder.maxClipSeconds))s"
                    posting = false
                } catch VideoTranscoderError.overBudget {
                    videoNotice = "that clip is too heavy to carry, even compressed"
                    posting = false
                } catch {
                    videoNotice = "the clip couldn't be prepared"
                    posting = false
                }
            }
        }
    }

    /// Lossless container-level trim of the selected range — passthrough
    /// preset, so nothing is re-encoded and the composer pays no generation
    /// loss ahead of the transcoder's one real encode. Own error type on
    /// purpose: this is composer plumbing, not the transcoder's.
    private enum TrimError: Error { case exportFailed }

    private static func exportTrimmed(url: URL, range: ClosedRange<Double>) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw TrimError.exportFailed
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        session.outputURL = out
        session.outputFileType = .mov
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
            end: CMTime(seconds: range.upperBound, preferredTimescale: 600))

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw TrimError.exportFailed
        }
        return out
    }

    /// Evenly spaced frames for the scrubber strip, small on purpose (memory)
    /// and transform-applied so a portrait clip's strip reads upright.
    private static func filmstrip(of url: URL, count: Int = 8) async -> [UIImage] {
        let asset = AVURLAsset(url: url)
        guard let seconds = try? await asset.load(.duration).seconds, seconds > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 0, height: 120)
        var out: [UIImage] = []
        for i in 0..<count {
            let t = seconds * (Double(i) + 0.5) / Double(count)
            if let cg = try? await generator.image(
                at: CMTime(seconds: t, preferredTimescale: 600)).image {
                out.append(UIImage(cgImage: cg))
            }
        }
        return out
    }

    // MARK: Text editor (E2 + h1)

    /// The T tool: adds a text block. First (and only, this stage) entry on
    /// the rail; more tools land in later versions without touching the
    /// pipeline.
    private var toolRail: some View {
        Button { beginTextEdit(index: nil) } label: {
            Text("T")
                .stillwaterSerif(20, color: Stillwater.Palette.foam)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.black.opacity(0.35)))
                .overlay(Circle().strokeBorder(Stillwater.Palette.biolume.opacity(0.4)))
        }
        .buttonStyle(.plain)
    }

    /// All blocks, each its own sticker: the ENGINE's transform with the
    /// preview frame, framed to the ENGINE's measured block so wraps match
    /// the burn. `.position` takes the transform's translation — no placement
    /// is computed here. The block being text-edited is hidden (the editor
    /// scrim shows it); the others stay put.
    @ViewBuilder
    private func overlayLayer(frame: CGSize) -> some View {
        ForEach(overlays.indices, id: \.self) { i in
            if !(editingText && editingIndex == i) {
                blockView(i, frame: frame)
            }
        }
    }

    private func blockView(_ i: Int, frame: CGSize) -> some View {
        let o = overlays[i]
        let t = StoryTextEngine.transform(center: o.center,
                                          rotation: o.rotation,
                                          in: frame)
        let block = StoryTextEngine.measuredBlockSize(of: o, in: frame)
        return Text(o.string)
            .font(Font(o.font.uiFont(pointSize: o.height * frame.height) as CTFont))
            .foregroundStyle(Color(o.color.uiColor))
            .shadow(color: Color(o.color.strokeUIColor), radius: 1)
            .multilineTextAlignment(textAlignment(o.alignment))
            .frame(width: block.width * frame.width,
                   height: block.height * frame.height,
                   alignment: frameAlignment(o.alignment))
            .overlay {
                // Selection ring — a view artifact only; the burn never
                // sees it.
                if selectedOverlay == i {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Stillwater.Palette.biolume.opacity(0.6), lineWidth: 1)
                        .padding(-6)
                }
            }
            .rotationEffect(.radians(Double(o.rotation)))
            .position(x: t.tx, y: t.ty)
            .gesture(dragGesture(index: i, frame: frame)
                .simultaneously(with: rotateGesture(index: i)))
            .onTapGesture { tapBlock(i) }
    }

    /// Tap once to select; tap the selected block to edit its text.
    private func tapBlock(_ i: Int) {
        if selectedOverlay == i {
            beginTextEdit(index: i)
        } else {
            selectedOverlay = i
        }
    }

    private func dragGesture(index: Int, frame: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard overlays.indices.contains(index) else { return }
                selectedOverlay = index          // dragging selects
                var o = overlays[index]
                let start = dragStartCenter ?? o.center
                dragStartCenter = start
                // The ONLY arithmetic the composer adds: gesture points →
                // fraction deltas (the INPUT direction). The clamp is the
                // engine's, against the MEASURED text block — free drag on
                // both axes, the real block held fully on-frame.
                let proposed = CGPoint(
                    x: start.x + value.translation.width / frame.width,
                    y: start.y + value.translation.height / frame.height)
                o.center = StoryTextEngine.clampedCenter(
                    proposed,
                    blockSize: StoryTextEngine.measuredBlockSize(of: o, in: frame),
                    rotation: o.rotation,
                    in: frame)
                overlays[index] = o
            }
            .onEnded { _ in dragStartCenter = nil }
    }

    private func rotateGesture(index: Int) -> some Gesture {
        RotateGesture()
            .onChanged { value in
                guard overlays.indices.contains(index) else { return }
                selectedOverlay = index
                var o = overlays[index]
                let start = rotationStart ?? o.rotation
                rotationStart = start
                o.rotation = start + CGFloat(value.rotation.radians)
                overlays[index] = o
            }
            .onEnded { _ in rotationStart = nil }
    }

    /// Full-screen edit scrim: type, "done" (or tap away) commits; an empty
    /// commit removes the block. 80-char cap, ≤3 lines.
    private var textEditor: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { commitText() }
            VStack(spacing: 16) {
                TextField("say it", text: $draftText, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($textFieldFocused)
                    .multilineTextAlignment(.center)
                    .font(Font(StoryTextEngine.referenceFont(pointSize: 22) as CTFont))
                    .foregroundStyle(Color.white)
                    .tint(Stillwater.Palette.biolume)
                    .padding(.horizontal, 30)
                    .onChange(of: draftText) { _, new in
                        if new.count > Self.maxTextLength {
                            draftText = String(new.prefix(Self.maxTextLength))
                        }
                    }
                Button { commitText() } label: {
                    Text("done")
                        .stillwaterMono(9, trackingEm: 0.24, color: Stillwater.Palette.biolume)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private static let maxTextLength = 80
    /// E1's ONE reference size: glyph height 5% of frame height.
    private static let referenceTextHeight: CGFloat = 0.05

    /// Open the editor for block `index`, or for a NEW block (nil — the T
    /// tool's path). Photo AND video canvases (stage f).
    private func beginTextEdit(index: Int?) {
        guard media != nil, !editingText else { return }
        editingIndex = index
        draftText = index.flatMap { overlays.indices.contains($0) ? overlays[$0].string : nil } ?? ""
        editingText = true
        textFieldFocused = true
    }

    private func commitText() {
        editingText = false
        textFieldFocused = false
        defer { editingIndex = nil }
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = editingIndex, overlays.indices.contains(i) {
            if text.isEmpty {
                overlays.remove(at: i)
                selectedOverlay = nil
            } else {
                overlays[i].string = text
                selectedOverlay = i
            }
        } else {
            guard !text.isEmpty else { return }
            // Stagger fresh blocks down the middle so a second add doesn't
            // land invisibly on the first.
            let y = 0.42 + 0.08 * CGFloat(overlays.count % 4)
            overlays.append(StoryTextOverlay(string: text,
                                             center: CGPoint(x: 0.5, y: y),
                                             height: Self.referenceTextHeight,
                                             rotation: 0,
                                             alignment: .center))
            selectedOverlay = overlays.count - 1
        }
    }

    /// The per-block panel for the SELECTED block. Two rows: appearance
    /// (color · font · delete) and layout (alignment · size). Appearance
    /// fills and sizes glyphs — it never moves them; placement stays the
    /// engine's.
    private func selectedBlockPanel(_ i: Int) -> some View {
        VStack(spacing: 10) {
            // Colors — scrollable strip (white/black + house tones + accent
            // hues), so a fuller palette never crowds the row.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Array(StoryTextColor.allCases.enumerated()), id: \.offset) { _, c in
                        colorSwatch(i, c)
                    }
                }
                .padding(.horizontal, 2)
            }

            // Fonts — scrollable strip, each previewed in its own face.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(StoryTextFont.allCases.enumerated()), id: \.offset) { _, f in
                        fontButton(i, f)
                    }
                }
                .padding(.horizontal, 2)
            }

            // Size + delete. Alignment buttons removed earlier (operator call):
            // the overlay keeps its `alignment` field, blocks default .center.
            HStack(spacing: 16) {
                Slider(value: Binding(
                    get: { overlays.indices.contains(i) ? overlays[i].height : Self.referenceTextHeight },
                    set: { if overlays.indices.contains(i) { overlays[i].height = $0 } }
                ), in: 0.03...0.12)
                .tint(Stillwater.Palette.biolume)

                Button {
                    overlays.remove(at: i)
                    selectedOverlay = nil
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Stillwater.Palette.mistDim)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 260)
        }
    }

    private func colorSwatch(_ i: Int, _ c: StoryTextColor) -> some View {
        Button {
            guard overlays.indices.contains(i) else { return }
            overlays[i].color = c
        } label: {
            Circle()
                .fill(Color(c.uiColor))
                .frame(width: 20, height: 20)
                .overlay(
                    Circle().strokeBorder(
                        overlays.indices.contains(i) && overlays[i].color == c
                            ? Stillwater.Palette.biolume
                            : Stillwater.Palette.mistDimmest.opacity(0.5),
                        lineWidth: overlays.indices.contains(i) && overlays[i].color == c ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func fontButton(_ i: Int, _ f: StoryTextFont) -> some View {
        Button {
            guard overlays.indices.contains(i) else { return }
            overlays[i].font = f
        } label: {
            Text("Aa")
                .font(Font(f.uiFont(pointSize: 15) as CTFont))
                .foregroundStyle(overlays.indices.contains(i) && overlays[i].font == f
                                 ? Stillwater.Palette.biolume
                                 : Stillwater.Palette.mistDim)
        }
        .buttonStyle(.plain)
    }

    private func textAlignment(_ a: NSTextAlignment) -> TextAlignment {
        switch a {
        case .left: return .leading
        case .right: return .trailing
        default: return .center
        }
    }

    private func frameAlignment(_ a: NSTextAlignment) -> Alignment {
        switch a {
        case .left: return .leading
        case .right: return .trailing
        default: return .center
        }
    }

    /// EXIF-normalize a picked photo to .up at scale 1 (one renderer pass) —
    /// see the loadPicked comment. The fidelity tests couldn't catch this:
    /// their bases are renderer-made and always .up.
    private static func normalizedUp(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up && image.scale == 1 { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// Delete the picker's temp copy of a canvas video (replacement, dismiss,
    /// or after a successful transcode) and tear down its preview player.
    /// `try?` — a second call is a no-op.
    private func discardVideoIfAny() {
        teardownPlayer()
        if case .video(let url, _) = media {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Trim preview (playhead scrub + play the selection)

    @MainActor
    private func setupPlayer(url: URL, hasAudio: Bool) {
        teardownPlayer()
        let p = AVPlayer(url: url)
        p.actionAtItemEnd = .none   // we handle the boundary ourselves
        // Managed audio only for a clip with sound; a silent clip stays out of
        // the shared session entirely (never interrupts other apps' audio).
        if hasAudio { activatePreviewAudio() }
        // 30 Hz playhead; LOOP the selected [in, out] window — at OUT, seek
        // back to IN and keep playing so the user always sees exactly the
        // segment that will post. Scrubbing a handle just moves the bounds.
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main) { time in
            playhead = time.seconds
            if isPlaying, time.seconds >= trimSelection.upperBound {
                p.seek(to: CMTime(seconds: trimSelection.lowerBound, preferredTimescale: 600),
                       toleranceBefore: .zero, toleranceAfter: .zero)
                playhead = trimSelection.lowerBound
            }
        }
        player = p
        playhead = 0
        // Auto-start the loop so the trim preview is live from the moment the
        // video lands, not tap-to-play.
        startLoop()
    }

    /// Play the selected window from the IN handle and keep it looping (the
    /// periodic observer wraps at OUT). Idempotent.
    @MainActor
    private func startLoop() {
        guard let player else { return }
        playhead = trimSelection.lowerBound
        isPlaying = true
        player.seek(to: CMTime(seconds: trimSelection.lowerBound, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            player.play()
        }
    }

    private func teardownPlayer() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        player?.pause()
        player = nil
        timeObserver = nil
        playhead = nil
        isPlaying = false
        deactivatePreviewAudio()   // hand audio back so other apps resume
    }

    /// Trim-preview audio, managed like VoicePlayer/VoiceRecorder: activate
    /// `.playback` only while a video preview is live (the video path is the
    /// only caller — a photo story never creates a player, so it never reaches
    /// here) so the user HEARS the clip while trimming. Deactivated on
    /// teardown with `.notifyOthersOnDeactivation` so Music/Spotify/podcast
    /// RESUMES. Uses AVAudioSession DIRECTLY — not the RTCAudioSession the call
    /// layer manages; the composer is unreachable during an active call (the
    /// call overlay covers the app), so the two never contend.
    private func activatePreviewAudio() {
        guard !previewAudioActive else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        previewAudioActive = true
    }

    private func deactivatePreviewAudio() {
        guard previewAudioActive else { return }
        previewAudioActive = false
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Strip drag: pause and show that exact frame (zero-tolerance seek).
    private func scrub(to seconds: Double) {
        guard let player else { return }
        player.pause()
        isPlaying = false
        let clamped = min(max(seconds, trimSelection.lowerBound), trimSelection.upperBound)
        playhead = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Play the SELECTED segment: from the playhead if it sits inside the
    /// window, else from the IN handle; the periodic observer stops at OUT.
    private func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }
        let start = playhead ?? trimSelection.lowerBound
        let from = (start < trimSelection.lowerBound || start >= trimSelection.upperBound - 0.05)
            ? trimSelection.lowerBound : start
        playhead = from
        isPlaying = true
        player.seek(to: CMTime(seconds: from, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            player.play()
        }
    }

    // MARK: Pills (Stillwater house shapes)
    private func pill(_ text: String) -> some View {
        Text(text)
            .stillwaterSerif(17, weight: .medium, color: Stillwater.Palette.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 26).fill(Stillwater.Palette.biolume))
    }

    private func outlinePill(_ text: String) -> some View {
        Text(text)
            .stillwaterSerif(15, color: Stillwater.Palette.biolume)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 23)
                    .strokeBorder(Stillwater.Palette.biolume.opacity(0.4))
            )
    }
}

// MARK: - In-composer camera capture (Item 3a photo + 3b video)

/// The system camera, wrapped for the story composer. Offers BOTH photo and
/// video via the native camera's own mode toggle (`mediaTypes` carries image +
/// movie); the delegate routes an image to `onPhoto` and a movie URL to
/// `onVideo`. Captured media converges on the composer's `applyPhoto` /
/// `applyVideo` — the SAME pipelines as a library pick, so nothing downstream
/// forks. Video is capped at the wire clip limit at capture time. Camera
/// hardware only; the composer hides the entry where no camera exists, so this
/// is never presented on the simulator.
struct StoryCameraCapture: UIViewControllerRepresentable {
    let onPhoto: (UIImage) -> Void
    let onVideo: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image", "public.movie"]   // native photo/video toggle
        picker.videoMaximumDuration = VideoTranscoder.maxClipSeconds
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: StoryCameraCapture
        init(_ parent: StoryCameraCapture) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL {
                parent.onVideo(url)
            } else if let image = info[.originalImage] as? UIImage {
                parent.onPhoto(image)
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}
