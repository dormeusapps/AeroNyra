//
//  NostrInboxTag.swift
//  Core/Nostr
//
//  v59 connection-leak fix · Stage 1 · the inbox-tag primitive.
//
//  Before v59 Stage 5 (2026-09-19) the `p` tag on every published gift wrap and
//  on the REQ filter carried an npub in the clear, and both rode the same
//  WebSocket task, so a relay operator could read the sender↔recipient graph
//  off one connection. This primitive produces the value that replaced it: a
//  per-direction, epoch-scoped tag keyed on the pair secret `S_AB`, so the relay
//  sees an opaque identifier that only the two paired devices can compute. On
//  the wire since Stage 5; what a relay still learns is THREAT_MODEL §3.2–§3.3.
//  Stage 1 was THIS FILE and its XCTest; the transport and wrap followed.
//
//  FRAMING (LOCKED for v1 — docs/NOSTR_INBOX_TAG_KAT.md §1):
//
//      TAG        = "AeroNyra/nostr-inbox-tag/v1"        (UTF-8, fixed)
//      epoch      = UInt64, big-endian, 8 bytes           (floor(unix / 86400); INJECTED)
//      label      = emitter's 32-byte RAW identity key    (the directional component)
//      counter    = UInt8, single byte, from 0
//      message(c) = TAG ‖ epoch ‖ label ‖ counter
//      h(c)       = HMAC-SHA256(key = S_AB, message(c))   full 32 bytes, NO truncation
//      tag        = the first h(c), c = 0, 1, 2, …, that is CURVE-VALID
//      wire form  = lowercase hex, 64 chars, as the `p` tag value
//
//  CURVE-VALID(b): b, read big-endian as x, satisfies 0 < x < p and x³ + 7 is a
//  quadratic residue mod p — i.e. `secp256k1_xonly_pubkey_parse` accepts it. The
//  vendored libsecp256k1 is the reference and the ONLY predicate here.
//
//  WHY 32 BYTES: strfry rejects a `p` value that is not exactly 64 hex chars
//  (events.cpp:40-42) and hex-decodes `#p` filters to exactly 32 bytes
//  (filters.h:186-189). WHY CURVE-VALID: roughly half of raw HMAC outputs are
//  not valid x-coordinates; a relay that tested membership could label our
//  traffic. The counter is INSIDE the HMAC message so the search is a pure
//  function of (S_AB, epoch, label) and both sides land on the same value.
//
//  WHY A NEW PRIMITIVE: `ReconnectBeacon.token` hardcodes its domain and its
//  16-byte truncation in a KAT-locked file on the live BLE path. This file
//  reproduces the HMAC construction under a new domain; it does not call, and
//  must not modify, the beacon. "No new cryptography": HMAC-SHA256 plus a
//  public validity test.
//
//  label is always the EMITTER's identity: a device publishes the tag labelled
//  with its OWN identity and predicts a contact's tag with THAT CONTACT's
//  identity, so tag(A→B) ≠ tag(B→A) and no pairing edge is visible.
//
//  PURE + INJECTED. No clock (the epoch is bucketed by the caller from an
//  injected timestamp via `epoch(at:)`), no I/O, no randomness. Not constant
//  time by design: matching is a hash-set lookup and the value becomes public
//  the moment it is published.
//

import Foundation
import CryptoKit
import Csecp256k1

public enum NostrInboxTag {

    // MARK: Locked constants (v1)

    /// Domain-separation tag. Bumping it is a new wire version — old tags can
    /// never be confused with new framing. LOCKED for v1.
    public static let domainTag = Data("AeroNyra/nostr-inbox-tag/v1".utf8)

    /// Epoch bucket width in seconds. 86,400 (one day) is forced by the relay
    /// filter budget for a 30-day-back + 1-ahead subscribe window; see the KAT
    /// §1. This is a Nostr-side constant, NOT the BLE reconnect epoch.
    public static let epochLength: UInt64 = 86_400

    /// Bytes per tag: the full HMAC-SHA256 output, no truncation.
    public static let tagLength = 32

    /// The 32-byte raw identity-key length the `label` must be.
    public static let labelLength = 32

    /// One tag: the curve-valid HMAC output and the counter that produced it.
    /// The counter is part of every KAT assertion — a correct tag reached with
    /// the wrong counter means the search diverged.
    public struct Tag: Equatable, Hashable, Sendable {
        /// 32 bytes, big-endian x-coordinate, guaranteed CURVE-VALID.
        public let value: Data
        /// The first counter (from 0) whose candidate passed CURVE-VALID.
        public let counter: UInt8

        /// The wire form: 64 lowercase hex characters, as the `p` tag value.
        public var hex: String { value.map { String(format: "%02x", $0) }.joined() }
    }

    // MARK: Tag search (KAT-anchored — see NOSTR_INBOX_TAG_KAT.md §4)

    /// The inbox tag for one direction of one pairing in one epoch.
    ///
    /// - Parameters:
    ///   - secret: the pairing discovery secret `S_AB` (from `DiscoverySecret`).
    ///     Opaque here; its derivation has its own KAT.
    ///   - epoch: the day index (see `epoch(at:)`). INJECTED — never the clock.
    ///   - label: the EMITTER's raw 32-byte identity key.
    /// - Returns: the first curve-valid candidate and the counter that produced it.
    ///
    /// Scans the counter upward from 0. Exhausting all 256 counters is a
    /// precondition failure, not a runtime path: P(c > 255) ≈ 2⁻²⁵⁶.
    public static func tag(secret: Data, epoch: UInt64, label: Data) -> Tag {
        precondition(label.count == labelLength,
                     "label must be \(labelLength)-byte raw identity key, got \(label.count)")
        for counter in UInt8.min...UInt8.max {
            let candidate = self.candidate(secret: secret, epoch: epoch,
                                           label: label, counter: counter)
            if isCurveValidX(candidate) {
                return Tag(value: candidate, counter: counter)
            }
        }
        preconditionFailure("inbox-tag counter exhausted (probability ≈ 2^-256)")
    }

    /// One raw candidate: `HMAC-SHA256(S_AB, TAG ‖ epoch_be8 ‖ label ‖ counter)`,
    /// full 32 bytes, BEFORE the curve test. Exposed (internal) so the test can
    /// assert exactly which candidates the search rejected.
    static func candidate(secret: Data, epoch: UInt64, label: Data, counter: UInt8) -> Data {
        var message = Data()
        message.append(domainTag)
        var be = epoch.bigEndian
        withUnsafeBytes(of: &be) { message.append(contentsOf: $0) }
        message.append(label)
        message.append(counter)
        let mac = HMAC<SHA256>.authenticationCode(for: message,
                                                  using: SymmetricKey(data: secret))
        return Data(mac)
    }

    // MARK: Curve predicate (KAT-anchored — see NOSTR_INBOX_TAG_KAT.md §3)

    /// CURVE-VALID: true iff `x` is exactly 32 bytes and parses as a BIP-340
    /// x-only public key — `0 < x < p` and `x³ + 7` is a quadratic residue mod p.
    /// Backed by the vendored libsecp256k1 (`secp256k1_xonly_pubkey_parse`),
    /// the reference predicate. No secret is involved, so the context is not
    /// randomized (same pattern as `Secp256k1.verify`).
    public static func isCurveValidX(_ x: Data) -> Bool {
        guard x.count == tagLength else { return false }
        guard let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE)) else {
            return false
        }
        defer { secp256k1_context_destroy(ctx) }
        var xonly = secp256k1_xonly_pubkey()
        let bytes = [UInt8](x)
        return secp256k1_xonly_pubkey_parse(ctx, &xonly, bytes) == 1
    }

    // MARK: Epoch bucketing (now INJECTED)

    /// Bucket an injected Unix time into a day index. `secondsSinceEpoch` is
    /// INJECTED by the caller — this function never reads the wall clock, so
    /// lifecycle tests are deterministic.
    public static func epoch(at secondsSinceEpoch: UInt64) -> UInt64 {
        secondsSinceEpoch / epochLength
    }
}
