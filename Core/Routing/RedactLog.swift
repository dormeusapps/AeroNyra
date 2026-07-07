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
    static func event(_ label: String, _ detail: @autoclosure () -> String) {
        #if DEBUG
        // Evaluate the autoclosure into a local first: the os.Logger string
        // interpolation captures its argument as an ESCAPING autoclosure, which a
        // non-escaping parameter can't be forwarded into directly. In release the
        // autoclosure is never invoked, so no identifier is ever computed.
        let detail = detail()
        log.debug("\(label, privacy: .public) · \(detail, privacy: .private)")
        #else
        log.debug("\(label, privacy: .public)")
        #endif
    }
}
