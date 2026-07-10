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
//  STAGE d: photo AND video, no text tools yet. The canvas is a plain
//  aspect-fit preview this stage; the fractional-geometry overlay model lands
//  with the text engine (stage e).
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

    /// TRIM (T1): the scrubber's inputs + selection, populated on video load.
    /// Defaults keep the clip LEGAL — in = 0, out = min(duration, cap) — so a
    /// ≤60s source opens fully selected and posts exactly like stage d.
    /// Selecting past the cap is allowed; it only disables post + turns the
    /// readout (the transcoder's gates stay the backstop on the real bytes).
    @State private var videoDuration: Double = 0
    @State private var videoThumbs: [UIImage] = []
    @State private var trimSelection: ClosedRange<Double> = 0...0
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

                canvas
                    .padding(.horizontal, 24)

                if case .video = media, videoDuration > 0 {
                    StoryTrimScrubber(thumbnails: videoThumbs,
                                      duration: videoDuration,
                                      legalCap: VideoTranscoder.maxClipSeconds,
                                      selection: $trimSelection)
                        .padding(.horizontal, 30)
                        .padding(.top, 14)
                        .disabled(posting)
                }

                Spacer(minLength: 16)

                footer
                    .padding(.horizontal, 30)
                    .padding(.bottom, 30)
            }
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task { await loadPicked(item) }
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
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .video(_, let thumb):
            ZStack {
                if let thumb {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                } else {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(Stillwater.Palette.biolume.opacity(0.25))
                        .overlay {
                            Text("video ready")
                                .stillwaterMono(9, trackingEm: 0.24, color: Stillwater.Palette.mistDimmest)
                        }
                }
                Image(systemName: "play.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Stillwater.Palette.foam.opacity(0.85))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            PhotosPicker(selection: $pickedItem,
                         matching: .any(of: [.images, .videos]),
                         photoLibrary: .shared()) {
                outlinePill("pick a photo or video")
            }
            .buttonStyle(.plain)
        } else {
            VStack(spacing: 12) {
                Button(action: post) {
                    pill(posting ? "posting…" : "post story")
                }
                .buttonStyle(.plain)
                .disabled(posting || selectionOverCap)
                .opacity(selectionOverCap ? 0.4 : 1.0)

                PhotosPicker(selection: $pickedItem,
                             matching: .any(of: [.images, .videos]),
                             photoLibrary: .shared()) {
                    Text("choose another")
                        .stillwaterMono(8, trackingEm: 0.22, color: Stillwater.Palette.mistDim)
                }
                .buttonStyle(.plain)
                .disabled(posting)

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
            discardVideoIfAny()
            let thumb = await Self.firstFrame(of: picked.url)
            media = .video(url: picked.url, thumb: thumb)
            // TRIM inputs: duration + filmstrip, and a LEGAL default window.
            let seconds = (try? await AVURLAsset(url: picked.url).load(.duration).seconds) ?? 0
            videoDuration = seconds
            trimSelection = 0...min(seconds, VideoTranscoder.maxClipSeconds)
            videoThumbs = await Self.filmstrip(of: picked.url)
        } else {
            guard let raw = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: raw) else { return }
            discardVideoIfAny()
            media = .photo(raw: raw, image: image)
            videoDuration = 0
            videoThumbs = []
            trimSelection = 0...0
        }
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

    /// Post the canvas as a story through the proven paths. Photo: downscale +
    /// fire-and-forget, dismiss immediately (the optimistic row is the
    /// progress UI). Video: hold the sheet through the transcode so the two
    /// gates can refuse HERE with the chat path's copy, then hand the wire
    /// bytes to a detached send and dismiss.
    private func post() {
        guard let media, !posting else { return }
        posting = true
        switch media {
        case .photo(let raw, _):
            Task { @MainActor in
                guard let jpeg = StreamView.meshSizedJPEG(from: raw) else { return }
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
                    let sendURL = fullClip
                        ? url
                        : try await Self.exportTrimmed(url: url, range: trimSelection)
                    let mp4 = try await VideoTranscoder.transcodeToMP4(from: sendURL)
                    if sendURL != url { try? FileManager.default.removeItem(at: sendURL) }
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

    /// Delete the picker's temp copy of a canvas video (replacement, dismiss,
    /// or after a successful transcode). `try?` — a second call is a no-op.
    private func discardVideoIfAny() {
        if case .video(let url, _) = media {
            try? FileManager.default.removeItem(at: url)
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
