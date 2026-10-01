//
//  BlockConfirmations.swift
//  Beacon
//
//  Plain Block / Unblock (Guideline 1.2), shared by Home (long-press and
//  swipe) and contact settings: the confirm alerts, their copy, and the call
//  into PairingService. A blocked chat stays in the chat list, read-only and
//  marked "blocked"; nothing here deletes or hides a row.
//
//  Lives in Beacon/ (a synchronized folder), not Screens/ (a classic group).
//

import SwiftUI

enum BlockCopy {
    static func blockTitle(_ name: String) -> String { "Block \(name)?" }
    static let blockMessage = "Their messages stop arriving, and they aren't told. They can't pair with you again unless you unblock them. Your chat stays in your chats, marked as blocked."
    static func unblockTitle(_ name: String) -> String { "Unblock \(name)?" }
    static let unblockMessage = "They can message you again, and your chat goes back to normal."
    static let blockFailedTitle = "Couldn't block"
    static let unblockFailedTitle = "Couldn't unblock"
    static let failedMessage = "Something went wrong saving the change. Please try again."
}

/// A pending Block or Unblock awaiting its confirm alert.
struct BlockRequest: Identifiable, Equatable {
    enum Kind: Equatable { case block, unblock }
    let kind: Kind
    let rawKey: Data
    /// The display name for the alert title.
    let name: String
    /// The raw local nickname, snapshotted into the denylist entry.
    let petname: String?
    var id: Data { rawKey }
}

private struct BlockConfirmations: ViewModifier {
    @Binding var request: BlockRequest?
    let pairing: PairingService?
    let onDone: () -> Void

    @State private var failed: BlockRequest.Kind?

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: Binding(get: { request != nil },
                                               set: { if !$0 { request = nil } }),
                   presenting: request) { r in
                switch r.kind {
                case .block:
                    Button("Block", role: .destructive) { perform(r) }
                case .unblock:
                    Button("Unblock") { perform(r) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { r in
                Text(r.kind == .block ? BlockCopy.blockMessage : BlockCopy.unblockMessage)
            }
            .alert(failed == .unblock ? BlockCopy.unblockFailedTitle : BlockCopy.blockFailedTitle,
                   isPresented: Binding(get: { failed != nil }, set: { if !$0 { failed = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(BlockCopy.failedMessage)
            }
    }

    private var title: String {
        guard let request else { return "" }
        return request.kind == .block ? BlockCopy.blockTitle(request.name) : BlockCopy.unblockTitle(request.name)
    }

    /// The service is required: without it the change fails visibly.
    private func perform(_ r: BlockRequest) {
        guard let pairing else { failed = r.kind; return }
        Task { @MainActor in
            do {
                switch r.kind {
                case .block: try await pairing.block(rawKey: r.rawKey, petname: r.petname)
                case .unblock: try await pairing.unblock(rawKey: r.rawKey)
                }
                onDone()
            } catch {
                RedactLog.event(r.kind == .block ? "block: FAILED" : "unblock: FAILED", "\(type(of: error))")
                failed = r.kind
            }
        }
    }
}

extension View {
    /// The Block / Unblock confirm alerts for `request`, and the failure alert.
    func blockConfirmations(_ request: Binding<BlockRequest?>,
                            pairing: PairingService?,
                            onDone: @escaping () -> Void = {}) -> some View {
        modifier(BlockConfirmations(request: request, pairing: pairing, onDone: onDone))
    }
}
