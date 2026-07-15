//
//  PTTReceiver.swift
//  Core/Media
//
//  The PTT receive pipeline — deliberately OUT of the BLE transport so the
//  security-critical replay/key state and the Opus codec sit behind a clean
//  boundary (the transport stays carrier-neutral: it demuxes frame types and
//  hands sealed audio bytes up via `audioFrames`, nothing more).
//
//  For each sealed frame it: unpacks the wire layout (`PTTAudioWire`), opens
//  under the link's anti-replay opener, and decodes. The decoded PCM is EMITTED
//  as a value on `.decoded(seq:pcm:)` (C-1) — playout (the net-new AVAudioEngine
//  player node + jitter buffer) consumes it in a later step. This component is
//  unit-testable with NO transport.
//
//  ── Per-link context lifecycle (the leak-prevention seam) ────────────────────
//  A session's inbound context (opener + decoder) is created by the PTT handshake
//  (4c-3) via `openSession(link:recvKey:)` and evicted by `dropLink(_:)`.
//  `dropLink` is the eviction PRIMITIVE (unit-tested here). WHO calls it — the
//  proposed plumbing — is the owner that wires transport→receiver (4c-2): it
//  already consumes `transport.reachabilityUpdates` (the canonical link-lifecycle
//  signal, emitted by `emitReachable()` at EVERY teardown site — disconnect,
//  dead-link, power-off, unsubscribe), so in that same consumer loop it diffs the
//  reachable set and calls `dropLink(id)` for departed links. No new transport
//  surface, no second stream consumer, no timer heuristic. (Pending your sign-off
//  on this mechanism before 4c-2 wires it.)
//

import Foundation
import CryptoKit

/// The outcome of receiving one sealed audio frame — surfaced so the pipeline is
/// unit-testable without hardware or playout.
public enum PTTReceiveOutcome: Equatable {
    // IC1: PTTReceiver stays pure/decode-only — the PCM escapes as a VALUE on
    // this case; no player reference, no callback, no closure enters PTTReceiver
    // or `Context`.
    case decoded(seq: UInt64, pcm: [Int16])   // opened + decoded; PCM emitted to the caller
    case replayed      // duplicate / too-old — dropped by the replay window
    case authFailed    // bad tag — forged or corrupt
    case malformed     // wire payload shorter than seq+tag
    case noSession     // no context for this link (pre-handshake / evicted)
    case decodeError   // opened but the Opus decode threw
}

public final class PTTReceiver {

    private struct Context {
        let opener: PTTFrameOpener
        let decoder: OpusVoiceCodec.Decoder
    }

    /// Per-link inbound context. The security-critical replay/key state — kept
    /// here, out of the carrier transport.
    private var contexts: [UUID: Context] = [:]

    public init() {}

    // MARK: Session lifecycle

    /// Seed a link's inbound context with the recv directional key from the PTT
    /// handshake (4c-3). Throws only if the Opus decoder can't be created.
    public func openSession(link: UUID, recvKey: SymmetricKey) throws {
        contexts[link] = Context(opener: PTTFrameOpener(key: recvKey),
                                 decoder: try OpusVoiceCodec.Decoder())
    }

    /// Evict a link's context. Idempotent. The eviction primitive the owner
    /// drives from the transport's link lifecycle (see the header note).
    public func dropLink(_ link: UUID) { contexts[link] = nil }

    /// Live context count — for the leak-prevention test.
    public var sessionCount: Int { contexts.count }

    // MARK: Receive

    /// Process one sealed audio frame from a link: unpack → open → decode →
    /// EMIT (C-1). Returns the outcome; `.decoded` carries the seq + PCM for a
    /// later playout consumer (unconsumed in C-1 — the coordinator discards it).
    @discardableResult
    public func receive(link: UUID, sealed: Data) -> PTTReceiveOutcome {
        guard let (seq, ciphertext, tag) = PTTAudioWire.unpack(sealed) else { return .malformed }
        guard let ctx = contexts[link] else { return .noSession }
        do {
            let opus = try ctx.opener.open(counter: seq, ciphertext: ciphertext, tag: tag,
                                           aad: PTTAudioWire.aad(forSeq: seq))
            do {
                // IC2: recvKey / Context / opener state never leave the coordinator
                // actor — this moves NO key material; plaintext PCM out is the feature.
                let pcm = try ctx.decoder.decode(opus)
                return .decoded(seq: seq, pcm: pcm)
            } catch {
                return .decodeError
            }
        } catch PTTSessionCryptoError.replayed {
            return .replayed
        } catch PTTSessionCryptoError.authenticationFailed {
            return .authFailed
        } catch {
            return .decodeError
        }
    }

    // IC6: `run(_:)` deleted. It was dead (B-4's `pttAudioTask` drives
    // `ingestPTTAudio → receive`, never `run`) and was the off-actor trap: a
    // nonisolated loop that would run `receive()` — and thus `contexts` /
    // opener / recvKey mutation — off the coordinator's executor.
}
