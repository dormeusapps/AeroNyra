# AeroNyra — Sender-Identity Threat Model

**Phase 9a-1 · Metadata hardening**
**Written 2026-06-29 · §2 and §3 rewritten 2026-09-19 (v59 connection-leak fix) · Status section updated 2026-09-19**

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

### Structural invariant (rewritten 2026-09-19)

The original text here said a `PreKeySignalMessage` "can never traverse Nostr". It
does: on the invite-echo path the redeemer's first sealed message — the prekey
message that establishes the session — is routed over the relays when no BLE link
exists (measured 2026-09-19: a 7,461-byte event, the only one of its size). What
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
| BLE PreKeySignalMessage leaks identity key + `.preKey` tell | A, B | **Open — verify against source** (§9.2) |
| Ciphertext length leaks message length | A, B, C | **Closed** — 9b padding ladder |
| BLE service UUID / local name / CB id linkability | A, B | **Open** — advertisement local name unstripped |
| Identity in app logs | local | **Closed** — `RedactLog`, Release-verified |
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
