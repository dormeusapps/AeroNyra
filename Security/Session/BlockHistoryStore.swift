// BlockHistoryStore.swift
// Security/Session
//
// The at-rest home for BLOCK HISTORY (Guideline 1.2, v68 §5a — the
// block-window leak): what a contact sent while blocked must never be shown,
// stored, notified or acknowledged, not even after Unblock. Two records, both
// kept after the contact is unblocked (the denylist entry is not):
//
//   • BLOCK PERIODS — per contact (raw 32-byte identity key), every
//     [blockedAt, unblockedAt] in Unix ms. Written at Unblock. A contact can
//     have several. A relay copy whose inner send time falls in one is dropped.
//   • REFUSED ENVELOPE IDS — every envelope dropped because of a block. FIFO,
//     capped at 8,192. A later copy under the same id (the sender's
//     `flushUndelivered` resend reuses it) is dropped before it is opened.
//
// Mirrors `BlockedContactsStore` for the seal: one file sealed with ChaChaPoly
// under its own DEK (own Keychain service), AAD-bound, atomic write,
// `.completeFileProtectionUntilFirstUserAuthentication`. Unlike that store it
// holds its state IN MEMORY (loaded once, at init): `isRefused` is a Set
// lookup under a lock — no disk, no crypto per message.
//
// WRITES. A period is written SYNCHRONOUSLY and the call throws if the write
// fails, so Unblock can refuse rather than unblock with no record. Refused ids
// are written DEBOUNCED (the Nostr ledger's pattern: one save `saveDelay`
// seconds after the first unsaved id, off the caller, on a utility queue);
// `flush()` writes any pending ids now.
//
// FAILURE POSTURE (Rubins, 2026-10-02):
//   • MISSING file → empty and readable. The normal case: nobody unblocked yet.
//   • PRESENT but unreadable (can't read, unseal or decode) → boot EMPTY for
//     delivery (fail open — a currently blocked contact is still dropped by the
//     denylist, a separate store), log "⚠️ block history load FAILED — booting
//     empty", and mark the store UNREADABLE. While unreadable it NEVER writes:
//     the file stays byte-for-byte as found. `recordPeriod` THROWS
//     (`.unreadable`), so Unblock is refused until a later launch reads the
//     file; `recordRefused` is a silent no-op. Only Erase clears it.
//
// WIPE: tombstone first (no save lands after it, the ledger store's pattern),
// then KEY FIRST, then the file. Idempotent.
//

import Foundation
import CryptoKit
import os

/// One block of one contact, in Unix ms. `unblockedAt >= blockedAt`.
public struct BlockPeriod: Codable, Equatable, Hashable, Sendable {
    public let blockedAt: Int64
    public let unblockedAt: Int64

    public init(blockedAt: Int64, unblockedAt: Int64) {
        self.blockedAt = blockedAt
        self.unblockedAt = unblockedAt
    }
}

/// The store's contents. PURE value logic (no I/O, no crypto). Only `periods`,
/// the refused-id `order` and `capacity` are encoded; the lookup set is rebuilt
/// on decode, so a blob can never carry an inconsistent set/order pair.
struct BlockHistory: Codable, Equatable, Sendable {

    static let defaultCapacity = BlockHistoryStore.defaultCapacity

    /// Block periods per raw identity key, oldest first.
    private(set) var periods: [Data: [BlockPeriod]] = [:]
    /// Refused envelope ids, front = oldest. The FIFO eviction queue.
    private var order: [Data] = []
    /// Fast membership lookup, derived from `order`.
    private var present: Set<Data> = []
    let capacity: Int

    init(capacity: Int = BlockHistory.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    var refusedCount: Int { order.count }

    func periods(for rawKey: Data) -> [BlockPeriod] { periods[rawKey] ?? [] }

    func isRefused(_ id: Data) -> Bool { present.contains(id) }

    /// Appends `period` for `rawKey`. Returns false (no change) if that exact
    /// period is already recorded — a retried Unblock after a failed one.
    mutating func addPeriod(_ period: BlockPeriod, for rawKey: Data) -> Bool {
        var list = periods[rawKey] ?? []
        guard !list.contains(period) else { return false }
        list.append(period)
        periods[rawKey] = list
        return true
    }

    /// Records `id`. Returns false (no change) if it was already present.
    mutating func addRefused(_ id: Data) -> Bool {
        guard !present.contains(id) else { return false }
        present.insert(id)
        order.append(id)
        if order.count > capacity {
            present.remove(order.removeFirst())
        }
        return true
    }

    // MARK: Codable

    private struct ContactPeriods: Codable {
        let rawKey: Data
        let periods: [BlockPeriod]
    }

    private enum CodingKeys: String, CodingKey {
        case periods, refused, capacity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let cap = max(1, try c.decodeIfPresent(Int.self, forKey: .capacity) ?? Self.defaultCapacity)
        self.capacity = cap
        var periods: [Data: [BlockPeriod]] = [:]
        for entry in try c.decode([ContactPeriods].self, forKey: .periods) {
            periods[entry.rawKey, default: []].append(contentsOf: entry.periods)
        }
        self.periods = periods
        // De-dup preserving first-seen order, then honour the cap (drop oldest).
        var seen = Set<Data>()
        var clean: [Data] = []
        for id in try c.decode([Data].self, forKey: .refused) where !seen.contains(id) {
            seen.insert(id)
            clean.append(id)
        }
        if clean.count > cap {
            clean.removeFirst(clean.count - cap)
            seen = Set(clean)
        }
        self.order = clean
        self.present = seen
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let entries = periods
            .map { ContactPeriods(rawKey: $0.key, periods: $0.value) }
            .sorted { $0.rawKey.lexicographicallyPrecedes($1.rawKey) }
        try c.encode(entries, forKey: .periods)
        try c.encode(order, forKey: .refused)
        try c.encode(capacity, forKey: .capacity)
    }
}

public final class BlockHistoryStore: Wipeable, Sendable {

    public enum StoreError: Error, Equatable {
        /// The file is present but could not be read at init: nothing is written.
        case unreadable
        /// `wipe()` has run on this instance: nothing is written.
        case wiped
        /// `unblockedAt` is earlier than `blockedAt`.
        case invalidPeriod
    }

    /// This store's DEK service — distinct from every other store's.
    public static let defaultKeychainService = "com.aeronyra.blockhistory.v1"

    /// Sealed-file name, next to `blocked-contacts.v1.seal`.
    static let fileName = "block-history.v1.seal"

    /// Associated data binding the ciphertext to this purpose + version.
    private static let aad = Data("aeronyra.block-history.v1".utf8)

    /// Refused-id cap (FIFO: the oldest is evicted first).
    public static let defaultCapacity = 8192

    /// Seconds from the first unsaved refused id to its save.
    public static let defaultSaveDelay: TimeInterval = 3

    private struct State {
        var history: BlockHistory
        /// False when the file was present but unreadable at init.
        let readable: Bool
        var wiped = false
        /// Refused ids recorded since the last write.
        var dirty = false
        var saveScheduled = false
    }

    private let fileURL: URL
    private let dek: SymmetricKey
    private let keychainService: String
    private let saveDelay: TimeInterval
    private let state: OSAllocatedUnfairLock<State>

    /// Loads the file now (see FAILURE POSTURE). Throws only if the directory
    /// can't be created.
    public init(directory: URL,
                dek: SymmetricKey,
                keychainService: String = BlockHistoryStore.defaultKeychainService,
                capacity: Int = BlockHistoryStore.defaultCapacity,
                saveDelay: TimeInterval = BlockHistoryStore.defaultSaveDelay) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
        self.fileURL = fileURL
        self.dek = dek
        self.keychainService = keychainService
        self.saveDelay = saveDelay

        var initial = State(history: BlockHistory(capacity: capacity), readable: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let sealed = try Data(contentsOf: fileURL)
                let box = try ChaChaPoly.SealedBox(combined: sealed)
                let plaintext = try ChaChaPoly.open(box, using: dek, authenticating: Self.aad)
                initial.history = try JSONDecoder().decode(BlockHistory.self, from: plaintext)
            } catch {
                RedactLog.event("⚠️ block history load FAILED — booting empty", "\(type(of: error))")
                initial = State(history: BlockHistory(capacity: capacity), readable: false)
            }
        }
        self.state = OSAllocatedUnfairLock(initialState: initial)
    }

    // MARK: - Reads (memory only)

    /// False when the file was present but unreadable at init.
    public var isReadable: Bool { state.withLock { $0.readable } }

    public func periods(for rawKey: Data) -> [BlockPeriod] {
        state.withLock { $0.history.periods(for: rawKey) }
    }

    public func isRefused(_ envelopeID: Data) -> Bool {
        state.withLock { $0.history.isRefused(envelopeID) }
    }

    // MARK: - Writes

    /// Records one block period for `rawKey` and writes the file before
    /// returning. THROWS — recording nothing — while unreadable, after wipe, or
    /// if the write fails. An identical period already recorded is a no-op.
    public func recordPeriod(rawKey: Data, blockedAt: Int64, unblockedAt: Int64) throws {
        guard unblockedAt >= blockedAt else { throw StoreError.invalidPeriod }
        let period = BlockPeriod(blockedAt: blockedAt, unblockedAt: unblockedAt)
        try state.withLock { s in
            guard s.readable else { throw StoreError.unreadable }
            guard !s.wiped else { throw StoreError.wiped }
            var next = s.history
            guard next.addPeriod(period, for: rawKey) else { return }
            try write(next)          // under the lock: no wipe between check and write
            s.history = next
            s.dirty = false          // this write carried any pending refused ids too
        }
    }

    /// Records a refused envelope id: in memory now, on disk after `saveDelay`.
    /// A silent no-op while unreadable or after wipe.
    public func recordRefused(_ envelopeID: Data) {
        let schedule: Bool = state.withLock { s in
            guard s.readable, !s.wiped else { return false }
            guard s.history.addRefused(envelopeID) else { return false }
            s.dirty = true
            guard !s.saveScheduled else { return false }
            s.saveScheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + saveDelay) { [weak self] in
            guard let self else { return }
            do { try self.flush() } catch {
                RedactLog.event("block history: save FAILED", "\(type(of: error))")
            }
        }
    }

    /// Writes pending refused ids now. A no-op when nothing is pending, while
    /// unreadable, or after wipe. On failure the ids stay pending.
    public func flush() throws {
        try state.withLock { s in
            s.saveScheduled = false
            guard s.dirty, s.readable, !s.wiped else { return }
            try write(s.history)
            s.dirty = false
        }
    }

    /// Encode, seal, and write atomically. Called only under the state lock,
    /// after the readable and wiped checks (the ledger store's rationale for
    /// holding the lock across this small write applies).
    private func write(_ history: BlockHistory) throws {
        let plaintext = try JSONEncoder().encode(history)
        let sealed = try ChaChaPoly.seal(plaintext, using: dek, authenticating: Self.aad).combined
        try sealed.write(to: fileURL,
                         options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: - Wipeable

    /// Crypto-erase: tombstone, destroy the DEK, then remove the sealed file.
    /// Idempotent.
    public func wipe() async throws {
        // Tombstone FIRST, under the state lock: waits out an in-flight write,
        // then no later write can land.
        state.withLock { $0.wiped = true }
        // KEY FIRST, then the file: if the removal then fails, what survives is
        // a sealed file under a destroyed key — unreadable by any later identity.
        try SessionStoreKey.destroy(service: keychainService)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}

// MARK: - The period rule (v68 §5a)

extension BlockPeriod {

    /// Milliseconds after Unblock still treated as "sent while blocked": room
    /// for a sender whose clock runs a little ahead (Rubins, 2026-10-02).
    public static let afterUnblockMarginMs: Int64 = 30_000

    /// Whether a relay copy whose inner rumor time is `seconds` (Unix SECONDS,
    /// the sender's clock) was sent during this block. The rumor time has
    /// whole-second resolution, so the block start is floored to its second;
    /// the end is `unblockedAt` plus the margin, inclusive. The arithmetic
    /// saturates: a sender-chosen time near Int64's limits cannot trap.
    public func coversRelaySend(atSeconds seconds: Int64) -> Bool {
        let (product, overflowed) = seconds.multipliedReportingOverflow(by: 1000)
        let sentMs = overflowed ? (seconds < 0 ? Int64.min : Int64.max) : product
        let startMs = (blockedAt / 1000) * 1000
        let (sum, pastMax) = unblockedAt.addingReportingOverflow(Self.afterUnblockMarginMs)
        let endMs = pastMax ? Int64.max : sum
        return sentMs >= startMs && sentMs <= endMs
    }
}

// MARK: - Leftover sweep

extension BlockHistoryStore {

    /// `LeftoverSweep`'s step for a PREVIOUS identity's history: destroys the
    /// key, then removes the file, WITHOUT opening it (the store's init would
    /// try to read it with the sweep's scratch key and log a false load
    /// failure). Same key-before-file order as `wipe()`. Idempotent.
    struct LeftoverWipe: Wipeable {
        let directory: URL
        let keychainService: String

        func wipe() async throws {
            try SessionStoreKey.destroy(service: keychainService)
            let url = directory.appendingPathComponent(BlockHistoryStore.fileName, isDirectory: false)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}
