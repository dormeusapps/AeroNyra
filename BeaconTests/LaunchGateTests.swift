//
//  LaunchGateTests.swift
//  BeaconTests
//
//  Pins the launch order: an erase in this process wins; then the Terms of
//  Use; only then `boot` (identity load + stack build). One test per route
//  that could reach onboarding or chats, each with a spy `boot` proving
//  nothing is built behind the terms. The acceptance state is a real
//  TermsAcceptanceStore in a temp directory.
//

import XCTest
@testable import Beacon

@MainActor
final class LaunchGateTests: XCTestCase {

    private enum Route: Equatable { case onboarding, ready, bootFailed }

    private final class BootSpy {
        var calls = 0
        let route: Route
        init(_ route: Route) { self.route = route }
        func boot() -> Route { calls += 1; return route }
    }

    private func makeStore() -> TermsAcceptanceStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-gate.\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return TermsAcceptanceStore(directory: dir)
    }

    private func throwawayDefaults() -> UserDefaults {
        let name = "launch-gate-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func launch(_ store: TermsAcceptanceStore, _ spy: BootSpy,
                        retirement: StackRetirementLatch.Decision = .build) -> LaunchStep<Route> {
        LaunchGate.run(retirement: retirement,
                       termsAccepted: { store.isAccepted() },
                       boot: { spy.boot() })
    }

    private func isTerms(_ step: LaunchStep<Route>) -> Bool {
        if case .terms = step { return true }
        return false
    }

    private func booted(_ step: LaunchStep<Route>) -> Route? {
        if case .booted(let route) = step { return route }
        return nil
    }

    /// Fresh install: no record, no identity.
    func testFreshInstallShowsTermsAndBuildsNothing() {
        let spy = BootSpy(.onboarding)
        XCTAssertTrue(isTerms(launch(makeStore(), spy)))
        XCTAssertEqual(spy.calls, 0)
    }

    /// Reinstall: the Keychain identity survived (boot WOULD reach chats),
    /// the acceptance file did not.
    func testReinstallShowsTermsBeforeChats() {
        let spy = BootSpy(.ready)
        XCTAssertTrue(isTerms(launch(makeStore(), spy)))
        XCTAssertEqual(spy.calls, 0)
    }

    /// Update from builds ≤ 14: only the version 1 defaults record exists.
    func testUpdateFromVersionOneDefaultsShowsTerms() {
        UserDefaults.standard.set(["version": 1, "acceptedAt": Date()],
                                  forKey: TermsAcceptanceStore.legacyDefaultsKey)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: TermsAcceptanceStore.legacyDefaultsKey) }
        let spy = BootSpy(.ready)
        XCTAssertTrue(isTerms(launch(makeStore(), spy)))
        XCTAssertEqual(spy.calls, 0)
    }

    /// Update that raised the terms version over an older file record.
    func testOlderAcceptedVersionShowsTerms() throws {
        let store = makeStore()
        try store.recordAcceptance(version: TermsVersion.current - 1, legacyDefaults: throwawayDefaults())
        let spy = BootSpy(.ready)
        XCTAssertTrue(isTerms(launch(store, spy)))
        XCTAssertEqual(spy.calls, 0)
    }

    func testCurrentVersionBootsOnce() throws {
        let store = makeStore()
        try store.recordAcceptance(legacyDefaults: throwawayDefaults())
        let spy = BootSpy(.ready)
        XCTAssertEqual(booted(launch(store, spy)), .ready)
        XCTAssertEqual(spy.calls, 1)
    }

    /// After an Erase: the erase's terms wipe ran; the relaunch shows terms.
    func testAfterEraseShowsTerms() async throws {
        let store = makeStore()
        try store.recordAcceptance(legacyDefaults: throwawayDefaults())
        try await TermsAcceptanceWipe(store: store).wipe()
        let spy = BootSpy(.onboarding)
        XCTAssertTrue(isTerms(launch(store, spy)))
        XCTAssertEqual(spy.calls, 0)
    }

    /// Boot-failed door: "Try again" re-runs the same sequence. Behind the
    /// terms when not accepted; passes straight through when accepted.
    func testBootFailedDoorIsBehindTheTerms() throws {
        let store = makeStore()
        let spy = BootSpy(.bootFailed)
        XCTAssertTrue(isTerms(launch(store, spy)))
        XCTAssertEqual(spy.calls, 0)
        try store.recordAcceptance(legacyDefaults: throwawayDefaults())
        XCTAssertEqual(booted(launch(store, spy)), .bootFailed)
        XCTAssertEqual(spy.calls, 1)
    }

    /// An erase in this process wins over everything, terms unread.
    func testRetiredProcessNeverReadsTermsOrBoots() {
        let spy = BootSpy(.ready)
        var termsRead = false
        let step = LaunchGate.run(retirement: .restartRequired,
                                  termsAccepted: { termsRead = true; return true },
                                  boot: { spy.boot() })
        guard case .restartRequired = step else { return XCTFail("expected restartRequired") }
        XCTAssertFalse(termsRead)
        XCTAssertEqual(spy.calls, 0)
    }

    /// Leftover sweep: runs just AFTER an acceptance, so it must never carry
    /// the terms wipe (else the terms would show twice).
    func testLeftoverSweepNeverClearsTheAcceptance() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-gate-sweep.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let u = UUID().uuidString
        let sweep = try LeftoverSweep.standard(
            storeDirectory: dir,
            services: .init(sessionKey: "test.gate.session.\(u)", nostrIdentity: "test.gate.nostr.\(u)"),
            swiftData: NoopWipe())
        XCTAssertFalse(sweep.steps.contains { $0 is TermsAcceptanceWipe })
    }

    private struct NoopWipe: Wipeable {
        func wipe() async throws {}
    }
}
