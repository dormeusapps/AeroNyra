//
//  MeshPresence.swift
//  Screens
//
//  A thin, observable bridge from the BLE transport's live state to the UI.
//
//  The transport publishes the set of currently-linked peers as ephemeral
//  CoreBluetooth ids (NOT cryptographic identities — those arrive later via the
//  PrekeyBundle handshake). This holds that set so SwiftUI can react: the Nearby
//  radar shows a live blip per nearby device, and the status line counts them.
//
//  TWO RESOLUTIONS OF THE SAME TRUTH:
//   • `reachableIDs`     — ephemeral CoreBluetooth link ids. One physical peer
//                          linked over both GATT directions appears as TWO ids,
//                          and we don't know WHO any of them are. Good enough for
//                          the radar (blips) and a rough device count.
//   • `reachablePeerKeys`— identity-resolved (Phase 7a). The RAW 32-byte public
//                          keys of peers reachable RIGHT NOW, fed from
//                          FirstContactCoordinator, which maps links → identities
//                          and de-dups the per-role double-count. This is what
//                          per-conversation presence ("Direct" vs "Out of range")
//                          reads.
//
//  A device linked at the radio level but not yet identity-exchanged shows up in
//  `reachableIDs` (a radar blip) but NOT in `reachablePeerKeys` — correct: we
//  sense the device, but don't yet know who it is, so we never fabricate a Peer
//  identity from a BLE id. The named peer rows light up only once identity
//  exchange has happened.
//

import Foundation
import Observation

@Observable
final class MeshPresence {

    /// Ids of peers we currently have a usable BLE link to. Updated from the
    /// transport's `reachabilityUpdates` stream on the main actor. Ephemeral
    /// CoreBluetooth ids — un-deduped across GATT roles, no identity.
    var reachableIDs: [UUID] = []

    /// Identity-resolved reachability (Phase 7a): the RAW 32-byte public keys
    /// (`Peer.publicKeyData` form) of peers we can reach over BLE right now.
    /// Fed from `FirstContactCoordinator.reachablePeers`, which resolves links →
    /// identities and collapses the per-role double-count. Empty for a device
    /// that is linked but not yet identity-exchanged.
    var reachablePeerKeys: Set<Data> = []

    /// Whether the radio is actively scanning. The central scans continuously
    /// while the transport is running, so this is true once started.
    var isScanning: Bool = true

    /// Count of reachable RADIOS (ephemeral link ids). Not de-duped to identity;
    /// use `reachablePeerKeys.count` for a count of distinct reachable PEERS.
    var reachableCount: Int { reachableIDs.count }

    /// Whether a given peer — keyed by its RAW 32-byte `Peer.publicKeyData` — is
    /// reachable over BLE right now. The single read the per-conversation and
    /// per-row presence UI calls into.
    func isReachable(_ key: Data) -> Bool {
        reachablePeerKeys.contains(key)
    }
}
