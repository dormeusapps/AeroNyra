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
//  E1-REDUX (sticker model): the block is sized to the MEASURED text — not a
//  fixed frame fraction — so a caption drags anywhere the clamp allows.
//  `measuredBlockSize` is the one new surface; transform/clampedCenter/
//  flatten and the DrawContent seam are unchanged (the kept fidelity
//  literals prove it).
//

import UIKit
import SwiftUI   // h2: UIColor(_ color: Color) bridging for the palette

// MARK: - Appearance (h2 — fills and sizes glyphs, never moves them)

/// The story-text palette. White + black are the legibility essentials over
/// varied media; the house tones (foam/abyss/biolume) and the app's accent
/// hues fill out the brights. The hue set is REUSED from `Stillwater.Accent`
/// — one source of truth, no duplicated hex. Stored on the block as a stable
/// enum id (never a raw color on the wire — flatten bakes it).
enum StoryTextColor: CaseIterable {
    case white, black, foam, abyss, biolume, cyan, aqua, violet, rose, coral, amber, lime

    var uiColor: UIColor {
        switch self {
        case .white:   return .white
        case .black:   return .black
        case .foam:    return UIColor(Stillwater.Palette.foam)
        case .abyss:   return UIColor(Stillwater.Palette.abyss)
        case .biolume: return UIColor(Stillwater.Palette.biolume)
        case .cyan:    return Self.accent("cyan")
        case .aqua:    return Self.accent("aqua")
        case .violet:  return Self.accent("violet")
        case .rose:    return Self.accent("rose")
        case .coral:   return Self.accent("coral")
        case .amber:   return Self.accent("amber")
        case .lime:    return Self.accent("lime")
        }
    }

    /// A hue from the app's accent presets (DesignSystem) by name — the ONE
    /// place these hexes live; falls back to biolume if a name ever drifts.
    private static func accent(_ name: String) -> UIColor {
        if let hex = Stillwater.Accent.presets.first(where: { $0.name == name })?.hex {
            return UIColor(Stillwater.Palette.hex(hex))
        }
        return UIColor(Stillwater.Palette.biolume)
    }

    /// Legibility stroke DERIVED from the fill's luminance — dark stroke behind
    /// a light fill, light stroke behind a dark one — so it scales to every
    /// color without a per-case table.
    var strokeUIColor: UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.5
            ? UIColor.black.withAlphaComponent(0.8)
            : UIColor.white.withAlphaComponent(0.8)
    }
}

/// The story-text faces — 8 visually DISTINCT looks, all on-device (no
/// bundled/custom fonts beyond the two house voices, zero licensing). Stored
/// on the block as a stable enum id (never a raw font name on the wire —
/// flatten bakes it), so it renders identically on send/receive. Every case
/// falls back to a system face if its named font is ever unavailable, so
/// there is no crash and no invisible text. `.serif` stays the default.
enum StoryTextFont: CaseIterable {
    case serif      // Newsreader (house serif)
    case sans       // San Francisco (system)
    case heavy      // system black weight
    case rounded    // SF Rounded
    case mono       // SplineSansMono (house mono / typewriter)
    case script     // Snell Roundhand (handwriting)
    case marker     // Marker Felt
    case condensed  // narrow heavy face

    func uiFont(pointSize: CGFloat) -> UIFont {
        switch self {
        case .serif:
            return Self.named("Newsreader14pt-Medium", pointSize, fallback: .serif)
        case .sans:
            return UIFont.systemFont(ofSize: pointSize, weight: .medium)
        case .heavy:
            return UIFont.systemFont(ofSize: pointSize, weight: .black)
        case .rounded:
            return Self.designed(.rounded, pointSize, weight: .semibold)
        case .mono:
            return Self.named("SplineSansMono-Regular", pointSize, fallback: .monospaced)
        case .script:
            return Self.named("SnellRoundhand-Bold", pointSize, fallback: .serif)
        case .marker:
            return Self.named("MarkerFelt-Wide", pointSize, fallback: .rounded)
        case .condensed:
            return Self.condensed(pointSize)
        }
    }

    /// A named face, falling back to a system-design face (never nil, never
    /// invisible).
    private static func named(_ name: String, _ size: CGFloat,
                              fallback design: UIFontDescriptor.SystemDesign) -> UIFont {
        if let font = UIFont(name: name, size: size) { return font }
        return designed(design, size, weight: .medium)
    }

    private static func designed(_ design: UIFontDescriptor.SystemDesign, _ size: CGFloat,
                                 weight: UIFont.Weight) -> UIFont {
        let system = UIFont.systemFont(ofSize: size, weight: weight)
        guard let d = system.fontDescriptor.withDesign(design) else { return system }
        return UIFont(descriptor: d, size: size)
    }

    /// A real condensed face if present, else system-bold squeezed via the
    /// width trait — always resolves.
    private static func condensed(_ size: CGFloat) -> UIFont {
        for name in ["HelveticaNeue-CondensedBold", "AvenirNextCondensed-Bold"] {
            if let font = UIFont(name: name, size: size) { return font }
        }
        let base = UIFont.systemFont(ofSize: size, weight: .bold)
        let desc = base.fontDescriptor.addingAttributes(
            [.traits: [UIFontDescriptor.TraitKey.width: -0.35]])
        return UIFont(descriptor: desc, size: size)
    }
}

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
    /// Appearance (h2). Defaults keep every pre-h2 call site — including the
    /// fidelity suite's literals — byte-identical.
    var color: StoryTextColor = .foam
    var font: StoryTextFont = .serif
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

    /// The default face — h2 moved the lookup into `StoryTextFont`; this
    /// stays as the serif shorthand (editor chrome, pre-h2 call sites).
    static func referenceFont(pointSize: CGFloat) -> UIFont {
        StoryTextFont.serif.uiFont(pointSize: pointSize)
    }

    /// STICKER MODEL (E1-redux): the block is the text's own measured
    /// bounds — text can sit anywhere the clamp allows, at any rotation.
    /// The only frame-relative bound left is the wrap ceiling: text longer
    /// than this fraction of the frame's width wraps.
    static let wrapWidthFraction: CGFloat = 0.9

    /// The measured text block, in FRACTIONS of the frame: width is the
    /// widest laid-out line (≤ the wrap ceiling), height the laid-out text
    /// height. This is what callers pass to `clampedCenter` so the REAL
    /// block — not a fixed frame fraction — stays on-frame. Shares the
    /// attributed-string builder with `drawText`, so measurement and drawing
    /// cannot drift.
    static func measuredBlockSize(of overlay: StoryTextOverlay,
                                  in frame: CGSize) -> CGSize {
        guard !overlay.string.isEmpty else { return .zero }
        let bounds = attributedString(for: overlay, in: frame).boundingRect(
            with: CGSize(width: frame.width * wrapWidthFraction,
                         height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil)
        return CGSize(width: bounds.width / frame.width,
                      height: bounds.height / frame.height)
    }

    /// The production drawer: white fill with a dark stroke (legible on any
    /// footage), drawn in a rect of exactly the MEASURED text size, centered
    /// on the transformed origin. `alignment` seats shorter lines within a
    /// multi-line block (whose width is the longest line) — on a single line
    /// it is a visual no-op, correctly.
    static func drawText(_ overlay: StoryTextOverlay, in frame: CGSize,
                         context: CGContext) {
        guard !overlay.string.isEmpty else { return }
        let attributed = attributedString(for: overlay, in: frame)
        let bounds = attributed.boundingRect(
            with: CGSize(width: frame.width * wrapWidthFraction,
                         height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil)
        attributed.draw(
            with: CGRect(x: -bounds.width / 2,
                         y: -bounds.height / 2,
                         width: ceil(bounds.width),
                         height: ceil(bounds.height)),
            options: [.usesLineFragmentOrigin],
            context: nil)
    }

    /// ONE builder for measurement and drawing — the text style lives here
    /// and nowhere else. h2: fill/face come from the overlay's appearance
    /// fields; the stroke flips dark↔light with the fill so any color stays
    /// legible on any footage.
    private static func attributedString(for overlay: StoryTextOverlay,
                                         in frame: CGSize) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = overlay.alignment
        return NSAttributedString(
            string: overlay.string,
            attributes: [
                .font: overlay.font.uiFont(pointSize: overlay.height * frame.height),
                .foregroundColor: overlay.color.uiColor,
                .strokeColor: overlay.color.strokeUIColor,
                .strokeWidth: -3,   // negative: stroke AND fill
                .paragraphStyle: paragraph,
            ])
    }
}
