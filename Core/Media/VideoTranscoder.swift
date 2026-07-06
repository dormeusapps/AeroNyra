// VideoTranscoder.swift
// Core/Media
//
// v1 VIDEO MESSAGES: turn a picked library clip into wire-ready mp4 bytes.
// Two gates, in order:
//
//   1. DURATION, before any transcode (`maxClipSeconds`): the user gets an
//      immediate "clip too long" instead of waiting out an export that the
//      chunker would reject anyway.
//   2. SIZE, after export (`maxOutputBytes`): the hard wire ceiling, DERIVED
//      from `MediaChunker.maxTotalBytes` so the sender cap and the receiver's
//      defensive bound can never drift. The check is `<=` — a blob of exactly
//      the ceiling passes, matching `manifestWithinBounds`.
//
// PRESET CHOICE (LOCKED for v1): `AVAssetExportPresetMediumQuality` (~540p).
// 720p H.264 runs ~2–2.5 Mbps → a full 60 s clip lands ~18–20 MB, over the
// ceiling; medium (~1–1.5 Mbps) puts 60 s comfortably at ~8–12 MB. Raising
// quality means shortening the cap — a deliberate product trade, not a knob
// to turn casually. `fileLengthLimit` is set below the ceiling as headroom;
// the post-export byte check is the authority.
//

import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - VideoTranscoderError

public enum VideoTranscoderError: Error, Equatable {
    /// The picked clip exceeds `maxClipSeconds` — rejected BEFORE transcode.
    case clipTooLong(seconds: Double)
    /// AVAssetExportSession could not produce output.
    case exportFailed(String)
    /// The export finished but the file exceeds the wire ceiling — distinct
    /// from `clipTooLong`: the clip passed the duration gate yet still could
    /// not be fit under the byte budget.
    case overBudget(bytes: Int)
}

// MARK: - VideoTranscoder

/// Namespace (case-less enum, house style — cannot be instantiated).
public enum VideoTranscoder {

    /// Longest clip v1 accepts, checked on the picked asset up front.
    public static let maxClipSeconds: Double = 60

    /// Hard wire ceiling — derived, never restated (16 MiB today).
    public static let maxOutputBytes = MediaChunker.maxTotalBytes

    /// Export target under the hard ceiling so container overhead can't tip
    /// a boundary clip over it.
    static let exportTargetBytes: Int64 = 15 * 1024 * 1024

    /// Gate 1, standalone so a picker can reject before transcode: throws
    /// `.clipTooLong` if the asset runs past `maxClipSeconds`.
    public static func validateDuration(of asset: AVAsset) async throws {
        let seconds = try await asset.load(.duration).seconds
        guard seconds <= maxClipSeconds else {
            throw VideoTranscoderError.clipTooLong(seconds: seconds)
        }
    }

    /// Duration-gate, then transcode `url`'s clip to H.264/AAC mp4 under the
    /// wire ceiling. Returns the bytes to hand to `sendMedia(_:mime:.mp4:)`.
    /// The temp output file is always cleaned up.
    public static func transcodeToMP4(from url: URL) async throws -> Data {
        let asset = AVURLAsset(url: url)
        try await validateDuration(of: asset)

        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            throw VideoTranscoderError.exportFailed("no export session for asset")
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        session.outputURL = out
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.fileLengthLimit = exportTargetBytes

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        guard session.status == .completed else {
            let reason = session.error?.localizedDescription
                ?? "status \(session.status.rawValue)"
            try? FileManager.default.removeItem(at: out)
            throw VideoTranscoderError.exportFailed(reason)
        }

        let data = try Data(contentsOf: out)
        try? FileManager.default.removeItem(at: out)

        // Gate 2 — the authority. `<=`: exactly the ceiling passes, matching
        // the receiver's `manifestWithinBounds`.
        guard data.count <= maxOutputBytes else {
            throw VideoTranscoderError.overBudget(bytes: data.count)
        }
        return data
    }
}

// MARK: - PickedVideo

/// A video picked from the photo library, copied out of the picker's sandbox
/// to a temp URL the transcoder can read. Reusable by the real composer UI
/// when video leaves the debug trigger.
public struct PickedVideo: Transferable {
    public let url: URL

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov"
                    : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedVideo(url: dest)
        }
    }
}
