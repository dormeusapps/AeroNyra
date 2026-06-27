//
//  FirstContactCoordinator.swift
//  Security/Session
//
//  Marries the BLE transport to the secure-session store to perform CARRIER-
//  NEUTRAL first contact.
//
//  On a new link both peers exchange prekey bundles. A deterministic tie-break
//  (the higher identity key initiates) picks exactly ONE initiator, so the two
//  sides don't both start a session at once (simultaneous initiation can cross
//  the ratchets). The initiator establishes a session from the peer's bundle
//  and sends the first sealed message; the responder's session forms when it
//  opens that first (prekey) message, which self-identifies the sender.
//
//  CARRIER-NEUTRAL BY DESIGN: although wired to BLE here, a bundle pasted from a
//  QR code or arriving over a future internet transport enters the SAME
//  `onBundle` path. Nothing here assumes proximity, and nothing assumes a peer
//  count — sessions scale to as many peers as you meet.
//
//  STEP 3 PROOF (temporary): on becoming initiator the coordinator auto-sends a
//  "hello". This is a console proof of the encrypted round-trip and is removed
//  when the composer drives the real send path. It persists nothing.
//
//  An `actor` so its mutable link/peer state is race-free; the composition root
//  feeds it the transport's streams.
//

import Foundation

actor FirstContactCoordinator {

    private let store: SignalSessionStore
    private let transport: BLEMeshTransport

    /// Links we've already greeted with our bundle (don't re-send each tick).
    private var greetedLinks: Set<UUID> = []
    /// Peer identity learned per link from their bundle.
    private var linkPeers: [UUID: PublicIdentity] = [:]

    init(store: SignalSessionStore, transport: BLEMeshTransport) {
        self.store = store
        self.transport = transport
    }

    // MARK: Reachability → send our bundle to new links

    func onReachable(_ ids: [UUID]) async {
        let current = Set(ids)
        greetedLinks.formIntersection(current)   // drop links that went away
        for link in current where !greetedLinks.contains(link) {
            greetedLinks.insert(link)
            await sendOurBundle(to: link)
        }
    }

    private func sendOurBundle(to link: UUID) async {
        do {
            let bundle = try store.localPrekeyBundle()
            try await transport.sendBundle(bundle.data, toLink: link)
            print("first-contact: sent our bundle → link \(link)")
        } catch {
            greetedLinks.remove(link)   // allow a retry on the next tick
            print("first-contact: bundle send to \(link) failed: \(error)")
        }
    }

    // MARK: Inbound bundle → maybe initiate

    func onBundle(link: UUID, data: Data) async {
        let bundle = PrekeyBundle(data: data)
        guard let peer = try? store.peerIdentity(from: bundle) else {
            print("first-contact: malformed bundle on link \(link)")
            return
        }
        linkPeers[link] = peer

        // Deterministic initiator: the higher identity key initiates. Both
        // sides compute the same comparison, so exactly one initiates.
        let mine = Array(store.localIdentity.agreementKey)
        let theirs = Array(peer.agreementKey)
        let iInitiate = theirs.lexicographicallyPrecedes(mine)

        if iInitiate {
            await initiate(with: bundle, peer: peer)
        } else {
            print("first-contact: responder role for \(peer.userIDHex.prefix(16))… — awaiting hello")
        }
    }

    private func initiate(with bundle: PrekeyBundle, peer: PublicIdentity) async {
        do {
            let session = try store.establishSession(from: bundle)
            // TEMP step-3 proof — removed when the composer drives send().
            let hello = "hello from \(store.localIdentity.userIDHex.prefix(8))"
            let sealed = try session.seal(Data(hello.utf8))
            try await transport.send(Envelope(ciphertext: sealed))
            print("first-contact: INITIATED → sealed hello sent to \(peer.userIDHex.prefix(16))…")
        } catch {
            print("first-contact: initiate failed: \(error)")
        }
    }

    // MARK: Inbound envelope → open

    func onEnvelope(_ envelope: Envelope) async {
        do {
            let (peer, plaintext) = try store.openInbound(envelope.ciphertext)
            let text = String(data: plaintext, encoding: .utf8) ?? "<\(plaintext.count) bytes>"
            print("first-contact: OPENED from \(peer.userIDHex.prefix(16))…: \"\(text)\"")
        } catch {
            print("first-contact: open failed: \(error)")
        }
    }
}
