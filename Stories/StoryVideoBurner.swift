//
//  StoryVideoBurner.swift
//  Stories
//
//  STILLWATER · text-on-video (stage f): the composite pass.
//
//  Burns the composer's overlays into a clip and returns a NEW temp mp4 —
//  composite-THEN-transcode: this output goes to the UNTOUCHED
//  `VideoTranscoder.transcodeToMP4`, so the 60s/16MiB gates fire on the true
//  final wire bytes. The intermediate export is `HighestQuality` on purpose:
//  it never touches the wire, and the transcoder's medium pass is the one
//  real generation loss.
//
//  ORIENTATION (the trap, pinned by StoryVideoBurnTests): a portrait clip
//  stores landscape pixels behind a 90° `preferredTransform`. The burn
//  composites in the DISPLAY frame: the CIFilter-handler composition hands
//  each source frame already display-oriented and sizes the render to the
//  transform-APPLIED extent, and the overlay bitmap is laid out on that same
//  display frame. So the fractions the composer previews against the
//  (transform-applied) thumbnail are the fractions the burn uses. The output
//  carries an identity transform.
//
//  WHY the CIFilter compositor and not AVVideoCompositionCoreAnimationTool:
//  the CA tool's offline renderer crashed in the simulator (IOSurface →
//  _xpc_api_misuse) under the fidelity suite. Compositing one static bitmap
//  needs none of the CA machinery; `composited(over:)` per frame is the
//  deterministic equivalent, and the portrait/landscape literals pin the
//  result either way.
//
//  GEOMETRY IS THE ENGINE'S: the overlay image is `StoryTextEngine.flatten`
//  on a TRANSPARENT base of the display size — the exact transform + drawText
//  the photo path burns with, one renderer, no second code path. The
//  `DrawContent` seam passes through for the fidelity tests' marker blocks.
//
//  Audio passes through untouched (the export session carries the asset's
//  audio tracks; only video gets a composition).
//

import UIKit
import AVFoundation
import CoreImage

enum StoryVideoBurnerError: Error {
    case noVideoTrack
    case exportFailed
}

/// Namespace (case-less enum, house style — cannot be instantiated).
enum StoryVideoBurner {

    /// Burn `overlays` into the clip at `url`; returns a temp mp4 the caller
    /// owns (hand it to the transcoder, then delete it).
    static func burn(url: URL,
                     overlays: [StoryTextOverlay],
                     drawContent: StoryTextEngine.DrawContent = StoryTextEngine.drawText)
        async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw StoryVideoBurnerError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)

        // Display frame: the transform-applied extent — the same frame the
        // handler's source frames arrive in, and the frame the composer's
        // preview fractions were placed against.
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(preferred)
        let renderSize = CGSize(width: abs(displayRect.width),
                                height: abs(displayRect.height))

        // The overlay bitmap: the engine's flatten on a clear base of the
        // display size — geometry identical to the photo burn. Built ONCE;
        // composited over every frame.
        let overlayImage = Self.overlayImage(size: renderSize,
                                             overlays: overlays,
                                             drawContent: drawContent)
        guard let overlayCG = overlayImage.cgImage else {
            throw StoryVideoBurnerError.exportFailed
        }
        let overlayCI = CIImage(cgImage: overlayCG)

        let composition = try await AVMutableVideoComposition.videoComposition(
            with: asset,
            applyingCIFiltersWithHandler: { request in
                request.finish(with: overlayCI.composited(over: request.sourceImage),
                               context: nil)
            })

        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw StoryVideoBurnerError.exportFailed
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        session.outputURL = out
        session.outputFileType = .mp4
        session.videoComposition = composition

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw StoryVideoBurnerError.exportFailed
        }
        return out
    }

    /// Overlays alone, on transparency, at the display size — rendered by
    /// the ENGINE (scale 1, one geometry).
    private static func overlayImage(size: CGSize,
                                     overlays: [StoryTextOverlay],
                                     drawContent: StoryTextEngine.DrawContent) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let clear = UIGraphicsImageRenderer(size: size, format: format).image { _ in }
        return StoryTextEngine.flatten(base: clear, overlays: overlays,
                                       drawContent: drawContent)
    }
}
