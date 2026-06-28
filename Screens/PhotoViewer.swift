//
//  PhotoViewer.swift
//  Screens
//
//  Fullscreen photo viewer, presented when a photo bubble is tapped.
//
//  Calm + dark: the image sits on pure black, fit to the screen. Pinch or
//  double-tap to zoom; pan while zoomed; swipe down (or the ✕) to dismiss.
//  No chrome beyond the close affordance — the photo is the subject.
//
//  Pure system colors only (black / white): a photo viewer wants a true
//  black surround, independent of the app's design tokens.
//

import SwiftUI
import UIKit

struct PhotoViewer: View {

    let image: UIImage

    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    /// Tracks a downward drag while at 1×, for the swipe-to-dismiss feel.
    @State private var dismissDrag: CGFloat = 0

    private static let minScale: CGFloat = 1
    private static let maxScale: CGFloat = 4
    private static let zoomedScale: CGFloat = 2.5
    private static let dismissThreshold: CGFloat = 120

    var body: some View {
        ZStack {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(x: offset.width,
                        y: offset.height + dismissDrag)
                .gesture(magnify)
                .simultaneousGesture(drag)
                .onTapGesture(count: 2) { toggleZoom() }

            closeButton
        }
        .statusBarHidden(true)
    }

    // MARK: - Close

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.white.opacity(0.16)))
                }
                .accessibilityLabel("Close")
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .opacity(dismissDrag > 0 ? 0 : 1)
    }

    // MARK: - Derived

    /// Fades the black surround as the photo is dragged down to dismiss.
    private var backgroundOpacity: Double {
        let progress = min(Double(dismissDrag) / 400, 1)
        return 1 - progress * 0.85
    }

    // MARK: - Gestures

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(lastScale * value.magnification,
                                Self.minScale), Self.maxScale)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= Self.minScale {
                    resetTransform()
                }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1 {
                    // Pan the zoomed image.
                    offset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                } else {
                    // At 1×, only a downward pull arms the dismiss.
                    dismissDrag = max(0, value.translation.height)
                }
            }
            .onEnded { _ in
                if scale > 1 {
                    lastOffset = offset
                } else if dismissDrag > Self.dismissThreshold {
                    dismiss()
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { dismissDrag = 0 }
                }
            }
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.22)) {
            if scale > 1 {
                resetTransform()
            } else {
                scale = Self.zoomedScale
                lastScale = Self.zoomedScale
            }
        }
    }

    private func resetTransform() {
        withAnimation(.easeOut(duration: 0.2)) {
            scale = 1
            lastScale = 1
            offset = .zero
            lastOffset = .zero
        }
    }
}
