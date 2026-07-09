import os

/// Single choke point for log lines that would otherwise emit identity-bearing
/// material to the device console — long-term identity keys, npubs, peer key
/// hex, or message wire ids. `print()` is NOT stripped in release builds, so
/// those lines shipped to every tester's console; this routes them through one
/// gate instead of 36 hand-wrapped `#if DEBUG` blocks.
///
/// Contract:
///   • The `label` is always emitted. It must carry NO identifier — only the
///     event name plus benign dynamics (counts, link UUIDs, hop counts, bools).
///   • The `detail` is the sensitive part (identity hex, npub, wire id, and any
///     `\(error)` we don't want to risk). It is compiled in ONLY for DEBUG
///     builds and annotated `.private` — mirroring the `privacy: .private`
///     posture the Nostr/BLE transports already use — so it never reaches a
///     release console. In release the autoclosure is not even evaluated, so
///     the line is genuinely contentless: no identifier is computed or logged.
enum RedactLog {
    private static let log = Logger(subsystem: "com.aeronyra.app", category: "redacted")

    /// Emit `label` publicly; include `detail` only in DEBUG (redacted `.private`).
    ///
    /// LEVEL: `.notice`, not `.debug`. `.debug` messages are not persisted, are
    /// hidden in Console by default, and never reach a sysdiagnose — so the
    /// release-visible labels were, in practice, invisible in the field. `.notice`
    /// is captured in the on-disk log store and appears in a sysdiagnose, which is
    /// the point: the redacted labels are the field-diagnostic surface. This is
    /// only safe because every label is `.public` AND carries no sensitive
    /// material — sizes, per-peer link ids, and identity hex all live in the
    /// DEBUG-only `.private` `detail`, which the `#else` branch omits entirely.
    static func event(_ label: String, _ detail: @autoclosure () -> String) {
        #if DEBUG
        // Evaluate the autoclosure into a local first: the os.Logger string
        // interpolation captures its argument as an ESCAPING autoclosure, which a
        // non-escaping parameter can't be forwarded into directly. In release the
        // autoclosure is never invoked, so no identifier is ever computed.
        let detail = detail()
        log.notice("\(label, privacy: .public) · \(detail, privacy: .private)")
        #else
        log.notice("\(label, privacy: .public)")
        #endif
    }
}
