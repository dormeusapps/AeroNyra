//
//  PTTSessionOwner.swift
//  Core/Media
//
//  PTT C-3a: the listener-side AVAudioSession owner for a live walkie session.
//  This commit ships INERT: nothing constructs or calls PTTSessionOwner yet
//  (`MessageInbox.onPTTSession` stays nil; C-3b wires the composition root).
//  It holds the C-2 `PTTPlayer` and anchors the process-global audio session
//  to the wire session's lifetime, mirroring `CallEngine`'s session policy:
//  activate once at start, deactivate once at end with
//  `.notifyOthersOnDeactivation`, and a system interruption ends the spurt.
//
//  Invariants owned here (named at the enforcement sites below):
//    IC5-revised — the audio session is anchored to the WIRE session
//          (`.pttOpened`/`.pttClosed` from the coordinator), not to the cover
//          UI and not per-press. `opened(link:)`/`closed(link:)` are the ONLY
//          session-lifetime edges; half-duplex talker↔listener flips inside a
//          session never touch the session.
//    IC7 — foreground-only. No `audio` background mode exists or is added;
//          when the app backgrounds mid-session the system suspends audio and
//          the wire session dies with the link — nothing here pretends
//          otherwise.
//    IC8 — `isLive` is THE live flag: because `setActive(false)` is
//          process-global and this codebase has six uncoordinated
//          deactivation sites, every other owner's deactivation guard reads
//          this ONE property (C-3b adds the one-line guards). It is a single
//          readable choke point, never duplicated logic.
//
//  DECIDED (do not revisit): category is `.playAndRecord` + mode `.default`
//  + `[.defaultToSpeaker]` for the WHOLE session — identical to
//  `PTTCaptureEngine.start()`, so the talker↔listener flip needs no category
//  change. NOT CallEngine's `.voiceChat`, and nothing
//  `RTCAudioSession`/`useManualAudio`-shaped. No `routeChangeNotification`
//  handling in v1.
//

import Foundation
import AVFoundation

// MARK: - Audio-session seam (injectable — tests never touch the real session)

/// The two session side effects the owner performs, behind a protocol so unit
/// tests exercise flag/ordering/idempotency logic hardware-free (real
/// `setCategory`/`setActive` calls can throw on the simulator and are not
/// observable). The default is the real `AVAudioSession`.
protocol PTTAudioSessionControlling {
    /// `.playAndRecord`, mode `.default`, `[.defaultToSpeaker]`, then
    /// `setActive(true)` — the DECIDED whole-session configuration.
    func activateForPTT() throws
    /// `setActive(false, options: [.notifyOthersOnDeactivation])` — the same
    /// polite release `PTTCaptureEngine.deactivateSession()` performs, so
    /// music/podcasts resume after the session.
    func deactivate()
}

/// Real implementation over the process-global shared session.
struct SystemPTTAudioSession: PTTAudioSessionControlling {
    func activateForPTT() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker])
        try session.setActive(true)
    }
    func deactivate() {
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

// MARK: - Playout seam

/// The slice of the C-2 player the owner drives. A protocol (with `PTTPlayer`
/// as the shipped conformer) so tests can assert call ordering and the
/// `drop(link:)` handoff without constructing an `AVAudioEngine` graph.
protocol PTTLivePlayout: AnyObject {
    /// Ready the playout path for a fresh wire session. Called AFTER
    /// `preemptPlayback` — live pre-empts in-flight note/story playback
    /// before the player is armed.
    func readyForSession()
    /// Flush the link's jitter buffer and release its IC4 claim (C-2 surface).
    func drop(link: UUID)
}

extension PTTPlayer: PTTLivePlayout {
    /// C-2's player self-arms on the first `enqueue` (clock + engine graph
    /// start there, by design — IC3), so readying is a no-op today. The seam
    /// exists so `opened(link:)`'s ordering (pre-empt BEFORE ready) is a
    /// tested contract, and so C-3b can hang warm-up here without reshaping
    /// `opened`.
    func readyForSession() {}
}

// MARK: - Owner

/// Listener-side session owner for live PTT. One per app (C-3b constructs it
/// at the composition root and points `MessageInbox.onPTTSession` at it).
@MainActor
final class PTTSessionOwner {

    private let player: any PTTLivePlayout
    private let audioSession: any PTTAudioSessionControlling

    /// Pre-empt seam: live PTT pre-empts any in-flight note/story playback
    /// (decided). C-3a does NOT reach into `VoicePlayer` — C-3b's composition
    /// root wires this closure to it. Nil (no-op) until then: inert.
    var preemptPlayback: (() -> Void)?

    /// IC8 — THE live flag. True while at least one PTT wire session holds an
    /// ACTIVATED audio session. Fail closed (§2.1 point 2): the flag asserts a
    /// fact about the audio session, not an aspiration about the wire — a flag
    /// raised over a phantom (never-activated) session would suppress
    /// `VoicePlayer`'s `setActive(false)`, which is what lets background music
    /// resume (F2), so music would never resume. `setActive(true)` succeeds
    /// FIRST, then the flag rises. Single readable property — C-3b's guards
    /// are one-line reads of this, never copies of the logic.
    private(set) var isLive = false

    /// The open wire sessions, keyed the way `PTTPlayer` keys playout: by BLE
    /// link id. Multiple peers can hold sessions concurrently (`.pttOpen`
    /// seeds contexts on both role-links), so the session activates on the
    /// first open (0 → 1) and deactivates on the last close (1 → 0).
    private var openLinks: Set<UUID> = []

    private var observers: [NSObjectProtocol] = []

    init(player: any PTTLivePlayout,
         audioSession: any PTTAudioSessionControlling = SystemPTTAudioSession()) {
        self.player = player
        self.audioSession = audioSession
        installInterruptionObserver()
    }

    // MARK: Wire-session edges (IC5-revised — the ONLY session-lifetime edges)

    /// A PTT wire session opened (`.pttOpened` → `onPTTSession(true, …)`).
    /// Idempotent per link. On the first open: activate the session, and only
    /// if activation SUCCEEDS raise the IC8 flag, pre-empt in-flight playback,
    /// then ready the player — in that order (§2.1 point 2: fail closed).
    ///
    /// Activate-then-commit: a link is inserted into `openLinks` only after a
    /// successful activation (or when joining an already-live session). §2.1
    /// pins fail-closed but is silent on this edge; committing the link on a
    /// FAILED first activation would leave `openLinks` non-empty with
    /// `isLive == false`, so every later `opened(...)` would see a "joined"
    /// session and never retry — a permanently phantom session until full
    /// close. Not tracking the failed link means the next `opened(...)` is a
    /// 0→1 edge again and retries activation: transient failures self-heal.
    func opened(link: UUID) {
        guard !openLinks.contains(link) else { return }      // double-open: no-op
        guard openLinks.isEmpty else {   // session already ours (and live) —
            openLinks.insert(link)       // new link joins, no re-activation
            return
        }

        do {
            try audioSession.activateForPTT()
        } catch {
            // Fail closed (§2.1 point 2): no flag, no pre-empt, no ready, and
            // the link is NOT tracked — the next open retries activation.
            RedactLog.event("[PTTSessionOwner] session activate failed — staying closed",
                            "\(type(of: error))")
            return
        }
        openLinks.insert(link)           // commit only on successful activation
        isLive = true                    // IC8 — raise the choke-point flag
        preemptPlayback?()               // live pre-empts note/story playback
        player.readyForSession()         // AFTER pre-empt (tested ordering)
    }

    /// A PTT wire session closed (`.pttClosed` → `onPTTSession(false, …)`).
    /// Idempotent per link: drop the link's playout, and when the LAST open
    /// session closes, lower the IC8 flag and release the session politely.
    func closed(link: UUID) {
        guard openLinks.remove(link) != nil else { return }  // double-close: no-op
        player.drop(link: link)
        guard openLinks.isEmpty else { return }              // others still live
        isLive = false                   // IC8 — lower the flag…
        audioSession.deactivate()        // …then release (.notifyOthers…)
    }

    // MARK: Interruption (mirrors CallEngine's v1 policy)

    /// v1 POLICY, honest and simple (same as `CallEngine`): a system audio
    /// interruption (an incoming phone call, Siri) ENDS the spurt — the
    /// session is gone and pretending otherwise would just play silence at a
    /// down flag. Every open link is closed through the one close path, so
    /// the flag drops and the session is released. `.ended` is ignored; a
    /// fresh `.pttOpened` re-opens cleanly. NO route-change handling in v1.
    private func installInterruptionObserver() {
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor [weak self] in self?.interruptionBegan() }
        })
    }

    /// Split out (internal) so the ending policy is unit-testable without
    /// posting notifications through the real center.
    func interruptionBegan() {
        for link in openLinks { closed(link: link) }
    }
}
