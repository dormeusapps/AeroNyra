// ContactRemovalRequest.swift
// Beacon (the composition root — no new synchronized folder, see the pbxproj rule)
//
// How a contact's ROWS are removed, in one place. Crypto trust goes FIRST, at
// the call site (revoke / SAS discard); only after that succeeds does a caller
// delete the rows here. Shared by Remove Contact (HomeView) and the SAS
// "Doesn't match" flow so the two can never drift apart.
//

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
