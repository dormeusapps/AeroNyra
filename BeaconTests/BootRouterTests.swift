// BootRouterTests.swift
// The bootstrap decision table, as an executable spec. This is the REFERENCE
// that ContentView.bootstrap() must reproduce (Step 1) — written first, on
// purpose, so the implementation is measured against it and not the reverse.
//
//   load()                          buildStack   →  route
//   ─────────────────────────────────────────────────────────────────────────
//   throws .notFound                (not called)    .onboarding
//   throws .identityUnwrapFailed    (not called)    .bootFailed(.identityUnreadable)
//   throws .keychain(_)             (not called)    .bootFailed(.identityUnreadable)
//   succeeds                        throws          .bootFailed(.stackFailed)
//   succeeds                        succeeds        .ready(identity, container)
//
// Rows 2–4 are the regression pins for the identity-overwrite incident: a
// device that HAS an identity but cannot produce it (dead Enclave key → a
// throwing unwrap; a locked Keychain → a non-notFound OSStatus; a stack that
// won't build though the identity loaded fine) must NEVER route to onboarding,
// because the four-tap `overwrite: true` path lives there. `.onboarding` is
// reachable from EXACTLY ONE input — `load()` threw `.notFound` (no item).
//
// SEAM TAKES THE OPERATIONS, NOT THEIR ERRORS. The router itself owns the
// sequencing: it calls `load`, and calls `buildStack` ONLY on a successful
// load. That is the property under test — the "buildStack runs only after a
// good load" ordering is enforced HERE, not by bootstrap()'s control flow, so
// the tests can assert buildStack was never invoked when load threw. A seam
// that took two optional errors could not: it would pin a function that cannot
// commit the bug.
//
// Contract this pins for Step 1:
//   enum BootFailure: Equatable { case identityUnreadable, stackFailed }
//   enum BootRoute {                              // NOT Equatable — see below
//       case onboarding
//       case bootFailed(BootFailure)
//       case ready(IdentityKeypair, ModelContainer)
//   }
//   enum BootRouter {
//       static func route(load: () throws -> IdentityKeypair,
//                         buildStack: (IdentityKeypair) throws -> ModelContainer) -> BootRoute
//   }
//
// Why BootRoute is NOT Equatable: `.ready` carries an `IdentityKeypair` (a
// struct over Curve25519 private keys — not Equatable) and a `ModelContainer`
// (a SwiftData framework class — not Equatable). Rather than bolt `==` onto a
// Secure-Enclave-backed key type just to satisfy XCTAssertEqual, the tests
// destructure each arm: `.ready` compares the identity by its 64-byte private
// blob (proving the LOADED identity propagated, not a fresh one) and the
// container by reference identity (`===`). BootFailure stays Equatable.

import XCTest
import CryptoKit         // SHA256 — compare identities without exposing key bytes
import Security          // errSecInteractionNotAllowed
import SwiftData         // ModelContainer / ModelConfiguration
@testable import Beacon

final class BootRouterTests: XCTestCase {

    private struct StackBuildError: Error {}

    /// A real in-memory container so `.ready`'s payload can be compared by
    /// reference identity — the router must hand back the SAME one buildStack
    /// produced, not merely "a" container.
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Peer.self, Conversation.self, Message.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// Compare identities by the SHA256 of their private blob, never the blob
    /// itself: if a future edit turns an `XCTAssertTrue(sameIdentity(...))` into
    /// `XCTAssertEqual(a, b)`, XCTest's failure message prints the operands —
    /// and a 32-byte digest is safe to print where 64 bytes of private key are
    /// not. Same proof of "the loaded identity propagated," no key material
    /// reachable by any assertion string.
    private func identityDigest(_ k: IdentityKeypair) -> SHA256Digest {
        SHA256.hash(data: k.serializedPrivateBlob())
    }

    private func sameIdentity(_ a: IdentityKeypair, _ b: IdentityKeypair) -> Bool {
        identityDigest(a) == identityDigest(b)
    }

    // Row 1 — the ONLY road to onboarding: no identity item exists. buildStack
    // must not run (a fresh install has nothing to build a stack over yet).
    func testNotFoundIsTheSoleRouteToOnboarding() {
        var buildStackCalls = 0
        let route = BootRouter.route(
            load: { throw IdentityError.notFound },
            buildStack: { _ in buildStackCalls += 1; throw StackBuildError() })
        guard case .onboarding = route else {
            return XCTFail("notFound must route to .onboarding, got \(route)")
        }
        XCTAssertEqual(buildStackCalls, 0, "buildStack must not run when load threw")
    }

    // Row 2 — REGRESSION PIN. A sealed identity whose Enclave key died loads as
    // `.identityUnwrapFailed` (IdentityKeypair.swift:263). Item present, key
    // real, just unreadable — must not be mistaken for "fresh install."
    func testIdentityUnwrapFailedRoutesToBootFailedUnreadable() {
        var buildStackCalls = 0
        let route = BootRouter.route(
            load: { throw IdentityError.identityUnwrapFailed },
            buildStack: { _ in buildStackCalls += 1; throw StackBuildError() })
        guard case .bootFailed(let failure) = route else {
            return XCTFail("expected .bootFailed, got \(route)")
        }
        XCTAssertEqual(failure, .identityUnreadable)
        XCTAssertEqual(buildStackCalls, 0)
    }

    // Row 3 — REGRESSION PIN. A locked Keychain surfaces as
    // `.keychain(errSecInteractionNotAllowed)` (IdentityKeypair.swift:273).
    // Every non-notFound OSStatus is "unreadable," never "absent."
    func testLockedKeychainRoutesToBootFailedUnreadable() {
        var buildStackCalls = 0
        let route = BootRouter.route(
            load: { throw IdentityError.keychain(errSecInteractionNotAllowed) },
            buildStack: { _ in buildStackCalls += 1; throw StackBuildError() })
        guard case .bootFailed(let failure) = route else {
            return XCTFail("expected .bootFailed, got \(route)")
        }
        XCTAssertEqual(failure, .identityUnreadable)
        XCTAssertEqual(buildStackCalls, 0)
    }

    // Row 3b — any other non-notFound IdentityError is likewise unreadable, not
    // onboarding. A corrupted blob is item-present-but-unusable, same class.
    func testCorruptedKeyDataRoutesToBootFailedUnreadable() {
        let route = BootRouter.route(
            load: { throw IdentityError.corruptedKeyData },
            buildStack: { _ in throw StackBuildError() })
        guard case .bootFailed(let failure) = route else {
            return XCTFail("expected .bootFailed, got \(route)")
        }
        XCTAssertEqual(failure, .identityUnreadable)
    }

    // Row 4 — REGRESSION PIN. Identity loaded FINE; the model/session stack
    // failed to build (e.g. a SwiftData schema migration on a foreground
    // update, or disk-full). The identity is intact — a DISTINCT failure whose
    // copy may honestly promise the identity and contacts are safe.
    func testStackFailureAfterSuccessfulLoadRoutesToBootFailedStackFailed() {
        let route = BootRouter.route(
            load: { IdentityKeypair.generate() },
            buildStack: { _ in throw StackBuildError() })
        guard case .bootFailed(let failure) = route else {
            return XCTFail("expected .bootFailed, got \(route)")
        }
        XCTAssertEqual(failure, .stackFailed)
    }

    // Row 5 — the happy path, WITH TEETH. `.ready` must carry the very identity
    // load returned (compared by private blob) and the very container buildStack
    // produced (compared by reference identity), not stand-ins.
    func testLoadedAndStackBuiltRoutesToReadyCarryingTheLoadedIdentityAndContainer() throws {
        let loaded = IdentityKeypair.generate()
        let built = try makeContainer()
        let route = BootRouter.route(
            load: { loaded },
            buildStack: { _ in built })
        guard case .ready(let identity, let container) = route else {
            return XCTFail("expected .ready, got \(route)")
        }
        XCTAssertTrue(sameIdentity(identity, loaded), ".ready must carry the LOADED identity")
        XCTAssertTrue(container === built, ".ready must carry the container buildStack produced")
    }

    // Ordering, as its own assertion: buildStack is invoked with the identity
    // `load` returned — the sequencing teeth the two-error seam could not ask.
    func testBuildStackReceivesTheLoadedIdentity() throws {
        let loaded = IdentityKeypair.generate()
        let built = try makeContainer()
        var received: IdentityKeypair?
        _ = BootRouter.route(
            load: { loaded },
            buildStack: { id in received = id; return built })
        let unwrapped = try XCTUnwrap(received, "buildStack must be called on a good load")
        XCTAssertTrue(sameIdentity(unwrapped, loaded))
    }

    // The invariant itself, as a test: onboarding has EXACTLY ONE preimage.
    // Every non-notFound load error and every post-load stack error stays out.
    func testOnboardingHasExactlyOnePreimage() {
        let loadErrors: [IdentityError] = [
            .identityUnwrapFailed,
            .keychain(errSecInteractionNotAllowed),
            .corruptedKeyData,
            .alreadyExists,
            .accessControlCreationFailed,
        ]
        for error in loadErrors {
            let route = BootRouter.route(
                load: { throw error },
                buildStack: { _ in throw StackBuildError() })
            if case .onboarding = route {
                XCTFail("\(error) must NOT route to onboarding")
            }
        }
        // Load succeeds, stack fails — also never onboarding.
        let stackRoute = BootRouter.route(
            load: { IdentityKeypair.generate() },
            buildStack: { _ in throw StackBuildError() })
        if case .onboarding = stackRoute {
            XCTFail("a stack failure must NOT route to onboarding")
        }
    }
}
