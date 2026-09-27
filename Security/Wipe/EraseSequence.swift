// EraseSequence.swift
// Security/Wipe
//
// ERASE FIX 4b — THE ORDER of an erase, as one small type with injected
// steps, so the order lives in one place and a test (EraseSequenceTests)
// fails if anyone reorders it.
//
// THE ORDER, and why each step sits where it does:
//   1. retireProcess     — the 4a latch. First, before anything else: from
//                          here on `bootstrap()` refuses to build a stack,
//                          whatever route the erase ends on.
//   2. cancelDeliveries  — pending invite-echo relay fallbacks. Each finishes
//                          its bounded ack wait and publishes nothing.
//   3. stopRouter        — both rails (BLE and relays) stop BEFORE any
//                          teardown, so nothing a teardown tries to send can
//                          leave: a walkie link's close message and a call's
//                          decline are dropped, by decision. The contact's
//                          call or walkie times out instead. Nothing leaves
//                          the device after an erase, goodbyes included.
//                          AWAITED: `MessageRouter` is an actor, so its
//                          `stop()` runs on the router's executor. Awaiting it
//                          means each transport's stop is already queued on
//                          its own serial queue before any later step runs,
//                          so any send a later step causes is queued behind it.
//   4. teardown          — end live calls and walkies and release their audio
//                          (mic, camera, audio session). While the ready
//                          screen is still mounted: its engines live there.
//   5. showWipingScreen  — the render-commit barrier: returns once the wiping
//                          surface has appeared, i.e. the ready screen and its
//                          live model rows have left the tree. No deletion
//                          before this.
//   6. wipe              — identity gate, full sweep, verify. Reports whether
//                          the wipe completed.
//   7. releaseReferences — drop the old stack's objects. After the wipe,
//                          because the wipe itself uses some of them.
//   8. finish            — route: the restart screen on a complete wipe, the
//                          door on an incomplete one. Steps 7 and 8 run on
//                          BOTH outcomes.
//
// Every step runs exactly once, in this order, each awaited to completion
// before the next starts. The type owns ORDER only; what each step does lives
// at the composition root (ContentView).
//

import Foundation

@MainActor
struct EraseSequence {

    /// What the wipe step reports. `incomplete` covers every failure the
    /// wipe detects (identity delete refused, a store step failed, store
    /// files still present) — `finish` routes it to the door.
    enum Outcome: Equatable {
        case complete
        case incomplete
    }

    let retireProcess: () -> Void
    let cancelDeliveries: () -> Void
    let stopRouter: () async -> Void
    let teardown: () async -> Void
    let showWipingScreen: () async -> Void
    let wipe: () async -> Outcome
    let releaseReferences: () -> Void
    let finish: (Outcome) -> Void

    /// Run the steps in THE ORDER above. Returns the wipe's outcome (the
    /// value `finish` was given) so callers and tests can read it.
    @discardableResult
    func run() async -> Outcome {
        retireProcess()
        cancelDeliveries()
        await stopRouter()
        await teardown()
        await showWipingScreen()
        let outcome = await wipe()
        releaseReferences()
        finish(outcome)
        return outcome
    }
}
