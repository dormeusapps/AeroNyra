//
//  AsyncStreamSemanticsTests.swift
//  BeaconTests
//
//  Q2 — RUNTIME SEMANTICS the app silently depends on after an in-process
//  erase → re-onboard. The BLE transport is one @State instance shared across
//  identities (ContentView.swift:98); its streams are created once in init
//  (BLEMeshTransport.swift:239-261) and are meant to have ONE reader each. After
//  re-onboarding in the same process the OLD router's consume task (never
//  cancelled — MessageRouter.stop() has no caller) and the NEW router's both
//  await `incoming`; and the old coordinator's deinit cancels its reader of
//  `audioFrames` while the new coordinator reads it.
//
//  Two questions, on a bare AsyncStream (no app code):
//    1. Two tasks awaiting one stream: does each element reach ONE reader, and
//       do they split the elements between them?
//    2. Cancelling one reader: does that terminate the stream for the other?
//
//  These tests RECORD the answer (attachments + log) and pin it, so a future OS
//  runtime that changes the behaviour fails here instead of silently.
//

import XCTest
import os

final class AsyncStreamSemanticsTests: XCTestCase {

    private final class Log: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: [String]())
        func append(_ s: String) { lock.withLock { $0.append(s) } }
        var all: [String] { lock.withLock { $0 } }
    }

    // MARK: 1. Two concurrent readers

    func testTwoReadersEachElementReachesOneReader() async throws {
        let (stream, cont) = AsyncStream<Int>.makeStream()
        let log = Log()
        let a = Task { for await x in stream { log.append("A\(x)") } }
        let b = Task { for await x in stream { log.append("B\(x)") } }
        try await Task.sleep(for: .milliseconds(200))       // both suspended in next()

        // Spaced: each reader has time to re-await (like BLE frames arriving apart).
        for i in 0..<20 {
            cont.yield(i)
            try await Task.sleep(for: .milliseconds(20))
        }
        // Burst: back to back (like a chunked media transfer).
        for i in 100..<120 { cont.yield(i) }
        try await Task.sleep(for: .milliseconds(200))
        cont.finish()
        await a.value
        await b.value

        let got = log.all
        let aCount = got.filter { $0.hasPrefix("A") }.count
        let bCount = got.filter { $0.hasPrefix("B") }.count
        let summary = "A=\(aCount) B=\(bCount) total=\(got.count) sequence=\(got.joined(separator: ","))"
        print("Q2.1 two readers: \(summary)")
        let attachment = XCTAttachment(string: summary)
        attachment.lifetime = .keepAlways          // readable from the .xcresult even on a pass
        add(attachment)

        XCTAssertEqual(got.count, 40, "every element delivered exactly once (none duplicated, none lost)")
        XCTAssertEqual(Set(got.map { String($0.dropFirst()) }).count, 40, "no element delivered twice")
        XCTAssertGreaterThan(aCount, 0, "reader A received a share")
        XCTAssertGreaterThan(bCount, 0, "reader B received a share — the readers SPLIT the stream")
    }

    // MARK: 2. Cancelling one reader

    func testCancellingOneReaderTerminatesTheStreamForTheOther() async throws {
        let (stream, cont) = AsyncStream<Int>.makeStream()
        let log = Log()
        let a = Task { for await x in stream { log.append("A\(x)") } }
        let b = Task {
            for await x in stream { log.append("B\(x)") }
            log.append("B-ended")
        }
        try await Task.sleep(for: .milliseconds(200))

        a.cancel()                                           // the old coordinator's deinit
        try await Task.sleep(for: .milliseconds(200))
        let r1 = cont.yield(1)
        let r2 = cont.yield(2)
        try await Task.sleep(for: .milliseconds(200))
        let endedBeforeFinish = log.all.contains("B-ended")
        cont.finish()
        await b.value

        let got = log.all
        let yieldResult = "\(r1) / \(r2)"
        let summary = "after cancelling A: yield=\(yieldResult) B-ended-before-finish=\(endedBeforeFinish) log=\(got.joined(separator: ","))"
        print("Q2.2 cancel one reader: \(summary)")
        let attachment = XCTAttachment(string: summary)
        attachment.lifetime = .keepAlways          // readable from the .xcresult even on a pass
        add(attachment)

        XCTAssertTrue(endedBeforeFinish,
                      "cancelling ONE reader terminated the stream: the other reader's loop ended without finish()")
        XCTAssertFalse(got.contains("B1") || got.contains("B2"),
                       "after the cancel, the surviving reader receives nothing")
    }
}
