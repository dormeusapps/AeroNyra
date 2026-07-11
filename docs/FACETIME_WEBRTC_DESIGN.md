# FaceTime v1 (Calling) — Design Doc [RECONSTRUCTED]

**Status:** reconstruction, July 10 2026. The original FACETIME_WEBRTC_DESIGN.md was
lost (untracked, deleted from disk). This document is rebuilt from the committed
source of record — every claim below is traced to a file:line that exists on disk
today, and nothing is asserted that the code does not itself state. Where the
original doc may have said more, §6 lists the decisions that remain genuinely open.

**Scope of what's committed:** the complete signaling layer (wire kinds, codec,
sealing, verified-gate, state machine) for voice-only calling. The media layer
(WebRTC), composition-root wiring, and UI are **not built** (§5).

---

## 1. Architecture (as committed)

- **Signaling rides the existing sealed channel.** A call-signaling frame is a
  `MessagePayload` like any text message: tagged plaintext, padded, sealed under
  the Signal session to the peer, routed over the same addressed rail — BLE when
  the peer is verified-reachable, Nostr Tier-2 fallback otherwise
  (`FirstContactCoordinator.sendCallSignal`, `FirstContactCoordinator.swift:1043-1050`).
  Signals are **untracked** envelopes (no delivery timer); `sendCallSignal` throws
  if no transport takes the frame, "so the call layer can end the attempt
  immediately."
- **Media is WebRTC, behind a seam.** `CallMediaSession`
  (`CallController.swift:35-68`) is the entire surface the state machine needs:
  make-offer / make-answer / start / close + three one-shot callbacks (connected,
  failed, remote-ended). The concrete RTCPeerConnection wrapper was deliberately
  deferred ("the libWebRTC pod is NOT added yet, by build order" —
  `CallController.swift:16-18`).
- **No server, no push, no CallKit.** "One call at a time, both parties foreground
  in the live chat — there is NO server, NO push, NO CallKit, so 'ringing' is a
  sealed request plus a local timeout, nothing more" (`CallController.swift:4-8`).

### Security shape (CallSignal.swift:19-24, verbatim intent)

A request/answer body carries the **complete SDP**, and the SDP carries the
**DTLS-SRTP certificate fingerprint** (`a=fingerprint:` line). The whole body is
sealed under the existing Signal session to the **verified** contact, exactly like
a text message — so **the media keys are authenticated by the existing trust
root. No new trust root, no call server.**

---

## 2. Wire facts (committed, hardware-proven per prior handoffs)

### Payload kinds (`Core/Media/MessagePayload.swift:78-90`)

| Tag | Kind | Body |
|---|---|---|
| 8 | `callRequest` | `callID(16) ‖ complete SDP offer` (UTF-8) |
| 9 | `callAnswer` | `callID(16) ‖ complete SDP answer` (UTF-8) |
| 10 | `callDecline` | exactly `callID(16)` — decline AND cancel-before-connect |

Kinds 1–7 are text/media/ack/nostrIdentity/reconnectHello/inviteEcho; kind 11
(`inviteEchoV2`) landed after the call kinds. **Next free tag: 12.** "Never
renumber these without a wire-version bump" (`MessagePayload.swift:77`).

### Body discipline (`Core/Calls/CallSignal.swift`)

- `callID` = 16 CSPRNG bytes, minted fresh per call attempt by the caller — same
  shape as a MessageID/mediaID (`:56-58`, `CallController.swift:313-317`).
- **`maxSDPBytes = 32 KiB`** (`:63`): defensive ceiling mirroring
  `manifestWithinBounds`' posture — "a real voice-only offer with gathered
  candidates is a few KB; 32 KiB is far above any legitimate SDP and far below
  anything that could stress the payload buckets. A parse above it returns nil."
- **Strict parsers on the untrusted receive path** (`:86-122`): nil on short
  buffer, empty SDP, oversize SDP, non-UTF-8, or (decline) any length ≠ 16. A
  malformed frame is ignored; **nothing is sent back**.
- The `MessagePayload` bridge lives in `Core/Calls` (not MessagePayload.swift) "so
  call knowledge stays in Core/Calls, mirroring how `deliveryAck` builders live
  beside their feature" (`:145-160`).
- **Padding:** call kinds are among the padded (non-media) kinds —
  `sealedPlaintext()` wraps them via `PayloadPadding` to a `PayloadBucket` tier
  (`MessagePayload.swift:160-166`), so a call frame's ciphertext length is
  bucket-shaped like text.

### Receive gate (`FirstContactCoordinator.swift:1234-1272`)

All three kinds are gated **7f STRICT-VERIFIED, exactly like `.text`**: "call
signaling is user-reaching content — an unverified session-holder must not be
able to ring us." Unverified sender → drop silently (RedactLog label only, no
reply). Parsed frames yield `SessionEvent.callSignal(peerKey:signal:)` (`:93`) —
routed to the call layer, **never persisted as a Message**.

---

## 3. The state machine (`Core/Calls/CallController.swift`, committed)

States: `idle → outgoingRinging | incomingRinging → connecting → active → ended(reason)`;
`reset()` returns `ended → idle` (UI-driven, after rendering the outcome).

End reasons (`:77-84`): `declined`, `remoteDeclined`, `timedOut`, `connectFailed`,
`hungUp`, `failed` — six distinct outcomes, deliberately not collapsed.

Committed rules, each with its rationale from the header comments:

1. **Ring timeout 45 s, both sides, local-only** (`:101-104`): "there is no server
   to enforce it, so both ends run their own clock and the callee's banner simply
   disappears." Timeout fires `onMissedCall` exactly once per unanswered attempt
   (`:118-122`); decline/connect-fail do NOT fire it.
2. **Stale-frame rule** (`:27-29`): every inbound signal is matched against the
   current attempt's `callID`; "a frame from any other attempt (a late relay
   delivery, a replay, a crossed decline) is dropped without a state change."
3. **Busy = auto-decline the NEW attempt** (`:224-227`): a request arriving during
   any in-progress call sends `.decline(newCallID)` back; the current call is
   untouched.
4. **`decline` doubles as cancel-before-connect** (`:154-161`): caller cancel while
   ringing sends decline so the callee's banner drops. A caller-cancel received
   while our banner is up ends as `.timedOut` + missed-call row (`:247-252`).
5. **Post-connect hang-up is NOT a wire signal** (`:193-195`): "closing the RTC
   connection IS the hang-up, which the peer sees as `onRemoteEnded`." Only
   pre-connect outcomes ride the sealed channel.
6. **One call at a time** (`startCall` no-ops unless `.idle`, `:137-138`).
7. **Accept failure is silent to the caller** (`:166-168`): if the callee's media
   session throws building the answer, the caller just times out; the callee sees
   `.failed` locally.

---

## 4. Locked v1 decisions and their rationale (from code comments)

| Decision | Where | Rationale (as committed) |
|---|---|---|
| **Voice-only** | `CallSignal.swift:4`, `CallController.swift:4,15` | "FaceTime-v1 (voice-only)"; the media seam is described as "the WebRTC **audio** wrapper"; `maxSDPBytes` is calibrated to voice-only offers |
| **Non-trickle ICE** | `CallSignal.swift:26-30` | "LOCKED for v1: each side gathers ALL its candidates and sends ONE complete SDP. Signaling rides the relay path when out of BLE range, where each leg costs seconds — trickling candidates would multiply that latency for nothing. One sealed round trip total: request → answer." |
| **STUN-only, no TURN** | `CallController.swift:20-25` | "NAT HONESTY (no TURN in v1): STUN-only ICE fails against symmetric NAT / CGNAT — common on cellular. That failure surfaces as `mediaFailed()` → `.ended(.connectFailed)`, which the UI renders as 'Couldn't connect — try joining the same WiFi'. It is a THIRD terminal outcome, distinct from decline and timeout (the callee DID accept); both ends detect it locally from their own ICE state, no extra signaling." |
| **No server / push / CallKit** | `CallController.swift:4-8` | Ringing = sealed request + local timeout; both parties foreground |
| **Media keys via existing trust root** | `CallSignal.swift:19-24` | SDP fingerprint sealed to the verified contact; no new trust root |
| **Strict, silent parsers** | `CallSignal.swift:86-122` | Untrusted receive path; malformed → ignore, never reply |
| **7f strict-verified gate** | `FirstContactCoordinator.swift:1234+` | An unverified session-holder must not be able to ring us |

**Drift note:** `CallSignal.swift:11-17` still says the wire placement (tags 8–10 +
the coordinator gate) is "deferred… lands in a LATER step." That step has since
landed (`MessagePayload.swift:86-88`, coordinator `:1043-1050`, `:1234-1272`). The
comment is stale; the code is authoritative.

---

## 5. Not built (verified absent from disk)

1. **`CallMediaSession` implementation** — no WebRTC dependency exists anywhere
   (Podfile: LibSignalClient only; Vendor: secp256k1 only; zero WebRTC references).
2. **Composition-root wiring** — `CallController` is never instantiated outside
   `Core/Calls/`; the `.callSignal` event has no consumer; `sendCallSignal` has no
   caller; `onMissedCall` writes no row.
3. **UI** — no ring banner, no accept/decline surface, no in-call bar, no call
   entry point in the chat.
4. **Tests** — no test file references `CallSignal` or `CallController`.

---

## 6. The three open forks — operator decisions required before build

### Fork 1 — which WebRTC library
No dependency is present, and the project pins its security-critical dependencies
deliberately (LibSignalClient: git tag + FFI prebuild checksum). Options:
- **(a) `stasel/WebRTC` binary distribution** (SPM/CocoaPods, widely used, needs a
  version you pin and trust);
- **(b) build libwebrtc from source** (reproducible, very heavy);
- **(c) Google's legacy pod** (unmaintained — not recommended).

### Fork 2 — voice-only vs voice+video
Everything committed says voice-only v1. Video adds camera capture/render, changes
the SDP profile (the 32 KiB ceiling likely still holds but was calibrated to
voice), and raises a signaling-shape question the original doc may have answered:
does a request declare video intent (a body/flag change = wire change), or does v1
always negotiate audio+video and toggle the camera in-band (kinds 8–10 stay
byte-compatible, but both builds must update — flag day)? Decide scope first;
shape second.

### Fork 3 — STUN-only vs TURN (and whose servers)
The committed posture is STUN-only with the honest `connectFailed` outcome.
"Working over the internet" holds for many NAT pairs but **not** symmetric
NAT/CGNAT (common on cellular). Options:
- **(a) keep STUN-only** (committed posture; honest failure copy);
- **(b) STUN + self-hosted TURN** (coturn; credentials + a server that sees both
  parties' call-time IPs — a metadata decision);
- **(c) STUN + third-party TURN service** (same metadata concern, less control).
Even STUN alone is a choice: whichever STUN host is configured learns each
party's IP and call timing. The original THREAT_MODEL.md (also lost) governed
this; the reconstruction cannot.

---

## 7. Build order once the forks are ruled (proposed, per-concern patches)

1. **P1** — dependency + project housekeeping (the pinned WebRTC, alone).
2. **P2** — `WebRTCCallMedia: CallMediaSession` (non-trickle gather, DTLS-SRTP,
   configured ICE servers) + unit tests against the seam.
3. **P3** — composition root: coordinator `.callSignal` → `CallController`;
   `sendSignal` → `sendCallSignal`; `onMissedCall` → inbox row.
4. **P4** — UI: call entry point, ring banner (accept/decline), in-call bar,
   outcome rendering (+ video surfaces if Fork 2 says so).
5. **P5** — audio-session/interruption/teardown hardening.
