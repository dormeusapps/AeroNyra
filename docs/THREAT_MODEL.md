# AeroNyra — Sender-Identity Threat Model

**Phase 9a-1 · Metadata hardening**
**Written 2026-06-29 · §2 and §3 rewritten 2026-09-19 (v59 connection-leak fix) · Status section updated 2026-09-19 · §9 updated 2026-09-27 (envelope seal, erase, mesh relaying, logs) · §11 added 2026-10-01 (reports to the developer) · §11.5 updated and §12 added 2026-10-02 (block periods) · §13 added 2026-10-03 (backups)**

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
| **C** | Relay operator (Nostr) | Runs a relay we connect to: sees our subscription, every event we publish, our IP, and which of its connections each event is served to | No |
| **C2** | Firehose observer (Nostr) | Anyone holding an unauthenticated kind-1059 subscription on a relay we use (relay.primal.net and nos.lol serve one): sees every event, its size and its arrival time; sees no subscriptions and no IPs | No |
| **D** | Compromised recipient | The intended counterparty | Yes (by design) |

Adversary **D** always learns the sender — that is what it means to receive a
message — and is out of scope for sealed sender. **A** and **B** see identical
wire bytes; **B** additionally learns the source *link* (split-horizon requires
it) and participates actively, but holds no keys, so it cannot open an
`Envelope`. **C** sees which of its connections receives each event and when, and
holds both endpoints of every conversation edge as pseudonyms; it never sees an
identity (§3). **C2** sees only the event stream, and can pair the two directions
of a conversation from the delivery receipt's timing (§3). Neither can open an
`Envelope`.

---

## 3. Nostr leg — no identity on the wire; a pseudonymous connection graph remains

*Rewritten 2026-09-19. As written on 2026-06-29 this section was titled "sender is
sealed" and rested on the event bytes alone. That was true of the bytes and false of
the connection: until v59 Stage 5 the REQ named our npub in its `#p` filter and every
EVENT named the recipient's npub in its `p` tag, on the same WebSocket, so a relay
operator read the sender↔recipient graph off one connection with no cryptography
broken. Closed by the v59 connection-leak fix, commits `62d6283` … `057c606`,
2026-09-14 to 2026-09-19; framing and vectors in `NOSTR_INBOX_TAG_KAT.md`. What
follows is the post-fix model, measured on two devices against both relays on
2026-09-19.*

### 3.1 What is on the wire now

- **Subscription.** One REQ per contact page, 1,920 values: 60 slots × 32 epochs
  (30 back, the current one, 1 ahead; epoch = 86,400 s). A real slot holds
  `tag(peer→us, e) = HMAC(S_AB, domain ‖ e ‖ label ‖ counter)`, curve-valid, keyed on
  the pair secret only the two paired devices can derive; a decoy slot holds the same
  construction under a device secret derived from our identity agreement key. Every
  page is fully padded; never a bare set. Subscription ids are random 16-hex, one per
  page per socket, stable for the socket's life; an epoch rollover replaces the filter
  on the same id (60 values out, 60 in). While an invite we minted is live, one more
  REQ carries the three invite-echo tags for that invite. **No npub appears in any
  frame.**
- **Publish.** A kind-1059 gift wrap signed by a fresh ephemeral key, `created_at`
  back-dated by a random offset in `[0, 2 days]`, tagged `["p", tag(us→peer, e)]` —
  the directional tag, never the npub. Our real key signs only the seal inside the
  NIP-44 layer. The rumor carries our real pubkey two encryption layers deep.
- **Relays.** Two: `relay.primal.net` and `nos.lol`, each its own socket, publish
  fanned out to both, inbound merged and deduplicated. `relay.damus.io` was in the
  default set from 2026-07-04 to 2026-09-19 and never served this app's inbox
  subscription in that time: it answers every kind-1059 subscription, with or without
  a `#p` filter, with `CLOSED "ERROR: auth-required"`. Every earlier statement of
  three relays or multi-relay availability was false for those eleven weeks.
- **No NIP-42 authentication, ever.** Authenticating binds our real npub to the
  connection — the exact binding this section exists to remove. A relay that refuses
  a tag filter is dropped, not authenticated to. No relay enters the default list
  without a single-device capture showing it serves an unauthenticated kind-1059
  subscription; NIP-11 does not disclose the policy.

### 3.2 What adversary C (the operator) still learns — the residual set

1. **A pseudonymous per-relay connection graph.** The operator serves A's tagged event
   to B's subscription and B's to A's, so it holds both endpoints of every
   conversation edge as connection pseudonyms, with no clock needed. Identities are
   never on the wire.
2. **Active-sender count per epoch, and contact count to page granularity.** Decoy
   slots never receive events, so the slots that do are the real, active contacts;
   the page count bounds the contact count at 60 per page.
3. **Receiver linkability across days.** Consecutive epoch windows share 31 of 32
   epochs, so the same subscription is recognisable across rollovers; a mid-epoch
   add, remove or block moves exactly one slot's 32 values.
4. **IP address and online time per connection.** Unchanged by the fix. A VPN moves
   the address and nothing else in this list.
5. **Timing and size.** The relay's own receipt time is the real send time; the
   back-date hides only the inner timestamp. Text events are about 2.6 KB; media
   chunks up to about 56 KB, so media, and roughly how much, is distinguishable
   from text.
6. **An invite in flight.** The three-value echo subscription is visible while an
   invite we minted is live — and, as built, until the next plan refresh after its
   expiry (typically the next rollover), not merely TTL plus skew. Tracked (§9.3).
7. **Backlog on reconnect.** The REQ carries no `since`, so every fresh socket
   replays the relay's stored backlog for our tags, bounded by relay retention.
8. **An invite echo, only when the Bluetooth handshake does not complete** (Option A,
   2026-09-26; see "Structural invariant" below). The operator then sees the
   minter's echo subscription and one echo-sized event from the redeemer's
   connection: that a pairing happened between those two connections, not its
   content. Since 2026-09-27 a publish that no socket took is retried once, 2 s
   later, so there can be two attempts; never two accepted copies.

### 3.3 What adversary C2 (the firehose observer) learns

Everything in 3.2 items 2, 5 and 6 that can be read from events alone, plus:

- **Both directions of a conversation, paired by timing.** On receipt of a text the
  recipient's delivery receipt is published at once, so every event to `tag(A→B)` is
  followed within about 0.5 s by exactly one same-sized event to `tag(B→A)`. Tag
  unlinkability holds in the cryptography and fails in practice for this observer:
  the pair, the message cadence, and a live "recipient's app is in the foreground"
  signal are all readable from the stream. Mitigation queued, not built (§9.3).
- **The first message of a session.** The npub announce fires once per launch per
  peer alongside the first text or the first receipt, so a simultaneous pair of events
  on one tag marks a session start.

C2 holds no subscriptions and no IPs, so it cannot tie a tag to a connection.

### 3.4 What neither C nor C2 learns

Any npub. Any identity key. Content. The real `created_at`. Which page slot belongs
to which contact, beyond activity. Whether two tags in one page belong to the same
contact across the 32-epoch window (decoys and real slots are indistinguishable by
construction).

### Structural invariant (rewritten 2026-09-19, amended 2026-09-26)

The original text here said a `PreKeySignalMessage` "can never traverse Nostr". It
does: on the invite-echo path the redeemer's first sealed message — the prekey
message that establishes the session — is routed over the relays when no BLE link
exists (measured 2026-09-19: a 7,461-byte event, the only one of its size). Since
Option A (`c1327b6`, `6f07ac5`) the redeemer sends the echo over BLE first and waits
2 s for the minter's BLE ack. Three outcomes, each observed on hardware 2026-09-26:
- **Handshake completes** (ack inside the wait): the echo never goes to a relay. R1,
  3 of 3 runs — the redeemer logged the ack and no relay fallback.
- **Handshake does not complete** (a minter without the ack, a stale BLE link, a
  lost ack): after the wait the SAME sealed envelope is published to the relays,
  once; the minter dedups it if the BLE copy also landed. R2, and the stale-link
  repro (fallback at +2.05 s). The wait is 2 s in the foreground; if the redeemer
  is backgrounded it can run longer (observed +30.7 to +69.3 s on a 30 s rig), and
  if the invite has under 2 s left the echo goes to the relays without waiting.
- **No BLE link at all**: the echo goes straight to the relays. R3.
Whenever the echo does reach a relay, the operator sees the connections involved —
the minter's echo subscription and the redeemer's publish — and one event of
recognisable size passing between them: that a pairing happened between those two
connections, not its content. What
holds is narrower and sufficient: on Nostr that message exists only inside the
NIP-44 gift wrap, encrypted to the minter's npub under an ephemeral key, so a relay
sees ciphertext and cannot read the identity key or the `.preKey` type byte. The
identity-key exposure in §4 therefore remains **BLE-only** — not because the prekey
message stays off Nostr, but because Nostr carries it only sealed. The earlier claim
that `peer.nostrPubkey` is learned only from a sealed `.nostrIdentity` payload is
also retired: the invite payload carries the minter's npub and the V2 echo carries
the redeemer's, which is what makes a pure-Nostr pairing possible at all.

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

*(Closed 2026-09-27 for builds with the envelope seal — every session message is
sealed to the recipient's identity key, `9c685a6`; see §9.1. Builds before the flag
day still emit it.)*

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
| Nostr outer event reveals sender | C | **Closed** — ephemeral key + encrypted seal (§3). *2026-09-19: this row was true of the bytes and wrong about the connection; see §9.4.* |
| Nostr recipient `#p` tag reveals recipient | C | **Accepted/tracked** — inherent to NIP-59 addressed delivery. *2026-09-19: closed for identity by the v59 inbox tag; residual is connection-level (§3.2).* |
| Our Nostr subscription binds npub ↔ IP ↔ online time | C | **Accepted/tracked** — recipient-side presence. *2026-09-19: no npub in any subscription; binds a padded tag set ↔ IP ↔ online time (§3.2).* |
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
not a Phase 9a item. *(Revisited and largely closed by v59, 2026-09-19 — §3, §9.3.)*

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

**§4.2 — the PreKeySignalMessage (closed 2026-09-27, flag day).** `e2536d1` adds
EnvelopeSeal v1: `0x01 ‖ eph_pub ‖ ChaCha20-Poly1305(inner)`, X25519 with a fresh
ephemeral key per message to the recipient's identity key, HKDF-SHA256 with
`info = label ‖ version ‖ eph_pub ‖ recipient_pub`, `aad = version ‖ eph_pub`.
Known-answer vectors come from an independent stdlib-only Python implementation
(`tools/gen_envelope_seal_kat.py`, self-checked against RFC 7748, 5869 and 8439).
`9c685a6` seals EVERY session message inside `SignalSession.seal` and unseals in
`openInbound` / `SignalSession.open`: a relaying phone now sees the version byte, a
random ephemeral key and ciphertext — neither the sender's identity key nor the
`.preKey` / `.whisper` type byte, so first contact is indistinguishable from steady
state. Plain libsignal bytes are refused before libsignal parses them, so builds
before this one cannot exchange messages with it (flag day). Relaying is unaffected
(the router forwards before the session layer sees an envelope; pinned by test).
What stays visible: size (bucket + 49 bytes), timing, hop count (the envelope TTL).
The outer layer has no forward secrecy of its own — the inner libsignal ratchet does.

**Erase leaves nothing running (2026-09-27).** Before, the old stack kept its relay
sockets and subscriptions and its Bluetooth link after "erase: complete", and kept
sending reconnect beacons its former contacts' phones recognise, once per new link,
until the process died (hardware, build `5a2cdf0`). `25b0719`/`b12c8c9` stop the
router inside the erase; `69abbb2` makes the Bluetooth transport quiet after
`stop()` (no rescan, connect or advertise; GATT service removed). Hardware-verified.

**Failed-erase leftovers (2026-09-27).** A new identity's first boot opened every
store with `loadOrCreate` and could load a previous identity's allowlist (with its
verified states), Nostr secret, ledgers and chats. `a64a7ff` sweeps them before
onboarding (a partial sweep lands on the door); `c30c541` makes every store wipe
destroy its key before its file, so a partial failure leaves an unreadable file.

**Removed contacts' sessions (2026-09-27).** A libsignal session left on disk was
reused by a same-key re-pair (an old-ratchet message still opened — verified by a
throwaway test). Remove Contact and the SAS "Doesn't match" discard now delete it
(`fb63283`, `8e12c62`), and boot deletes any session that belongs to no enrolled or
blocked contact (`907ed20`).

**Live gates follow the allowlist (2026-09-27).** A revoke racing an in-flight enroll
or verify could leave a revoked key in the live reconnect or verified gate until
relaunch (fail-open). `52b892b` re-checks after the coordinator adds and removes if
revoked.

**Identifiers in logs (2026-09-27).** `8e51e7d` removes every identity-key prefix,
Bluetooth peripheral/central id, link id, message/envelope/event id, npub and
walkie session id from log calls; `LogHygieneTests` scans the sources for any log
call that interpolates one. `10d22fc` routes the remaining bare prints through
`RedactLog`.

### 9.2 Still open

**§4.2 — the PreKeySignalMessage: verified, then closed (2026-09-27).** Verified
against source: it did traverse Bluetooth after invite pairing — the invite echo is
a prekey message and Option A sends it over Bluetooth first — and every nearby
AeroNyra phone relays it (§9.3, mesh relaying). Closed by the envelope seal for
builds from the flag day on (§9.1). Builds before it, still in the field, keep the
exposure until they update; the privacy page discloses it.

**§4.4 — the advertisement local name.** `CBAdvertisementDataLocalNameKey:
"AeroNyra"` still broadcasts. Not identity-bearing (identical for every install),
but it fingerprints the app. Tracked, unfixed.

**Nostr recipient-side metadata.** Closed for identity by v59 (§3.1); the
connection-level residual set (§3.2) and the firehose residuals (§3.3) are the
current open items, tracked in §9.3 and §9.4.

### 9.3 New exposures found since

**2026-09-19 — the Nostr connection-level leak, and what its fix uncovered.**

- *Connection binding (found 2026-09-13, closed 2026-09-19).* Until v59 Stage 5 the
  subscription carried our npub and every publish carried the recipient's, on one
  socket: a relay operator read the graph off the connection. §3 as originally
  written missed it because it examined the event bytes only. Closed by the pair-secret
  directional tag with decoy padding (§3.1, `NOSTR_INBOX_TAG_KAT.md`), commits
  `62d6283` … `057c606`. Measured clean on both devices, both relays: zero npub bytes in
  any frame across subscribe, publish, media, rollover, reconnect and a pure-Nostr
  pairing.
- *relay.damus.io never served the inbox.* From 2026-07-04 it answered every kind-1059
  subscription with `CLOSED "ERROR: auth-required"`; the app has never authenticated.
  Removed from the defaults. The refusal was misread as an outage ("a 503") for
  eleven weeks, and every "three relays" statement in that period was false. Two
  transport defects turned the refusal into a reconnect loop (133 connects in ten
  minutes): the permanent-refusal match missed the `ERROR:` preface, and the reconnect
  backoff reset on every received frame. Both fixed and pinned (`4d66081`, `1d3b23e`).
  **NIP-42 is not a remedy and is forbidden** (§3.1).
- *Receipt pairing for a firehose observer.* Open. The delivery receipt fires within
  ~0.5 s of receipt, pairing `tag(A→B)` with `tag(B→A)` for anyone reading the event
  stream (§3.3). Candidate mitigation: a randomised delay on the relay-path receipt.
  Queued post-v59; not a wire-format change.
- *The announce tell.* Open, accepted: a session-start marker once per launch per
  peer (§3.3).
- *The invite-echo subscription lingers.* Open: pruned only when a plan is recomputed,
  so it outlives expiry until the next rollover. A one-shot expiry timer is queued.
  Consequence: the transport's CLOSE frame has never executed in any test; the timer
  will be its first exercise.
- *REQ frame bytes were nondeterministic* (unsorted JSON keys), so "an unchanged plan
  sends nothing" held only by chance and half of all refreshes re-sent 128 KB per page
  per relay. Fixed and pinned (`3e686aa`).
- *The prekey message does traverse Nostr* on the invite-echo path, sealed (§3,
  structural invariant). No exposure; the old wording is retired.

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

**Call-time IP disclosure (calls and live PTT-over-IP).** Call media is
direct peer-to-peer WebRTC with no STUN and no TURN configured
(`CallICEConfig.operatorSupplied` is empty). Each party therefore learns the
other's real network address at call time: the address appears in the ICE
candidates exchanged over the sealed signaling channel and in the media path
itself. This is inherent to P2P media, is already true of calls as shipped, and
is unchanged by live PTT-over-IP. Exposure is to the counterparty (adversary
set: the verified contact you chose to call). The addresses are never disclosed
to a relay or to a passive observer of the signaling channel, since the offer
and answer travel sealed. Note that once media flows, an observer positioned on
the network path can still see that the two endpoints are exchanging real-time
traffic — content stays encrypted, but the fact and timing of a direct call
between two addresses is visible to a path observer. Verified 2026-09-11: a
Wi-Fi to cellular call connected host-to-host over globally routable IPv6 with
zero ICE servers. Consequence of the no-infrastructure choice: no operator host
ever learns call-time IPs or call timing. Cross-network calling requires both
sides to have working IPv6; IPv4-only endpoints on either side fail to connect
rather than falling back to a relay.

**Mesh relaying (documented 2026-09-27).** Every AeroNyra phone relays every
Bluetooth envelope it receives from any linked AeroNyra phone, before and whether
or not it can open it (`MessageRouter.handleInbound`), up to 7 hops; links form
with any phone advertising the service, with no identity check. Relays never
re-flood (Nostr arrivals are not relayed). A relaying phone sees the cleartext
header (version, TTL — so hop distance — and a random id), the size bucket, timing
and the arrival link; since the envelope seal, not the sender's identity key and
not the message type. Nothing is persisted on the relaying phone (an in-memory
seen-id cache); there is no store-and-forward and no setting to turn it off.
Disclosed on the privacy page.

### 9.4 Current disposition

| Exposure | Adversary | Disposition |
|----------|-----------|-------------|
| Nostr outer event reveals sender | C | **Closed** — ephemeral key + sealed seal (§3.1) |
| Nostr connection binds sender ↔ recipient by npub | C | **Closed 2026-09-19** — v59 inbox tag + decoy padding (§3.1, §9.3) |
| Nostr `#p` tag reveals recipient identity | C | **Closed 2026-09-19** — the tag is pair-secret, epoch-scoped (§3.1) |
| Nostr subscription binds npub ↔ IP ↔ online time | C | **Closed for npub 2026-09-19**; tag set ↔ IP ↔ online time remains (§3.2) |
| Pseudonymous per-relay connection graph, active-sender counts, cross-day window linkability, IP, timing, size | C | **Accepted/tracked** — the §3.2 residual set |
| Delivery receipt pairs both directions by timing | C2 | **Open** — randomised relay-path receipt delay queued (§9.3) |
| Announce marks a session start | C2 | **Accepted** (§3.3) |
| Invite-echo subscription outlives expiry | C | **Open** — expiry timer queued; CLOSE path untested until then (§9.3) |
| Relay count and availability claims | — | **Corrected 2026-09-19** — two relays; damus never served; NIP-42 forbidden (§3.1) |
| BLE steady-state sender | A, B | **Closed** (§4.1) |
| BLE PrekeyBundle broadcasts identity key | A, B | **Closed** — `ce57ae8` deleted `sendOurBundle` |
| BLE PreKeySignalMessage leaks identity key + `.preKey` tell | A, B | **Closed 2026-09-27** for flag-day builds — every session message sealed to the recipient (§9.1); older builds in the field still emit it |
| Any nearby AeroNyra phone relays our envelopes (size, timing, hop count, arrival link) | A | **Accepted/disclosed** — mesh relaying (§9.3) |
| Erased process keeps relay sockets, subscriptions and Bluetooth beacons alive | A, B, C | **Closed 2026-09-27** — router stopped in the erase; Bluetooth quiet after stop (§9.1) |
| Failed erase: a new identity loads the previous identity's stores | local | **Closed 2026-09-27** — pre-onboarding sweep; key-before-file wipes (§9.1) |
| Removed contact's session reused by a same-key re-pair | local / the contact | **Closed 2026-09-27** — deleted on remove, on SAS discard and at boot (§9.1) |
| Revoke racing enroll/verify leaves a live gate open | local | **Closed 2026-09-27** — post-checks (§9.1) |
| Ciphertext length leaks message length | A, B, C | **Closed** — 9b padding ladder |
| BLE service UUID / local name / CB id linkability | A, B | **Open** — advertisement local name unstripped |
| Identity in app logs | local | **Closed** — `RedactLog`, Release-verified; 2026-09-27: no identifiers in any log call, source-scanned by `LogHygieneTests` (§9.1) |
| Identity in OS URL-router logs | local | **Accepted/documented** (§9.3) |
| Locked-Keychain identity overwrite via BLE restoration | — | **Closed** — `BootRouter` single-preimage routing + `load()` error taxonomy, regression-tested (§9.3) |
| Call-time IP of each party | the counterparty (flow visible to path observer) | **Accepted** — inherent to P2P media; no relay means no third party learns it (§9.3) |

## 10. Push-to-talk (PTT) live voice — per-frame session crypto

*(Added 2026-07-13 with the BLE-live PTT crypto. Scope of this chapter: the
per-frame confidentiality/integrity/authenticity of a live voice stream —
`Core/Media/PTTSessionCrypto.swift`. The handshake that delivers the session
secret rides the existing sealed Signal channel and is covered by §4.1; audio
capture/transport is out of scope here.)*

### 10.1 Construction

A live voice stream cannot ride the per-message Double Ratchet — ratcheting
25–50 frames/sec is the wrong primitive and would explode the skipped-key store.
Instead:

- **Handshake.** The initiator draws a random 32-byte session secret `S` and
  seals it to the peer over the established Signal session — the same sealed,
  verified-contact channel as text/calls (§4.1). No new admission path: a
  stranger cannot open a PTT session (the 7f verified gate applies identically).
- **Directional keys.** Both sides derive two keys with HKDF-SHA256 (salt empty;
  version + direction in the `info` label):
  `K_i→r = HKDF(S, "aeronyra.ptt.v1|initiator->responder")` and
  `K_r→i = HKDF(S, "aeronyra.ptt.v1|responder->initiator")`.
- **Per-frame AEAD.** Each 20 ms frame is `ChaCha20-Poly1305(frame,
  key = K_dir, nonce = 0x00000000‖BE64(counter), aad = BE64(seq))`, `counter` a
  monotonic UInt64 incremented once per frame.

Every frame is thus confidential, integrity-protected, and authenticated as
coming from the verified paired contact — the same trust root as the rest of the
app.

### 10.2 Nonce-uniqueness argument (the load-bearing invariant)

ChaCha20-Poly1305 is catastrophically broken by a single (key, nonce) reuse, so
uniqueness is argued, not assumed — and pinned by test:

1. **Fresh key per session.** `S` is random per PTT session ⇒ the derived keys
   are new each session, so counters restarting at 0 across sessions reuse no
   (key, nonce) pair.
2. **Directional separation.** The two directions use *different* keys, so both
   parties starting their own counter at 0 cannot collide — exactly why a single
   shared key was rejected.
3. **Monotonic counter, no wrap.** Within a direction the counter strictly
   increases and the sealer **throws at the ceiling** rather than wrap (a session
   re-handshakes long before 2⁶⁴ frames). So each nonce is used once per key.

Pinned by `PTTSessionCryptoTests` (distinct/monotonic nonces; ceiling throws)
and by the external KAT vectors (`tools/ptt_kat_gen.py` → RFC 8439/5869 ground
truth).

### 10.3 Replay + reorder

The receiver runs a 64-wide anti-replay window (RFC 6479 bitmap in one UInt64):
it **rejects duplicates and frames older than 64 behind the highest accepted**,
while **permitting in-window reorder** (the lossy BLE path reorders slightly).
The window advances **only on authenticated frames** — a forged counter fails the
AEAD verify before it can shift the window, so an attacker cannot use a bogus
high counter to starve legitimate frames. Bound: a frame more than 64
newer-frames stale is indistinguishable from loss and dropped, which is
acceptable for real-time voice (a stale frame is useless anyway).

### 10.4 Scope: 1:1 sealed only

PTT is **1:1 to a paired, verified contact only**. Public-channel (`meshRoom`)
PTT is explicitly **out of scope** — it would be plaintext voice on the air to
anyone in range and requires separate operator sign-off. Nothing in
`PTTSessionCrypto` is reachable from an unsealed channel.

### 10.5 What a relay / on-air observer sees (adversaries A, B, C)

The frames carry no plaintext and no identity: an on-air BLE observer or a relay
sees a stream of **opaque ChaCha20-Poly1305 frames** — ciphertext + 16-byte tag,
each ~voice-frame-sized, at ~50/sec while a party transmits. Residual leakage is
**traffic analysis only**: frame sizes, timing, and who-transmits-when (talk vs
silence cadence), plus the BLE-link linkability already tracked in §9.4. No key
material, no cross-session linkage beyond that, no frame content. The session
secret itself never crosses the air in the clear — it is sealed over the Signal
channel (§4.1).

### 10.6 Disposition

| Exposure | Adversary | Disposition |
|----------|-----------|-------------|
| PTT frame content on air | A, B | **Closed** — per-frame ChaCha20-Poly1305 under a fresh per-session directional key (§10.1–10.2) |
| PTT frame replay / injection | A, B | **Closed** — AEAD auth + RFC 6479 window; advances only on authentic frames (§10.3) |
| PTT nonce reuse | A, B | **Closed** — fresh key/session + directional keys + monotonic no-wrap counter; KAT-pinned (§10.2) |
| PTT talk/silence + timing metadata | A, B, C | **Accepted/tracked** — traffic analysis only; content sealed (§10.5) |
| Public-channel PTT (plaintext voice) | any-in-range | **Out of scope** — 1:1 sealed only; needs separate sign-off (§10.4) |

## 11. Reports to the developer

*Added 2026-10-01 with the Guideline 1.2 report step (commits `c61dd3f` … on
`feature/live-ptt-over-ip`). Until then a report was a `mailto:` carrying only
the app version, the time, the user's nickname for the contact and local
reference numbers. This section covers what the report now carries and who
learns it. Rules in code: the header of `Screens/ReportMail.swift`.*

### 11.1 What a report is

An email the user sends from their own mail app to `support@dormeusapps.com`:
Apple Mail's composer inside the app, or the share sheet when Mail is not set
up. The app builds it and shows all of it in a preview first; nothing leaves
the phone unless the user sends it. There is no server, no upload, **no
attachment and no image of any kind**. A report never travels over the app's
own transports (Bluetooth or the relays).

Only a SENT report changes anything for the contact: the contact is blocked,
their libsignal session is deleted, and their identity key is refused for
pairing (QR, invite, invite echo) for good on this install. Erase is the only
reset. Cancelled, saved as a draft, or failed: nothing happens to the contact.

### 11.2 What a report may contain

- the reason the user chose (spam, harassment or bullying, sexual or explicit
  content, threats or violence, other);
- the user's local nickname for the contact;
- a **contact code**: SHA-256(`"AeroNyra/report-contact/v1"` ‖ raw 32-byte
  identity key), first 16 bytes, in hex. The same contact gives the same code
  in every reporter's report; the code cannot be turned back into the key, so
  it cannot be used to message or pair with anyone;
- the app version and the time;
- **anything the user chooses to type about the person**: name, phone,
  email or social media, how they know them or where they met, how they got
  the invite, and "What happened". Each only when filled. **A report may
  therefore contain personal information about another person**, added by the
  reporter;
- for a message report, and only while its preview switch is on, the
  reported message's text **verbatim** (the content filter never applies to
  report content); a photo, video or voice note only as "[photo]" / "[video]"
  / "[voice note]".

Never: the identity key or any part of it, the npub, wire ids, local
reference numbers, media bytes, images, the reporter's own key or code, or
anything from another conversation. The typed fields exist only while the
report screen is open: never saved on the device, never logged.

### 11.3 Who learns what

| Party | Learns |
|---|---|
| **The developer** (recipient of the email) | Everything in it, in plaintext; the reporter's email address (the sender), so a link between that address and the contact code; across reports, which codes are reported, how often, and by how many reporters |
| **Both email providers** (the reporter's and the developer's) | The same email. Stored under their own policies; protected in transit by TLS at best, **not end-to-end** |
| **The reported contact** | Not told. May infer a block: their messages stop being delivered and no delivery receipts come back |
| Relays, Bluetooth observers (A, B, C, C2) | Nothing new: a report never uses the app's transports |

### 11.4 Retention and disclosure

Reports are kept for **up to 1 year, or longer if needed for a legal
matter**. **We may share a report with law enforcement when required by law
or when someone may be in danger.**

### 11.5 Limits and accepted residuals

- **A report is a claim, not proof.** The text comes from the reporter's own
  phone and the email can be edited in the mail app before it is sent.
- **No images, deliberately.** So that the developer never receives imagery by
  email, including illegal imagery of minors. The preview tells the user not to
  attach photos and to contact the police first if a crime has happened.
- **No ejection.** The developer runs no server and cannot remove content from,
  or disable, another person's app. Nothing in the app's copy claims otherwise.
  Whether and how to add an "eject" mechanism is an open decision.
- **Nothing is recalled.** Nothing already on the reporter's phone is
  removed by a block or a report: the chat stays, as evidence. Whatever the
  contact sends from the block on is dropped on the reporter's phone before it
  becomes a message (`FirstContactCoordinator.receive`, both transports):
  never shown, stored, notified or acknowledged. A report can
  never be undone, so for a reported contact this holds for good; for a plain
  block it also holds after Unblock, by the block periods and refused ids of
  §12, within the limits listed there (§12.5). Messages the contact handed to
  a relay BEFORE the block, if the phone had not fetched them yet: while the
  contact is blocked or reported they are not fetched (Block takes the
  contact's tags out of the relay subscription), and any that still arrive are
  dropped the same way; after a plain Unblock they arrive with a send time
  before the block period and are delivered normally — correctly, since they
  were sent before the block. Our own queued messages to them never send (the
  verified gate refuses them after the revoke).
- **The contact code is a stable pseudonym** of the contact at the developer.

### 11.6 Disposition

| Exposure | Adversary | Disposition |
|---|---|---|
| Report content (reason, nickname, contact code, typed details, reported message text) | the developer; both email providers | **Accepted/disclosed** — user-initiated, shown in full first, sent only by the user; retention up to 1 year (§11.4) |
| Personal information about another person, typed by the reporter | the developer; both email providers | **Accepted/disclosed** — optional fields, each sent only when filled |
| Reporter's email address linked to a contact code | the developer | **Accepted** — inherent to a report by email |
| Identity key, npub, wire ids, media, images in a report | — | **Closed by rule** — forbidden (`ReportMail.swift` header), pinned by tests |
| Report inferred by the reported contact | the contact | **Accepted** — silent block; delivery stops |

## 12. Block periods — nothing sent while blocked appears after Unblock

*Added 2026-10-02 (v68 §5a; commits `4b5fb24` store, `2572fc5` relay send
time, `7830aea` the drop, `f20407a` tripwire, `4ff5a1a` Unblock copy). Before
this, Unblock re-added the contact's inbox tags to the relay subscription; the
REQ has no `since` (§3.2 item 7), so the relay replayed everything the contact
had sent while blocked, and the phone opened, stored, notified and
acknowledged it seconds after Unblock (seen twice on hardware, 2026-10-01). A
sender's `flushUndelivered` resend under the same wire id could leak the same
way over Bluetooth (from source; not seen on hardware).*

**Invariant.** Anything a contact sends while blocked is never shown, stored,
notified or acknowledged — not even after Unblock. For a contact who was never
blocked, the receive path is unchanged. The fix lives only on the blocker's
phone; the sender's app is unchanged and is never told.

### 12.1 What is recorded

`Security/Session/BlockHistoryStore.swift`: one file
(`block-history.v1.seal`) sealed with ChaChaPoly under its own DEK (Keychain
service `com.aeronyra.blockhistory.v1`), AAD-bound, in the same directory as
the denylist, held in memory after one load at init.

- **Block periods**, per contact (raw identity key): every
  `[blockedAt, unblockedAt]` in Unix ms. `PairingService.unblock` writes the
  period **first** — before re-enrolling and before removing the denylist
  entry. If that write fails (file unreadable, store wiped or missing, disk
  error), Unblock throws, nothing else changes, and the contact stays blocked.
  `unblockedAt` is never before `blockedAt` (a clock set back cannot make a
  period invalid and refuse Unblock forever).
- **Refused envelope ids**: FIFO, capped at 8,192. Recorded for every envelope
  dropped because of a block — at the blocked guard and by the period rule.
  Written debounced (3 s), and flushed when the app goes to the background
  and on the erase sequence's stop.

Kept after Unblock (the denylist entry is not). Erase identity removes the key
and then the file (`EmergencyWipe`), and so does the pre-onboarding leftover
sweep, without opening the file (`BlockHistoryStore.LeftoverWipe`).

### 12.2 The relay send time, and how far it is trusted

A relay copy is a NIP-59 gift wrap (§3.1). `NostrGiftWrap.wrap` sets the
inner **rumor's `created_at` to the sender's wall clock** (`now`,
`Core/Nostr/NostrGiftWrap.swift:71`, used at `:82` and `:88`); only the seal
and the outer wrap are back-dated, by a random 0–2 days (`:103`, `:120`,
`NostrEvent.randomizedTimestamp`). The rumor's `created_at` has been the
sender's wall clock, unchanged, since `d839406` (the gift wrap's first
commit); this was checked at `4d2be3a` (the first relay transport), `ca988eb`
(Build 10), `b1bb234` (Build 13), `dfbda7a` (Build 14) and HEAD. No
production caller passes its own `now`. `unwrapDetailed`
returns the rumor time in **seconds**; the transport hands it to `receive` as
`relaySentAtSeconds`. Bluetooth has no send time (nil).

- **A relay cannot change it.** The rumor's bytes are the plaintext of the
  seal's NIP-44 payload: the NIP-44 MAC is checked when it is opened
  (`NostrGiftWrap.swift:169`), and the seal's id covers that payload and is
  schnorr-signed by the sender's key (`seal.isValid()`, `:162`). The rumor's
  author must equal the seal's (`:177`).
- **The sender sets it.** It is the sender's clock and the sender's claim; a
  modified client could write any value. Accepted: the block is silent, so the
  sender does not know when, or that, it ended.
- **The rumor's own id is NOT recomputed.** Nothing reads it, so it cannot
  affect this rule. A recompute check is a possible future hardening (its own
  commit, with a known-answer test against captured old-build traffic).

### 12.3 The rule

In `FirstContactCoordinator.receive`, after decrypt and the blocked guard,
before the announce and the payload switch (so before any event and any
delivery receipt), for every payload kind:

- only a relay copy (`relaySentAtSeconds` not nil) is checked; **Bluetooth is
  exempt** — it carries no send time;
- `sentMs = relaySentAtSeconds × 1000`, saturating at Int64's limits (a
  sender-chosen value cannot trap);
- for each of the sender's periods: `start` = `blockedAt` floored to the whole
  second (the rumor time has one-second resolution); `end` = `unblockedAt` +
  30 s (room for a sender clock a little ahead);
- **drop if `start ≤ sentMs ≤ end`** — and record the envelope id as refused.

`BlockPeriod.coversRelaySend(atSeconds:)`; logged as
`first-contact: DROP sent while blocked` (no key, id or content).

### 12.4 Refused ids

Checked at the very top of `receive`, **before decrypt**: an envelope whose id
was dropped for a block is dropped again, with no decrypt and no receipt
(`first-contact: DROP refused id`). The sender's `flushUndelivered` resends an
undelivered message under the same id, over Bluetooth or the relay; this
catches that resend on both transports, during the block, after Unblock, and
after a relaunch (the set is persisted). Envelope ids are 16 random bytes from
the system CSPRNG (`MessageID.random()`, `Core/Models/Envelope.swift:45-50`;
`byteCount = 16`, `:34`), assigned by the sender
(`FirstContactCoordinator.swift:1128` text, `:1275` media; a resend reuses
the original id). The set holds only ids dropped for a block, so a contact who
was never blocked is never matched. A reported contact's messages are dropped
by the denylist guard as before (and their session is deleted), whatever the
history holds.

### 12.5 Limits and accepted residuals

- **R1 — a message first sent after Unblock is delivered, whenever it was
  written.** If the sender had no internet and no Bluetooth route for the
  whole block, their app could not send; the message goes out for the first
  time after Unblock, under an id this phone never saw and with a relay time
  after the period (or none, over Bluetooth). It is delivered. Closing this
  needs a timestamp written when the message is composed, inside the payload:
  `.text` has no room for one, so it means a new payload kind, which builds
  ≤ 14 drop silently (no receipt) — a flag day. Accepted (Rubins, 2026-10-02).
  **The Unblock alert's line "Messages they sent while blocked won't appear"
  does not cover this case. That was a deliberate copy decision:** the line is
  true in every case except a sender who was offline for the whole block,
  which is rare, and a longer line would explain that rare case to every user.
- **Sender clock behind.** If the sender's clock is N minutes behind, their
  legitimate relay messages in the first N minutes + 30 s after Unblock fall
  inside the period and are **silently dropped** (and their ids refused). This
  only ever affects a contact who was blocked: the rule reads periods by the
  sender's key, and a contact with none is never checked. A sender clock
  **ahead** by more than 30 s lets a message sent just before Unblock through.
  Phones set their clocks automatically; both are accepted.
- **The sender can notice.** Messages they sent during the block never reach
  Delivered (a relay copy stays "cast"; a Bluetooth one becomes "Not
  delivered" and is retried, refused each time), while later ones do. A fake
  receipt to hide this is forbidden: nothing sent while blocked is ever
  acknowledged.
- **A damaged history file fails open for delivery.** A present-but-unreadable
  `block-history.v1.seal` boots empty for the life of the process
  (`⚠️ block history load FAILED — booting empty`) and is **never written**, so
  it stays exactly as found. Delivery fails open: the backlog of contacts
  already unblocked is no longer filtered. Contacts **currently** blocked stay
  protected by the separate denylist. Unblock is refused (the "Couldn't
  unblock" alert). If the damage was temporary, a later launch that reads the
  file restores normal behaviour; if the file is permanently damaged, only
  Erase identity clears it.
- **First-unlock assumption.** The store reads its file once, at init, and
  treats any failure as damage. That is safe only because nothing can start
  Beacon before the device's first unlock: the identity is a
  `WhenUnlockedThisDeviceOnly` Keychain item and boot builds no store unless it
  loads; the DEK is `AfterFirstUnlockThisDeviceOnly`; the only background modes
  are Bluetooth, with no state restoration, no background tasks, no push, no
  VoIP. `BeaconTests/FirstUnlockAssumptionTests.swift` fails if any of that
  changes in `Info.plist` or the source. If background relaunch is ever added,
  or the identity's Keychain protection class is relaxed, **add the retryable
  locked state first** ("can't read yet" kept apart from "damaged").

### 12.6 Disposition

| Exposure | Adversary | Disposition |
|---|---|---|
| Relay backlog sent while blocked, delivered after Unblock | the blocked contact | **Closed** — dropped by the period rule before any event or receipt (§12.3) |
| Same-id resend (Bluetooth or relay) after Unblock or relaunch | the blocked contact | **Closed** — refused id, dropped before decrypt (§12.4) |
| Message first sent after Unblock, written while blocked (R1) | the blocked contact | **Accepted** — needs a sender timestamp (flag day); not covered by the Unblock alert line, by decision (§12.5) |
| Forged or forward-dated rumor time | a modified sender client | **Accepted** — sender-controlled; a relay cannot alter it (seal signature + NIP-44 MAC, §12.2) |
| Legitimate messages lost to a sender clock behind | the formerly blocked contact (loss, not exposure) | **Accepted** — first N min + 30 s after Unblock; never-blocked contacts unaffected (§12.5) |
| Sender infers the block from never-Delivered messages | the blocked contact | **Accepted** — no fake receipts, ever (§12.5) |
| Unreadable block-history file | — | **Accepted, fail open for delivery** — never written; currently blocked contacts still dropped; Unblock refused until readable or Erase (§12.5) |
| Launch before first unlock reads the file as damaged | — | **Not reachable today** — pinned by `FirstUnlockAssumptionTests`; add the retryable locked state before changing it (§12.5) |

---

## 13. Device and iCloud backups

*Added 2026-10-03 (commit `55b822e`, backup exclusion). Line numbers are at
`a7475fd`. Before `55b822e`, an iPhone or iCloud backup carried the app's
messages, media and contacts. The SwiftData store is not sealed by an app key
(the user-presence `MessageVault` is not used in production), so anyone who
could open the backup could read them.*

**Invariant.** From the first launch of a build with `55b822e`, nothing the
app stores under Application Support is included in a new backup. What still
reaches backups is listed in §13.3. Private keys never leave the device in a
form another device can use.

### 13.1 What is kept out of backups

- **All of Application Support, marked excluded at every launch.**
  `BackupExclusion.excludeApplicationSupport()`
  (`Beacon/BackupExclusion.swift:52-65`) sets `isExcludedFromBackup` on the
  folder and reads it back (`:34-46`). It is the first line of `bootstrap()`
  (`Beacon/ContentView.swift:527`), before the terms gate reads its file and
  before any store opens. A folder's exclusion covers files created in it
  later. A failure never blocks launch: it logs
  `backup: exclusion FAILED — app data may be included in backups` (`:44`,
  `:56`), and the next launch tries again.
- **What that folder holds:**
  - the SwiftData store: messages, media bytes (`Message.mediaData`,
    `Core/Models/PersistentModels.swift:241`), contacts and contact photos
    (`Peer.customAvatarData`, `:55`), in the default location
    `Application Support/default.store` with its sidecars
    (`Beacon/ContentView.swift:1404-1414`; `Security/Wipe/SwiftDataStoreWipe.swift:23-27`);
  - `BeaconSignalStore/`: every sealed store and the session snapshot
    (`Security/Session/PersistentBeaconStore.swift:178-182`);
  - the terms acceptance file (`Beacon/TermsAcceptance.swift:40`).
- **Media temp files live in `tmp/`,** which iOS never backs up:
  `Screens/VoiceRecorder.swift:60`, `Core/Media/VideoTranscoder.swift:75, 119`,
  `Screens/Conversation1View.swift:1843, 1961`, `Screens/VideoBubble.swift:111`,
  `Stories/StoryComposerView.swift:388, 513`, `Core/Media/PTTCaptureEngine.swift:303`,
  `Core/Media/WaveformExtractor.swift:28`.
- Hardware: the iPad logged `backup: Application Support excluded=true`
  before any store loaded (Debug build of `55b822e`, 2026-10-02). The line is
  Debug-only (`Beacon/BackupExclusion.swift:60-64`).

### 13.2 Limit: backups made before the update

The exclusion is set when the updated app launches. A backup made before the
first launch of a build with `55b822e`, including every backup of Build 14 and
earlier, still contains that data until the backup is replaced or deleted. The
app cannot reach or change an existing backup.

### 13.3 What still lands in backups (UserDefaults)

UserDefaults (`Library/Preferences`) is backed up by iOS and cannot be excluded
this way (`Beacon/BackupExclusion.swift:19-21`). It holds:

| Key | Holds | Where |
|---|---|---|
| `aeronyra.displayName` | the user's own display name | `Screens/SettingsView.swift:36`, `Screens/HomeView.swift:62` |
| `aeronyra.selfPhoto` | the user's own photo (JPEG bytes) | `Screens/SettingsView.swift:37` |
| `aeronyra.contentFilter.words.v1` | the words the user added to the content filter | `Screens/ContentFilter.swift:233` |
| `aeronyra.reportedMessages.v1` | local ids of messages the user reported (shows that they reported) | `Screens/Conversation1View.swift:150`; `Screens/ReportMail.swift:94` |
| `nostr.lastKnownLocalPubkey.v1` | the user's own Nostr **public** key | `Beacon/ContentView.swift:868-873`; `Security/Wipe/DeviceResidueWipe.swift:57` |
| `aeronyra.contentFilter.enabled.v1` | filter on/off | `Screens/ContentFilter.swift:232` |
| `aeronyra.contentFilter.introShown.v1` | filter pop-up already shown | `Beacon/ContentFilterView.swift:21` |
| `aeronyra.accentHex` | accent colour | `DesignSystem/Stillwater.swift:84` |
| `aeronyra.walkie.allowInbound.v1` | "Allow walkie from contacts" | `Core/Calls/WalkieSettings.swift:28` |
| `aeronyra.eulaAccepted.v1` | version 1 terms record: never written by current code, removed on acceptance | `Beacon/TermsAcceptance.swift:43, 81` |

No private key and no message content is stored in UserDefaults.
**Fix B** (designed, parked, **not approved**) would move the first five rows
into a sealed, backup-excluded store. Until it ships, they reach backups.

### 13.4 Keychain

Every Keychain item the app writes is a `ThisDeviceOnly` class and sets
`kSecAttrSynchronizable: false`. The update paths change only
`kSecValueData`, so they never change either setting.

| Item | Accessibility | Synchronizable |
|---|---|---|
| Identity key (wrapped by the Secure Enclave key when present) | `WhenUnlockedThisDeviceOnly` (`Security/Identity/IdentityKeypair.swift:314-315`; production protection `Beacon/ContentView.swift:551`) | false (`IdentityKeypair.swift:303`) |
| Secure Enclave key handle (the key itself never leaves the Enclave) | `WhenUnlockedThisDeviceOnly` (`Security/Identity/SecureEnclaveWrapper.swift:231, 269`) | false (`:268`) |
| Six store keys (`session.dek.v1`, one per service) | `AfterFirstUnlockThisDeviceOnly` (`Security/Session/SessionStoreKey.swift:89`) | false (`:88`) |
| Nostr secret key | `AfterFirstUnlockThisDeviceOnly` (`Core/Nostr/NostrSecretStore.swift:70`) | false (`:69`) |

(`MessageVault`'s key, `Security/AtRest/MessageVault.swift:289, 297`, follows
the same rule but is not created in production.)

So no item is ever in iCloud Keychain, and no item moves to another device,
whether by backup, restore or migration.

### 13.5 Same-phone restore — UNTESTED

Apple's documentation says `ThisDeviceOnly` Keychain items can be included in
an **encrypted** backup, sealed to that phone's hardware, and restored only to
the **same** phone. If so, restoring such a backup to the same phone could bring
back the identity key, the Nostr secret and the store keys, while chats and
contacts do not come back (Application Support is excluded, §13.1). The app
would then boot with the old identity and no contacts; contacts would have to
pair again. **Untested on this app**, and not relied on anywhere. A restore to
a **different** phone brings back no Keychain item: the app finds no identity,
and the sweep before onboarding clears any old store files and the UserDefaults
in §13.3 except the accent colour and the legacy terms key
(`Security/Wipe/LeftoverSweep.swift:6-14, 57-62`;
`Security/Wipe/DeviceResidueWipe.swift:86-94`; `Beacon/ContentView.swift:601-606`).

### 13.6 Delete and reinstall on the same phone

Deleting the app removes its container: Application Support (messages, media,
contacts, sealed stores, terms acceptance) and UserDefaults (name, photo,
settings). The Keychain items survive. Reinstalling therefore boots the same
identity with no messages, contacts or settings, and shows the terms again (the
acceptance file lived in Application Support). Hardware: "Delete + reinstall
(identity kept)" passed on 2026-10-01 (session handoff v68 §4). That check
recorded the identity surviving. The removal of the container is standard iOS
behaviour and was not separately recorded.

### 13.7 Disposition

| Exposure | Adversary | Disposition |
|---|---|---|
| Messages, media, contacts, contact photos and sealed stores in a new backup | whoever can open the backup | **Closed** for builds with `55b822e`, from their first launch (§13.1) |
| Backups made before that first launch | whoever can open the backup | **Accepted** — the app cannot reach existing backups (§13.2) |
| Own name, own photo, own filter words, reported-message ids, own Nostr public key, preferences in backups | whoever can open the backup | **Open** — Fix B parked, not approved (§13.3) |
| Private keys in iCloud Keychain or on another device | — | **Closed** — every item `ThisDeviceOnly`, non-synchronizable (§13.4) |
| Identity returning after a same-phone encrypted restore, without chats | — | **Untested** — Apple-documented behaviour, not checked on this app (§13.5) |
