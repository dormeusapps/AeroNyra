//
//  PTTSessionOwner.swift
//  Core/Media
//
//  PTT C-3a, re-keyed by C-3b′ (§3.5): the listener-side AVAudioSession owner
//  for a live walkie session. Still INERT: nothing constructs or calls
//  PTTSessionOwner yet (`MessageInbox.onPTTSession` stays nil; C-3c wires the
//  composition root). It anchors the process-global audio session to the wire
//  SESSION's lifetime — keyed by pttID, the session id `onPTTSession` already
//  carries, because the refcount counts concurrent REASONS to be live and
//  those reasons are sessions, not BLE links (the audio layer never sees a
//  link). It mirrors `CallEngine`'s session policy: activate once at start,
//  deactivate once at end with `.notifyOthersOnDeactivation`, and a system
//  interruption ends the spurt. The owner does NOT hold the player: the
//  coordinator owns `PTTPlayer` and evicts it link-keyed at `.pttClose`
//  (C-3c) — neither reaches into the other's axis.
//
//  Invariants owned here (named at the enforcement sites below):
//    IC5-revised — the audio session is anchored to the WIRE session
//          (`.pttOpened`/`.pttClosed` from the coordinator), not to the cover
//          UI and not per-press. `opened(pttID:peerKey:)`/`closed(pttID:)`
//          are the ONLY session-lifetime edges; half-duplex talker↔listener
//          flips inside a session never touch the session.
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

// MARK: - Owner

/// Listener-side session owner for live PTT. One per app (C-3c constructs it
/// at the composition root and points `MessageInbox.onPTTSession` at it).
/// Owns the audio session + IC8 flag + pre-empt, keyed by SESSION; it holds
/// no player and no link — the coordinator owns the `PTTPlayer` and drops it
/// link-keyed at `.pttClose` (§3.5).
@MainActor
final class PTTSessionOwner {

    private let audioSession: any PTTAudioSessionControlling

    /// Pre-empt seam: live PTT pre-empts any in-flight note/story playback
    /// (decided). This file does NOT reach into `VoicePlayer` — C-3c's
    /// composition root wires this closure to it. Nil (no-op) until then:
    /// inert.
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

    // MARK: Static lookup (§2.1 point 5 — the guard-site accessor)

    /// The one live owner, assigned at the composition root in C-3c — never
    /// here, never in `init`. Weak: the static creates no ownership edge and
    /// clears itself when the owner deallocates. Until C-3c wires it, it is
    /// nil, so `PTTSessionOwner.isLive` reads `false` and every C-3b guard is
    /// inert by construction.
    static weak var shared: PTTSessionOwner?

    /// §2.1 point 5 — a LOOKUP through `shared`, not a copy: the instance
    /// `isLive` above stays the single source of truth, so nothing can drift
    /// and `opened`/`closed` never write process-global state. A nil `shared`
    /// reads `false` — fail closed, the same posture as §2.1 point 2. Main-
    /// actor-isolated like the class; every guard site is `@MainActor`, so
    /// the read is synchronous there (no `await`).
    static var isLive: Bool { shared?.isLive ?? false }

    /// The open wire sessions, keyed by SESSION id — pttID, exactly what
    /// `onPTTSession` carries (§3.5). The refcount counts concurrent REASONS
    /// for the process-global session to be live, and those reasons are
    /// sessions, not BLE links. NOT peerKey: that is identity and would not
    /// distinguish two sessions from the same peer — two pttIDs from one peer
    /// must count as two. pttID is 16 CSPRNG bytes, fresh per session and
    /// non-secret (I4). Same edge semantics as before the re-key: the audio
    /// session activates on the first open (0 → 1) and deactivates on the
    /// last close (1 → 0).
    private var openSessions: Set<Data> = []

    private var observers: [NSObjectProtocol] = []

    init(audioSession: any PTTAudioSessionControlling = SystemPTTAudioSession()) {
        self.audioSession = audioSession
        installInterruptionObserver()
    }

    // MARK: Wire-session edges (IC5-revised — the ONLY session-lifetime edges)

    /// A PTT wire session opened (`.pttOpened` → `onPTTSession(true, …)`) —
    /// a direct match to the event's payload, no bridge, no link (§3.5).
    /// Idempotent per session. On the first open: activate the session, and
    /// only if activation SUCCEEDS raise the IC8 flag, then pre-empt in-flight
    /// playback — in that order (§2.1 point 2: fail closed). `peerKey` has no
    /// key role here (pttID is the key); it is accepted per the pinned
    /// signature and used only for the log line — short hex prefixes only,
    /// never key material.
    ///
    /// Activate-then-commit: a pttID is inserted into `openSessions` only
    /// after a successful activation (or when joining an already-live audio
    /// session). §2.1 pins fail-closed but is silent on this edge; committing
    /// the pttID on a FAILED first activation would leave `openSessions`
    /// non-empty with `isLive == false`, so every later `opened(...)` would
    /// see a "joined" session and never retry — a permanently phantom session
    /// until full close. Not tracking the failed pttID means the next
    /// `opened(...)` is a 0→1 edge again and retries activation: transient
    /// failures self-heal.
    func opened(pttID: Data, peerKey: Data) {
        guard !openSessions.contains(pttID) else { return }  // double-open: no-op
        RedactLog.event("[PTTSessionOwner] session open",
                        "pttID \(shortHex(pttID)) peer \(shortHex(peerKey, bytes: 8))…")
        guard openSessions.isEmpty else { // audio session already ours (live) —
            openSessions.insert(pttID)    // new session joins, no re-activation
            return
        }

        do {
            try audioSession.activateForPTT()
        } catch {
            // Fail closed (§2.1 point 2): no flag, no pre-empt, and the pttID
            // is NOT tracked — the next open retries activation.
            RedactLog.event("[PTTSessionOwner] session activate failed — staying closed",
                            "\(type(of: error))")
            return
        }
        openSessions.insert(pttID)       // commit only on successful activation
        isLive = true                    // IC8 — raise the choke-point flag
        preemptPlayback?()               // live pre-empts note/story playback
    }

    /// A PTT wire session closed (`.pttClosed` → `onPTTSession(false, …)`).
    /// Idempotent per session: when the LAST open session closes, lower the
    /// IC8 flag and release the audio session politely. Player eviction is
    /// NOT here — the coordinator drops the player link-keyed at `.pttClose`,
    /// where the link is in hand (§3.5).
    func closed(pttID: Data) {
        guard openSessions.remove(pttID) != nil else { return } // double-close: no-op
        guard openSessions.isEmpty else { return }              // others still live
        isLive = false                   // IC8 — lower the flag…
        audioSession.deactivate()        // …then release (.notifyOthers…)
    }

    // MARK: Interruption (mirrors CallEngine's v1 policy)

    /// v1 POLICY, honest and simple (same as `CallEngine`): a system audio
    /// interruption (an incoming phone call, Siri) ENDS the spurt — the
    /// session is gone and pretending otherwise would just play silence at a
    /// down flag. Every open session is closed through the one close path, so
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
        for pttID in openSessions { closed(pttID: pttID) }
    }

    // MARK: Log formatting (I4 — pttID/peer short hex only, never key material)

    /// Short hex prefix for logs, same shape as the coordinator's `pttIDLog`.
    /// pttID is a NON-secret random session id (like a callID); the peer key
    /// is public identity — a prefix identifies without dumping either.
    private func shortHex(_ data: Data, bytes: Int = 4) -> String {
        data.prefix(bytes).map { String(format: "%02x", $0) }.joined()
    }
}
