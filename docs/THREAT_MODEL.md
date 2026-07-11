# AeroNyra — Sender-Identity Threat Model

**Phase 9a-1 · Metadata hardening**
**Written 2026-06-29 · Status section updated 2026-07-09**

Scope of this document: what an adversary can learn about **who sent a message**,
across both transports, and which exposures Phase 9 will close, defer, or
accept-and-document. It is the prerequisite for the rest of Phase 9 (9b
fixed-size padding, 9c rotating BLE identifiers) and deliberately defines the
problem before any code changes.

This is a *sender-identity* model. Message length is out of scope here (9b).
Long-term radio linkability is out of scope here (9c). Recipient-side metadata
is noted where it bears on the design but is not a 9a deliverable.

> **Reading note for agents.** §1–§8 are the model as written on 2026-06-29. §9
> is a later addition recording which exposures have since been closed, by which
> commit, and what new exposures have appeared. **Where §9 contradicts an earlier
> section, §9 is current and the earlier section is historical.** Real source on
> disk outranks both.

---

## 1. System recap (what's on the wire)

AeroNyra carries one opaque `Envelope` over two transports:

- **BLE mesh** (Pillar 1): broadcast flooding. `Envelope.wireData()` rides a
  framed GATT write/notify (`[type][len][payload]`). Sealing is libsignal
  (PQXDH + Triple Ratchet), identity bridged from a Secure-Enclave Curve25519
  key.
- **Nostr** (Pillar 2): addressed delivery. The same sealed `Envelope` is
  NIP-59 gift-wrapped and published to a relay.

The `Envelope` itself exposes only a routing minimum in cleartext:
`version (1B)`, `ttl (1B)`, and a random 16-byte `id`. There is **no sender
field and no destination field**. Everything identifying lives inside
`ciphertext`, which is the libsignal seal output.

---

## 2. Adversaries

| ID | Adversary | Position | Can decrypt? |
|----|-----------|----------|--------------|
| **A** | Passive RF sniffer (BLE) | In radio range; captures every frame | No |
| **B** | Malicious relaying peer (BLE) | A mesh node that forwards traffic | No |
| **C** | Relay operator / observer (Nostr) | Sees published events + our subscription | No |
| **D** | Compromised recipient | The intended counterparty | Yes (by design) |

Adversary **D** always learns the sender — that is what it means to receive a
message — and is out of scope for sealed sender. **A** and **B** see identical
wire bytes; **B** additionally learns the source *link* (split-horizon requires
it) and participates actively, but holds no keys, so it cannot open an
`Envelope`. **C** sees who receives and when, but not who sent (see §4).

---

## 3. Nostr leg — sender is sealed (no 9a action)

Confirmed against `NostrGiftWrap.wrap` and `NostrEvent`:

- The outer gift wrap (kind 1059) is signed by a **fresh ephemeral key** minted
  per envelope (`randomScalar()`), with `created_at` back-dated by a random
  offset in `[0, 2 days]` (`randomizedTimestamp`, NIP-59), and tagged only
  `["p", peerHex]`. The event's `pubkey` field is the ephemeral key, never our
  npub.
- Our **real** secp256k1 key signs only the *seal* (kind 13), which is NIP-44
  encrypted inside the wrap. Our identity therefore appears only inside
  ciphertext that only the recipient can open.
- The rumor (kind 20059) carries our real pubkey but sits two encryption layers
  deep.

Nothing in the call path above the wrap re-leaks the sender
(`send` → `routeOut` → `router.send(nostrRecipient:)` → `publishViaNostr` →
`addressed.publish` → `wrap`; the sender secret is consumed only inside the
encrypted seal). **Adversary C learns recipient + timing + size, never sender.**

### Structural invariant (load-bearing)

A `PreKeySignalMessage` — the one libsignal frame that embeds the sender's
long-term identity key (see §4) — **can never traverse Nostr.** The Tier-2
fallback requires `peer.nostrPubkey`, which is only learned by opening a sealed
`.nostrIdentity` payload, which requires an established session in both
directions. By the time Nostr is addressable, the handshake is well past the
prekey stage. Therefore the identity-key exposure in §4 is **BLE-only**, and any
fix targets BLE alone.

---

## 4. BLE leg — first contact emits the long-term identity key in clear

Steady-state BLE is already sealed; first contact is not. The session store
makes both facts explicit in code, not by inference.

### 4.1 Steady state — already sealed

`SignalSessionStore.openInbound`'s `.whisper` branch performs trial decryption
across established sessions: a steady-state message carries **no sender
identity**, so the sender is "whichever session opens it." A passive observer
reads opaque bytes and a length. This is the desired sealed-sender property, and
it already holds. The store's own comment calls this "the honest interim until
sealed sender lands" — the audit's conclusion is that for steady state, this
*is* the destination, not an interim.

### 4.2 Exposure #1 — the PreKeySignalMessage

The first message from an initiator is a `PreKeySignalMessage`. In
`openInbound`, the `.preKey` branch does `message.identityKey.serialize()` —
reading the sender's long-term identity key **straight from the message bytes,
with no session required.** A sniffer parses the same field identically. The
PreKeySignalMessage framing carries `identityKey` and `registrationId` as
plaintext; only the inner payload is encrypted.

Worse, the discriminator is cleartext: `openInbound` switches on
`payload.first` (the libsignal message-type byte), so **A/B can distinguish
first contact (`.preKey`) from steady state (`.whisper`) before inspecting
anything else** — a reliable "two parties are meeting for the first time, right
now" signal, with the initiator's identity key attached.

### 4.3 Exposure #2 — the PrekeyBundle

On every new link, `FirstContactCoordinator.sendOurBundle` emits
`store.localPrekeyBundle().data` (= `BundleWire.encode(freshBundleMaterial)`).
`peerIdentity(from:)` decodes `decoded.identityKey` with **no session**,
confirming the bundle wire exposes the identity key in a parseable field. The
vendored `PreKeyBundle` enumerates the full contents: `identityKey`,
`registrationId`, `deviceId`, EC prekey, signed prekey + signature, and Kyber
prekey + signature.

The bundle is "link-local" *logically* (sent to one link, never relayed), but
BLE is a **broadcast radio** — any Adversary A in range captures the frame and
reads the identity key directly. This is the strongest linkable identifier
AeroNyra emits.

*(Closed 2026-07-07 — see §9.1.)*

### 4.4 BLE advertisement (adjacent, not identity)

`startAdvertising` broadcasts a fixed `serviceUUID` and
`CBAdvertisementDataLocalNameKey: "AeroNyra"`. This does not leak *sender
identity* (it is identical for every install), but it fingerprints the app and
announces device presence. The CoreBluetooth peripheral identifier is ephemeral
across sessions but stable *within* one. Both belong to **9c** (rotating BLE
identifiers), recorded here because they interact with §6.

---

## 5. Why Signal-style sealed sender does not apply

LibSignal's sealed sender (`SenderCertificate` / `UnidentifiedSenderMessage`)
presumes a **server** that issues certificates binding identity to account.
AeroNyra has no server and no accounts by design. The mesh's "sender = decrypting
session" already delivers the steady-state property the certificate scheme
exists to provide, without any certificate authority. **9a must not bolt on the
certificate path** — it is the wrong tool for a serverless mesh and would
introduce an authority the architecture deliberately omits.

---

## 6. Coupling: 9a gates 9c

Rotating BLE identifiers (9c) hide "the same radio over time." But if first
contact keeps broadcasting a **stable** `identityKey` + `registrationId` in the
bundle (§4.3), a sniffer simply re-links a device by its identity key and 9c's
benefit collapses. The two phases must be decided together: **the value of 9c is
bounded by what 9a does about over-RF first-contact key material.**

The realistic mitigation is *not* "encrypt the bundle" — first contact is a
chicken-and-egg problem (no shared secret yet). It is to move first contact
**off the radio**: the `onBundle` path is already carrier-neutral and accepts a
QR-pasted bundle, so an out-of-band (QR) first contact keeps the identity key off
RF entirely. Over-RF bundle exchange then becomes the explicitly-weaker,
documented fallback.

---

## 7. Disposition (as of 2026-06-29 — current state in §9)

| Exposure | Adversary | Disposition |
|----------|-----------|-------------|
| Nostr outer event reveals sender | C | **Closed** — ephemeral key + encrypted seal (§3) |
| Nostr recipient `#p` tag reveals recipient | C | **Accepted/tracked** — inherent to NIP-59 addressed delivery; recipient-side, not 9a |
| Our Nostr subscription binds npub ↔ IP ↔ online time | C | **Accepted/tracked** — recipient-side presence; revisit with multi-relay / Tor-style transport later |
| BLE steady-state sender | A, B | **Closed** — sender = decrypting session (§4.1) |
| BLE PreKeySignalMessage leaks identity key + `.preKey` tell | A, B | **9a-2** — move first contact off-RF (QR-preferred) |
| BLE PrekeyBundle broadcasts identity key over RF | A, B | **9a-2** — same mitigation |
| BLE service UUID / local name / CB id linkability | A, B | **9c** — rotating identifiers (gated by 9a-2) |
| Ciphertext length leaks message length | A, B, C | **9b** — fixed-size padding |

---

## 8. Phase 9a plan (derived from this model)

- **9a-1** *(this document)* — threat model committed to the repo.
- **9a-2** — first-contact posture: QR-preferred first contact (identity key off
  RF); over-RF bundle exchange documented as the weaker fallback.
- **9a-3** — close the steady-state sealed-sender ledger line: confirm no
  certificate machinery is to be added (§5) and that §4.1 is the intended
  end-state, not an interim.

Recipient-side Nostr metadata (the `#p` tag and subscription linkability) is
recorded in §7 as tracked, to be revisited alongside multi-relay work — it is
not a Phase 9a item.

---

## 9. Status — what has closed, what remains, what is new

*Added 2026-07-09. Grounded in landed commits and hardware-verified results.*

### 9.1 Closed since this doc was written

**§4.3 — the over-RF PrekeyBundle broadcast is deleted.** Commit `ce57ae8`
removed `sendOurBundle` entirely. It was deleted, not gated: identity is not
known at greet time, so there was nothing to gate on. Enrolled contacts bootstrap
their session from the QR / invite payload instead. This is the mitigation §6
prescribed — first contact moved off the radio. It also closed the closed-contact
admission caveats (stranger-session formation, stranger `Peer`-row insert).

**Identity-bearing log statements.** Commit `3f28750` added
`Core/Routing/RedactLog.swift` — an `os.Logger` choke point with `privacy:
.private`, where identity detail is compiled only under `#if DEBUG` and the
release build emits a contentless label. 36 leaking sites were routed through it.
**Verified on hardware in Release configuration**, both at startup and on the
live pairing path.

**§7 row — ciphertext length.** Phase 9b shipped. `PayloadBucket` pads to a
256 / 1024 / 4096 / 16384 ladder.

**§8 reconnection.** The sealed connect-time auth handshake is built and
KAT-anchored. See `RECONNECT_HANDSHAKE.md`, `RECONNECT_BEACON_KAT.md`,
`RECONNECT_DISCOVERY_SECRET_KAT.md`.

### 9.2 Still open

**§4.2 — the PreKeySignalMessage.** Not resolved by `ce57ae8`. Removing the greet
closed the *unsolicited bundle broadcast*; it did not change the fact that a
libsignal `PreKeySignalMessage` carries `identityKey` and `registrationId` in
plaintext framing, nor that the message-type byte distinguishes `.preKey` from
`.whisper` to a passive observer. **Whether the bootstrap prekey message still
traverses BLE after QR/invite pairing must be verified against real source before
this row is called closed.** Do not assume.

**§4.4 — the advertisement local name.** `CBAdvertisementDataLocalNameKey:
"AeroNyra"` still broadcasts. Not identity-bearing (identical for every install),
but it fingerprints the app. Tracked, unfixed.

**Nostr recipient-side metadata.** The `#p` tag and subscription linkability
remain accepted/tracked, unchanged.

### 9.3 New exposures found since

**iOS logs the full invite URL to the device console.** When an
`aeronyra://invite/…` URL is opened, the OS URL router emits
`Cannot issue sandbox extension for URL:aeronyra://invite/…` containing the
complete string — **prekey bundle and long-term identity key included** — in a
Release build. This is platform code; no app-side logging change suppresses it.

Assessed acceptable: the console is local and sandboxed, the invite is designed
to traverse untrusted channels, and reading it requires an unlocked, paired
device. Recorded because it means the "identity off open RF" principle has a
platform-side hole on the *invite* path that `ce57ae8` does not close. A device
sysdiagnose captures it.

**`UIBackgroundModes = (bluetooth-central, bluetooth-peripheral)` ships in the
Release Info.plist.** Whether CoreBluetooth **state restoration** is actually
armed behind it — a `CBCentralManagerOptionRestoreIdentifierKey` and a
`willRestoreState` implementation — **has not been verified.** If it is, a
headless relaunch on a locked device makes `store.load()` throw a non-`notFound`
error, `bootstrap()`'s catch-all routes to `.onboarding`, and one tap runs
`overwrite: true` — **destroying the real identity and every pairing,
unrecoverably.** See `BLE_BACKGROUND_WAKE_DESIGN.md`. **This must be checked
before any archive.**

> **CLOSED (verified against source, this cannot occur).** The catch-all this
> entry feared no longer exists. Three facts, each in source: (1) state
> restoration is not armed — `CBCentralManagerOptionRestoreIdentifierKey` and
> `willRestoreState` appear nowhere, so the trigger is absent regardless; (2)
> `IdentityStore.load()` maps a locked Keychain (`errSecInteractionNotAllowed`)
> to `.keychain(status)`, NOT `.notFound`
> (`Security/Identity/IdentityKeypair.swift:269-273`) — "locked" and "absent"
> are distinct errors; (3) `BootRouter.route` sends ONLY `.notFound` to
> `.onboarding`, every other throw to `.bootFailed(.identityUnreadable)`, and
> runs `buildStack` only after a successful load (`Beacon/BootRouter.swift:60-63`),
> which `bootstrap()` consumes one-arm-per-route with no catch-all
> (`Beacon/ContentView.swift:278-291`). So a locked-Keychain relaunch routes to
> `.bootFailed(.identityUnreadable)`, never destructive onboarding. Regression-
> locked: `BootRouterTests.testLockedKeychainRoutesToBootFailedUnreadable` asserts
> `.bootFailed(.identityUnreadable)` with `buildStackCalls == 0`. The original
> risk text above is kept as the historical record. (`BLE_BACKGROUND_WAKE_DESIGN.md`
> is currently missing from disk — flagged for restoration; not load-bearing for
> this closure, which rests on source + tests.)

### 9.4 Current disposition

| Exposure | Adversary | Disposition |
|----------|-----------|-------------|
| Nostr outer event reveals sender | C | **Closed** (§3) |
| Nostr `#p` tag reveals recipient | C | **Accepted/tracked** |
| Nostr subscription binds npub ↔ IP ↔ online time | C | **Accepted/tracked** |
| BLE steady-state sender | A, B | **Closed** (§4.1) |
| BLE PrekeyBundle broadcasts identity key | A, B | **Closed** — `ce57ae8` deleted `sendOurBundle` |
| BLE PreKeySignalMessage leaks identity key + `.preKey` tell | A, B | **Open — verify against source** (§9.2) |
| Ciphertext length leaks message length | A, B, C | **Closed** — 9b padding ladder |
| BLE service UUID / local name / CB id linkability | A, B | **Open** — advertisement local name unstripped |
| Identity in app logs | local | **Closed** — `RedactLog`, Release-verified |
| Identity in OS URL-router logs | local | **Accepted/documented** (§9.3) |
| Locked-Keychain identity overwrite via BLE restoration | — | **Closed** — `BootRouter` single-preimage routing + `load()` error taxonomy, regression-tested (§9.3) |
