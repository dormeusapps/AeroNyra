//
//  BlockWindowTests.swift
//  BeaconTests
//
//  Pins the v68 §5a fix (commit C4). INVARIANT: anything a contact sends
//  while blocked is never shown, stored, notified or acknowledged, even after
//  Unblock; for a contact who was never blocked the receive path is unchanged.
//
//   • receive: a refused envelope id is dropped before it is opened; the
//     blocked guard records the id; a relay copy whose inner send time falls
//     in a block period (start floored to the second, end + 30 s) is dropped
//     and its id refused — whatever the payload kind; Bluetooth (nil time)
//     is never period-checked.
//   • Unblock records the period FIRST: if that fails, nothing else changes.
//   • Erase / leftover sweep remove the history's key and file.
//
//  A real coordinator over a real router whose only transport records relay
//  publishes: a delivery receipt is one publish to the sender's key (the npub
//  lookup returns the raw key itself). "Nothing received" is asserted after a
//  sentinel from another contact has arrived — events are delivered in order.
//

import XCTest
import CryptoKit
import os
@testable import Beacon

@MainActor
final class BlockWindowTests: XCTestCase {

    // MARK: - Rig

    private final class Received: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: [MessageID]())
        func append(_ id: MessageID) { lock.withLock { $0.append(id) } }
        var ids: [MessageID] { lock.withLock { $0 } }
    }

    private struct Contact {
        let session: any SecureSession
        let raw: Data
    }

    private struct Rig {
        let us: SignalSessionStore
        let coordinator: FirstContactCoordinator
        let relay: RecordingRelay
        let history: BlockHistoryStore
        let received: Received
        let contacts: [Contact]
        let sentinel: Contact
    }

    private func makeDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("block-window.\(tag).\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeHistory(_ dir: URL, _ key: SymmetricKey) throws -> BlockHistoryStore {
        try BlockHistoryStore(directory: dir, dek: key, keychainService: "test.bw.\(UUID().uuidString)",
                              saveDelay: 3600)
    }

    /// `contacts` senders plus a sentinel, all verified, all with sessions to us.
    private func makeRig(contacts count: Int = 2, history: BlockHistoryStore?,
                         wireHistory: Bool = true) async throws -> Rig {
        let us = SignalSessionStore()
        let coordinator = FirstContactCoordinator(store: us, transport: BLEMeshTransport())
        let relay = RecordingRelay()
        await coordinator.setRouter(MessageRouter(transports: [relay]))
        await coordinator.setNostrKeyLookup { raw in raw }
        var all: [Contact] = []
        for _ in 0...count {
            let them = SignalSessionStore()
            let session = try them.establishSession(from: try us.localPrekeyBundle())
            all.append(Contact(session: session, raw: us.rawPublicKey(of: them.localIdentity)))
        }
        await coordinator.enableReconnect(agreementPrivate: Curve25519.KeyAgreement.PrivateKey(),
                                          allowlistIdentities: all.map(\.raw),
                                          verifiedIdentities: all.map(\.raw))
        if wireHistory, let history { await coordinator.setBlockHistory(history) }

        let received = Received()
        let events = coordinator.events
        let collector = Task {
            for await event in events {
                switch event {
                case .received(_, _, let wireID): received.append(wireID)
                case .receivedMedia(_, _, _, let wireID, _, _, _): received.append(wireID)
                default: break
                }
            }
        }
        addTeardownBlock { collector.cancel() }
        let fallback = SymmetricKey(size: .bits256)
        return Rig(us: us, coordinator: coordinator, relay: relay,
                   history: try history ?? makeHistory(try makeDir("unused"), fallback),
                   received: received, contacts: Array(all.dropLast()), sentinel: all.last!)
    }

    private func text(_ c: Contact, _ s: String = "hi") throws -> Data {
        try c.session.seal(MessagePayload.text(Data(s.utf8)).sealedPlaintext())
    }

    @discardableResult
    private func send(_ rig: Rig, _ c: Contact, id: MessageID = .random(),
                      relaySeconds: Int64?, payload: Data? = nil) async throws -> MessageID {
        let ct = try payload.map { try c.session.seal($0) } ?? (try text(c))
        await rig.coordinator.receive(Envelope(id: id, ciphertext: ct), relaySentAtSeconds: relaySeconds)
        return id
    }

    /// Waits until a sentinel text has been received: every earlier event is in.
    private func settle(_ rig: Rig) async throws {
        let id = try await send(rig, rig.sentinel, relaySeconds: nil)
        let deadline = Date().addingTimeInterval(5)
        while !rig.received.ids.contains(id), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(rig.received.ids.contains(id), "precondition: the sentinel arrived")
    }

    private func receipts(_ rig: Rig, to c: Contact) -> Int {
        rig.relay.publishedTo.filter { $0 == c.raw }.count
    }

    private func period(_ rig: Rig, _ c: Contact, _ blockedAt: Int64, _ unblockedAt: Int64) throws {
        try rig.history.recordPeriod(rawKey: c.raw, blockedAt: blockedAt, unblockedAt: unblockedAt)
    }

    private func refused(_ rig: Rig, _ id: MessageID) -> Bool {
        rig.history.isRefused(Data(id.bytes))
    }

    /// A period with a non-whole-second start, so the floor matters.
    private let blockedAt: Int64 = 1_700_000_000_500
    private let unblockedAt: Int64 = 1_700_000_100_000

    // MARK: - Never blocked / empty history

    func testANeverBlockedContactIsUnchanged() async throws {
        let rig = try await makeRig(history: try makeHistory(try makeDir("h"), SymmetricKey(size: .bits256)))
        let blocked = rig.contacts[0], never = rig.contacts[1]
        try period(rig, blocked, blockedAt, unblockedAt)

        let relayCopy = try await send(rig, never, relaySeconds: 1_700_000_050)   // inside the OTHER contact's period
        let bluetoothCopy = try await send(rig, never, relaySeconds: nil)
        try await settle(rig)

        XCTAssertTrue(rig.received.ids.contains(relayCopy))
        XCTAssertTrue(rig.received.ids.contains(bluetoothCopy))
        XCTAssertEqual(receipts(rig, to: never), 2, "exactly one receipt each")
        XCTAssertFalse(refused(rig, relayCopy))
        XCTAssertFalse(refused(rig, bluetoothCopy))
    }

    func testAnEmptyHistoryChangesNothing() async throws {
        for wired in [true, false] {
            let rig = try await makeRig(history: try makeHistory(try makeDir("h"), SymmetricKey(size: .bits256)),
                                        wireHistory: wired)
            let c = rig.contacts[0]
            let a = try await send(rig, c, relaySeconds: 1_700_000_050)
            let b = try await send(rig, c, relaySeconds: nil)
            try await settle(rig)
            XCTAssertTrue(rig.received.ids.contains(a), "wired=\(wired)")
            XCTAssertTrue(rig.received.ids.contains(b), "wired=\(wired)")
            XCTAssertEqual(receipts(rig, to: c), 2, "wired=\(wired)")
        }
    }

    // MARK: - The unblock backlog

    func testARelayCopySentDuringTheBlockIsDroppedWithNoReceipt() async throws {
        let rig = try await makeRig(history: try makeHistory(try makeDir("h"), SymmetricKey(size: .bits256)))
        let c = rig.contacts[0]
        try period(rig, c, blockedAt, unblockedAt)

        let id = try await send(rig, c, relaySeconds: 1_700_000_050)
        try await settle(rig)

        XCTAssertFalse(rig.received.ids.contains(id), "never shown or stored")
        XCTAssertEqual(receipts(rig, to: c), 0, "never acknowledged")
        XCTAssertTrue(refused(rig, id), "its id is refused from now on")
    }

    func testARelayCopyAfterTheMarginIsDelivered() async throws {
        let rig = try await makeRig(history: try makeHistory(try makeDir("h"), SymmetricKey(size: .bits256)))
        let c = rig.contacts[0]
        try period(rig, c, blockedAt, unblockedAt)

        let id = try await send(rig, c, relaySeconds: (unblockedAt + 30_000) / 1000 + 1)
        try await settle(rig)

        XCTAssertTrue(rig.received.ids.contains(id))
        XCTAssertEqual(receipts(rig, to: c), 1)
    }

    func testTheBoundaries() async throws {
        let rig = try await makeRig(history: try makeHistory(try makeDir("h"), SymmetricKey(size: .bits256)))
        let c = rig.contacts[0]
        try period(rig, c, blockedAt, unblockedAt)          // 1_700_000_000_500 … 1_700_000_100_000

        let atFlooredStart = try await send(rig, c, relaySeconds: 1_700_000_000)
        let secondBefore = try await send(rig, c, relaySeconds: 1_699_999_999)
        let atMarginEnd = try await send(rig, c, relaySeconds: 1_700_000_130)   // unblockedAt + 30 s
        let secondAfter = try await send(rig, c, relaySeconds: 1_700_000_131)
        try await settle(rig)

        XCTAssertFalse(rig.received.ids.contains(atFlooredStart), "the start is floored to its second")
        XCTAssertTrue(rig.received.ids.contains(secondBefore))
        XCTAssertFalse(rig.received.ids.contains(atMarginEnd), "the margin end is inclusive")
        XCTAssertTrue(rig.received.ids.contains(secondAfter))
        XCTAssertEqual(receipts(rig, to: c), 2, "receipts only for the two delivered")
    }

    func testTheRuleConvertsSecondsToMilliseconds() {
        let p = BlockPeriod(blockedAt: 1_700_000_000_000, unblockedAt: 1_700_000_060_000)
        XCTAssertTrue(p.coversRelaySend(atSeconds: 1_700_000_030), "seconds × 1000 lands inside the ms period")
        XCTAssertFalse(p.coversRelaySend(atSeconds: 1_700_000_030_000), "a ms value read as seconds is far outside")
        XCTAssertFalse(p.coversRelaySend(atSeconds: 1_699_999_999))
        XCTAssertTrue(p.coversRelaySend(atSeconds: 1_700_000_090), "end + 30 s")
        XCTAssertFalse(p.coversRelaySend(atSeconds: 1_700_000_091))
    }

    func testAHostileTimeNearTheLimitsCannotTrap() {
        let p = BlockPeriod(blockedAt: 1_700_000_000_000, unblockedAt: 1_700_000_060_000)
        XCTAssertFalse(p.coversRelaySend(atSeconds: Int64.max))
        XCTAssertFalse(p.coversRelaySend(atSeconds: Int64.min))
        XCTAssertTrue(BlockPeriod(blockedAt: 0, unblockedAt: Int64.max).coversRelaySend(atSeconds: Int64.max))
    }

    // MARK: - Refused ids (the sender's resend reuses them)

    func testABluetoothDropWhileBlockedIsRefusedForGoodOverBothTransports() async throws {
        let rig = try await makeRig(history: try makeHistory(try makeDir("h"), SymmetricKey(size: .bits256)))
        let c = rig.contacts[0]
        await rig.coordinator.setBlockedIdentities([c.raw])
        let id = try await send(rig, c, relaySeconds: nil)            // dropped by the blocked guard
        XCTAssertTrue(refused(rig, id), "the blocked guard records the id")

        // Unblock, then the sender's resend: the SAME id, freshly sealed.
        try period(rig, c, blockedAt, unblockedAt)
        await rig.coordinator.setBlockedIdentities([])
        try await send(rig, c, id: id, relaySeconds: nil)
        try await send(rig, c, id: id, relaySeconds: (unblockedAt + 30_000) / 1000 + 60)
        try await settle(rig)

        XCTAssertFalse(rig.received.ids.contains(id))
        XCTAssertEqual(receipts(rig, to: c), 0)
    }

    func testANewBluetoothIDAfterUnblockIsDelivered() async throws {   // R1, accepted
        let rig = try await makeRig(history: try makeHistory(try makeDir("h"), SymmetricKey(size: .bits256)))
        let c = rig.contacts[0]
        try period(rig, c, blockedAt, unblockedAt)
        let id = try await send(rig, c, relaySeconds: nil)
        try await settle(rig)
        XCTAssertTrue(rig.received.ids.contains(id), "Bluetooth has no send time: never period-checked")
        XCTAssertEqual(receipts(rig, to: c), 1)
    }

    func testMediaSentDuringTheBlockIsDropped() async throws {
        let rig = try await makeRig(history: try makeHistory(try makeDir("h"), SymmetricKey(size: .bits256)))
        let c = rig.contacts[0]
        try period(rig, c, blockedAt, unblockedAt)
        let manifest = try await send(rig, c, relaySeconds: 1_700_000_050,
                                      payload: MessagePayload.mediaManifest(Data("{}".utf8)).sealedPlaintext())
        let chunk = try await send(rig, c, relaySeconds: 1_700_000_050,
                                   payload: MessagePayload.mediaChunk(Data(repeating: 1, count: 64)).sealedPlaintext())
        try await settle(rig)
        XCTAssertTrue(refused(rig, manifest), "dropped by the period, whatever the payload kind")
        XCTAssertTrue(refused(rig, chunk))
        XCTAssertEqual(receipts(rig, to: c), 0)
    }

    // MARK: - Relaunch

    func testDropsSurviveARelaunch() async throws {
        let dir = try makeDir("h")
        let key = SymmetricKey(size: .bits256)
        let first = try makeHistory(dir, key)
        let rig = try await makeRig(history: first)
        let c = rig.contacts[0]
        let earlier = MessageID.random()
        try first.recordPeriod(rawKey: c.raw, blockedAt: blockedAt, unblockedAt: unblockedAt)
        first.recordRefused(Data(earlier.bytes))
        try first.flush()

        // Relaunch: a new store over the same file, wired in its place.
        let reloaded = try makeHistory(dir, key)
        XCTAssertEqual(reloaded.periods(for: c.raw).count, 1, "the period survived")
        XCTAssertTrue(reloaded.isRefused(Data(earlier.bytes)), "the refused id survived")
        await rig.coordinator.setBlockHistory(reloaded)
        let relaunched = Rig(us: rig.us, coordinator: rig.coordinator, relay: rig.relay, history: reloaded,
                             received: rig.received, contacts: rig.contacts, sentinel: rig.sentinel)

        let inside = try await send(relaunched, c, relaySeconds: 1_700_000_050)
        try await send(relaunched, c, id: earlier, relaySeconds: nil)
        try await settle(relaunched)
        XCTAssertFalse(rig.received.ids.contains(inside))
        XCTAssertFalse(rig.received.ids.contains(earlier))
        XCTAssertEqual(receipts(rig, to: c), 0)
    }

    // MARK: - Unblock (PairingService)

    private struct PairingRig {
        let pairing: PairingService
        let enrollment: EnrollmentService
        let blockedStore: BlockedContactsStore
        let coordinator: FirstContactCoordinator
        let contact: Data
    }

    private func makePairingRig(history: BlockHistoryStore?) async throws -> PairingRig {
        let dir = try makeDir("stores")
        let sessionStore = try SignalSessionStore(appIdentity: IdentityKeypair.generate(),
                                                  directory: try makeDir("session"),
                                                  dek: SymmetricKey(size: .bits256))
        let contactStore = SignalSessionStore()
        let toUs = try contactStore.establishSession(from: try sessionStore.localPrekeyBundle())
        let opened = try sessionStore.openInbound(try toUs.seal(Data("hello".utf8)))
        let contact = sessionStore.rawPublicKey(of: opened.peer)
        let coordinator = FirstContactCoordinator(store: sessionStore, transport: BLEMeshTransport())
        let enrollment = EnrollmentService(
            store: try ContactAllowlistStore(directory: dir, dek: SymmetricKey(size: .bits256),
                                             keychainService: "test.bw.a.\(UUID().uuidString)"),
            pendingStore: try PendingInvitesStore(directory: dir, dek: SymmetricKey(size: .bits256),
                                                  keychainService: "test.bw.p.\(UUID().uuidString)"),
            coordinator: coordinator)
        try await enrollment.enroll(identity: contact, verified: true)
        let blockedStore = try BlockedContactsStore(directory: try makeDir("blocked"),
                                                    dek: SymmetricKey(size: .bits256),
                                                    keychainService: "test.bw.b.\(UUID().uuidString)")
        let pairing = PairingService(sessionStore: sessionStore, coordinator: coordinator,
                                     enrollment: enrollment, ourNostrPublicKey: nil,
                                     blockedStore: blockedStore, blockHistory: history,
                                     initialBlocked: [])
        return PairingRig(pairing: pairing, enrollment: enrollment, blockedStore: blockedStore,
                          coordinator: coordinator, contact: contact)
    }

    private func assertStillBlocked(_ r: PairingRig, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(r.pairing.isBlocked(r.contact), "still blocked", file: file, line: line)
        XCTAssertEqual(try r.blockedStore.load().map(\.rawKey), [r.contact], "denylist unchanged on disk",
                       file: file, line: line)
        XCTAssertFalse(r.enrollment.contains(r.contact), "nothing re-enrolled", file: file, line: line)
    }

    func testUnblockRecordsThePeriodFromTheBlockToNow() async throws {
        let history = try makeHistory(try makeDir("h"), SymmetricKey(size: .bits256))
        let r = try await makePairingRig(history: history)
        try await r.pairing.block(rawKey: r.contact, petname: nil)
        let blockedAt = try XCTUnwrap(try r.blockedStore.load().first?.blockedAt)
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        try await r.pairing.unblock(rawKey: r.contact)
        let after = Int64(Date().timeIntervalSince1970 * 1000)

        let periods = history.periods(for: r.contact)
        XCTAssertEqual(periods.count, 1)
        XCTAssertEqual(periods.first?.blockedAt, blockedAt, "the denylist entry's block time")
        XCTAssertGreaterThanOrEqual(periods.first?.unblockedAt ?? 0, before)
        XCTAssertLessThanOrEqual(periods.first?.unblockedAt ?? .max, after)
        XCTAssertFalse(r.pairing.isBlocked(r.contact))
        XCTAssertTrue(r.enrollment.contains(r.contact))
    }

    func testAnUnreadableHistoryRefusesUnblockAndChangesNothing() async throws {
        let dir = try makeDir("h")
        try Data("not a sealed box".utf8).write(to: dir.appendingPathComponent(BlockHistoryStore.fileName))
        let history = try makeHistory(dir, SymmetricKey(size: .bits256))
        XCTAssertFalse(history.isReadable, "precondition")
        let r = try await makePairingRig(history: history)
        try await r.pairing.block(rawKey: r.contact, petname: nil)

        do {
            try await r.pairing.unblock(rawKey: r.contact)
            XCTFail("Unblock must be refused while the history is unreadable")
        } catch BlockHistoryStore.StoreError.unreadable {}
        try assertStillBlocked(r)
    }

    func testAFailedPeriodWriteLeavesEnrollmentAndTheDenylistUntouched() async throws {
        let history = try makeHistory(try makeDir("h"), SymmetricKey(size: .bits256))
        let r = try await makePairingRig(history: history)
        try await r.pairing.block(rawKey: r.contact, petname: nil)
        try await history.wipe()                       // every later write throws .wiped

        do {
            try await r.pairing.unblock(rawKey: r.contact)
            XCTFail("a failed period write must refuse Unblock")
        } catch BlockHistoryStore.StoreError.wiped {}
        try assertStillBlocked(r)
    }

    func testNoHistoryStoreRefusesUnblock() async throws {
        let r = try await makePairingRig(history: nil)
        try await r.pairing.block(rawKey: r.contact, petname: nil)
        do {
            try await r.pairing.unblock(rawKey: r.contact)
            XCTFail("never unblock with no record")
        } catch PairingService.BlockError.storeUnavailable {}
        try assertStillBlocked(r)
    }

    func testAReportedContactIsNeverUnblockedAndNoPeriodIsWritten() async throws {
        let history = try makeHistory(try makeDir("h"), SymmetricKey(size: .bits256))
        let r = try await makePairingRig(history: history)
        try await r.pairing.reportAndBlock(rawKey: r.contact, petname: nil)
        do {
            try await r.pairing.unblock(rawKey: r.contact)
            XCTFail("a reported contact is never unblocked")
        } catch PairingService.BlockError.reported {}
        XCTAssertEqual(history.periods(for: r.contact), [], "no period written")
        XCTAssertTrue(r.pairing.isBlocked(r.contact))
        XCTAssertFalse(r.enrollment.contains(r.contact))
    }

    func testAReportedContactsMessagesAreStillDropped() async throws {
        let rig = try await makeRig(history: try makeHistory(try makeDir("h"), SymmetricKey(size: .bits256)))
        let c = rig.contacts[0]
        await rig.coordinator.setBlockedIdentities([c.raw])   // a reported entry is in the drop set
        let a = try await send(rig, c, relaySeconds: 1_700_000_050)
        let b = try await send(rig, c, relaySeconds: nil)
        try await settle(rig)
        XCTAssertFalse(rig.received.ids.contains(a))
        XCTAssertFalse(rig.received.ids.contains(b))
        XCTAssertEqual(receipts(rig, to: c), 0)
    }

    // MARK: - Erase

    func testTheLeftoverSweepRemovesTheHistoryKeyAndFileWithoutOpeningIt() async throws {
        let dir = try makeDir("sweep")
        let u = UUID().uuidString
        var services = LeftoverSweep.Services(sessionKey: "test.bw.sweep.session.\(u)",
                                              nostrIdentity: "test.bw.sweep.nostr.\(u)")
        services.contactAllowlist = "test.bw.sweep.allow.\(u)"
        services.pendingInvites = "test.bw.sweep.pending.\(u)"
        services.blockedContacts = "test.bw.sweep.blocked.\(u)"
        services.eventLedger = "test.bw.sweep.ledger.\(u)"
        services.blockHistory = "test.bw.sweep.history.\(u)"
        let all = [services.sessionKey, services.contactAllowlist, services.pendingInvites,
                   services.blockedContacts, services.eventLedger, services.blockHistory]
        addTeardownBlock {
            for svc in all { try? SessionStoreKey.destroy(service: svc) }
            try? NostrSecretStore.destroy(service: services.nostrIdentity)
        }
        let key = try SessionStoreKey.loadOrCreate(service: services.blockHistory)
        try BlockHistoryStore(directory: dir, dek: key, keychainService: services.blockHistory)
            .recordPeriod(rawKey: Data(repeating: 4, count: 32), blockedAt: 1, unblockedAt: 2)
        let file = dir.appendingPathComponent(BlockHistoryStore.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "precondition")

        let sweep = try LeftoverSweep.standard(storeDirectory: dir, services: services,
                                               swiftData: NoOpWipe(), residue: NoOpWipe())
        let errors = await sweep.run()

        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNotEqual(try SessionStoreKey.loadOrCreate(service: services.blockHistory)
                            .withUnsafeBytes { Data($0) },
                          key.withUnsafeBytes { Data($0) }, "the key was destroyed")
    }

    func testTheLeftoverWipeDestroysTheKeyBeforeTheFile() async throws {
        let dir = try makeDir("leftover-keyfirst")
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        }
        let service = "test.bw.leftover.keyfirst.\(UUID().uuidString)"
        addTeardownBlock { try? SessionStoreKey.destroy(service: service) }
        let original = try SessionStoreKey.loadOrCreate(service: service)
        try BlockHistoryStore(directory: dir, dek: original, keychainService: service)
            .recordPeriod(rawKey: Data(repeating: 5, count: 32), blockedAt: 1, unblockedAt: 2)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        var threw = false
        do {
            try await BlockHistoryStore.LeftoverWipe(directory: dir, keychainService: service).wipe()
        } catch { threw = true }
        XCTAssertTrue(threw, "precondition: the file removal must fail on a read-only dir")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)

        let fresh = try SessionStoreKey.loadOrCreate(service: service)
        XCTAssertNotEqual(fresh.withUnsafeBytes { Data($0) }, original.withUnsafeBytes { Data($0) },
                          "the DEK must be destroyed BEFORE the file removal is attempted")
        XCTAssertFalse(try BlockHistoryStore(directory: dir, dek: fresh, keychainService: service).isReadable,
                       "the surviving file must be unreadable under any new key")
    }

    func testTheEraseAndSweepListsIncludeTheHistory() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(contentsOf: root.appendingPathComponent("Beacon/ContentView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(content.range(of: "additionalSteps: ["))
        let end = try XCTUnwrap(content.range(of: "]", range: start.upperBound..<content.endIndex))
        let steps = content[start.upperBound..<end.lowerBound]
        XCTAssertTrue(steps.contains("blockHistory,"), "EmergencyWipe must erase the block history")
        let sweep = try String(contentsOf: root.appendingPathComponent("Security/Wipe/LeftoverSweep.swift"),
                               encoding: .utf8)
        XCTAssertTrue(sweep.contains("BlockHistoryStore.LeftoverWipe("), "the leftover sweep must erase it")
    }
}

// MARK: - Doubles

/// The router's addressed transport: records every relay publish's recipient.
private final class RecordingRelay: MeshTransport, AddressedTransport, @unchecked Sendable {
    let kind: TransportKind = .internet
    let incoming: AsyncStream<(link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)>
    private let cont: AsyncStream<(link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)>.Continuation
    private let recipients = OSAllocatedUnfairLock(initialState: [Data]())
    var publishedTo: [Data] { recipients.withLock { $0 } }

    init() {
        var c: AsyncStream<(link: UUID, envelope: Envelope, relaySentAtSeconds: Int64?)>.Continuation!
        incoming = AsyncStream { c = $0 }
        cont = c
    }
    func start() async throws {}
    func stop() { cont.finish() }
    func send(_ envelope: Envelope) async throws { throw NostrTransportError.sendRequiresRecipient }
    func relay(_ envelope: Envelope, excludingLinks: Set<UUID>) async {}
    func publish(_ envelope: Envelope, to recipient: Data) async throws {
        recipients.withLock { $0.append(recipient) }
    }
}

private struct NoOpWipe: Wipeable {
    func wipe() async throws {}
}
