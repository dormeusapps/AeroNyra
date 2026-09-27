// StackRetirement.swift
// Security/Wipe
//
// ERASE FIX 4a — the PROCESS-LIFETIME latch that forbids building a second
// session stack after an erase has begun.
//
// WHY. The BLE transport is one instance for the life of the process
// (ContentView's `transport` @State) and its AsyncStreams are created once and
// never recreated. After an erase, any new stack built IN THE SAME PROCESS
// shares those streams with the old one:
//   • today (old stack never stopped) → two readers on `incoming` and
//     `audioFrames` SPLIT the frames: ~half of nearby messages lost, walkie
//     audio broken (pinned by AsyncStreamSemanticsTests);
//   • once erase stops the old router (4b) → cancelling a reader TERMINATES the
//     stream for everyone: a new stack would get NO Bluetooth inbound at all.
// So after an erase this process must never build another stack; the user
// relaunches. No path from an erase reaches a new stack today: a verified
// erase ends on the restart screen, and a failed one on its own door
// (`.eraseIncomplete`), which has no "Try again" — only "Erase and start
// over". Anything added later that builds a stack still has to go through
// `bootstrap()`, which consults this latch FIRST. That is why the guard lives
// there and not on any one route.
//
// ONE-WAY by construction: there is no un-retire. A fresh process (a relaunch)
// starts un-retired.
//

import Foundation

@MainActor
final class StackRetirementLatch {

    /// The process-wide latch. Tests construct their own instances.
    static let shared = StackRetirementLatch()

    /// True once an erase has begun in this process.
    private(set) var isRetired = false

    /// What `bootstrap()` may do in this process.
    enum Decision: Equatable {
        case build            // no erase yet: build the stack as normal
        case restartRequired  // an erase began: never build again — relaunch
    }

    var bootstrapDecision: Decision { isRetired ? .restartRequired : .build }

    /// One-way. Called first thing in every erase, before anything else runs.
    func retire() { isRetired = true }
}
