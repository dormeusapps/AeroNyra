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
//  under the link's anti-replay opener, and decodes. In 4c-1 the decoded PCM is
//  DISCARDED — playout (the net-new AVAudioEngine player node + jitter buffer)
//  lands in a later step. This component is unit-testable with NO transport.
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
    case decoded       // opened + decoded (PCM discarded in 4c-1)
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
    /// DISCARD (4c-1). Returns the outcome; playout replaces the discard in 4c-2.
    @discardableResult
    public func receive(link: UUID, sealed: Data) -> PTTReceiveOutcome {
        guard let (seq, ciphertext, tag) = PTTAudioWire.unpack(sealed) else { return .malformed }
        guard let ctx = contexts[link] else { return .noSession }
        do {
            let opus = try ctx.opener.open(counter: seq, ciphertext: ciphertext, tag: tag,
                                           aad: PTTAudioWire.aad(forSeq: seq))
            do {
                _ = try ctx.decoder.decode(opus)   // proves the path; PCM discarded in 4c-1
                return .decoded
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

    /// Consume the transport's audio stream until it ends. Call once after wiring
    /// (4c-2). Each frame runs through `receive(link:sealed:)`.
    public func run(_ audioFrames: AsyncStream<(link: UUID, sealed: Data)>) async {
        for await frame in audioFrames {
            receive(link: frame.link, sealed: frame.sealed)
        }
    }
}
