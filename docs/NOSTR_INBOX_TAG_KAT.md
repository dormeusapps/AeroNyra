# Nostr Inbox Tag — Framing & Known-Answer Vectors

**v59 connection-leak fix · Stage 1 · the KAT spec the primitive's XCTest is written from**
**Written 2026-09-14 · anchors HMAC-SHA256 to RFC 4231 and the curve predicate to
libsecp256k1 · all vectors computed out-of-impl (Python + coincurve 21.0.0, which
links the real libsecp256k1) before any Swift**

This is the external reference the inbox-tag primitive is anchored to **before**
implementation, per project discipline. The Swift test asserts CryptoKit's output
against these exact bytes. Do not edit a vector without recomputing the whole set.

**Stage 1 is this primitive and this test. Nothing else.** No transport, no table,
no padding, no wire change.

---

## 0. What this is for

Today the `p` tag on every published event and on the REQ filter carries an npub in
the clear, and both ride the same WebSocket task. A relay operator reads the
sender↔recipient graph off one connection (v59 §2).

This primitive replaces that value with a per-direction tag keyed on the pair secret
`S_AB`, so the relay sees an opaque, epoch-scoped identifier instead of a durable,
portable one.

`S_AB` comes from `DiscoverySecret.derive` and is an **opaque input** here; its
derivation is a separate primitive with its own KAT
(`RECONNECT_DISCOVERY_SECRET_KAT.md`).

---

## 1. Framing (LOCKED for v1)

```
TAG        = "AeroNyra/nostr-inbox-tag/v1"     (UTF-8, fixed; bumping it = new version)
epoch      = UInt64, BIG-ENDIAN, 8 bytes        floor(unixSeconds / 86400); now is INJECTED
label      = emitter's 32-byte RAW identity key (the directional component)
counter    = UInt8, single byte, starts at 0

message(c) = TAG ‖ epoch ‖ label ‖ counter
h(c)       = HMAC-SHA256(key = S_AB, message(c))          full 32 bytes, NO truncation
tag        = the first h(c), for c = 0, 1, 2, …, that satisfies CURVE-VALID below
wire form  = lowercase hex, 64 chars, as the `p` tag value
```

**CURVE-VALID(b)**, for a 32-byte big-endian value `b` → integer `x`:

```
p = 2^256 − 2^32 − 977
valid  ⇔  0 < x < p  AND  (x³ + 7) mod p is a quadratic residue mod p
```

Equivalently: `secp256k1_xonly_pubkey_parse` succeeds. Both formulations were run
against all vectors below and agree on every value tested.

`x³ + 7 ≡ 0` is **provably unreachable** in F_p — it would be a point of order 2, and
the group order is prime and odd; confirmed computationally (−7 is not a cube mod p).
No zero-case branch is needed.

Fixed inputs used below (hex), deliberately the same as `RECONNECT_BEACON_KAT.md` so
the two sets are diffable:

```
TAG   4165726f4e7972612f6e6f7374722d696e626f782d7461672f7631
S1    000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
S2    1111111111111111111111111111111111111111111111111111111111111111
LA    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
LB    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
```

### Why each choice is what it is

- **32 bytes, no truncation — forced, not preferred.** strfry rejects any `p` or `e`
  tag whose value is not exactly 64 characters and hex-decodable
  (`events.cpp:40-42`), and the filter side hex-decodes `#p` and requires exactly 32
  bytes (`filters.h:186-189`). A 16-byte tag under `p` is refused by all three
  default relays. Truncating and moving to another tag letter was rejected: it breaks
  both writers (`NostrGiftWrap.swift:110`, `NostrTransport.swift:866`), three test
  assertions, and the NIP-59 shape that lets our wraps sit among other kind-1059
  traffic.

- **Curve-valid — the wire format locks at Stage 5 and Stage 5 is a flag day.**
  Roughly half of raw HMAC outputs are not valid x-only x-coordinates (measured:
  1,009 of 2,000). A relay that tested curve membership would see half our `p` values
  fail and could label our traffic as a set. strfry does not test this today, and the
  subscription-id prefix (`NostrTransport.swift:200`) already names the app, so the
  *immediate* gain is nil — but changing the tag's shape after 1.0 is public costs a
  second flag day, and this is the last moment the cohort is TestFlight-only. Pay the
  one byte of counter now.

- **Counter in the message, not a nonce beside it.** The search must be deterministic
  and identical on both sides: the publisher computes `tag(A→B, e)`, the subscriber
  predicts the same value from the same inputs. Framing the counter into the HMAC
  message keeps the whole tag a pure function of `(S_AB, epoch, label)`.

- **Counter cap 255.** Exhaustion is a precondition failure, not a runtime path
  — P(c > 255) ≈ 2⁻²⁵⁶. Measured distribution over 5,000 tags: mean ≈ 1.0 extra
  iteration, max c = 10.

- **label is always the EMITTER's identity.** A device publishes, per contact, the
  tag labelled with its **own** identity; it predicts a contact's tag using **that
  contact's** identity. `tag(A→B) ≠ tag(B→A)`, so no pairing edge is visible.

- **No constant-time requirement.** Matching is a hash-set lookup, not secret
  equality. HMAC is constant-time via CryptoKit; the curve predicate operates on a
  value that becomes public the moment it is published.

- **86,400-second epochs — forced by the filter budget.** The subscribe window is 30
  days back plus 1 ahead. At the BLE production width of 900 s
  (`FirstContactCoordinator.swift:268`) that is 2,977 tags for a *single* contact,
  against a cap of 2,047 hex-decoded 32-byte values in one filter's value array
  (`filters.h:41`). One contact would overflow one filter. At 86,400 s it is 32 tags
  per contact; 12 contacts is 384 tags, ~26 KB on the wire, inside every limit
  including nos.lol's 131,072-byte frame. **This width is a Nostr-side constant. It
  is not a change to the BLE epoch.**

- **This is a NEW primitive in a NEW file.** `ReconnectBeacon.token` hardcodes both
  its domain (`:70`) and `tokenLength = 16` (`:44`, `:77`), in a file whose header
  marks its constants LOCKED. It cannot express this framing without a signature
  change to a KAT-locked, live-BLE-path function. v59 §3's phrase "the existing BLE
  reconnect primitive under a new domain string" is **false as written**: we
  reproduce the construction, we do not call it. "No new cryptography" survives —
  this is HMAC-SHA256 plus a public validity test.

---

## 2. Tier 1 — HMAC-SHA256 primitive anchor (RFC 4231)

Proves our HMAC-SHA256 invocation matches the standard. Published RFC 4231 cases;
the test runs CryptoKit `HMAC<SHA256>` against them.

| Case | key | data | HMAC-SHA256 |
|------|-----|------|-------------|
| TC1 | `0x0b`×20 | `"Hi There"` | `b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7` |
| TC2 | `"Jefe"` | `"what do ya want for nothing?"` | `5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843` |

---

## 3. Tier 1b — curve-validity predicate anchor

Pins CURVE-VALID independently of the HMAC, so a predicate regression cannot hide
behind correct hashing. Both formulations agree on every row.

| Case | x (hex) | CURVE-VALID | proves |
|------|---------|-------------|--------|
| C1 | `79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798` | **true** | generator G.x accepted |
| C2 | `0000…0000` (x = 0) | **false** | zero rejected |
| C3 | `0000…0001` (x = 1) | **true** | small valid x |
| C4 | `0000…0002` (x = 2) | **true** | small valid x |
| C5 | `0000…0003` (x = 3) | **true** | small valid x |
| C6 | `fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2e` (x = p−1) | **false** | in-field but not on curve |
| C7 | `fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f` (x = p) | **false** | out of field rejected |

C6 and C7 are distinct failures — one is a curve test, one is a range test. Assert
both.

---

## 4. Tier 2 — inbox-tag framing KATs

Each row is the first curve-valid `HMAC-SHA256(S, TAG ‖ epoch_be8 ‖ label ‖ c)`,
scanning `c` upward from 0. **The counter is part of the assertion** — a correct tag
reached with the wrong counter means the search diverged.

| ID | S | epoch | label | c | tag (32B) | proves |
|----|---|-------|-------|---|-----------|--------|
| N1 | S1 | 0 | LA | 0 | `b1c25406911c8c4c9f9b0b9c154018f81f2022ca5371eac1fb03b78849c49ba0` | baseline framing |
| N2 | S1 | 1 | LA | 0 | `ef4def82e2f091b1dca4a72e7d8ea43d8992dff3876e17ff518bd122fea8bdb1` | epoch changes tag |
| N3 | S1 | 0 | LB | 0 | `61bdfb6891c688d02d83ca69699b39593c38ec158d2fac36a00cae21d06d5cac` | direction/label changes tag |
| N4 | S2 | 0 | LA | 0 | `42b02b584c0fc600830e69a483f34f4d82351a5344faf643eb13e91978026989` | pair-secret separation |
| N5 | S1 | 20710 | LA | 0 | `e2040b8422ba4aa5e05e44d9bad5d1e5c8182a1101c612c6bf75e023cec8882a` | realistic epoch (2026-09-14) |
| N6 | S1 | 2 | LA | **3** | `98ed9f9f76f47b942929bfdd09472120f5fe72cad42559c5eb32d2dbfd970904` | **exercises the search loop** |

**N6 is the load-bearing vector.** N1–N5 all land on `c = 0` and would pass against
an implementation that never increments. N6 requires three rejections before the
fourth candidate is accepted. If N6 is dropped from the test, the search is untested.

Cross-checks the test also asserts:

- N1, N2, N6 pairwise distinct → epoch changes the tag.
- N1 ≠ N3 (label) → directionality holds.
- N1 ≠ N4 (secret) → pair separation holds.
- Every N is CURVE-VALID and parses as an x-only public key.
- **Domain separation:** `N1[0..<16] != 6a332966a02fb42e762af3f14bf50a6a`
  (`RECONNECT_BEACON_KAT.md` V1, same S1/epoch 0/LA under the beacon TAG). Same
  inputs, different domain, different output.

---

## 5. Property tests (alongside the fixed KATs)

- **Determinism:** same `(S_AB, epoch, label)` → same tag and same counter across calls.
- **Round-trip:** the publisher's tag for `(S_AB, E, L_self)` equals the subscriber's
  prediction for `(S_AB, E, L_self)`; a stranger secret `S_X` yields no match.
- **Direction:** `tag(S_AB, E, L_A) != tag(S_AB, E, L_B)` over fresh random pairs.
- **Separation over fresh pairs:** independent random `(S, label)` produce distinct
  tags (probabilistic, assert over many trials).
- **Every output is curve-valid**, asserted over many random inputs — not just the
  six fixed rows.
- **Counter distribution sanity:** over ≥1,000 random inputs the mean counter is ≈ 1
  and the max is well under the 255 cap. A mean near 0 means the predicate is
  accepting everything; a mean near 255 means it is accepting nothing. Both are
  silent failures that fixed vectors alone would catch only by luck.
- **`now` injection:** epoch is computed from an injected timestamp, never the wall
  clock.
- **Decode independence:** changing the `p`-tag value does not affect unwrap — it
  checks kind, signatures and the two NIP-44 layers only
  (`NostrGiftWrap.swift:126-158`) and the inbound handler filters on kind alone
  (`NostrTransport.swift:685`). Assert this so a later change cannot quietly make the
  tag load-bearing on receive.

---

## 6. Carried forward — read before Stage 3

Two ways the decoy padding can be built so that it does nothing. Neither is a Stage 1
change; both are recorded here because the reasons live in this framing.

- **Decoys must themselves be curve-valid.** The beacon padded with random 16-byte
  values, which was fine on BLE. Here, a random 32-byte decoy fails the curve test
  about half the time, so a relay could split the subscribe set into "plausible
  pubkeys" and "not", and the real contact count falls straight out. Generate decoys
  through the same CURVE-VALID search.

- **Decoys must be stable for the whole epoch.** If the padding is re-randomised on
  each re-REQ, a relay diffs two subscriptions within one epoch and everything that
  changed is a decoy — which unmasks the real tags exactly. Derive decoys
  deterministically from a device-local secret and the epoch, so every re-REQ in an
  epoch presents a byte-identical set. The heal path at `NostrTransport.swift:428`
  re-sends the REQ on every reconnect, so this will be exercised constantly.

---

## 7. Implementation notes (asserted, not assumed)

- **Blocker, not a detail:** `ReconnectBeacon.swift`, `ReconnectEpochBuilder.swift`,
  `BeaconRecognizer.swift` and their tests **must not appear in the Stage 1 diff**. If
  they do, stop. The live BLE path is out of scope for this stage and for this fix.
- **HMAC:** CryptoKit `HMAC<SHA256>`, keyed by `S_AB`.
- **Curve predicate:** the vendored libsecp256k1 in `Core/Nostr/` is the reference; a
  pure field-arithmetic Legendre check is an acceptable equivalent and the test
  asserts the vectors regardless of which surface is used. If both are present,
  assert they agree.
- **Exact Swift signatures are locked against the compiler at code time, not before**
  — per the project's never-guess-an-API rule. This doc fixes the *bytes*; the Swift
  fixes the *calls*.
- **Test placement:** `BeaconTests/`, one `final class <Subject>Tests: XCTestCase`,
  XCTest only, matching `ReconnectBeaconTests.swift`. `BeaconTests` is a
  `PBXFileSystemSynchronizedRootGroup` with no exception set
  (`project.pbxproj:159-163`), so a new file joins the test target with no pbxproj
  edit — but **a green build proves only that the file parsed**. Evidence is the new
  class and method names appearing in the `.xcresult` test list.
- **`Data.hexString`** is redefined privately per test file in this tree
  (`ReconnectBeaconTests.swift:160`, `ContactAllowlistCodecTests.swift:146`). Follow
  the existing pattern rather than hoisting it.

---

## 8. Provenance

Every vector in §2, §3 and §4 was computed out of implementation, in Python, before
any Swift existed. The curve predicate was cross-checked three independent ways on
every value — Legendre symbol, constructive square root (`p ≡ 3 mod 4`), and
`secp256k1_xonly_pubkey_parse` via coincurve 21.0.0 — and all three agree on every
row and on 5,000+ generated tags.

The same script reproduces all six vectors of `RECONNECT_BEACON_KAT.md` exactly,
which is what anchors this document's framing implementation to the one already
shipped.
