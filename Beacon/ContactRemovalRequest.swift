// ContactRemovalRequest.swift
// Beacon (the composition root — no new synchronized folder, see the pbxproj rule)
//
// How a contact's ROWS are removed, in one place. Crypto trust goes FIRST, at
// the call site (revoke / SAS discard); only after that succeeds does a caller
// delete the rows here. Shared by Remove Contact (HomeView) and the SAS
// "Doesn't match" flow so the two can never drift apart.
//

import Foundation
import Observation
import SwiftData

@MainActor
enum ContactRows {

    /// Delete a contact's rows: its `.direct` conversation EXPLICITLY
    /// (Peer→Conversation is `.nullify`, so deleting the peer alone would
    /// orphan it), then the Peer, then save. Any `@Query` over peers drops the
    /// row on save. The caller must guarantee no mounted view still holds a
    /// direct reference to this Peer or its Conversation.
    static func delete(_ peer: Peer, in context: ModelContext) {
        if let convo = peer.conversations.first(where: { $0.kind == .direct }) {
            context.delete(convo)
        }
        context.delete(peer)
        try? context.save()
    }
}

/// SAS "Doesn't match" → row removal, handed from the chat to the ROOT of the
/// chats stack. The chat must never delete its own rows (the erase-crash
/// lesson: deleting Peer/Conversation rows under a mounted view that still
/// holds them can fault a deleted row), so after the crypto discard it only
/// POSTS the key from its `.onDisappear`; `ChatsRootView` — which owns the
/// stack's `[Peer]` path — deletes the rows once that Peer is no longer in the
/// path. TAKE-ONCE: a request is consumed exactly once.
@MainActor
@Observable
final class ContactRemovalRequest {

    struct Request: Equatable {
        let key: Data      // the peer's raw identity key (Peer.publicKeyData)
        let token: Int     // monotonic; two requests are never equal
    }

    private(set) var request: Request?
    private var nextToken = 0

    func post(_ key: Data) {
        nextToken += 1
        request = Request(key: key, token: nextToken)
    }

    /// The pending key, consumed — but ONLY when that Peer is no longer in the
    /// navigation path (`pathKeys`: the path's `Peer.publicKeyData`s). While it
    /// is still there the request stays pending and nil is returned; the root
    /// asks again on its next path change.
    func takeIfClear(pathKeys: [Data]) -> Data? {
        guard let key = request?.key, !pathKeys.contains(key) else { return nil }
        request = nil
        return key
    }
}
