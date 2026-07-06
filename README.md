# AeroNyra

**Offline-first, serverless, end-to-end encrypted messaging.** No accounts, no servers, no stranger discovery — contacts are proven directly and messages travel over a Bluetooth LE mesh, falling back to Nostr relays only when there's no one nearby.

> Status: **v1 — private beta (TestFlight).** iOS only.

---

## What it is

AeroNyra is a **closed-contact** messenger. There is no directory, no phone-number lookup, no "people you may know." You add a contact one of two ways: **in person**, by scanning each other's QR code, or **remotely**, by sending a single-use invite over any channel you like — AirDrop, Messages, email — and then confirming a matching 4-word phrase together on a quick call. Either way, no stranger can reach you. From then on, messages between you route:

1. **directly, device-to-device, over a Bluetooth LE mesh** when you're in range, and
2. **over public Nostr relays** as an encrypted fallback when you're not.

There is no AeroNyra server. There is no account to create and nothing to recover — your identity lives only on your device.

**v1 supports:** text, voice messages, photos, and video, all end-to-end encrypted.

## Security model

- End-to-end encryption via the **Signal protocol** (PQXDH + Triple Ratchet, `libsignal`).
- Identity is proven **in person by QR, or remotely by a single-use invite plus a spoken 4-word confirmation** — no trust-on-first-use, no server-vouched keys. In-person scans are authenticated by proximity (nothing in transit to interpose on); remote invites are authenticated by the 4-word phrase, which catches any tampering of the invite in transit.
- **Relay-bypass invariant:** messages received over Nostr are never re-broadcast over the mesh.
- No telemetry. No analytics. No data collected.

Design details live in the threat model and contact model docs. If you find a vulnerability, see [`SECURITY.md`](SECURITY.md).

## Building

Requirements:
- **Xcode 26.5**, iOS 17.0+ deployment target
- **CocoaPods** (LibSignalClient is a pod)

Steps:

    git clone https://github.com/dormeusapps/AeroNyra.git
    cd AeroNyra
    pod install
    open Beacon.xcworkspace   # always the workspace, never the .xcodeproj

Build note: this project sets `SWIFT_ENABLE_EXPLICIT_MODULES = NO` so `libsignal` compiles under Xcode 26.5.

Bluetooth mesh features require **physical devices** — the simulator has no BLE radio.

## License

AeroNyra is licensed under the **GNU Affero General Public License v3.0**, with an **additional App Store distribution permission under AGPL section 7**. See [`LICENSE`](LICENSE) for the AGPL text and [`AGPL-APPSTORE-EXCEPTION.md`](AGPL-APPSTORE-EXCEPTION.md) for the exception. In short: the source stays fully open under the AGPL, and the app may also be distributed through the App Store despite its incompatible terms.

## Contributing

Contributions are welcome under the **same AGPL-3.0 + App Store exception** as the project. By opening a pull request you agree your contribution is licensed on those terms. Please read the exception notice before contributing.
