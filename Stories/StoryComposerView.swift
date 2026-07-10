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
//  STAGE b: photo only, no text tools. The canvas is a plain aspect-fit
//  preview this stage; the fractional-geometry overlay model lands with the
//  text engine (stage e). Video routes in at stage d.
//
//  The composer owns compose + send, nothing downstream: the downscale is the
//  SAME `StreamView.meshSizedJPEG` the chat photo path ships (one
//  implementation, not a fork), and everything below `sendMedia` is the
//  shipped SEC-6 machinery, untouched.
//

import SwiftUI
import UIKit
import PhotosUI

struct StoryComposerView: View {

    /// Both handed in by the presenting stream (a story goes to ONE peer per
    /// send, as shipped) — the composer never resolves peers or conversations
    /// itself. Non-optional on purpose: no media surface without a live inbox.
    let inbox: MessageInbox
    let conversation: Conversation

    @Environment(\.dismiss) private var dismiss

    @State private var pickedItem: PhotosPickerItem?
    /// The picked photo, held as raw bytes (what `meshSizedJPEG` takes) plus
    /// the decoded image for the canvas preview.
    @State private var photoData: Data?
    @State private var photoImage: UIImage?
    /// Double-tap guard on the post pill; the sheet dismisses right after the
    /// send Task is spawned, mirroring the chat path's fire-and-forget.
    @State private var posting = false

    var body: some View {
        ZStack {
            Stillwater.Palette.abyss.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 8)

                Spacer(minLength: 16)

                canvas
                    .padding(.horizontal, 24)

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
    /// The editing canvas. Stage b renders the media alone; the text overlay
    /// layer (fractional geometry) grows HERE in stage e.
    @ViewBuilder
    private var canvas: some View {
        if let photoImage {
            Image(uiImage: photoImage)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Stillwater.Palette.biolume.opacity(0.25))
                .overlay {
                    Text("pick a photo to begin")
                        .stillwaterMono(9, trackingEm: 0.24, color: Stillwater.Palette.mistDimmest)
                }
        }
    }

    // MARK: Footer
    @ViewBuilder
    private var footer: some View {
        if photoImage == nil {
            PhotosPicker(selection: $pickedItem,
                         matching: .images,
                         photoLibrary: .shared()) {
                outlinePill("pick a photo")
            }
            .buttonStyle(.plain)
        } else {
            VStack(spacing: 12) {
                Button(action: post) {
                    pill(posting ? "posting…" : "post story")
                }
                .buttonStyle(.plain)
                .disabled(posting)

                PhotosPicker(selection: $pickedItem,
                             matching: .images,
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
    @MainActor
    private func loadPicked(_ item: PhotosPickerItem) async {
        defer { pickedItem = nil }
        guard let raw = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: raw) else { return }
        photoData = raw
        photoImage = image
    }

    /// Post the canvas as a story: the chat path's proven downscale, then the
    /// shipped story-capable send seam. Fire-and-forget like the chat sends —
    /// the optimistic row (with its delivery state) is the progress UI, so the
    /// sheet dismisses immediately.
    private func post() {
        guard let photoData, !posting else { return }
        posting = true
        Task { @MainActor in
            guard let jpeg = StreamView.meshSizedJPEG(from: photoData) else { return }
            await inbox.sendMedia(jpeg, mime: .jpeg, in: conversation, isStory: true)
        }
        dismiss()
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
