//
//  InboxFilterDropTests.swift
//  BeaconTests
//
//  Pins the content filter on both sides of the inbox: a received text the
//  filter blocks leaves no trace (no Message, Peer or Conversation row, no
//  unread), and the same text is stored when the filter is OFF; a text the
//  user sends that the filter blocks is never stored or sent.
//

import XCTest
import SwiftData
@testable import Beacon

@MainActor
final class InboxFilterDropTests: XCTestCase {

    private struct Harness {
        let container: ModelContainer
        let context: ModelContext
        let inbox: MessageInbox
    }

    /// `blocks` stands in for the filter: true = the filter is ON and matches.
    private func makeHarness(blocks: @escaping @MainActor (String) -> Bool) throws -> Harness {
        let container = try ModelContainer(
            for: Peer.self, Conversation.self, Message.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let coordinator = FirstContactCoordinator(store: SignalSessionStore(),
                                                  transport: BLEMeshTransport())
        let inbox = MessageInbox(modelContext: container.mainContext,
                                 coordinator: coordinator,
                                 router: MessageRouter(transports: []),
                                 isVerified: { _ in true },
                                 filterBlocks: blocks)
        return Harness(container: container, context: container.mainContext, inbox: inbox)
    }

    private func count<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws -> Int {
        try context.fetchCount(FetchDescriptor<T>())
    }

    private func unread(in context: ModelContext) throws -> Int {
        try context.fetchCount(FetchDescriptor<Message>(predicate: #Predicate { !$0.isOutbound && !$0.isRead }))
    }

    private let peerKey = Data(repeating: 7, count: 32)

    // MARK: - Receive

    func testFilteredTextIsDroppedWithoutATrace() throws {
        let h = try makeHarness(blocks: { ContentFilterMatcher(userWords: "").matches($0) })
        let outcome = h.inbox.ingestReceivedText(peerKey: peerKey, plaintext: Data("you bitch".utf8),
                                                 wireID: .random())
        XCTAssertEqual(outcome, .dropped)
        XCTAssertEqual(try count(Message.self, in: h.context), 0)
        XCTAssertEqual(try count(Peer.self, in: h.context), 0)
        XCTAssertEqual(try count(Conversation.self, in: h.context), 0)
        XCTAssertEqual(try unread(in: h.context), 0)
    }

    func testCleanTextIsStored() throws {
        let h = try makeHarness(blocks: { ContentFilterMatcher(userWords: "").matches($0) })
        let outcome = h.inbox.ingestReceivedText(peerKey: peerKey, plaintext: Data("see you at 7".utf8),
                                                 wireID: .random())
        XCTAssertEqual(outcome, .stored)
        XCTAssertEqual(try count(Message.self, in: h.context), 1)
        XCTAssertEqual(try unread(in: h.context), 1)
    }

    /// Filter OFF: the same text is stored like any other.
    func testFilterOffStoresTheSameText() throws {
        let h = try makeHarness(blocks: { _ in false })
        let outcome = h.inbox.ingestReceivedText(peerKey: peerKey, plaintext: Data("you bitch".utf8),
                                                 wireID: .random())
        XCTAssertEqual(outcome, .stored)
        XCTAssertEqual(try count(Message.self, in: h.context), 1)
    }

    // MARK: - Send

    private func conversation(in context: ModelContext) -> Conversation {
        let peer = Peer(publicKeyData: peerKey)
        context.insert(peer)
        let conversation = Conversation(kind: .direct, peer: peer)
        context.insert(conversation)
        return conversation
    }

    func testFilteredSendIsNeverStoredOrSent() async throws {
        let h = try makeHarness(blocks: { ContentFilterMatcher(userWords: "").matches($0) })
        let convo = conversation(in: h.context)
        await h.inbox.send("  you bitch ", in: convo)
        XCTAssertEqual(try count(Message.self, in: h.context), 0)
    }

    /// Control: a clean text is stored (then fails to send — no session here).
    func testCleanSendIsStored() async throws {
        let h = try makeHarness(blocks: { ContentFilterMatcher(userWords: "").matches($0) })
        let convo = conversation(in: h.context)
        await h.inbox.send("see you at 7", in: convo)
        XCTAssertEqual(try count(Message.self, in: h.context), 1)
    }

    /// Filter OFF: no check on the send side either (one switch).
    func testFilterOffSendsTheSameText() async throws {
        let h = try makeHarness(blocks: { _ in false })
        let convo = conversation(in: h.context)
        await h.inbox.send("you bitch", in: convo)
        XCTAssertEqual(try count(Message.self, in: h.context), 1)
    }

    /// The real app wiring: `ContentFilter.blocks` reading the settings.
    func testDefaultWiringReadsTheSetting() throws {
        let container = try ModelContainer(
            for: Peer.self, Conversation.self, Message.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let inbox = MessageInbox(modelContext: container.mainContext,
                                 coordinator: FirstContactCoordinator(store: SignalSessionStore(),
                                                                      transport: BLEMeshTransport()),
                                 router: MessageRouter(transports: []),
                                 isVerified: { _ in true })
        let saved = UserDefaults.standard.object(forKey: ContentFilter.enabledKey)
        addTeardownBlock { UserDefaults.standard.set(saved, forKey: ContentFilter.enabledKey) }

        UserDefaults.standard.set(true, forKey: ContentFilter.enabledKey)
        XCTAssertEqual(inbox.ingestReceivedText(peerKey: peerKey, plaintext: Data("merde".utf8),
                                                wireID: .random()), .dropped)
        UserDefaults.standard.set(false, forKey: ContentFilter.enabledKey)
        XCTAssertEqual(inbox.ingestReceivedText(peerKey: peerKey, plaintext: Data("merde".utf8),
                                                wireID: .random()), .stored)
    }
}
