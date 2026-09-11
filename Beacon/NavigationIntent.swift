// NavigationIntent.swift
// Beacon (the composition root — no new synchronized folder, see the pbxproj rule)
//
// The app's ONE programmatic-navigation primitive (live PTT-over-IP step 5,
// Rubins' ruling 2026-09-11: the responder banner MUST deep-link). Before
// this, a conversation could only be reached by tapping its row; the
// notification-tap handler (N3) is a stub for the same reason. Any surface
// that needs to put the user in a peer's chat posts a request here; the
// chats root (ContentView) observes it and replaces its navigation path.
//
// TAKE-ONCE: the stream view consumes a request for ITS peer exactly once
// (`takeWalkieRequest`), so a stale request can never re-fire on a later
// appear. The token makes two requests for the same peer distinguishable
// to `onChange`, so a second banner tap while already in that chat still
// raises the cover.
//

import Foundation
import Observation

@MainActor
@Observable
final class NavigationIntent {

    struct Request: Equatable {
        let key: Data          // the peer's raw identity key (Peer.publicKeyData)
        let walkie: Bool       // raise the walkie cover on arrival
        let token: Int         // monotonic; two requests are never equal
    }

    private(set) var request: Request?
    private var nextToken = 0

    /// Put the user in `key`'s conversation; with `walkie`, the cover opens
    /// on arrival and adopts any link already open to that peer.
    func open(_ key: Data, walkie: Bool) {
        nextToken += 1
        request = Request(key: key, walkie: walkie, token: nextToken)
    }

    func openWalkie(with key: Data) { open(key, walkie: true) }

    /// The stream view for `key` asks on appear (and on every new request):
    /// true exactly once per walkie request for this peer; a request for
    /// another peer, or a non-walkie request, is left in place.
    func takeWalkieRequest(for key: Data) -> Bool {
        guard let r = request, r.key == key, r.walkie else { return false }
        request = nil
        return true
    }
}
