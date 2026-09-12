// WebRTCCallMedia+PTTLink.swift
// Core/Calls
//
// The link-only face of `WebRTCCallMedia` (globe pulse, loop 2): the peer's
// voice level for the walkie sphere. Lives in its own file so the controller
// file stays free of WebRTC types and `WebRTCCallMedia.swift` (the shared
// call media layer) gains no behavior — its only change was `pc` becoming
// readable from here (`private` → `private(set)`).
//
// SOURCE: `RTCRtpReceiver.sources` → `RTCRtpSource.audioLevel` — the RTP
// `ssrc-audio-level` header extension, surfaced by libwebrtc as the level of
// the LAST packet played out. A synchronous read, no stats poll, no report
// parsing. The value is LINEAR 0…1 (spec `RTCRtpContributingSource.audioLevel`:
// 10^(-dBov/20)); the engine maps it onto the sphere's dB meter scale.
//
// THREADING: `receivers` and `sources` are proxied calls that block the main
// thread onto WebRTC's signaling thread (and, for `sources`, the worker
// thread) — sub-millisecond while a link is open and signaling is idle. Same
// shape as `attachRemoteVideo`'s `pc.receivers` read. NEVER called on the
// call path: only `PTTLinkController.remoteAudioLevel` reads it, gated on
// the link being `.open`, and only while a walkie cover runs the meter.
//

import Foundation
import WebRTC

extension WebRTCCallMedia {

    /// nil before connect (no packets yet), after `close()` (`pc` is nil),
    /// or when the header extension was not negotiated (`audioLevel` nil —
    /// the engine logs that case once so a missing pulse is diagnosable).
    /// `public`: the witness for a public protocol requirement on a public
    /// class, like `setMicMuted` — internal here would let the protocol's nil
    /// default win silently.
    public var remoteAudioLevel: Double? {
        guard let pc else { return nil }
        for receiver in pc.receivers where receiver.track is RTCAudioTrack {
            return receiver.sources.first?.audioLevel?.doubleValue
        }
        return nil
    }

    /// My own voice level while transmitting (globe pulse, loop 3), LINEAR
    /// 0…1, from the audio sender's `media-source` stats entry — the level of
    /// the mic as WebRTC encodes it, the only in-process source of it. ASYNC:
    /// one `statisticsForSender:` request per call (spec getStats with the
    /// sender's selection), callback on the signaling thread, libwebrtc
    /// caches the report for 50 ms. nil with no peer connection (closed), no
    /// audio sender, or no such entry — the engine logs that once per run.
    /// libwebrtc always invokes the completion, on a closed connection too,
    /// so the continuation cannot leak; the `pc` guard runs before every
    /// request regardless.
    public func localAudioLevel() async -> Double? {
        guard let pc,
              let sender = pc.senders.first(where: { $0.track is RTCAudioTrack }) else { return nil }
        return await withCheckedContinuation { cont in
            pc.statistics(for: sender) { report in
                let source = report.statistics.values.first {
                    $0.type == "media-source" && ($0.values["kind"] as? String) == "audio"
                }
                cont.resume(returning: (source?.values["audioLevel"] as? NSNumber)?.doubleValue)
            }
        }
    }
}
