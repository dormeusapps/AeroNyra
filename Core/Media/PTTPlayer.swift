//
//  PTTPlayer.swift
//  Core/Media
//
//  PTT C-2: the playout half of BLE-live push-to-talk — a jitter buffer plus
//  the AVAudioEngine player that drains it on a fixed 20 ms clock. This commit
//  ships INERT: nothing constructs or calls PTTPlayer yet (C-3 wires it); it
//  only has to compile and carry its unit-tested correctness core.
//
//  Invariants owned here (named at the enforcement sites below):
//    IC3 — `enqueue` NEVER blocks the caller and spawns no per-frame Task;
//          a single private serial queue confines all mutable state and
//          preserves FIFO. Playout is CLOCK-driven (20 ms DispatchSourceTimer),
//          not arrival-driven — reactive scheduling can't hold timing across
//          a hole in the sequence.
//    IC4 — exactly ONE audible stream: the first `enqueue` for a link claims
//          playout; every other link's frames are dropped until the claim
//          clears. Enforced nowhere else (`.pttOpen` seeds contexts on both
//          role-links, and multiple peers can hold sessions concurrently).
//    IC5 — this file never CONFIGURES the audio session: no setCategory /
//          setActive / override anywhere (grep them: zero hits). Session
//          category/activation lifetime belongs to C-3's coordinator; this
//          player only drives its own engine graph. Observe-only session
//          notifications (mediaServicesWereReset) are allowed — reading that
//          the world changed is not owning it.
//

import Foundation
import AVFoundation

// MARK: - Pure DSP (unit-tested, no hardware, no AVFoundation types)

/// Per-link reorder/jitter buffer over decoded 20 ms PCM frames. A value type
/// with zero hardware dependencies — the same "pure DSP, fully unit-tested"
/// pattern as `OpusFrameSlicer`/`PTTCaptureDSP`. The PLAYER owns the clock and
/// the prebuffer timeout; this type only stores frames and answers questions.
struct PTTJitterBuffer {
    /// Prebuffer depth: hold playout until 3 frames (60 ms) are queued, or the
    /// player's own timeout fires. The buffer exposes readiness; it never waits.
    static let prebufferDepth = 3
    /// Hard cap — matches the transport's per-peer audio ring
    /// (`BLEMeshTransport.audioRingCapacity`, K = 8). Beyond it, drop-OLDEST:
    /// late audio is worthless; the freshest frames win.
    static let capacity = 8

    /// What the clock tick gets for the seq it expected.
    enum Pop: Equatable {
        /// The expected frame was buffered — play it.
        case frame([Int16])
        /// The expected seq is missing but LATER frames are buffered (a hole in
        /// the sequence) — the caller schedules one frame of silence.
        case gap
        /// Nothing buffered at all (underrun) — silence, and the caller's
        /// consecutive-silence counter decides when the talk-spurt is over.
        case empty
    }

    /// Highest seq the playout clock has consumed (frame OR silence-fill).
    /// Drop-late gate: anything at or below this is history and is discarded.
    private(set) var lastPlayed: UInt64?
    private var frames: [UInt64: [Int16]] = [:]

    var count: Int { frames.count }
    /// Prebuffer readiness — the player starts its clock when this turns true
    /// (or its own timeout elapses first).
    var isReady: Bool { frames.count >= Self.prebufferDepth }
    /// Where a fresh talk-spurt's clock should start.
    var minBufferedSeq: UInt64? { frames.keys.min() }

    /// Insert a decoded frame. Returns false when the frame was NOT kept:
    /// late (`seq <= lastPlayed` — its slot already played, possibly as
    /// silence), or a duplicate of a buffered seq.
    @discardableResult
    mutating func push(seq: UInt64, pcm: [Int16]) -> Bool {
        if let last = lastPlayed, seq <= last { return false }   // drop-late
        if frames[seq] != nil { return false }                   // duplicate
        frames[seq] = pcm
        // Cap at 8 (transport ring K): drop-OLDEST beyond it.
        while frames.count > Self.capacity, let oldest = frames.keys.min() {
            frames.removeValue(forKey: oldest)
        }
        return true
    }

    /// Consume the clock tick for `expectedSeq`. Advances the drop-late gate to
    /// `expectedSeq` whether or not the frame was present (a silence-filled slot
    /// is played history too — a late copy of it must not queue), and purges any
    /// buffered frame the gate has passed.
    mutating func pop(expectedSeq: UInt64) -> Pop {
        lastPlayed = max(lastPlayed ?? expectedSeq, expectedSeq)
        let pcm = frames.removeValue(forKey: expectedSeq)
        for stale in frames.keys where stale < expectedSeq {
            frames.removeValue(forKey: stale)
        }
        if let pcm { return .frame(pcm) }
        return frames.isEmpty ? .empty : .gap
    }

    /// Discard all queued frames but KEEP `lastPlayed`, so stragglers from the
    /// spurt that just ended stay drop-late instead of seeding a phantom spurt.
    mutating func flush() { frames.removeAll() }
}

// MARK: - Player (serial-queue confined; hardware path gated at C-3's by-ear gate)

/// Drains jitter buffers into an `AVAudioPlayerNode` on a fixed 20 ms clock.
/// `@unchecked Sendable`: mirrors `PTTCapturePipeline` — every piece of mutable
/// state is confined to the ONE private serial queue (`queue`); `enqueue` and
/// `drop` only hop onto it. No lock is needed because nothing is ever touched
/// from two threads (I3-style confinement, playout side).
final class PTTPlayer: @unchecked Sendable {

    /// If the prebuffer never fills (a 1–2 frame spurt, or heavy loss), start
    /// anyway after this many ticks so short clips aren't swallowed.
    private static let prebufferTimeoutTicks = 6        // 120 ms
    /// Consecutive silence-fills that end the talk-spurt.
    private static let maxConsecutiveSilence = 3
    private static let frameSeconds = 0.020

    /// THE confinement queue. All mutable state below, every AVAudioEngine /
    /// AVAudioPlayerNode call (attach/connect/start/scheduleBuffer/stop), and
    /// the playout timer live here and only here.
    private let queue = DispatchQueue(label: "beacon.ptt.player")

    // Queue-confined state — touch only from `queue`.
    /// `var`, not `let` (both): when mediaserverd reconfigures, a persistent
    /// engine can refuse `start()` against a healthy session — the recovery is
    /// replacing the instance (see `rebuildEngine()`, the playout twin of
    /// `PTTCaptureEngine.rebuildEngine()`). The node goes with it: it belongs
    /// to the dead instance's graph and can never play again.
    private var engine = AVAudioEngine()
    private var node = AVAudioPlayerNode()
    private var engineWired = false
    private var buffers: [UUID: PTTJitterBuffer] = [:]
    /// IC4 — the single audible stream's owner. First `enqueue` claims it;
    /// frames for any other link are dropped until it clears.
    private var activeLink: UUID?
    private var timer: DispatchSourceTimer?
    private var playing = false          // false while prebuffering
    private var prebufferTicks = 0
    private var expectedSeq: UInt64 = 0
    private var silenceRun = 0

    /// 48 kHz mono Float32 — the mixer-native format the Int16 frames are
    /// widened into for `scheduleBuffer`.
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: Double(OpusVoiceCodec.sampleRate),
                                       channels: 1, interleaved: false)

    /// Observer tokens — touched from init/deinit ONLY, never from `queue`.
    private var observers: [NSObjectProtocol] = []

    init() {
        installEngineObservers()
    }

    // MARK: Engine-death observation (IC5 — observe-only; handlers hop to `queue`)

    /// The system stops engines from AVFoundation's own threads; without these
    /// observers the player only DISCOVERS a dead engine at the next spurt's
    /// `ensureEngine()`, and a mid-spurt death limps silently (schedule() drops
    /// buffers against a stopped engine). Both handlers hop onto the
    /// confinement queue before touching any state, and both are deliberately
    /// CONSERVATIVE — they act only where playback is already broken, never on
    /// a healthy path:
    ///   • config change: only when the notification names the CURRENT engine
    ///     instance (registration is object-nil, so a rebuild can't stale the
    ///     filter — the identity check happens per-event, and it also screens
    ///     out OTHER engines' notifications, e.g. PTTCaptureEngine's), only
    ///     mid-spurt (`playing` — prebuffer/idle already recover through
    ///     ensureEngine WITH the clip intact), and only when the engine truly
    ///     stopped (`!isRunning` — an engine that survived the change, or was
    ///     already restarted by a newer spurt before this hop landed, is
    ///     healthy: leave it alone).
    ///   • media services reset: every instance is invalid by contract, so
    ///     rebuild UNCONDITIONALLY — but end the spurt only if `playing`; a
    ///     prebuffering spurt survives, its transition tick wires and starts
    ///     the fresh engine (the jitter buffer is pure data).
    private func installEngineObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] note in
            guard let self, let changed = note.object as? AVAudioEngine else { return }
            self.queue.async {
                guard changed === self.engine, self.playing,
                      !self.engine.isRunning else { return }
                RedactLog.event("[PTTPlayer] engine config change mid-spurt", "spurt ended")
                self.endSpurt(keepBuffer: true)
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                RedactLog.event("[PTTPlayer] media services reset", "rebuilding engine")
                if self.playing { self.endSpurt(keepBuffer: true) }
                self.rebuildEngine()
            }
        })
    }

    // MARK: Inbound seam

    /// Hand one decoded 20 ms frame to the player. SYNCHRONOUS and
    /// non-blocking (IC3): the caller — ultimately the BLE receive path — gets
    /// control back immediately; no Task, no await, no actor. The serial queue
    /// preserves arrival FIFO.
    func enqueue(link: UUID, seq: UInt64, pcm: [Int16]) {
        queue.async { [self] in
            // IC4 — first-claim / ignore-if-busy (the `PTTAutoPlay.claim`
            // pattern): claim on first frame, drop every other link's frames
            // while the claim is held.
            if activeLink == nil {
                activeLink = link
                startClock()
            } else if activeLink != link {
                return                                   // busy — dropped
            }
            buffers[link, default: PTTJitterBuffer()].push(seq: seq, pcm: pcm)
        }
    }

    /// Flush a link's buffer; if it held the IC4 claim, release the claim and
    /// stop the node (e.g. the link's session closed or the peer vanished).
    func drop(link: UUID) {
        queue.async { [self] in
            buffers.removeValue(forKey: link)
            if activeLink == link { endSpurt(keepBuffer: false) }
        }
    }

    deinit {
        timer?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: Playout clock (queue-confined)

    /// IC3 — playout is CLOCK-driven: a 20 ms repeating timer on the serial
    /// queue pops exactly one slot per tick, frame or silence. Arrival events
    /// never schedule audio directly.
    private func startClock() {
        playing = false
        prebufferTicks = 0
        silenceRun = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.frameSeconds,
                   leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard let link = activeLink else { endSpurt(keepBuffer: false); return }

        if !playing {
            // Prebuffer phase: wait for depth 3 (60 ms) or the player-owned
            // timeout — the buffer exposes readiness, the clock lives here.
            prebufferTicks += 1
            let ready = buffers[link]?.isReady ?? false
            guard ready || prebufferTicks >= Self.prebufferTimeoutTicks else { return }
            guard let first = buffers[link]?.minBufferedSeq else {
                // Timed out with nothing queued (every push was drop-late).
                if prebufferTicks >= Self.prebufferTimeoutTicks { endSpurt(keepBuffer: true) }
                return
            }
            expectedSeq = first
            // `playing` rises ONLY on a verified engine (ensureEngine's
            // activate-then-commit): on failure the spurt ends cleanly and
            // the next enqueue re-claims and retries against the (possibly
            // rebuilt) graph.
            guard ensureEngine() else { endSpurt(keepBuffer: true); return }
            playing = true
        }

        switch buffers[link]?.pop(expectedSeq: expectedSeq) ?? .empty {
        case .frame(let pcm):
            silenceRun = 0
            schedule(pcm)
        case .gap, .empty:
            // Hole or underrun: keep the clock honest with one frame of
            // silence rather than warping time.
            silenceRun += 1
            if silenceRun >= Self.maxConsecutiveSilence {
                endSpurt(keepBuffer: true)               // talk-spurt is over
                return
            }
            schedule(nil)
        }
        expectedSeq &+= 1
    }

    /// Stop the clock and the node and clear the IC4 claim. `keepBuffer` keeps
    /// the link's `lastPlayed` gate (flushing only queued frames) so stragglers
    /// from the finished spurt are dropped as late; `false` forgets the link.
    private func endSpurt(keepBuffer: Bool) {
        timer?.cancel()
        timer = nil
        playing = false
        silenceRun = 0
        if node.isPlaying {
            // stop() shares play()'s uncatchable-NSException family; teardown
            // must never abort the process. On a throw the node is abandoned —
            // ensureEngine's rebuild path replaces it if it stays wedged.
            if let err = BeaconCatchException({ node.stop() }) {
                RedactLog.event("[PTTPlayer] stop threw", err.localizedDescription)
            }
        }
        if let link = activeLink {
            if keepBuffer { buffers[link]?.flush() } else { buffers.removeValue(forKey: link) }
        }
        activeLink = nil                                 // IC4 claim released
    }

    // MARK: Engine graph (queue-confined; IC5 — graph only, never the session)

    /// Bring the graph up for a spurt. Returns false when the engine cannot be
    /// made playable — the caller fails the spurt cleanly (`endSpurt`) instead
    /// of limping into a `playing` state the engine can't back; the NEXT
    /// `enqueue` re-claims and retries, so transient failures self-heal (the
    /// same posture as `PTTSessionOwner.opened`'s activate-then-commit).
    private func ensureEngine() -> Bool {
        guard let format else { return false }
        wireIfNeeded(format)
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch {
                // A persistent instance whose I/O unit died under a
                // mediaserverd reconfigure can refuse start() forever — the
                // capture side's field-confirmed failure. Replace engine+node
                // ONCE and retry before giving up.
                RedactLog.event("[PTTPlayer] engine start failed — rebuilding", "\(type(of: error))")
                rebuildEngine()
                wireIfNeeded(format)
                engine.prepare()
                do { try engine.start() } catch {
                    RedactLog.event("[PTTPlayer] engine start failed after rebuild", "\(type(of: error))")
                    return false
                }
            }
        }
        // start() returning cleanly is a snapshot, not a guarantee: the system
        // stops engines from AVFoundation's own threads (session deactivation,
        // route change), so re-read immediately before play(). A false read
        // here fails the spurt; without it, play() on a stopped engine raises
        // the uncatchable "_engine->IsRunning()" NSException and aborts.
        guard engine.isRunning else {
            RedactLog.event("[PTTPlayer] engine stopped before play", "spurt dropped")
            return false
        }
        if !node.isPlaying {
            // Even past the guard above, the system can stop the engine in the
            // microseconds before play() executes — and play()'s NSException is
            // uncatchable from Swift. The ObjC shim is the ONLY thing that can
            // turn that abort into a dropped spurt.
            if let err = BeaconCatchException({ node.play() }) {
                RedactLog.event("[PTTPlayer] play threw", err.localizedDescription)
                return false
            }
        }
        return true
    }

    /// Attach/connect once per engine INSTANCE — `engineWired` is reset only
    /// by `rebuildEngine()`, so a rebuilt graph gets rewired and a live one is
    /// never re-touched.
    private func wireIfNeeded(_ format: AVAudioFormat) {
        guard !engineWired else { return }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engineWired = true
    }

    /// Replace a dead engine — playout twin of `PTTCaptureEngine.rebuildEngine()`
    /// (engine ONLY, never the session; releasing the old instance releases its
    /// dead I/O unit). The node is replaced with it: the old node belongs to the
    /// dead instance's graph, the same reason the capture side re-fetches its
    /// input node after a rebuild.
    private func rebuildEngine() {
        if engine.isRunning { engine.stop() }
        engine = AVAudioEngine()
        node = AVAudioPlayerNode()
        engineWired = false
    }

    /// One 20 ms slot → the player node. `pcm == nil` schedules 960 samples of
    /// silence (gap/underrun fill).
    private func schedule(_ pcm: [Int16]?) {
        guard let format,
              let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(OpusVoiceCodec.samplesPerFrame)),
              let ch = buf.floatChannelData else { return }
        buf.frameLength = AVAudioFrameCount(OpusVoiceCodec.samplesPerFrame)
        if let pcm {
            let n = min(pcm.count, OpusVoiceCodec.samplesPerFrame)
            for i in 0..<n { ch[0][i] = Float(pcm[i]) / 32767 }
            if n < OpusVoiceCodec.samplesPerFrame {
                for i in n..<OpusVoiceCodec.samplesPerFrame { ch[0][i] = 0 }
            }
        } else {
            for i in 0..<OpusVoiceCodec.samplesPerFrame { ch[0][i] = 0 }
        }
        guard engine.isRunning else { return }
        node.scheduleBuffer(buf, completionHandler: nil)
    }
}
