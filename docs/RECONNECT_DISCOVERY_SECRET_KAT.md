# Reconnect Discovery Secret (S_AB) — Derivation Framing & Known-Answer Vectors

**Closed-Contact · Step 5c · the KAT spec the S_AB derivation primitive's XCTest is written from**
**Written 2026-06-30 · anchors X25519 to RFC 7748 §6.1 and HKDF-SHA256 to RFC 5869; the v1 framing vector computed out-of-impl (Python) before any Swift**

> **Restored 2026-09-14**, alongside `RECONNECT_BEACON_KAT.md`, after `docs/` was found
> holding only three files while the canon list named six. Content is byte-identical to
> the last known copy. Before restoring, every vector below was recomputed and matched
> exactly: RFC 7748 §6.1 public keys and shared point `K`, DH symmetry, RFC 5869 TC1 and
> TC3 (PRK and OKM), the `C` public key, and DV1/DV2/DV3 including the DV1 symmetry
> cross-check. This document is confirmed against the construction, not merely retrieved.

This is the external reference the discovery-secret primitive is anchored to **before**
implementation, per project discipline — the sibling of `RECONNECT_BEACON_KAT.md`. The
beacon KAT treats `S_AB` as an opaque input; this doc specifies how `S_AB` is *produced*
and pins its bytes. The Swift test asserts CryptoKit's output against these exact values.
Do not edit a vector without recomputing the whole set.

---

## 0. Where this sits

`BeaconRecognizer.Contact.secret` (the per-pairing discovery secret `S_AB`) is **injected**
into the beacon layer — the recognizer is deliberately independent of how `S_AB` is derived.
This primitive fills that slot. It is the one place the long-term **X25519 identity agreement
key** is used for discovery, and it is used **nowhere else in the protocol**: a bare
identity×identity static DH is not one of the X3DH/PQXDH DH combinations (those mix
ephemerals/prekeys for forward secrecy and never combine the two static identities), so this
DH output is computed in no other code path. Domain separation via `info` (§1) closes the
residual concern regardless.

The key is reachable directly: `IdentityKeypair.agreement` is a CryptoKit
`Curve25519.KeyAgreement.PrivateKey` (software-resident at runtime; the Secure Enclave only
wraps the at-rest blob). No libsignal, no Enclave round-trip, no raw-scalar handling.

---

## 1. Framing (LOCKED for v1)

```
ikm   = X25519(our identity-agreement PRIVATE key, their identity-agreement PUBLIC key)
        = the 32-byte raw X25519 shared point
salt  = ""                                          (empty / zero-length)
info  = "AeroNyra/discovery-secret/v1"              (UTF-8, fixed; bumping it = new version)
S_AB  = HKDF-SHA256(ikm, salt, info, L = 32)        (32-byte key; a CryptoKit SymmetricKey)
```

- **The agreement key, not the signing key.** `ikm` is built from the X25519
  `Curve25519.KeyAgreement` key — i.e. `PublicIdentity.userID` (= `agreementKey`), the same
  raw 32-byte key the beacon uses as its `label` and that `BeaconRecognizer.Contact.identity`
  carries. One key serves label, DH peer-input, and recognizer. The Ed25519 signing key is
  not involved.
- **Symmetric, no canonicalization.** X25519 DH is symmetric: `DH(a_priv, B_pub)` and
  `DH(b_priv, A_pub)` yield the identical point, hence identical `S_AB`. Because no public-key
  material is folded into `salt`/`info`, both sides feed byte-identical HKDF inputs and reach
  the same `S_AB` with zero tie-break or sort logic.
- **No public-key fold (DECIDED).** `salt` is empty and `info` is the bare domain label. The
  DH output already binds `S_AB` to the exact pair (it is a function of both keys), so folding
  `sorted(pubA,pubB)` would be belt-on-belt; the only thing it would buy — insurance against
  low-order/degenerate peer public keys — is already gated by SAS pairing, since a peer key
  must survive the 4-word confirmation to reach the allowlist. Kept simple by design.
- **HKDF, not raw DH bytes.** HKDF is retained for domain separation (`info`) and to condition
  the non-uniform curve-point output into a uniform 32-byte key.
- **Stable ⇒ derive-once-cache (wiring note, not part of this primitive).** Identity keys are
  permanent, so `S_AB` is stable; it is derived once per contact and cached in RAM as
  `Contact.secret`, recomputed only on a key-change alert. At rest, only the contact's *public*
  key is stored — never `S_AB`. The caching/wiring is Step 5d; **this primitive is the pure
  function only**: `derive(ourAgreementPriv, theirAgreementPub) -> SymmetricKey`.

Fixed inputs used below (hex):

```
INFO  4165726f4e7972612f646973636f766572792d7365637265742f7631   ("AeroNyra/discovery-secret/v1", 28 bytes)
```

---

## 2. Tier 1a — X25519 DH anchor (RFC 7748 §6.1, raw 32-byte shared point)

Proves our X25519 invocation matches the standard. These are the published RFC 7748 §6.1
values; the test reconstructs the keys from these raw private/public bytes via
`Curve25519.KeyAgreement.PrivateKey(rawRepresentation:)` / `.PublicKey(rawRepresentation:)`,
performs `sharedSecretFromKeyAgreement`, and asserts the `SharedSecret`'s raw bytes (it is
`ContiguousBytes`) equal `K`.

| field | value (hex) |
|-------|-------------|
| Alice priv `a` | `77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a` |
| Alice pub  `A` | `8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a` |
| Bob   priv `b` | `5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb` |
| Bob   pub  `B` | `de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f` |
| shared `K` | `4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742` |

- `A` and `B` are confirmed to be `X25519(a, 9)` and `X25519(b, 9)` (the test may also assert
  `privateKey.publicKey.rawRepresentation` against them).
- **Clamping:** X25519 clamps the private scalar internally; the RFC's raw private bytes are
  fed as-is and the library clamps them. Reconstructing from these exact bytes therefore
  reproduces `K`. (Verified out-of-impl.)
- **Symmetry:** `DH(a, B) == DH(b, A) == K`. (Verified out-of-impl.)

---

## 3. Tier 1b — HKDF-SHA256 anchor (RFC 5869)

Proves our HKDF invocation matches the standard. TC1 is the canonical RFC 5869 case; **TC3 is
the directly-relevant one — empty salt** — since v1 framing uses an empty salt.

**TC1** (salt + info present, L=42):

```
IKM  = 0x0b × 22
salt = 0x000102030405060708090a0b0c                 (13 bytes)
info = 0xf0f1f2f3f4f5f6f7f8f9                         (10 bytes)
PRK  = 077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5
OKM  = 3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865
```

**TC3** (empty salt, empty info, L=42 — the empty-salt path our framing uses):

```
IKM  = 0x0b × 22
salt = ""
info = ""
PRK  = 19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04
OKM  = 8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8
```

**Empty-salt equivalence (load-bearing note).** HMAC pads a key shorter than the block size
with zeros to the block size, so `HMAC(key="")` equals `HMAC(key=0x00 × 32)` equals
`HMAC(key=0x00 × 64)`. RFC 5869 defines "salt not provided" as HashLen (32) zero bytes.
Therefore CryptoKit's `salt: Data()` (empty), the RFC's "not provided," and this reference
computation all produce the **same** PRK. This is why an empty salt is safe and deterministic.

---

## 4. Tier 2 — S_AB framing KAT (chains off Tier 1a `K`)

The full-pipeline vector. `ikm` is the Tier 1a RFC 7748 shared point `K`, so a passing test
proves DH **and** HKDF **and** the framing in one chain. The test runs
`sharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: INFO,
outputByteCount: 32)` (or the equivalent `HKDF<SHA256>.deriveKey(...)`) and asserts the bytes.

| ID | ikm | info | salt | S_AB (32B) | proves |
|----|-----|------|------|------------|--------|
| **DV1** | `K` (RFC 7748 §6.1) | `AeroNyra/discovery-secret/v1` | "" | `e3c109ab7b8841085689cae5bed1def3bd37ce8390f35cf73187a6a40d4bf380` | baseline framing + full DH→HKDF chain |
| **DV2** | `K` | `AeroNyra/discovery-secret/v2` | "" | `bd97aa67435dd37517b16cf4a9766e2b2b02968bf63d07dc9742b35fe885e417` | `info` domain separation (≠ DV1) |
| **DV3** | `DH(a, C)` | `AeroNyra/discovery-secret/v1` | "" | `cf6d70dbeaeaf9aa713cf8f41cdb27af535c890c2250784162efd4b447833fe7` | pair separation (≠ DV1) |

where for **DV3** the second peer `C` is:

```
C priv = 0x01 × 32
C pub  = a4e09292b651c278b9772c569f5fa9bb13d906b46ab68c9df9dc2b4409f8a209   (= X25519(C_priv, 9))
```

Cross-checks the test also asserts:
- **DV1 symmetry:** computing `S_AB` from `DH(b, A)` instead of `DH(a, B)` yields byte-identical
  DV1 — the no-canonicalization property.
- **DV1 ≠ DV2** (domain separation: bumping `info` changes the key).
- **DV1 ≠ DV3** (pair separation: a different peer changes the key).

---

## 5. Property tests (alongside the fixed KATs)

- **Determinism:** same `(ourPriv, theirPub)` → same `S_AB` across calls.
- **Symmetry over fresh pairs:** for randomly generated A and B,
  `derive(A_priv, B_pub) == derive(B_priv, A_pub)`. (Generative; assert over many pairs.)
- **Separation over fresh pairs:** for independent random pairs, derived secrets differ
  (probabilistic; assert over many trials).
- **Public-input rejection (negative):** a secret built from the two *public* keys alone (no
  private key) is **not** equal to `S_AB` — guards against a regression that would make the
  secret world-computable and collapse beacon unlinkability. (Construct any public-only function
  and assert inequality; this is a guard-rail, not a standard.)
- **Feeds the beacon:** `S_AB` as produced here is accepted as `ReconnectBeacon.token`'s
  `secret:` and round-trips through `BeaconRecognizer` (recognition round-trip already covered
  in `RECONNECT_BEACON_KAT.md` §4 with an injected secret; here we confirm the *derived* secret
  satisfies the same round-trip).

---

## 6. Implementation notes (asserted, not assumed)

- **DH:** `Curve25519.KeyAgreement.PrivateKey(rawRepresentation:).sharedSecretFromKeyAgreement(with:)`
  → `SharedSecret`. Extract raw bytes for the Tier 1a assertion via `withUnsafeBytes` /
  `ContiguousBytes`.
- **HKDF:** `SharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(),
  sharedInfo: Data("AeroNyra/discovery-secret/v1".utf8), outputByteCount: 32)` is the full RFC
  5869 HKDF (extract-then-expand) with the shared secret as IKM. `HKDF<SHA256>.deriveKey(
  inputKeyMaterial:salt:info:outputByteCount:)` is an acceptable equivalent; the test asserts
  the vectors regardless of which surface is used.
- **Exact CryptoKit signatures are locked against the compiler at code time, not before** — per
  the project's "never guess an API surface" rule. This doc fixes the *bytes*; the Swift fixes
  the *calls*.
- **XCTest only.** Tiers 1a/1b/2 are fixed-vector assertions; §5 are property/generative tests.

---

## 7. Related

- `RECONNECT_BEACON_KAT.md` — consumes `S_AB` as an opaque input.
- `NOSTR_INBOX_TAG_KAT.md` — the v59 Nostr inbox tag, which uses the same `S_AB` as its HMAC
  key under a different domain string.
