//
//  StackRetirementLatchTests.swift
//  BeaconTests
//
//  Erase fix 4a — pins the process-lifetime latch `bootstrap()` consults before
//  it may build a session stack. After an erase has begun, the process must
//  never build a second stack on the shared BLE streams (see
//  AsyncStreamSemanticsTests for why: two readers split frames; a cancelled
//  reader terminates the stream for everyone).
//
//  Each test uses its OWN latch instance — never `.shared`, which belongs to
//  the app host running these tests.
//

import XCTest
@testable import Beacon

@MainActor
final class StackRetirementLatchTests: XCTestCase {

    func testFreshLatchAllowsBuilding() {
        let latch = StackRetirementLatch()
        XCTAssertFalse(latch.isRetired)
        XCTAssertEqual(latch.bootstrapDecision, .build)
    }

    func testRetiredLatchRequiresRestart() {
        let latch = StackRetirementLatch()
        latch.retire()
        XCTAssertTrue(latch.isRetired)
        XCTAssertEqual(latch.bootstrapDecision, .restartRequired)
    }

    func testRetireIsIdempotentAndOneWay() {
        let latch = StackRetirementLatch()
        latch.retire()
        latch.retire()
        XCTAssertEqual(latch.bootstrapDecision, .restartRequired,
                       "retiring twice stays retired; the type offers no way back")
    }
}
