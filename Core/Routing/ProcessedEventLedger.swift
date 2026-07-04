// ProcessedEventLedger.swift
// Core/Routing
//
// ISSUE-5 (backlog-replay guard). A bounded, persistable record of OUTER Nostr
// event ids (kind-1059 gift wraps) this device has already processed, so a relay
// REPLAY of a stored wrap — or the same wrap fanned in from several relays — is
// recognised and skipped BEFORE the expensive schnorr verify + NIP-44 unwrap,
// instead of logging `open failed: openFailed` once per relay per replay.
//
// WHY THE OUTER event id (not the inner Envelope id): an undecryptable wrap
// never yields an Envelope, so it never reaches the router's envelope-id dedup
// (SeenCache). The only stable handle available BEFORE unwrap is the outer 1059
// event id — a hash of the event's own bytes — so that is what we ledger, at the
// TOP of `NostrTransport.handleInboundEventLocked`.
//
// RECORD ON FIRST SIGHT, regardless of unwrap outcome: the id is a content hash,
// so a re-send of the same bytes is byte-identical (equally valid or invalid,
// equally decryptable or not) — re-processing it can only repeat the same result,
// so skipping it is always correct. A genuinely different message necessarily has
// a different id. This is why recording the id BEFORE `isValid()` is safe: a bad
// signature can't be forged onto an id computed from different content, and an
// already-consumed wrap's ratchet key stays spent.
//
// EVICTION mirrors `SeenCache` (MessageRouter): bounded FIFO — insertion order,
// oldest evicted — which is all a replay guard needs. It never benefits from LRU
// reordering, and relays only replay recent-ish stored events. If an old id ages
// out and that wrap is replayed once more, it costs exactly one re-processed
// open-fail before being re-recorded: bounded and self-healing.
//
// Codable so the owning sealed store (a later step, mirroring
// ContactAllowlistStore) can seal it to disk and crypto-erase it on emergency
// wipe. PURE value logic — no I/O, no crypto, no transport — so it is fully
// unit-testable on the Mac. Only `order` + `capacity` are encoded; the `present`
// lookup set is rebuilt on decode, so the sealed blob can never carry an
// inconsistent set/order pair.
//

import Foundation

public struct ProcessedEventLedger: Codable, Equatable, Sendable {

    /// Default cap. Generous for replay-dedup: relays replay recent stored
    /// events, so a few thousand ids covers the window with room to spare. At
    /// ~64-char hex ids this is a few hundred KB sealed — trivial.
    public static let defaultCapacity = 8192

    /// Fast membership lookup. Derived from `order`; NOT encoded (rebuilt on
    /// decode) so a persisted blob can't desynchronise the two.
    private var present: Set<String>
    /// Insertion order, front = oldest. The FIFO eviction queue.
    private var order: [String]
    /// Maximum ids retained before the oldest is evicted.
    public let capacity: Int

    public init(capacity: Int = ProcessedEventLedger.defaultCapacity) {
        self.present = []
        self.order = []
        self.capacity = max(1, capacity)
    }

    /// Number of ids currently retained.
    public var count: Int { order.count }

    /// Record `id` as processed. Returns `true` if it was ALREADY present (a
    /// replay / cross-relay duplicate — the caller should SKIP), else inserts it
    /// and returns `false` (first sight — the caller proceeds). Same contract as
    /// `SeenCache.containsOrInsert`.
    @discardableResult
    public mutating func containsOrInsert(_ id: String) -> Bool {
        if present.contains(id) { return true }
        present.insert(id)
        order.append(id)
        if order.count > capacity {
            let evicted = order.removeFirst()
            present.remove(evicted)
        }
        return false
    }

    /// Whether `id` has been recorded (no mutation).
    public func contains(_ id: String) -> Bool { present.contains(id) }

    // MARK: - Codable (encode order + capacity only; rebuild `present` on decode)

    private enum CodingKeys: String, CodingKey {
        case order, capacity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try c.decode([String].self, forKey: .order)
        let cap = max(1, try c.decodeIfPresent(Int.self, forKey: .capacity)
                          ?? Self.defaultCapacity)

        // De-dup preserving first-seen order, then honour the cap (drop oldest
        // overflow) so a blob written under a larger cap can't exceed a smaller
        // one after a downgrade.
        var seen = Set<String>()
        var clean: [String] = []
        clean.reserveCapacity(min(stored.count, cap))
        for id in stored where !seen.contains(id) {
            seen.insert(id)
            clean.append(id)
        }
        if clean.count > cap {
            let overflow = clean.count - cap
            clean.removeFirst(overflow)
            seen = Set(clean)
        }

        self.capacity = cap
        self.order = clean
        self.present = seen
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(order, forKey: .order)
        try c.encode(capacity, forKey: .capacity)
    }
}
