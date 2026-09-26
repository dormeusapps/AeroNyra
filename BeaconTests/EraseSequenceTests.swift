//
//  EraseSequenceTests.swift
//  BeaconTests
//
//  Erase fix 4b — pins THE ORDER of an erase (see EraseSequence's header for
//  why each step sits where it does). Reordering the steps in `run()` fails
//  these tests. Every step records its name; the tests assert the exact
//  list, so a step that runs twice, is skipped, or moves also fails.
//

import XCTest
@testable import Beacon

@MainActor
final class EraseSequenceTests: XCTestCase {

    /// Collects step names in the order they ran.
    private final class Recorder {
        var steps: [String] = []
    }

    private static let expectedOrder = [
        "retireProcess",
        "cancelDeliveries",
        "stopRouter",
        "teardown",
        "showWipingScreen",
        "wipe",
        "releaseReferences",
        "finish",
    ]

    /// A sequence whose every step records its name. `wipeOutcome` is what
    /// the wipe step reports; `finish` records the outcome it was handed.
    private func makeSequence(_ recorder: Recorder,
                              wipeOutcome: EraseSequence.Outcome,
                              finished: @escaping (EraseSequence.Outcome) -> Void = { _ in })
    -> EraseSequence {
        EraseSequence(
            retireProcess: { recorder.steps.append("retireProcess") },
            cancelDeliveries: { recorder.steps.append("cancelDeliveries") },
            stopRouter: { recorder.steps.append("stopRouter") },
            teardown: { recorder.steps.append("teardown") },
            showWipingScreen: { recorder.steps.append("showWipingScreen") },
            wipe: { recorder.steps.append("wipe"); return wipeOutcome },
            releaseReferences: { recorder.steps.append("releaseReferences") },
            finish: { outcome in
                recorder.steps.append("finish")
                finished(outcome)
            })
    }

    func testCompleteWipeRunsEveryStepOnceInOrder() async {
        let recorder = Recorder()
        var finishedWith: EraseSequence.Outcome?
        let outcome = await makeSequence(recorder, wipeOutcome: .complete,
                                         finished: { finishedWith = $0 }).run()

        XCTAssertEqual(recorder.steps, Self.expectedOrder)
        XCTAssertEqual(outcome, .complete)
        XCTAssertEqual(finishedWith, .complete)
    }

    func testIncompleteWipeStillReleasesAndFinishesInOrder() async {
        let recorder = Recorder()
        var finishedWith: EraseSequence.Outcome?
        let outcome = await makeSequence(recorder, wipeOutcome: .incomplete,
                                         finished: { finishedWith = $0 }).run()

        XCTAssertEqual(recorder.steps, Self.expectedOrder,
                       "an incomplete wipe must still release references and route")
        XCTAssertEqual(outcome, .incomplete)
        XCTAssertEqual(finishedWith, .incomplete, "finish must route the door, not the restart screen")
    }

    /// The async steps suspend mid-step. The next step must not start until
    /// the suspended one has finished: teardown completes before the wiping
    /// screen, and the wiping screen has appeared before the wipe begins.
    func testSuspendingStepsFinishBeforeTheNextStarts() async {
        let recorder = Recorder()
        let sequence = EraseSequence(
            retireProcess: { recorder.steps.append("retireProcess") },
            cancelDeliveries: { recorder.steps.append("cancelDeliveries") },
            stopRouter: { recorder.steps.append("stopRouter") },
            teardown: {
                recorder.steps.append("teardown-begin")
                for _ in 0..<5 { await Task.yield() }
                try? await Task.sleep(nanoseconds: 10_000_000)
                recorder.steps.append("teardown-end")
            },
            showWipingScreen: {
                recorder.steps.append("showWipingScreen-begin")
                try? await Task.sleep(nanoseconds: 10_000_000)
                recorder.steps.append("showWipingScreen-end")
            },
            wipe: {
                recorder.steps.append("wipe-begin")
                try? await Task.sleep(nanoseconds: 10_000_000)
                recorder.steps.append("wipe-end")
                return .complete
            },
            releaseReferences: { recorder.steps.append("releaseReferences") },
            finish: { _ in recorder.steps.append("finish") })

        await sequence.run()

        XCTAssertEqual(recorder.steps, [
            "retireProcess",
            "cancelDeliveries",
            "stopRouter",
            "teardown-begin", "teardown-end",
            "showWipingScreen-begin", "showWipingScreen-end",
            "wipe-begin", "wipe-end",
            "releaseReferences",
            "finish",
        ])
    }
}
