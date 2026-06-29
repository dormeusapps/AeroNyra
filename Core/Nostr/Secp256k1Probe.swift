//
//  Secp256k1Probe.swift
//  Core/Nostr
//
//  Phase 8b-i-0 — link probe for the vendored libsecp256k1 C library.
//
//  This is scaffolding, not production identity code. It exists so a unit test
//  can prove — through the APP target, via `@testable import Beacon` — that the
//  vendored C library is compiled in and its symbols link, WITHOUT the test
//  target needing its own view of the C module. NostrIdentity (8b-i-1) will use
//  the same `import Csecp256k1` access path this file establishes, so a green
//  probe validates the real integration path rather than a test-only one.
//
//  It exercises the context lifecycle (create / randomize / destroy) and one
//  extrakeys entry point (x-only pubkey parse) to confirm both the core library
//  and the ENABLE_MODULE_EXTRAKEYS build flag took. No secret keys, no key
//  derivation happen here — that arrives in 8b-i-1.
//

import Foundation
import Security
import Csecp256k1

/// Internal link-probe for the secp256k1 C library. Returns true when the
/// library is present and its symbols are callable. Used only by tests; not
/// part of the identity surface.
enum Secp256k1Probe {

    /// Create a context, randomize it (side-channel hardening, and a second
    /// linked symbol to prove more than one entry point resolves), touch an
    /// extrakeys entry point, then tear the context down.
    /// - Returns: true iff context creation and randomization both succeed.
    static func contextLifecycleOK() -> Bool {
        guard let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE)) else {
            return false
        }
        defer { secp256k1_context_destroy(ctx) }

        var seed = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, seed.count, &seed) == errSecSuccess else {
            return false
        }
        guard secp256k1_context_randomize(ctx, seed) == 1 else {
            return false
        }

        // Extrakeys link check: parsing 32 zero bytes legitimately fails (zero
        // is not a valid x-only key), so the result is ignored — the point is
        // only that the symbol exists and links. If ENABLE_MODULE_EXTRAKEYS
        // weren't set, this line wouldn't compile.
        var xonly = secp256k1_xonly_pubkey()
        let zero = [UInt8](repeating: 0, count: 32)
        _ = secp256k1_xonly_pubkey_parse(ctx, &xonly, zero)

        return true
    }
}
