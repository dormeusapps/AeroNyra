// ProcessedEventLedgerTests.swift
// Tests
//
// Proves the ISSUE-5 backlog-replay guard primitive in isolation (no transport,
// no crypto, no I/O), the way the project pins every primitive before wiring.
// Covers the dedup contract, FIFO eviction at capacity, the Codable round-trip,
// and that decode rebuilds a consistent state (and honours a shrunk cap / drops
// a corrupt duplicate-laden `order`).

import XCTest
@testable import Beacon

final class ProcessedEventLedgerTests: XCTestCase {

    // First sight returns false (proceed); a repeat returns true (skip).
    func testContainsOrInsertDedup() {
        var ledger = ProcessedEventLedger()
        XCTAssertFalse(ledger.containsOrInsert("a"))   // first sight
        XCTAssertTrue(ledger.containsOrInsert("a"))    // replay
        XCTAssertTrue(ledger.contains("a"))
        XCTAssertFalse(ledger.contains("b"))
        XCTAssertEqual(ledger.count, 1)
    }

    // FIFO: at capacity, inserting a new id evicts the OLDEST, and the evicted id
    // is then treated as first-sight again (self-healing).
    func testFifoEvictionAtCapacity() {
        var ledger = ProcessedEventLedger(capacity: 3)
        XCTAssertFalse(ledger.containsOrInsert("1"))
        XCTAssertFalse(ledger.containsOrInsert("2"))
        XCTAssertFalse(ledger.containsOrInsert("3"))
        XCTAssertEqual(ledger.count, 3)

        // "4" overflows → evicts oldest "1".
        XCTAssertFalse(ledger.containsOrInsert("4"))
        XCTAssertEqual(ledger.count, 3)
        XCTAssertFalse(ledger.contains("1"))           // evicted
        XCTAssertTrue(ledger.contains("2"))
        XCTAssertTrue(ledger.contains("4"))

        // "1" replayed after eviction is first-sight again (costs one re-process).
        XCTAssertFalse(ledger.containsOrInsert("1"))
    }

    // A re-inserted existing id does NOT reorder the FIFO (no LRU promotion), so
    // it doesn't rescue itself from being the next eviction.
    func testRepeatDoesNotReorder() {
        var ledger = ProcessedEventLedger(capacity: 2)
        _ = ledger.containsOrInsert("x")
        _ = ledger.containsOrInsert("y")
        XCTAssertTrue(ledger.containsOrInsert("x"))     // repeat, no reorder
        _ = ledger.containsOrInsert("z")               // evicts oldest "x"
        XCTAssertFalse(ledger.contains("x"))
        XCTAssertTrue(ledger.contains("y"))
        XCTAssertTrue(ledger.contains("z"))
    }

    // Encode → decode preserves membership, order-derived state, and capacity.
    func testCodableRoundTrip() throws {
        var ledger = ProcessedEventLedger(capacity: 100)
        for id in ["e1", "e2", "e3"] { _ = ledger.containsOrInsert(id) }

        let data = try JSONEncoder().encode(ledger)
        let restored = try JSONDecoder().decode(ProcessedEventLedger.self, from: data)

        XCTAssertEqual(restored, ledger)
        XCTAssertEqual(restored.capacity, 100)
        XCTAssertTrue(restored.contains("e1"))
        XCTAssertTrue(restored.contains("e3"))
        XCTAssertEqual(restored.count, 3)
        // Eviction order survives: next overflow past cap would drop "e1" first.
        XCTAssertFalse(restored.contains("e4"))
    }

    // Decoding rebuilds `present` from `order`, so a decoded ledger behaves
    // identically to a live one (membership works without re-inserting).
    func testDecodeRebuildsLookup() throws {
        var ledger = ProcessedEventLedger()
        _ = ledger.containsOrInsert("only")
        let data = try JSONEncoder().encode(ledger)
        var restored = try JSONDecoder().decode(ProcessedEventLedger.self, from: data)
        XCTAssertTrue(restored.containsOrInsert("only"))   // recognised as replay
    }

    // A blob whose `order` exceeds a (downgraded) capacity is trimmed oldest-first
    // on decode, so the invariant `count <= capacity` always holds.
    func testDecodeHonoursShrunkCapacity() throws {
        // Hand-craft a blob with 5 ids but capacity 2.
        let json = #"{"order":["a","b","c","d","e"],"capacity":2}"#
        let restored = try JSONDecoder().decode(ProcessedEventLedger.self,
                                                from: Data(json.utf8))
        XCTAssertEqual(restored.capacity, 2)
        XCTAssertEqual(restored.count, 2)
        XCTAssertFalse(restored.contains("a"))   // oldest trimmed
        XCTAssertFalse(restored.contains("c"))
        XCTAssertTrue(restored.contains("d"))    // newest kept
        XCTAssertTrue(restored.contains("e"))
    }

    // A corrupt `order` carrying duplicates is de-duped on decode (first-seen
    // order preserved), so membership and count stay consistent.
    func testDecodeDeduplicatesCorruptOrder() throws {
        let json = #"{"order":["a","a","b","a"],"capacity":100}"#
        let restored = try JSONDecoder().decode(ProcessedEventLedger.self,
                                                from: Data(json.utf8))
        XCTAssertEqual(restored.count, 2)
        XCTAssertTrue(restored.contains("a"))
        XCTAssertTrue(restored.contains("b"))
    }

    // Missing capacity in an older blob decodes to the default, not a crash.
    func testDecodeMissingCapacityUsesDefault() throws {
        let json = #"{"order":["a","b"]}"#
        let restored = try JSONDecoder().decode(ProcessedEventLedger.self,
                                                from: Data(json.utf8))
        XCTAssertEqual(restored.capacity, ProcessedEventLedger.defaultCapacity)
        XCTAssertEqual(restored.count, 2)
    }
}
