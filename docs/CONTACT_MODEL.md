# AeroNyra — Closed-Contact & Pairing Model

**Design doc · supersedes the open-mesh first-contact model**
**Written 2026-06-29 · Status section updated 2026-07-09**

This document defines a deliberate pivot in how two AeroNyra devices become able
to talk to each other, and how that decision folds three previously-separate
roadmap items into one coherent design. It is the artifact the implementation is
built against — written and agreed before any code, the same way
`THREAT_MODEL.md` preceded Phase 9a.

Nothing in the cryptographic core changes: sealing, libsignal sessions, the
Triple Ratchet, NIP-59 gift-wrap, and padding are all untouched. What changes is
an **admission policy** layered on top, plus the **first-contact channel**.

> **Reading note for agents.** §1–§13 are the original design as agreed. §14 is a
> later addition: it records what the shipping code actually does, where it
> diverges from this doc, and which open decisions are now closed. **Where §14
> contradicts an earlier section, §14 describes reality and the earlier section
> describes intent.** Real source on disk outranks both.

---

## 1. The pivot

**Before (open mesh):** any AeroNyra device advertises; any device connects to
any peer it discovers; first contact happens over the air with whoever is in
range. Having the app + being nearby was sufficient to exchange keys and message.
This is the model the mixed bitchat reviews react to: strangers can reach
strangers, which is an open door for spam and targeted attack.

**After (closed contact):** having the app and being nearby is **not** a license
to message. Two devices only ever talk if they have **deliberately exchanged
codes first** — like trading phone numbers. A device forms a session only with an
identity it has been paired with; an unknown peer in range is dropped before any
session forms, before any message is possible. There is no door for a stranger to
walk through because no door exists until a code is exchanged.

This is strictly stronger than Apple's iMessage Contact Key Verification, which
*verifies a channel that is already open to anyone*. AeroNyra has **no open
channel until pairing succeeds**. Verification is the front door, not an
afterthought.

---

## 2. The model in one paragraph

To become contacts, two people exchange a pairing code. **Together**, they scan a
**QR code** — the key travels screen-to-camera and is authenticated by physical
proximity, with nothing to confirm afterward. **Apart**, the initiator generates
a **short-lived, single-use invite**, sends it over any channel (text, email,
Signal — the channel need not be secret), the peer redeems it, the two devices
run their key exchange, and then **both screens independently display the same
4-word confirmation phrase**. The two people read the words to each other over a
live voice/video call and each tap "matches." Only then are they contacts. If the
words differ, the app stops them — the invite was tampered with in transit. After
pairing, the two reach each other **near** over BLE mesh and **far** over Nostr;
strangers get neither.

---

## 3. Principles (LOCKED)

- **Closed by default.** No session forms with an unknown identity. Discovery
  reveals presence, never grants reachability.
- **Identity off open RF.** Long-term identity keys never travel over an
  unauthenticated broadcast. They move through the QR scan or the redeemed
  invite. This deletes the BLE first-contact leak (`THREAT_MODEL.md` §4.2/4.3) at
  its source rather than mitigating it.
- **Disposable envelope, permanent identity.** The invite expires; the identity
  key inside it does not.
- **Authenticated when it matters, frictionless when it can be.** QR (together)
  needs no confirmation because proximity authenticates it. The remote invite
  needs the spoken-word confirmation because the channel is untrusted.
- **No raw key material in the everyday UI.** The only code a user ever sees is
  the friendly 4-word phrase during pairing, and it disappears once paired. Key
  integrity over time is enforced by a **silent alert on change**, not by a
  fingerprint the user has to inspect.

---

## 4. Pairing — the two entry points

Both paths converge on the **same** carrier-neutral `onBundle` entry that already
exists: whether the bundle arrives by QR or by redeemed invite, it enters the
session layer identically. What the pivot removes is the *third* source — the
unsolicited over-RF bundle broadcast — which goes away entirely.

### 4.1 Together — QR

The initiator's device renders a QR encoding its **pairing payload** (§6). The
peer scans it with the camera. The key material never leaves the two screens, so
there is no channel an attacker can interpose on. Both sessions form; because the
exchange is physically authenticated, **no spoken confirmation is required** —
the pairing completes on a successful scan in each direction.

(Bidirectional: either both scan each other, or the scan carries enough for the
scanner to reply with its own payload over the freshly-formed channel. Which of
those — see Open Decisions.)

### 4.2 Apart — remote invite + 4-word confirmation

1. Initiator taps "Add by invite"; the device mints a **short-lived, single-use
   invite** (§6, §7) and the user sends it over any channel.
2. Peer opens the invite in AeroNyra and redeems it. The two devices complete the
   key exchange (the invite carries / bootstraps the bundle).
3. **Both devices independently compute and display the same 4-word phrase** from
   the two identity keys (§5).
4. The two people get on a live call, read the words to each other, and each tap
   **Matches** / **Doesn't match**.
5. On *Matches* both sides, they are contacts. On *Doesn't match*, the app aborts
   the pairing and discards the half-formed session — this is the MITM catch.

---

## 5. The 4-word confirmation (the SAS step)

**What it is.** A short phrase derived deterministically from **both** parties'
long-term identity keys. This is the same Short Authentication String mechanism
Apple's Contact Key Verification and Signal's safety numbers use — the audited
gold standard — presented as four words instead of a numeric block for
readability over a phone call.

**Why it is secure.** Because the phrase is a function of *both* identity keys, a
man-in-the-middle who intercepts the invite and substitutes their own key cannot
make both phrases match. To defeat it, the attacker would have to simultaneously
(a) MITM the invite channel **and** (b) MITM the live voice call in real time,
faking a voice the victim recognizes. That dual requirement is the high bar that
makes SAS strong.

**What we reuse.** `SignalSession.safetyNumber()` already produces a fingerprint
from both identity public keys via `NumericFingerprintGenerator` (returning a
`displayString` and a `qrPayload`). The 4-word phrase is a **friendlier encoding
of the same fingerprint material** — same security, different presentation. We
are not inventing crypto here; we are rendering an existing value as words.

**Where it appears.** Only on the pairing screen, only during the apart-flow,
only until pairing completes. See §9 for the deliberate absence of any
fingerprint in the conversation UI.

---

## 6. The pairing payload

The payload exchanged (QR or invite) carries what a peer needs to (a) establish a
session and (b) reach the device later over Nostr:

- the **prekey bundle** — identity key, signed prekey + signature, Kyber prekey +
  signature, one-time prekey. This is exactly what `store.localPrekeyBundle()`
  already serializes via `BundleWire.encode`. (PQXDH / Triple Ratchet, unchanged.)
- the device's **Nostr public key** (raw 32-byte x-only) so the far-reach path
  works from the first message — folding in the npub-bootstrap that currently
  rides a separate sealed announcement.

The QR encodes this directly. The invite carries it plus the invite envelope
(§7). Exact framing — KAT-anchored like every wire format in this project.

---

## 7. Invite lifecycle & expiry

Two distinct lifetimes, and only one expires:

- **The invite** is **short-lived (target ~10 minutes) and single-use.** A code
  screenshotted from a text thread or found a week later is dead. This shrinks
  the interception window to near-nothing. Single-use means redeeming it once
  burns it.
- **The identity key** inside it **never expires.** It is the "phone number" in
  the user's mental model — stable, or every contact would need constant
  re-pairing.

So: a disposable, expiring envelope carrying a permanent identity.

---

## 8. Admission policy

The new layer that makes "closed" real:

- **No unsolicited RF bundle.** `sendOurBundle`-to-every-reachable-link is
  removed. Devices stop throwing their identity key at strangers in range.
- **Allowlist gate.** A bundle is processed into a session only when it arrives
  through the pairing flow (QR scan or invite redemption). An identity not in the
  paired set is never admitted.
- **Drop unknown peers early.** A peer that connects at the radio level but
  resolves to no known contact is dropped before any session work.

### The reconnection crux

Once two devices are paired, walking back into BLE range must reconnect them
**automatically** with no re-pairing (decided: established pairs never re-pair).
But if bundles no longer fly over RF, how does a device tell that an in-range peer
is a known contact versus a stranger — *without* re-leaking identity to a sniffer?

Approach: on BLE connect, run a **sealed authentication handshake over the
already-established session** — the first frame is an authenticated "it's me" that
only a holder of the real session keys can produce, opened by trial against known
contacts' sessions (the same shape as the existing `.whisper` trial-decrypt in
`openInbound`). A stranger holds no session, produces nothing openable, and is
dropped. Identity stays sealed; pairing is the gate.

*(Resolved and shipped — see §14 and `RECONNECT_HANDSHAKE.md`.)*

---

## 9. Key-change handling & the no-fingerprint rule

**Silent alert on change (not a visible fingerprint).** Persistent fingerprints
exist so a user can later notice if a contact's key silently changed (a MITM or a
device swap). We get that protection **without** showing a scary code: if a paired
contact's identity key ever changes, the app raises a **quiet alert** ("this
contact's key changed — re-verify") and pauses the conversation until re-paired.
This mirrors Apple's behavior and Signal's, minus the hex blob.

**No fingerprint in the conversation UI (LOCKED, per product direction).** Tapping
a contact / opening a conversation **never** displays a fingerprint or safety
number. The only verification artifact a user ever sees is the 4-word phrase, and
only during the apart-pairing flow. Any current UI that surfaces a fingerprint
header is to be cleaned up in the UI pass.

---

## 10. What changes vs. what stays

**Unchanged:** all crypto — sealing, sessions, Triple Ratchet / PQXDH, NIP-59
gift-wrap, payload padding (Phase 9b). The Nostr far-reach path. The BLE envelope
transport for *paired* peers. `safetyNumber()`'s underlying fingerprint.

**Changes:** first contact moves from over-RF broadcast to QR / invite. A pairing
UI is added (show/scan QR, generate/redeem invite, 4-word confirm). An allowlist
admission gate is added. The over-RF bundle broadcast is removed. A connect-time
sealed auth handshake gates BLE links. Key-change raises a silent alert. The
npub-bootstrap folds into the pairing payload.

---

## 11. Roadmap impact

This pivot **subsumes** three previously-separate items into one coherent phase:

- **9a-2** (QR-preferred first contact) — becomes *QR/invite-mandatory* first
  contact. Resolved here.
- **9c** (rotating BLE identifiers) — most of it was already handled by iOS
  (automatic MAC rotation) or was a no-op (app link ids are never on the air).
  The one real remaining BLE-layer win (dropping the cleartext `"AeroNyra"` local
  name from the advertisement) folds in here as a small advertisement change. The
  per-device identity leak it was chasing is deleted by §3 "identity off open RF."
- **Phase 10 QR** (safety-number verification UI) — becomes the pairing UI
  described here, with the SAS rendered as 4 words and gated as admission.

Net: instead of three loosely-coupled features, there is one **Closed-Contact**
phase.

---

## 12. Open decisions (original list — dispositions in §14)

1. **QR directionality** — does each side scan the other, or does one scan and
   reply over the freshly-formed channel?
2. **Invite expiry mechanism** — signed expiry timestamp, initiator-tracked
   one-time token, or both. How "single-use" is enforced without a server.
3. **Reconnection auth handshake** (§8 crux) — confirm the sealed connect-time
   proof approach, then give it its own threat note.
4. **Pairing payload framing** — exact bytes of the QR/invite (bundle + Nostr
   key + invite envelope), KAT-anchored.
5. **4-word wordlist** — source/size of the list, how many bits of the
   fingerprint the four words encode, and that it is bidirectionally identical on
   both devices.
6. **Local-name strip** — fold the §11 advertisement cleanup into this phase or
   keep as a tiny standalone commit.

---

## 13. Build sequence (high-level — one green step at a time)

1. **SAS rendering primitive** — fingerprint → 4 words and back, pure + unit
   tested (KAT-anchored wordlist), no UI.
2. **Pairing payload codec** — encode/decode the QR/invite payload, pure + tested.
3. **Invite lifecycle** — mint / expiry / single-use accounting, pure + tested.
4. **Admission gate** — allowlist + drop-unknown in the session layer, tested
   against unknown-peer rejection.
5. **Reconnection auth handshake** — design note first, then primitive, then wire.
6. **Remove over-RF bundle broadcast** + local-name strip.
7. **Pairing UI** — QR show/scan, invite generate/redeem, 4-word confirm screen,
   silent key-change alert. Hardware-verified on two devices.

Each step's threat implications are checked as it lands; the model in this doc is
the reference they are checked against.

---

## 14. Implementation status — what the code actually does

*Added 2026-07-09. Grounded in file:line reads of real on-disk source. Where this
section and §1–§13 disagree, this section is reality.*

### 14.1 Open decisions, resolved

| # | Decision | Disposition |
|---|---|---|
| 1 | QR directionality | Implemented as a single scan → `pairFromScanned`, admitted `verified: true`. Proximity authenticates; no SAS prompt. |
| 2 | Invite expiry mechanism | **Both.** The envelope carries `mintedAt` / `expiresAt` timestamps, *and* the minter keeps a single-use `PendingInvites` ledger. **The ledger is authoritative** — `consume` checks its own stored expiry, never the echoed one. The envelope timestamps are redeemer-advisory. |
| 3 | Reconnection auth handshake | Shipped. See `RECONNECT_HANDSHAKE.md`, `RECONNECT_BEACON_KAT.md`, `RECONNECT_DISCOVERY_SECRET_KAT.md`. |
| 4 | Pairing payload framing | Shipped, KAT-anchored. See §14.2. |
| 5 | 4-word wordlist | Shipped. Derived from `safetyNumber()` fingerprint material. |
| 6 | Local-name strip | Not done. `CBAdvertisementDataLocalNameKey: "AeroNyra"` still broadcasts. Tracked, not identity-bearing. |

### 14.2 Wire facts

- **QR string:** `aeronyra://pair/` + unpadded base64url of the `PairingPayload`
  wire (~1,881 bytes → ~2,524 characters).
- **Invite string:** `aeronyra://invite/` + unpadded base64url of the `Invite`
  wire (version byte · 16-byte id · `mintedAt` · `expiresAt` · length-prefixed
  `PairingPayload`) — ~2,576 characters.
- **Base64url alphabet:** strictly `[A-Za-z0-9_-]`. No `+`, `/`, or `=` in the
  body. The alphabet is transport-safe.
- **Both `Invite(wire:)` and `PairingPayload(wire:)` are the untrusted-input
  boundary and are byte-strict** — version check, fixed offsets, declared
  lengths, trailing-junk rejection. **Any tolerance for mangled human transport
  lives in the string layer above them, never here.** This is an invariant.

### 14.3 The invite envelope is not authenticated. By design.

There is **no signature and no MAC** over the invite envelope (id, `mintedAt`,
`expiresAt`, framing). Rejection at `Invite(wire:)` is a structure/length check,
not an authentication check. Authentication lives *inside* the payload —
libsignal verifies `signedPreKeySignature` and `kyberPreKeySignature` against the
identity key at session establishment.

Consequences, and why this is correct:

- **Expiry is a blast-radius control, not a security boundary.** The 4-word SAS
  confirmation is the actual MITM defense (§5).
- Redeem enrolls the initiator **unverified**. The SAS gate opens verification.
- An attacker who rewrites the envelope gains nothing: a wrong id means the
  minter's ledger finds no match and the echo is ignored under the burn gate — a
  dead half-pairing, never an enrollment. A rewritten `expiresAt` is advisory
  only. A rewritten payload cannot survive libsignal's signature verification.
- **Therefore the string layer must never silently rewrite input into
  well-formed-but-different bytes.** It adds no adversarial capability, but it
  converts a loud, diagnosable failure into a silent dead half-pairing. Normalize
  only provably-transport-inserted artifacts; reject everything else loudly.

### 14.4 Known divergences from this doc

- **§6 violated: `pairFromScanned` ignores `payload.nostrPublicKey`.** A
  QR-paired contact has **no Nostr address and therefore no far path** — BLE
  only. `redeemInvite` threads the key through correctly; the QR path does not.
  This is a bug against §6, not a design choice.
- **§2 aspiration unmet: the invite only reaches the decoder via `onOpenURL`.**
  There is no paste-to-redeem UI. Email and iMessage do not linkify the custom
  scheme, so an invite sent over those channels has **no path into the app** —
  it is not corruption, it is a missing entry point. AirDrop works only because
  iOS offers "Open in AeroNyra." *(Fixes in progress.)*
- **QR renders but does not scan.** The Kyber-1024 prekey pushes the payload to
  ~85% of QR's absolute capacity at correction level L, producing a ~165-module
  symbol. Rendered into a 200 pt tile that is ~1 pt per module, at low contrast.
  Generable, unscannable. Correction level cannot be raised — capacity is the
  binding constraint.

### 14.5 Platform-side exposure, accepted and documented

When an invite URL is opened, **iOS logs the full URL string to the device
console** (`Cannot issue sandbox extension for URL:aeronyra://invite/…`),
including the complete prekey bundle and long-term identity key. This is the OS
URL router, not app code, and no app-side logging change can suppress it.

Assessed as acceptable: the console is local and sandboxed; the invite is
designed to traverse untrusted channels (§2); reading it requires an unlocked,
paired device. Recorded here because it means the §3 "identity off open RF"
principle has a platform-side hole on the *invite* path that the deliberate
removal of the BLE prekey greet (commit `ce57ae8`) does not close.
