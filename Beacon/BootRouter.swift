//
//  BootRouter.swift
//  Beacon
//
//  The pure decision at app start: load the identity, and ONLY on success build
//  the model/session stack, then map the two outcomes to a route. Pulling this
//  out of `ContentView.bootstrap()` is what lets the decision be tested in
//  isolation (BootRouterTests) — the router owns the sequencing, so a test can
//  assert `buildStack` is never invoked when `load` throws, which the old
//  catch-all could not express.
//
//  `.onboarding` is reachable from EXACTLY ONE input: `load()` threw
//  `.notFound` (no identity item at all). Every other load error is
//  `.identityUnreadable` — a device that HAS an identity but cannot produce it
//  (dead Enclave key, locked Keychain) must never be mistaken for a fresh
//  install, because the identity-overwrite path lives in onboarding.
//

import Foundation
import SwiftData   // ModelContainer

/// Why a boot could not reach `.ready`. These are the only two failures the
/// router produces; both carry no payload (the classification is the signal).
enum BootFailure: Equatable {
    /// An identity item exists but could not be produced as a keypair — a
    /// throwing unwrap (dead Enclave key) or a non-`notFound` Keychain status
    /// (locked device). NOT "fresh install."
    case identityUnreadable
    /// The identity loaded fine; the model/session stack failed to build (e.g. a
    /// SwiftData schema migration on a foreground update, or disk-full). The
    /// identity is intact — the honestly-reassuring failure.
    case stackFailed
}

/// The route a boot resolves to. NOT `Equatable`: `.ready` carries an
/// `IdentityKeypair` (Curve25519 private keys) and a `ModelContainer` (a
/// SwiftData framework class), neither Equatable — and bolting `==` onto a
/// Secure-Enclave-backed key type just to compare routes is the wrong trade.
/// Callers pattern-match.
enum BootRoute {
    case onboarding
    case bootFailed(BootFailure)
    case ready(IdentityKeypair, ModelContainer)
}

enum BootRouter {

    /// Run the boot sequence and classify it. `buildStack` is invoked ONLY after
    /// a successful `load`, with the loaded identity — the ordering the decision
    /// table pins. Errors are classified, not surfaced: `.notFound` →
    /// `.onboarding`; any other load error → `.bootFailed(.identityUnreadable)`;
    /// a `buildStack` throw → `.bootFailed(.stackFailed)`.
    static func route(
        load: () throws -> IdentityKeypair,
        buildStack: (IdentityKeypair) throws -> ModelContainer
    ) -> BootRoute {
        let identity: IdentityKeypair
        do {
            identity = try load()
        } catch IdentityError.notFound {
            return .onboarding
        } catch {
            return .bootFailed(.identityUnreadable)
        }

        do {
            let container = try buildStack(identity)
            return .ready(identity, container)
        } catch {
            return .bootFailed(.stackFailed)
        }
    }
}
