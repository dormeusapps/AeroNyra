//
//  PersistentModelsTests.swift
//  BeaconTests
//
//  Verifies the SwiftData layer without UI: the six-state delivery bridge,
//  deterministic avatar hue, the direct/mesh-room encryption distinction, and
//  insert/fetch/cascade through an in-memory `ModelContainer`.
//

import XCTest
import SwiftData
@testable import Beacon

@MainActor
final class PersistentModelsTests: XCTestCase {

    /// A fresh in-memory store with all three models registered.
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Peer.self, Conversation.self, Message.self,
            configurations: config
        )
        return ModelContext(container)
    }

    // MARK: Delivery-state bridge

    func testDeliveryStateRoundTripsAllSixCases() throws {
        let cases: [MessageDeliveryState] = [
            .waitingForRange, .sent, .findingPath,
            .delivered, .relayed(hops: 3), .notDelivered
        ]
        for state in cases {
            let m = Message(content: "x", isOutbound: true, deliveryState: state)
            XCTAssertEqual(m.deliveryState, state, "round-trip failed for \(state)")
        }
    }

    func testRelayedHopsArePreserved() throws {
        let m = Message(content: "x", isOutbound: true, deliveryState: .relayed(hops: 5))
        XCTAssertEqual(m.relayHops, 5)
        if case .relayed(let hops) = m.deliveryState {
            XCTAssertEqual(hops, 5)
        } else {
            XCTFail("expected .relayed")
        }
    }

    func testDeliveryStateIsQueryableViaRawField() throws {
        let context = try makeContext()
        let convo = Conversation(kind: .direct)
        context.insert(convo)

        let a = Message(content: "ok", isOutbound: true, deliveryState: .delivered)
        let b = Message(content: "stuck", isOutbound: true, deliveryState: .notDelivered)
        a.conversation = convo
        b.conversation = convo
        context.insert(a); context.insert(b)
        try context.save()

        // Fetch only the failed ones (the resend case) by the raw field.
        let failedRaw = "notDelivered"
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.deliveryStateRaw == failedRaw }
        )
        let failed = try context.fetch(descriptor)
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed.first?.content, "stuck")
    }

    // MARK: Avatar hue

    func testAvatarHueIsDeterministic() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let p1 = Peer(publicKeyData: key)
        let p2 = Peer(publicKeyData: key)
        XCTAssertEqual(p1.avatarHue, p2.avatarHue)        // same key -> same hue
        XCTAssertTrue((0.0...1.0).contains(p1.avatarHue)) // in range
    }

    func testAvatarHueDiffersByKey() throws {
        let a = Peer(publicKeyData: Data(repeating: 0x01, count: 32))
        let b = Peer(publicKeyData: Data(repeating: 0xFE, count: 32))
        XCTAssertNotEqual(a.avatarHue, b.avatarHue)
    }

    // MARK: Conversation kind

    func testDirectConversationIsEncrypted() throws {
        let c = Conversation(kind: .direct)
        XCTAssertTrue(c.isEncrypted)
        XCTAssertEqual(c.kind, .direct)
    }

    func testMeshRoomIsNotEncrypted() throws {
        let c = Conversation(kind: .meshRoom, title: "Public")
        XCTAssertFalse(c.isEncrypted)
        XCTAssertEqual(c.kind, .meshRoom)
    }

    // MARK: Persistence + relationships

    func testInsertAndFetchPeer() throws {
        let context = try makeContext()
        let key = Data(repeating: 0xAB, count: 32)
        context.insert(Peer(publicKeyData: key, displayName: "Theo"))
        try context.save()

        let peers = try context.fetch(FetchDescriptor<Peer>())
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers.first?.displayName, "Theo")
        XCTAssertEqual(peers.first?.publicKeyData, key)
    }

    func testCascadeDeleteRemovesMessages() throws {
        let context = try makeContext()
        let convo = Conversation(kind: .direct)
        context.insert(convo)
        for i in 0..<3 {
            let m = Message(content: "m\(i)", isOutbound: i.isMultiple(of: 2))
            m.conversation = convo
            context.insert(m)
        }
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Message>()).count, 3)

        // Deleting the conversation cascades to its messages.
        context.delete(convo)
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<Message>()).count, 0)
    }

    func testWireIDRoundTrips() throws {
        let id = MessageID.random()
        let m = Message(content: "x", isOutbound: true, wireID: id)
        XCTAssertEqual(m.wireID, id)
    }
}
