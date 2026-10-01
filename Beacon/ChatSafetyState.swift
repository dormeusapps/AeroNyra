//
//  ChatSafetyState.swift
//  Beacon
//
//  Blocked and reported chats (Guideline 1.2), as pure tables the views
//  read, so the rules are tested here and the views only render them:
//   • ChatSafety  — normal / blocked / reported, from the denylist;
//   • ChatRoster  — Home keeps blocked and reported chats, labelled, sorted
//                   with everyone else (they are not removed);
//   • ChatMode    — what a chat screen shows: the composer, the verify-gate,
//                   or a read-only transcript (blocked / reported);
//   • ChatActions — which safety actions each place offers.
//

import Foundation

enum ChatSafety: Equatable, Sendable {
    case normal
    /// Blocked by the user; reversible.
    case blocked
    /// Reported: blocked for good, never paired again.
    case reported

    static func of(_ rawKey: Data, in blocked: [BlockedContact]) -> ChatSafety {
        guard let entry = blocked.first(where: { $0.rawKey == rawKey }) else { return .normal }
        return entry.reported ? .reported : .blocked
    }

    /// The row label on Home; nil for a normal chat.
    var label: String? {
        switch self {
        case .normal: return nil
        case .blocked: return "blocked"
        case .reported: return "reported"
        }
    }
}

enum ChatRoster {

    /// Every chat, each with its safety state, sorted by name. Blocked and
    /// reported chats stay in the list.
    static func rows<Item>(_ items: [Item],
                           key: (Item) -> Data,
                           name: (Item) -> String,
                           blocked: [BlockedContact]) -> [(item: Item, safety: ChatSafety)] {
        items
            .map { (item: $0, safety: ChatSafety.of(key($0), in: blocked)) }
            .sorted { name($0.item).localizedCaseInsensitiveCompare(name($1.item)) == .orderedAscending }
    }
}

enum ChatMode: Equatable, Sendable {
    case composer
    case verifyGate
    /// Blocked or reported: the transcript only. No composer, no verify-gate,
    /// no call, video or walkie.
    case readOnly(ChatSafety)

    static func of(safety: ChatSafety, verified: Bool) -> ChatMode {
        switch safety {
        case .blocked, .reported: return .readOnly(safety)
        case .normal: return verified ? .composer : .verifyGate
        }
    }

    var isReadOnly: Bool {
        if case .readOnly = self { return true }
        return false
    }

    var showsComposer: Bool { self == .composer }
    var showsVerifyGate: Bool { self == .verifyGate }
    /// Call, video and walkie in the chat header.
    var showsCallButtons: Bool { !isReadOnly }
}

enum ChatAction: Equatable, Sendable {
    case block
    case unblock
    case report
}

enum ChatActions {

    /// Swipe, long-press and accessibility actions on a Home row, in order.
    static func row(_ safety: ChatSafety) -> [ChatAction] {
        switch safety {
        case .normal: return [.block, .report]
        case .blocked: return [.unblock, .report]
        case .reported: return []
        }
    }

    /// Report offered on a message's long-press and in the chat banner.
    static func offersReport(_ safety: ChatSafety) -> Bool { safety != .reported }

    /// Deleting from a reported chat deletes the user's evidence: warn first.
    static func warnsBeforeDeleting(_ safety: ChatSafety) -> Bool { safety == .reported }

    /// The warning's message (delete message, Clear History, Remove Contact).
    static func evidenceWarning(name: String) -> String {
        "This deletes your evidence. \(name) still can't pair with you again."
    }
}
