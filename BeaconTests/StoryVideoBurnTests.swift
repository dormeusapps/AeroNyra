//
//  StoryVideoBurnTests.swift
//  BeaconTests
//
//  Fidelity suite for the video text burn (stage f): the composite pass must
//  place overlays in the DISPLAY frame — including a portrait clip whose
//  pixels are stored landscape behind a 90° `preferredTransform`.
//
//  REFERENCE-FIRST, as in StoryTextEngineTests: expected pixels are
//  HAND-COMPUTED literals, marker blocks ride the engine's DrawContent seam,
//  every sample sits ≥10 px from a block edge, and marker centers are chosen
//  y-ASYMMETRIC so a vertical flip in the CoreAnimation tool cannot hide.
//  H.264 in/out → threshold assertions (white: red > 200, black: red < 60).
//
//  LANDSCAPE: 640×360 identity clip. Marker center (0.25, 0.25), size
//  (0.2, 0.2) → center (160, 90), block 128×72 → x∈[96,224], y∈[54,126].
//  PORTRAIT: same 640×360 pixels + preferredTransform (0,1,-1,0,360,0) →
//  display 360×640. Marker center (0.5, 0.25), size (0.2, 0.1) → center
//  (180, 160), block 72×64 → x∈[144,216], y∈[128,192]. Output dims are
//  asserted FIRST — 360×640 alone catches the renderSize trap.
//
//  XCTest only (not Swift Testing), per project standard.
//

import XCTest
import UIKit
import AVFoundation
@testable import Beacon

final class StoryVideoBurnTests: XCTestCase {

    // MARK: - Cases

    func testLandscapeBurn_markerAtHandComputedPixels() async throws {
        let src = try await Self.makeClip(width: 640, height: 360, transform: .identity)
        defer { try? FileManager.default.removeItem(at: src) }

        let out = try await StoryVideoBurner.burn(
            url: src,
            overlays: [Self.overlay(fx: 0.25, fy: 0.25)],
            drawContent: Self.marker(fw: 0.2, fh: 0.2))
        defer { try? FileManager.default.removeItem(at: out) }

        let b = try Bitmap(try await Self.frame(of: out, atSecond: 1))
        XCTAssertEqual(b.width, 640)
        XCTAssertEqual(b.height, 360)

        assertWhite(b, 160, 90)                   // block center
        assertWhite(b, 110, 68)                   // inside corners
        assertWhite(b, 210, 112)
        assertBlack(b, 85, 90)                    // outside left/right
        assertBlack(b, 235, 90)
        assertBlack(b, 160, 42)                   // outside top/bottom —
        assertBlack(b, 160, 138)                  //  a y-flip lands the block at y∈[234,306]
    }

    func testPortraitBurn_rendersInDisplayFrame() async throws {
        // The standard portrait-up matrix: (x,y) → (360 − y, x).
        let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)
        let src = try await Self.makeClip(width: 640, height: 360, transform: portrait)
        defer { try? FileManager.default.removeItem(at: src) }

        let out = try await StoryVideoBurner.burn(
            url: src,
            overlays: [Self.overlay(fx: 0.5, fy: 0.25)],
            drawContent: Self.marker(fw: 0.2, fh: 0.1))
        defer { try? FileManager.default.removeItem(at: out) }

        let b = try Bitmap(try await Self.frame(of: out, atSecond: 1))
        XCTAssertEqual(b.width, 360, "renderSize must be the transform-APPLIED extent")
        XCTAssertEqual(b.height, 640, "renderSize must be the transform-APPLIED extent")

        assertWhite(b, 180, 160)                  // block center, display coords
        assertWhite(b, 154, 138)                  // inside corners
        assertWhite(b, 206, 182)
        assertBlack(b, 132, 160)                  // outside left/right
        assertBlack(b, 228, 160)
        assertBlack(b, 180, 116)                  // outside top/bottom
        assertBlack(b, 180, 204)
    }

    // MARK: - Harness

    private static func overlay(fx: CGFloat, fy: CGFloat) -> StoryTextOverlay {
        StoryTextOverlay(string: "",
                         center: CGPoint(x: fx, y: fy),
                         height: 0.05,
                         rotation: 0,
                         alignment: .center)
    }

    /// The DrawContent seam, exactly as in StoryTextEngineTests: a solid
    /// white block of fractional size, centered on the transformed origin.
    private static func marker(fw: CGFloat, fh: CGFloat) -> StoryTextEngine.DrawContent {
        { _, frame, ctx in
            let w = fw * frame.width
            let h = fh * frame.height
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        }
    }

    /// Synthetic solid-black H.264 clip (2 s @ 30 fps) with the given
    /// writer-level `preferredTransform`.
    private static func makeClip(width: Int, height: Int,
                                 transform: CGAffineTransform) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "writer refused to start")
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetDataSize(buffer))   // BGRA zeros = black
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        for i in 0..<60 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: 30))
        }
        input.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        XCTAssertEqual(writer.status, .completed, "clip write failed: \(String(describing: writer.error))")
        return url
    }

    /// Mid-clip frame of the burned output. `appliesPreferredTrackTransform`
    /// is a no-op on the baked (identity-transform) output — safe either way.
    private static func frame(of url: URL, atSecond t: Double) async throws -> UIImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let cg = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        return UIImage(cgImage: cg)
    }

    /// RGBA8 readback in y-down, top-left-origin coordinates (as in
    /// StoryTextEngineTests).
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
}
