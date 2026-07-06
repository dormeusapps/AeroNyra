# Security Policy

AeroNyra is an end-to-end encrypted messenger. We take security reports
seriously and appreciate coordinated disclosure.

## Reporting a vulnerability

Email **support@dormeusapps.com** with:

- a description of the issue and its impact,
- steps to reproduce (or a proof of concept), and
- the affected version / build number.

Please **do not** open a public GitHub issue for security-sensitive reports.

If you'd like to encrypt your report, say so in a first (non-sensitive) email
and we'll arrange a key exchange.

## What to expect

- Acknowledgement within **72 hours**.
- An initial assessment and, where relevant, a fix timeline.
- Credit in the release notes if you'd like it (optional).

We aim to fix confirmed, high-severity issues promptly and to disclose them
once a fix is available to users.

## Scope

In scope: the AeroNyra iOS app and this repository — the cryptographic
handshake, the BLE mesh transport, the Nostr fallback path, key handling, and
local data protection.

Out of scope: the security of third-party Nostr relays themselves, and issues
requiring a physically unlocked, attacker-controlled device.

## Threat model

Before reporting, it may help to read the threat model and contact model docs
in this repository — some properties (e.g. the in-person pairing requirement)
are deliberate design choices, not gaps.
