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
//  Deliberately holds ids, not Peers. We do not yet know WHO a device is, only
//  that it is here — so we never fabricate a Peer identity from a BLE id. The
//  named peer rows light up only once identity exchange exists.
//

import Foundation
import Observation

@Observable
final class MeshPresence {

    /// Ids of peers we currently have a usable BLE link to. Updated from the
    /// transport's `reachabilityUpdates` stream on the main actor.
    var reachableIDs: [UUID] = []

    /// Whether the radio is actively scanning. The central scans continuously
    /// while the transport is running, so this is true once started.
    var isScanning: Bool = true

    var reachableCount: Int { reachableIDs.count }
}
