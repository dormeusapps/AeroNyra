//
//  StoryComposerView.swift
//  Stories
//
//  STILLWATER · Stories composer (Plan B, stage a1 STUB).
//
//  The full-screen home for composing a story: pick photo/video, place it on
//  an editing canvas, overlay text, flatten, and hand the flat bytes to the
//  proven `MessageInbox.sendMedia(isStory: true)` pipeline. The wire, the
//  receiver, expiry, and the bubble never learn there was an editing layer —
//  every future tool (text now; more later) is a composer-side change only.
//
//  THIS FILE IS THE a1 STUB: it exists to prove the `Stories/` sync-folder
//  is registered and linked (SwiftFileList + debug-dylib symbol), and to give
//  the a2 entry point something to present. It opens and dismisses; the
//  picker, canvas, and post land in stages b–f.
//

import SwiftUI

struct StoryComposerView: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Stillwater.Palette.abyss.ignoresSafeArea()

            VStack(spacing: 8) {
                Text("Story")
                    .stillwaterSerif(30, color: Stillwater.Palette.foam)
                Text("composer arrives here")
                    .stillwaterMono(9, trackingEm: 0.28, color: Stillwater.Palette.mistDim)
            }

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Text("close")
                            .stillwaterMono(9, trackingEm: 0.24, color: Stillwater.Palette.mistDim)
                    }
                    .buttonStyle(.plain)
                    .padding(20)
                    Spacer()
                }
                Spacer()
            }
        }
    }
}

// MARK: - Preview
#Preview("Stillwater — Story Composer") {
    StoryComposerView()
}
