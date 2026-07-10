//
//  StoryTextEngineTests.swift
//  BeaconTests
//
//  Fidelity suite for the story text engine's fraction→pixel geometry
//  (E1 + E1-redux sticker model).
//
//  REFERENCE-FIRST: every expected pixel below is a HAND-COMPUTED literal from
//  the approved plan — never produced by the conversion function under test.
//  If the engine's math is wrong, these tests can disagree with it.
//
//  E1-REDUX (sticker block): the block is sized to the MEASURED text, not a
//  fixed frame fraction, so text drags anywhere. Cases 1–4 and the two clamp
//  literals are KEPT VERBATIM — they pin transform/flatten/clampedCenter,
//  which the model change does not touch (operator-reviewed ruling). New:
//  Case 5 (a formerly-unreachable position), the clamp identity, the
//  measurement relations, the text-extent bound; the alignment test moves to
//  its real sticker meaning (seating a short line in a multi-line block).
//
//  Solid marker blocks (injected through the flatten's content seam) carry the
//  exact-pixel assertions; text gets a smoke test and an alignment-centroid
//  test only (antialiased glyph edges can't be asserted exactly).
//
//  Convention under test (pinned in the plan): image space, y-DOWN, origin
//  top-left; positive rotation is CLOCKWISE as seen on screen.
//
//  Sampling: every marker sample sits ≥10 px from a block edge so antialiasing
//  can't touch it. Cases 1–3 sample the flatten's CGImage directly (exact);
//  Case 4 rides the real meshSizedJPEG downscale, so it asserts with JPEG
//  thresholds (white: red > 200, black: red < 60).
//
//  XCTest only (not Swift Testing), per project standard.
//

import XCTest
import UIKit
@testable import Beacon

final class StoryTextEngineTests: XCTestCase {

    // MARK: - Harness

    /// Solid black base of an exact pixel size (renderer scale pinned to 1).
    private func solidBlackBase(width: Int, height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// The test seam: a solid white marker block of FRACTIONAL size (fw, fh),
    /// drawn centered on the origin of the already-transformed context. The
    /// engine owns placement (translate + rotate); the drawer sizes itself
    /// from the frame exactly as the production text drawer sizes its font.
    private static func marker(fw: CGFloat, fh: CGFloat) -> StoryTextEngine.DrawContent {
        { _, frame, ctx in
            let w = fw * frame.width
            let h = fh * frame.height
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        }
    }

    private func overlay(fx: CGFloat, fy: CGFloat,
                         rotation: CGFloat = 0,
                         string: String = "",
                         alignment: NSTextAlignment = .center) -> StoryTextOverlay {
        StoryTextOverlay(string: string,
                         center: CGPoint(x: fx, y: fy),
                         height: 0.05,
                         rotation: rotation,
                         alignment: alignment)
    }

    /// RGBA8 readback in y-down, top-left-origin coordinates.
    private struct Bitmap {
        let px: [UInt8]
        let width: Int
        let height: Int

        init(_ image: UIImage) throws {
            let cg = try XCTUnwrap(image.cgImage)
            let w = cg.width, h = cg.height
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = try XCTUnwrap(CGContext(
                data: &data, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            px = data
            width = w
            height = h
        }

        func red(_ x: Int, _ y: Int) -> UInt8 { px[(y * width + x) * 4] }
    }

    private func assertWhite(_ b: Bitmap, _ x: Int, _ y: Int,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(b.red(x, y), 200, "expected WHITE at (\(x), \(y))",
                             file: file, line: line)
    }

    private func assertBlack(_ b: Bitmap, _ x: Int, _ y: Int,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(b.red(x, y), 60, "expected BLACK at (\(x), \(y))",
                          file: file, line: line)
    }

    // MARK: - Case 1 · translation, no rotation
    // Base 3000×2000. Marker center (0.25, 0.75), size (0.10, 0.05).
    // Hand math: center = (750, 1500); block 300×100 → x∈[600,900], y∈[1450,1550].
    func testCase1_translationPlacesMarkerAtHandComputedPixels() throws {
        let flat = StoryTextEngine.flatten(
            base: solidBlackBase(width: 3000, height: 2000),
            overlays: [overlay(fx: 0.25, fy: 0.75)],
            drawContent: Self.marker(fw: 0.10, fh: 0.05))
        let b = try Bitmap(flat)

        assertWhite(b, 750, 1500)                 // block center
        assertWhite(b, 610, 1460)                 // inside corners, 10 px margin
        assertWhite(b, 890, 1540)
        assertBlack(b, 590, 1500)                 // 10 px outside left/right
        assertBlack(b, 910, 1500)
        assertBlack(b, 750, 1440)                 // 10 px outside top/bottom
        assertBlack(b, 750, 1560)
    }

    // MARK: - Case 2 · 90° rotation on a non-square frame (catches W/H swaps)
    // Base 2000×1000. Marker center (0.5, 0.5) → (1000, 500); size (0.20, 0.10)
    // → 400×100; θ = +90°. Rotated occupancy: x∈[950,1050], y∈[300,700].
    func testCase2_rightAngleRotationOnNonSquareFrame() throws {
        let flat = StoryTextEngine.flatten(
            base: solidBlackBase(width: 2000, height: 1000),
            overlays: [overlay(fx: 0.5, fy: 0.5, rotation: .pi / 2)],
            drawContent: Self.marker(fw: 0.20, fh: 0.10))
        let b = try Bitmap(flat)

        assertWhite(b, 1000, 500)                 // center is rotation-invariant
        assertWhite(b, 1000, 320)                 // inside rotated long axis —
        assertWhite(b, 1000, 680)                 //  un-rotated spans y∈[450,550] only
        assertBlack(b, 1060, 500)                 // no-rotation bug says inside (x∈[800,1200])
        assertBlack(b, 1000, 290)                 // beyond the rotated ends
        assertBlack(b, 1000, 710)
    }

    // MARK: - Case 3 · 30° rotation: sign + composition
    // Base 2000×2000. Marker center (0.5, 0.5) → (1000, 1000); size (0.30, 0.05)
    // → 600×100 (half-length 300, half-width 50); θ = +30° CLOCKWISE.
    // cos30 = 0.8660, sin30 = 0.5. Inside iff |u| ≤ 300, |v| ≤ 50 where
    // u = dx·cosθ + dy·sinθ, v = −dx·sinθ + dy·cosθ.
    //
    //  (1216, 1125) = center + (216.5, 125): u = 187.5+62.5 = 250 ✓, v = −108.25+108.25 = 0 ✓ → INSIDE.
    //   Under a FLIPPED sign (−30°): v = 108.25+108.25 = 216.5 > 50 → flipped paints it black.
    //  (1216, 875) = center + (216.5, −125): v = −108.25−108.25 = −216.5 → OUTSIDE.
    //   Under the flipped sign it's the inside point.
    //  (1250, 1000) = center + (250, 0): un-rotated says inside (|dx| ≤ 300, dy = 0);
    //   correct math: v = −250·0.5 = −125 → OUTSIDE. Kills no-rotation.
    func testCase3_thirtyDegreeRotationSignAndComposition() throws {
        let flat = StoryTextEngine.flatten(
            base: solidBlackBase(width: 2000, height: 2000),
            overlays: [overlay(fx: 0.5, fy: 0.5, rotation: .pi / 6)],
            drawContent: Self.marker(fw: 0.30, fh: 0.05))
        let b = try Bitmap(flat)

        assertWhite(b, 1000, 1000)                // center invariant
        assertWhite(b, 1216, 1125)                // kills sign-flipped rotation
        assertBlack(b, 1216, 875)                 // the mirror point
        assertBlack(b, 1250, 1000)                // kills no-rotation
    }

    // MARK: - Case 4 · end-to-end through the real downscale
    // Base 2560×1600 → meshSizedJPEG scale is exactly 0.5 → output 1280×800.
    // Marker center (0.25, 0.375) → source (640, 600), block 256×160
    // → source x∈[512,768], y∈[520,680]; after ×0.5: center (320, 300),
    // x∈[256,384], y∈[260,340]. JPEG thresholds; samples ≥10 px from edges.
    func testCase4_geometrySurvivesMeshSizedJPEGDownscale() throws {
        let flat = StoryTextEngine.flatten(
            base: solidBlackBase(width: 2560, height: 1600),
            overlays: [overlay(fx: 0.25, fy: 0.375)],
            drawContent: Self.marker(fw: 0.10, fh: 0.10))

        let png = try XCTUnwrap(flat.pngData())   // lossless into the downscale
        let jpeg = try XCTUnwrap(StreamView.meshSizedJPEG(from: png))
        let out = try XCTUnwrap(UIImage(data: jpeg))
        let b = try Bitmap(out)

        XCTAssertEqual(b.width, 1280)
        XCTAssertEqual(b.height, 800)

        assertWhite(b, 320, 300)                  // scaled block center
        assertWhite(b, 266, 270)                  // inside corners
        assertWhite(b, 374, 330)
        assertBlack(b, 246, 300)                  // outside, 10 px past edges
        assertBlack(b, 394, 300)
        assertBlack(b, 320, 250)
        assertBlack(b, 320, 350)
    }

    // MARK: - Case 5 · free placement at a formerly-unreachable position (E1-redux)
    // Frame 2000×1000; marker (0.10, 0.10) → 200×100; center (0.15, 0.80).
    // Old composer clamp (0.9-wide block) confined fx to [0.45, 0.55] — 0.15
    // was unreachable. Hand math: center = (300, 800); x∈[200,400], y∈[750,850].
    func testCase5_freePlacementAtFormerlyUnreachablePosition() throws {
        let flat = StoryTextEngine.flatten(
            base: solidBlackBase(width: 2000, height: 1000),
            overlays: [overlay(fx: 0.15, fy: 0.80)],
            drawContent: Self.marker(fw: 0.10, fh: 0.10))
        let b = try Bitmap(flat)

        assertWhite(b, 300, 800)                  // center
        assertWhite(b, 215, 765)                  // inside corners, ≥10 px margin
        assertWhite(b, 385, 835)
        assertBlack(b, 185, 800)                  // 15 px outside left/right
        assertBlack(b, 415, 800)
        assertBlack(b, 300, 740)                  // 10 px outside top/bottom
        assertBlack(b, 300, 860)
    }

    // MARK: - Clamp (pure math, plan literals)
    // Frame 1000×1000, block (0.10, 0.05).
    // θ = 0:   fx clamps to 1 − 0.10/2 = 0.95.
    // θ = 90°: the AABB half-width becomes the block's half-HEIGHT fraction
    //          → fx clamps to 1 − 0.025 = 0.975.
    func testClamp_unrotatedBlockStaysOnFrame() {
        let c = StoryTextEngine.clampedCenter(
            CGPoint(x: 0.99, y: 0.5),
            blockSize: CGSize(width: 0.10, height: 0.05),
            rotation: 0,
            in: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(c.x, 0.95, accuracy: 1e-9)
        XCTAssertEqual(c.y, 0.5, accuracy: 1e-9)
    }

    func testClamp_rotatedBlockClampsAgainstItsAABB() {
        let c = StoryTextEngine.clampedCenter(
            CGPoint(x: 0.99, y: 0.5),
            blockSize: CGSize(width: 0.10, height: 0.05),
            rotation: .pi / 2,
            in: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(c.x, 0.975, accuracy: 1e-9)
        XCTAssertEqual(c.y, 0.5, accuracy: 1e-9)
    }

    // E1-redux semantic pin: a real (small) block passes a formerly
    // unreachable position through UNCHANGED — legal band fx ∈ [0.05, 0.95]
    // contains 0.15, so the clamp is the identity there.
    func testClamp_smallBlockPermitsFreeHorizontalPlacement() {
        let c = StoryTextEngine.clampedCenter(
            CGPoint(x: 0.15, y: 0.5),
            blockSize: CGSize(width: 0.10, height: 0.05),
            rotation: 0,
            in: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(c.x, 0.15, accuracy: 1e-9)
        XCTAssertEqual(c.y, 0.5, accuracy: 1e-9)
    }

    // MARK: - Measurement (E1-redux; relational — glyph metrics aren't
    // hand-computable, so these pin RELATIONS, never fake literals)
    private let squareFrame = CGSize(width: 1000, height: 1000)

    func testMeasurement_widerStringMeasuresWider() {
        let short = StoryTextEngine.measuredBlockSize(
            of: overlay(fx: 0.5, fy: 0.5, string: "AA"), in: squareFrame)
        let long = StoryTextEngine.measuredBlockSize(
            of: overlay(fx: 0.5, fy: 0.5, string: "AAAA"), in: squareFrame)
        XCTAssertGreaterThan(long.width, short.width)
    }

    func testMeasurement_twoLinesMeasureRoughlyTwiceOne() {
        let one = StoryTextEngine.measuredBlockSize(
            of: overlay(fx: 0.5, fy: 0.5, string: "A"), in: squareFrame)
        let two = StoryTextEngine.measuredBlockSize(
            of: overlay(fx: 0.5, fy: 0.5, string: "A\nA"), in: squareFrame)
        XCTAssertGreaterThanOrEqual(two.height, one.height * 1.7,
                                    "second line collapsed — not a real two-line layout")
    }

    func testMeasurement_shortStringIsTextSizedNotFrameSized() {
        let size = StoryTextEngine.measuredBlockSize(
            of: overlay(fx: 0.5, fy: 0.5, string: "AB"), in: squareFrame)
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertLessThan(size.width, 0.5,
                          "two glyphs at 5% frame height cannot span half the frame — fixed-width block is back?")
    }

    // MARK: - Text extent (E1-redux; replaces the old smoke test)
    // A short string's glyphs must exist near center AND stay inside the
    // middle half of the frame in BOTH axes. Under the old fixed-width model
    // the drawn rect spanned x ∈ [50, 950]; two glyphs at 5% height live
    // comfortably inside [250, 750]. Pixel-level proof the block is
    // text-sized.
    func testTextExtent_blockIsTextSizedNotFixedWidth() throws {
        let flat = StoryTextEngine.flatten(
            base: solidBlackBase(width: 1000, height: 1000),
            overlays: [overlay(fx: 0.5, fy: 0.5, string: "AB")])
        let b = try Bitmap(flat)

        var lit = 0
        var minX = Int.max, maxX = Int.min
        var minY = Int.max, maxY = Int.min
        for y in stride(from: 0, through: 999, by: 2) {
            for x in stride(from: 0, through: 999, by: 2) where b.red(x, y) > 100 {
                lit += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThan(lit, 0, "no glyph pixels rendered")
        XCTAssertGreaterThan(minX, 250, "glyphs leaked left — fixed-width block is back?")
        XCTAssertLessThan(maxX, 750, "glyphs leaked right — fixed-width block is back?")
        XCTAssertGreaterThan(minY, 250, "glyphs leaked above the text-sized block")
        XCTAssertLessThan(maxY, 750, "glyphs leaked below the text-sized block")
    }

    // MARK: - Alignment (E1-redux: its real sticker meaning)
    // In a text-width block, alignment seats SHORTER lines within a
    // multi-line block (width = the longest line). Centroid of the short
    // second line's bright pixels: .left sits left of .right. Relational —
    // glyph pixels can't be asserted exactly.
    func testAlignment_shortLineSeatsWithinTextWidthBlock() throws {
        func lowerHalfCentroidX(_ alignment: NSTextAlignment) throws -> Double {
            let flat = StoryTextEngine.flatten(
                base: solidBlackBase(width: 1000, height: 1000),
                overlays: [overlay(fx: 0.5, fy: 0.5,
                                   string: "AAAAAAAA\nAA",
                                   alignment: alignment)])
            let b = try Bitmap(flat)
            var sum = 0.0, count = 0.0
            for y in stride(from: 500, through: 700, by: 2) {   // the short second line
                for x in stride(from: 0, through: 999, by: 2) where b.red(x, y) > 100 {
                    sum += Double(x)
                    count += 1
                }
            }
            XCTAssertGreaterThan(count, 0, "no glyph pixels for alignment \(alignment.rawValue)")
            return sum / max(count, 1)
        }

        let left = try lowerHalfCentroidX(.left)
        let right = try lowerHalfCentroidX(.right)
        XCTAssertLessThan(left, right - 20,
                          "short line's left centroid (\(left)) not left of right (\(right))")
    }
}
