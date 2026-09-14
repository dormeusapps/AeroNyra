# Reconnect Discovery Beacon — Framing & Known-Answer Vectors

**Closed-Contact · Step 5 · the KAT spec the beacon primitive's XCTest is written from**
**Written 2026-06-30 · anchors HMAC-SHA256 to RFC 4231; framing vectors computed out-of-impl (Python) before any Swift**

> **Restored 2026-09-14.** This file was missing from `docs/` while five sources still
> cited it (`ReconnectBeacon.swift:55`, `BeaconRecognizer.swift`,
> `ReconnectBeaconTests.swift:7`, `CONTACT_MODEL.md`, `THREAT_MODEL.md`). Content is
> byte-identical to the last known copy. Before restoring, all six Tier 2 vectors and
> both Tier 1 cases were recomputed from the framing below and matched exactly — so
> this document is confirmed against the construction, not merely retrieved. Confirm
> once against the hex literals at `ReconnectBeaconTests.swift:50-64`, which are
> currently the only on-disk copy of these numbers.

This is the external reference the discovery-beacon primitive is anchored to **before**
implementation, per project discipline. The Swift test asserts CryptoKit's output
against these exact bytes. Do not edit a vector without recomputing the whole set.

---

## 1. Framing (LOCKED for v1)

```
TAG       = "AeroNyra/reconnect-beacon/v1"        (UTF-8, fixed; bumping it = new version)
epoch     = UInt64, BIG-ENDIAN, 8 bytes           (time-bucket index; now is INJECTED)
label     = emitter's 32-byte RAW identity key     (Peer.publicKeyData rep; the directional tag)
message   = TAG ‖ epoch ‖ label
token     = HMAC-SHA256(key = S_AB, message)[0 ..< 16]    (first 16 bytes)
```

- **Key** is the per-pairing discovery secret `S_AB` (derivation is a *separate*
  primitive; here it is an opaque input).
- **label is always the EMITTER's identity.** A device emits, per pairing, the token
  labelled with its **own** identity; it predicts a contact's token using **that
  contact's** identity. This directionality is what makes A's and B's tokens differ
  on the wire (no visible pairing edge).
- **Truncation 16 bytes.** Matching is a hash-set lookup, not secret equality — no
  constant-time compare needed; HMAC itself is constant-time via CryptoKit.
- **Emission set is fixed-size 64**: real per-pairing tokens + random 16-byte decoys
  padded to 64, shuffled. Hides contact count N. (64 chosen so realistic closed-contact
  lists never spill; spillover is a *correctness* failure, so it is designed out.)
- **Epoch skew window:** a receiver precomputes its expected-token table for
  `{E−1, E, E+1}` to absorb clock drift between devices.

Fixed inputs used below (hex):

```
TAG   4165726f4e7972612f7265636f6e6e6563742d626561636f6e2f7631
S1    000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
S2    1111111111111111111111111111111111111111111111111111111111111111
LA    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
LB    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
```

---

## 2. Tier 1 — HMAC-SHA256 primitive anchor (RFC 4231, full 32-byte output)

Proves our HMAC-SHA256 invocation matches the standard. These are published RFC 4231
cases; the test runs CryptoKit `HMAC<SHA256>` against them.

| Case | key | data | HMAC-SHA256 |
|------|-----|------|-------------|
| TC1 | `0x0b`×20 | `"Hi There"` | `b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7` |
| TC2 | `"Jefe"` | `"what do ya want for nothing?"` | `5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843` |

---

## 3. Tier 2 — beacon framing KATs (token = 16-byte truncation)

Each row is `HMAC-SHA256(S, TAG ‖ epoch_be8 ‖ label)[0..<16]`.

| ID | S | epoch | label | token (16B) | proves |
|----|---|-------|-------|-------------|--------|
| V1 | S1 | 0 | LA | `6a332966a02fb42e762af3f14bf50a6a` | baseline framing |
| V2 | S1 | 1 | LA | `3afeeb02c195d9bbf287fb52a8ae54f6` | epoch changes token |
| V3 | S1 | 2 | LA | `bec0470d5fec95bab0f80a4cbd1b7356` | epoch changes token |
| V4 | S1 | 0 | LB | `4f1ff000e02fc46eb93022962142dbdb` | direction/label changes token |
| V5 | S2 | 0 | LA | `6a8f66118346ae5abe9b413dbf940c63` | pairing-secret separation |
| V6 | S1 | 1900000 | LA | `3d8b9ac310b1f3fa908f97fbbb7d5d09` | realistic epoch |

Cross-checks the test also asserts:
- V1, V2, V3 are pairwise distinct → epoch skew window `{E0,E1,E2}` yields 3 tokens.
- V1 ≠ V4 (label), V1 ≠ V5 (secret) → directionality and pairing separation hold.

---

## 4. Property tests (alongside the fixed KATs)

- **Decoy non-collision:** random 16-byte decoys do not match any entry in a receiver
  table built from real `(S_i, label_i)` pairs (probabilistic; assert over many trials).
- **Determinism:** same `(S, epoch, label)` → same token across calls.
- **Recognition round-trip:** emitter token for `(S_AB, E, L_self)` is found by a
  receiver predicting `(S_AB, E, L_self)`; a stranger secret `S_X` yields no match.
- **`now` injection:** epoch is computed from an injected timestamp, never the wall
  clock, so lifecycle tests are deterministic.

---

## 5. Related

- `RECONNECT_DISCOVERY_SECRET_KAT.md` — derivation of `S_AB`, the key used here.
- `NOSTR_INBOX_TAG_KAT.md` — the v59 Nostr inbox tag. Same directional-label idea,
  **separate primitive in a separate file**: it uses a different domain string, no
  truncation, and a curve-validity search. It does not call `ReconnectBeacon.token`
  and must not modify it.
