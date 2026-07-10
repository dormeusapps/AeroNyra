//
//  StoryTextEngine.swift
//  Stories
//
//  STILLWATER · the story text engine (E1): geometry + flatten.
//
//  An overlay's geometry is stored as FRACTIONS of the frame — center
//  (fx, fy) ∈ [0,1]², glyph height as a fraction of frame height — never as
//  absolute points. Text is positioned on a preview-sized canvas but burns in
//  at source resolution; fractions are what make those the same place.
//
//  ONE conversion function (`transform(center:rotation:in:)`) turns fractions
//  into a pixel-space placement. The SwiftUI preview (points) and the flatten
//  (source pixels) both call IT with different frame sizes — there is no
//  second code path to drift. Convention, pinned by the fidelity suite
//  (StoryTextEngineTests): image space, y-DOWN, origin top-left; positive
//  rotation is CLOCKWISE on screen.
//
//  The flatten is a synchronous UIGraphicsImageRenderer pass at the base
//  image's pixel size, scale pinned to 1 (the meshSizedJPEG discipline) —
//  the flat result then rides the proven photo path, and the wire, receiver,
//  expiry, and bubble never learn there was text.
//
//  `DrawContent` is the testability seam: production draws the reference
//  text style; the fidelity tests inject solid marker blocks for exact-pixel
//  assertions. No test-only branch lives inside production drawing code.
//
//  E1 ships ONE reference style (Newsreader serif, white fill, dark stroke).
//  Color/font/size-styling and multiple blocks are a later appearance stage.
//

import UIKit

// MARK: - StoryTextOverlay

/// One text block on the story canvas, geometry in frame fractions.
struct StoryTextOverlay {
    var string: String
    /// Fractional center, (fx, fy) ∈ [0,1]².
    var center: CGPoint
    /// Glyph point size as a fraction of frame HEIGHT.
    var height: CGFloat
    /// Radians; positive is clockwise on screen (y-down image space).
    var rotation: CGFloat
    /// Line alignment INSIDE the block — never moves the block itself.
    var alignment: NSTextAlignment
}

// MARK: - StoryTextEngine

/// Namespace (case-less enum, house style — cannot be instantiated).
enum StoryTextEngine {

    /// Draw an overlay's content centered on the origin of an
    /// already-transformed context. `frame` is the full pixel frame, so the
    /// drawer can size its content fractionally (font = height × frame
    /// height; a test marker = its own fractions of the frame).
    typealias DrawContent = (StoryTextOverlay, CGSize, CGContext) -> Void

    // MARK: Geometry — THE conversion

    /// THE fraction→pixel conversion: translate to (fx·W, fy·H), then rotate
    /// by θ about that point. Preview and flatten both call this; nothing
    /// else computes placement.
    static func transform(center: CGPoint, rotation: CGFloat,
                          in frame: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: center.x * frame.width,
                          y: center.y * frame.height)
            .rotated(by: rotation)
    }

    /// Clamp a fractional center so the ROTATED block's axis-aligned bounding
    /// box stays fully on-frame (`blockSize` in frame fractions). Needs the
    /// frame because rotation trades the block's pixel width for pixel
    /// height — fractions of DIFFERENT dimensions. A block bigger than the
    /// frame pins to the middle rather than inverting its bounds.
    static func clampedCenter(_ center: CGPoint, blockSize: CGSize,
                              rotation: CGFloat, in frame: CGSize) -> CGPoint {
        let halfW = blockSize.width * frame.width / 2
        let halfH = blockSize.height * frame.height / 2
        let c = abs(cos(rotation))
        let s = abs(sin(rotation))
        let fxHalf = (halfW * c + halfH * s) / frame.width
        let fyHalf = (halfW * s + halfH * c) / frame.height
        let x = fxHalf >= 0.5 ? 0.5 : min(1 - fxHalf, max(fxHalf, center.x))
        let y = fyHalf >= 0.5 ? 0.5 : min(1 - fyHalf, max(fyHalf, center.y))
        return CGPoint(x: x, y: y)
    }

    // MARK: Flatten

    /// Composite `overlays` into `base` at its FULL pixel size and return the
    /// flat image. Scale pinned to 1: points == pixels, so a Pro-Motion
    /// screen scale can't touch the burn (the meshSizedJPEG discipline).
    static func flatten(base: UIImage,
                        overlays: [StoryTextOverlay],
                        drawContent: DrawContent = Self.drawText) -> UIImage {
        guard let cg = base.cgImage else { return base }
        let pixelSize = CGSize(width: cg.width, height: cg.height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        return renderer.image { ctx in
            base.draw(in: CGRect(origin: .zero, size: pixelSize))
            for overlay in overlays {
                ctx.cgContext.saveGState()
                ctx.cgContext.concatenate(
                    Self.transform(center: overlay.center,
                                   rotation: overlay.rotation,
                                   in: pixelSize))
                drawContent(overlay, pixelSize, ctx.cgContext)
                ctx.cgContext.restoreGState()
            }
        }
    }

    // MARK: Reference style (E1: the ONE style)

    /// Newsreader medium (the app's human voice; PostScript name has no
    /// hyphen after the family), with a serif-design system fallback so the
    /// engine still renders if the custom font ever fails to register.
    static func referenceFont(pointSize: CGFloat) -> UIFont {
        if let newsreader = UIFont(name: "Newsreader14pt-Medium", size: pointSize) {
            return newsreader
        }
        let system = UIFont.systemFont(ofSize: pointSize, weight: .medium)
        guard let serif = system.fontDescriptor.withDesign(.serif) else { return system }
        return UIFont(descriptor: serif, size: pointSize)
    }

    /// The production drawer: white fill with a dark stroke (legible on any
    /// footage), laid out in a block 90% of the frame's width so `alignment`
    /// has room to mean something, centered on the transformed origin.
    static func drawText(_ overlay: StoryTextOverlay, in frame: CGSize,
                         context: CGContext) {
        guard !overlay.string.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = overlay.alignment
        let attributed = NSAttributedString(
            string: overlay.string,
            attributes: [
                .font: referenceFont(pointSize: overlay.height * frame.height),
                .foregroundColor: UIColor.white,
                .strokeColor: UIColor.black.withAlphaComponent(0.8),
                .strokeWidth: -3,   // negative: stroke AND fill
                .paragraphStyle: paragraph,
            ])

        let blockWidth = frame.width * 0.9
        let bounds = attributed.boundingRect(
            with: CGSize(width: blockWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil)
        attributed.draw(
            with: CGRect(x: -blockWidth / 2,
                         y: -bounds.height / 2,
                         width: blockWidth,
                         height: ceil(bounds.height)),
            options: [.usesLineFragmentOrigin],
            context: nil)
    }
}
