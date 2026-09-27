//
//  OrphanSessionPruneTests.swift
//  BeaconTests
//
//  Pins the boot-time orphan-session cleanup: sessions for enrolled AND
//  blocked contacts survive; every other persisted session is deleted from
//  disk; and NOTHING is pruned when either trust list failed to load (an
//  empty stand-in there means "unknown", and pruning against it would delete
//  live sessions).
//

import XCTest
import CryptoKit
@testable import Beacon

final class OrphanSessionPruneTests: XCTestCase {

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan-prune.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Our persistent store with three REAL sessions (three contacts opened a
    /// prekey message to us). Returns the store + the three peers.
    private func storeWithThreeSessions(_ me: IdentityKeypair, _ dir: URL, _ dek: SymmetricKey) throws
        -> (SignalSessionStore, [PublicIdentity]) {
        let store = try SignalSessionStore(appIdentity: me, directory: dir, dek: dek)
        var peers: [PublicIdentity] = []
        for _ in 0..<3 {
            let other = SignalSessionStore()
            let s = try other.establishSession(from: try store.localPrekeyBundle())
            peers.append(try store.openInbound(try s.seal(Data("hi".utf8))).peer)
        }
        return (store, peers)
    }

    func testPruneKeepsEnrolledAndBlockedAndDeletesTheRestFromDisk() throws {
        let me = IdentityKeypair.generate(); let dir = try makeDir(); let dek = SymmetricKey(size: .bits256)
        let (store, peers) = try storeWithThreeSessions(me, dir, dek)
        let enrolled = store.rawPublicKey(of: peers[0])
        let blocked = store.rawPublicKey(of: peers[1])

        var allowlist = ContactAllowlist()
        allowlist.enroll(identity: enrolled, at: 1, verified: true)
        let keep = SignalSessionStore.orphanPruneKeepSet(
            allowlist: allowlist,
            blocked: [BlockedContact(rawKey: blocked, blockedAt: 1, petname: nil, wasVerified: false)])
        let removed = try store.pruneSessions(keepingRawKeys: XCTUnwrap(keep))

        XCTAssertEqual(removed, 1)
        let reloaded = try SignalSessionStore(appIdentity: me, directory: dir, dek: dek)
        XCTAssertTrue(reloaded.hasSession(with: peers[0]), "enrolled contact keeps its session")
        XCTAssertTrue(reloaded.hasSession(with: peers[1]), "blocked contact keeps its session (unblock resumes)")
        XCTAssertFalse(reloaded.hasSession(with: peers[2]), "the orphan's session is gone from disk")
    }

    func testNothingToPruneWritesNothingAndRemovesNothing() throws {
        let me = IdentityKeypair.generate(); let dir = try makeDir(); let dek = SymmetricKey(size: .bits256)
        let (store, peers) = try storeWithThreeSessions(me, dir, dek)
        let all = Set(peers.map { store.rawPublicKey(of: $0) })
        XCTAssertEqual(try store.pruneSessions(keepingRawKeys: all), 0)
        let reloaded = try SignalSessionStore(appIdentity: me, directory: dir, dek: dek)
        for p in peers { XCTAssertTrue(reloaded.hasSession(with: p)) }
    }

    func testKeepSetIsNilWhenEitherTrustListFailedToLoad() {
        XCTAssertNil(SignalSessionStore.orphanPruneKeepSet(allowlist: nil, blocked: []),
                     "allowlist unknown → prune nothing")
        XCTAssertNil(SignalSessionStore.orphanPruneKeepSet(allowlist: ContactAllowlist(), blocked: nil),
                     "blocked list unknown → prune nothing")
        XCTAssertEqual(SignalSessionStore.orphanPruneKeepSet(allowlist: ContactAllowlist(), blocked: []), [])
    }
}
