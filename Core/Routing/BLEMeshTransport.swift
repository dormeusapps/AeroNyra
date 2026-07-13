//
//  BLEMeshTransport.swift
//  Core/Routing
//

import Foundation
import CoreBluetooth
import os

/// Concrete BLE mesh transport conforming to `MeshTransport`.
///
/// BIDIRECTIONAL + FRAME-TAGGED. Each device runs BOTH roles — peripheral
/// (advertises a service + exposes one write/notify characteristic) AND central
/// (scans, connects, writes + subscribes for notify). Data now flows BOTH ways
/// over a single link:
///
///   • central → peripheral : GATT write   (writeValue, with response)
///   • peripheral → central : GATT notify   (updateValue to subscribers)
///
/// So whichever role a phone holds on a given link, it can both send and receive
/// over it — the prerequisite for replies and multi-peer chat.
///
/// FRAME TAG: every reassembled frame starts with one type byte:
///   • 0x01 ENVELOPE — a sealed mesh payload. Relayable. Yielded to `incoming`.
///   • 0x02 BUNDLE   — a carrier-neutral PrekeyBundle (public key material) for
///                     first contact. LINK-LOCAL — never relayed. Yielded to
///                     `bundles` with the source link id.
/// The transport stays dumb about CONTENTS; it only multiplexes two frame
/// kinds (like an Ethertype) and routes each. It never inspects ciphertext.
///
/// WIRE LAYOUT per frame:  [1-byte type][4-byte big-endian length][payload]
/// Fragmentation/reassembly across MTU is below the frame layer.
///
/// PRESENCE: `reachabilityUpdates` emits the union of (peripherals we connected
/// to) + (centrals subscribed to us) so presence is symmetric. These are
/// EPHEMERAL CoreBluetooth ids, NOT cryptographic identities; identity arrives
/// via the first-contact coordinator above this layer. NO peer-count cap — the
/// transport links and tracks as many peers as the radio allows.
///
/// WRITE/NOTIFY MODE: writes use with-response (flow-controlled). Notifies use
/// `updateValue`, which can return false when the TX queue is full; we queue
/// and drain on `peripheralManagerIsReady(toUpdateSubscribers:)` so nothing is
/// silently dropped.
///
/// CONCURRENCY: not an actor. ALL mutable state is confined to `cbQueue`;
/// nothing touches it off that queue, which is what makes `@unchecked Sendable`
/// honest (the protocol allows "actor OR otherwise internally synchronized").
public final class BLEMeshTransport: NSObject, MeshTransport, @unchecked Sendable {

    // MARK: - Protocol: identity
    public let kind: TransportKind = .ble

    // MARK: - Protocol: inbound envelope stream (relayable payloads)
    // Phase 7b.1a: each inbound envelope is tagged with the SOURCE LINK it
    // arrived on, so the router can apply split-horizon — never relay a message
    // back to the peer it came from. Mirrors the `bundles` stream's shape.
    public let incoming: AsyncStream<(link: UUID, envelope: Envelope)>
    private let inbound: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation

    // MARK: - First-contact: inbound bundle stream (link-local key material)
    public let bundles: AsyncStream<(link: UUID, data: Data)>
    private let bundlesCont: AsyncStream<(link: UUID, data: Data)>.Continuation

    // MARK: - Closed-contact: inbound reconnect stream (link-local auth handshake)
    // The 0x03 reconnect frame (RECONNECT_AUTH_WIRING_5d.md §2.1): both the
    // Phase-1 beacon set and the Phase-2 sealed it's-me ride here, distinguished
    // by a 1-byte inner discriminator handled ABOVE the transport (the coordinator).
    // Link-local, point-to-point, NEVER relayed and NEVER handed to MessageRouter.
    public let reconnects: AsyncStream<(link: UUID, data: Data)>
    private let reconnectsCont: AsyncStream<(link: UUID, data: Data)>.Continuation

    // MARK: - Presence: linked peers (ephemeral BLE ids, NOT crypto identities)
    public let reachabilityUpdates: AsyncStream<[UUID]>
    private let reachabilityCont: AsyncStream<[UUID]>.Continuation

    // MARK: - Frame tags
    private enum FrameType: UInt8 {
        case envelope = 0x01   // relayable sealed payload
        case bundle   = 0x02   // link-local prekey bundle (first contact)
        case reconnect = 0x03  // link-local reconnect handshake (closed-contact auth)
    }

    // MARK: - Protocol constants (permanent, like a port number — NOT placeholder)
    static let serviceUUID = CBUUID(string: "5218EF92-305F-41B0-B29E-D0215FF59B8D")
    static let characteristicUUID = CBUUID(string: "2496E79A-7D3F-4AB1-B6AE-DE940F1597D1")

    /// Bytes of length-prefix framing after the 1-byte type tag.
    private static let lengthPrefixBytes = 4   // UInt32 big-endian payload length

    /// Upper bound on a frame's declared payload length. The largest legitimate
    /// frame is a sealed envelope whose padded plaintext fills the top
    /// PayloadBucket tier (16384 — see `PayloadBucket.sizes`) plus seal +
    /// envelope-header overhead, all well under 20 KB; bundles and reconnect
    /// sets are far smaller. 64 KiB leaves generous headroom while stopping a
    /// hostile 4-byte prefix (up to ~4.29 GB) from growing the PRE-AUTH
    /// reassembly buffer unbounded — frames are ingested from any link in radio
    /// range, before any identity gate. An oversized declaration drops the
    /// buffer to resync, exactly like an unknown frame type.
    private static let maxDeclaredFrameLength = 65_536

    // MARK: - Queue confinement
    private let cbQueue = DispatchQueue(label: "com.aeronyra.ble.transport")

    // MARK: - Central (scanner) side
    private var central: CBCentralManager?
    private var peers: [UUID: CBPeripheral] = [:]
    private var writeTargets: [UUID: CBCharacteristic] = [:]
    /// Reassembly buffers for inbound notifications (peripheral → us), keyed by
    /// link id THEN characteristic uuid — so two characteristics on one link
    /// never share a byte-buffer (interleaving corruption). The per-link cleanup
    /// (`notifyReassembly[id] = nil`) still drops the whole inner map. Private;
    /// the reassembly desk tests reach it via the `#if DEBUG` hooks below.
    private var notifyReassembly: [UUID: [CBUUID: ReassemblyState]] = [:]
    /// Consecutive FAILED FRAMES per peripheral, keyed by its id (ISSUE-11).
    /// A media transfer is thousands of chunked writes; a single transient ATT
    /// error mid-burst must NOT tear the link down (that aborts the transfer and
    /// leaves the receiver's reassembler stuck on a half-delivered payload). But
    /// a peer that powered its radio OFF fails EVERY write while CoreBluetooth
    /// stays silent (no didDisconnectPeripheral) — a zombie link. This counter
    /// tells the two apart: it climbs on consecutive FRAME failures and is reset
    /// to 0 by any successful write. Counting per frame (not per chunk) matters:
    /// with the old burst-enqueue, one doomed frame's queued chunks each failed
    /// separately and burned the whole threshold in a single send. Crossing
    /// `writeErrorTeardownThreshold` means the link is genuinely dead even if
    /// the error code wasn't conclusive.
    private var writeErrorCounts: [UUID: Int] = [:]
    /// Consecutive failed frames before we conclude the link is dead and tear
    /// it down. Low enough to surface a real zombie link within a few frames
    /// (→ noReachablePeers → Nostr fallback); high enough that a single
    /// backpressure glitch in a media burst is ridden through, as HEAD did.
    private static let writeErrorTeardownThreshold = 3

    // MARK: - Central-side write engine (per-peer FIFO, one chunk in flight)
    /// Outbound frames per peer, each frame as its remaining chunk slices in
    /// order. STRICT FIFO with flow control (ISSUE-11): only the head chunk of
    /// the head frame is ever in flight; the next leaves when `didWriteValueFor`
    /// acks it. This attributes an ATT failure to exactly ONE frame — the old
    /// tight enqueue loop put every chunk in flight at once, so one doomed
    /// frame produced N failure callbacks and multi-counted against the
    /// teardown threshold.
    private var writeQueues: [UUID: [[Data]]] = [:]
    /// Peers whose head chunk is awaiting its `didWriteValueFor` response.
    private var writeInFlight: Set<UUID> = []
    /// Resend budget left for the CURRENT head chunk before its whole frame is
    /// declared failed. A frame either completes or is dropped whole — a
    /// partially delivered frame would corrupt the peer's sequential
    /// reassembly ([type][len][payload]).
    private var chunkRetriesLeft: [UUID: Int] = [:]
    /// Resend attempts per chunk on a transient error before the frame fails.
    private static let chunkRetryLimit = 2

    // MARK: - Reconnect backoff after a dead-link teardown (central side)
    /// Consecutive write-failure teardowns per peripheral id (ISSUE-11).
    /// Without a holdoff, teardown → rescan → rediscover → re-greet → fail
    /// spins at radio speed against a peer whose writes keep failing. Same
    /// idiom as NostrTransport's relay backoff: exponential from
    /// `baseReconnectDelay`, capped at `maxReconnectDelay`, reset by any
    /// successful write (the same liveness signal that resets
    /// `writeErrorCounts`). Applies ONLY to write-failure teardowns — a normal
    /// didDisconnectPeripheral (peer walked away) still rescans immediately,
    /// so ISSUE-3b departure handling is untouched.
    private var reconnectAttempts: [UUID: Int] = [:]
    /// Peripherals we must not reconnect to before this deadline.
    private var reconnectHoldoff: [UUID: DispatchTime] = [:]
    private static let baseReconnectDelay: Double = 1     // seconds
    private static let maxReconnectDelay: Double = 30     // capped backoff ceiling

    // MARK: - Peripheral (advertiser) side
    private var peripheral: CBPeripheralManager?
    private var mailbox: CBMutableCharacteristic?
    private var subscribedCentrals: Set<UUID> = []
    /// Reassembly buffers for inbound writes (central → us), keyed by central id
    /// THEN characteristic uuid (see `notifyReassembly`). Private; DEBUG hooks.
    private var writeReassembly: [UUID: [CBUUID: ReassemblyState]] = [:]
    /// Notifications waiting because `updateValue` returned false (TX queue full).
    private var pendingNotifications: [Data] = []

    private var started = false
    private let log = Logger(subsystem: "com.aeronyra.app", category: "BLE")

    /// Per-source reassembly: we collect bytes until we have [type][len][payload].
    private struct ReassemblyState {
        var buffer = Data()
        var type: FrameType?
        var declaredLength: Int = -1
    }

    // MARK: - Init
    public override init() {
        var inb: AsyncStream<(link: UUID, envelope: Envelope)>.Continuation!
        self.incoming = AsyncStream<(link: UUID, envelope: Envelope)> { inb = $0 }
        self.inbound = inb

        var bnd: AsyncStream<(link: UUID, data: Data)>.Continuation!
        self.bundles = AsyncStream<(link: UUID, data: Data)> { bnd = $0 }
        self.bundlesCont = bnd

        var rcn: AsyncStream<(link: UUID, data: Data)>.Continuation!
        self.reconnects = AsyncStream<(link: UUID, data: Data)> { rcn = $0 }
        self.reconnectsCont = rcn

        var rch: AsyncStream<[UUID]>.Continuation!
        self.reachabilityUpdates = AsyncStream<[UUID]> { rch = $0 }
        self.reachabilityCont = rch

        super.init()
    }

    // MARK: - Lifecycle
    public func start() async throws {
        cbQueue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.central = CBCentralManager(delegate: self, queue: self.cbQueue)
            self.peripheral = CBPeripheralManager(delegate: self, queue: self.cbQueue)
            self.log.info("start(): managers created, awaiting powerOn")
        }
    }

    public func stop() {
        cbQueue.async { [weak self] in
            guard let self else { return }
            self.central?.stopScan()
            if self.peripheral?.isAdvertising == true { self.peripheral?.stopAdvertising() }
            for p in self.peers.values { self.central?.cancelPeripheralConnection(p) }
            self.peers.removeAll()
            self.writeTargets.removeAll()
            self.subscribedCentrals.removeAll()
            self.notifyReassembly.removeAll()
            self.writeReassembly.removeAll()
            self.pendingNotifications.removeAll()
            self.writeErrorCounts.removeAll()
            self.writeQueues.removeAll()
            self.writeInFlight.removeAll()
            self.chunkRetriesLeft.removeAll()
            self.reconnectAttempts.removeAll()
            self.reconnectHoldoff.removeAll()
            self.started = false
            self.emitReachable()
            self.log.info("stop(): radios torn down")
        }
    }

    private func emitReachable() {
        let ids = Set(writeTargets.keys).union(subscribedCentrals)
        reachabilityCont.yield(Array(ids))
    }

    // MARK: - Framing

    /// Build a wire frame: [type][4-byte big-endian length][payload].
    private static func frame(_ type: FrameType, _ payload: Data) -> Data {
        var d = Data()
        d.append(type.rawValue)
        var len = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &len) { d.append(contentsOf: $0) }
        d.append(payload)
        return d
    }

    /// Feed bytes into a reassembly state; return any completed (type, payload).
    /// Handles the 1-byte type + 4-byte length header, then the payload.
    private func ingest(_ chunk: Data, into state: inout ReassemblyState) -> (FrameType, Data)? {
        state.buffer.append(chunk)

        // 1) type byte
        if state.type == nil {
            guard let first = state.buffer.first else { return nil }
            guard let t = FrameType(rawValue: first) else {
                // Unknown frame type — drop the whole buffer to resync.
                log.error("unknown frame type \(first) — dropping buffer")
                state = ReassemblyState()
                return nil
            }
            state.type = t
            state.buffer.removeFirst(1)
        }

        // 2) length prefix
        if state.declaredLength < 0 {
            guard state.buffer.count >= Self.lengthPrefixBytes else { return nil }
            let prefix = state.buffer.prefix(Self.lengthPrefixBytes)
            let declared = prefix.reduce(0) { ($0 << 8) | Int($1) }
            guard declared <= Self.maxDeclaredFrameLength else {
                // Hostile or corrupt length — drop the whole buffer to resync
                // rather than accumulate toward it (unbounded pre-auth memory).
                log.error("frame declares \(declared) bytes (max \(Self.maxDeclaredFrameLength)) — dropping buffer")
                state = ReassemblyState()
                return nil
            }
            state.declaredLength = declared
            state.buffer.removeFirst(Self.lengthPrefixBytes)
        }

        // 3) payload
        guard state.buffer.count >= state.declaredLength else { return nil }
        let payload = Data(state.buffer.prefix(state.declaredLength))
        let type = state.type!
        state = ReassemblyState()   // reset for the next frame from this source
        return (type, payload)
    }

    /// Per-(link, characteristic) reassembly for inbound NOTIFICATIONS. Keying by
    /// the characteristic keeps two characteristics on one link from sharing a
    /// byte-buffer. Fetch inner map → fetch state → ingest → write both back.
    /// Private; the `#if DEBUG` hooks below let the desk tests drive it.
    private func ingestNotify(link: UUID, char: CBUUID, _ value: Data) -> (FrameType, Data)? {
        var linkMap = notifyReassembly[link] ?? [:]
        var state = linkMap[char] ?? ReassemblyState()
        let completed = ingest(value, into: &state)
        linkMap[char] = state
        notifyReassembly[link] = linkMap
        return completed
    }

    /// Per-(link, characteristic) reassembly for inbound WRITES. Fetched fresh and
    /// written back each request so sequential writes for the same central+char
    /// compose. See `ingestNotify`.
    private func ingestWrite(link: UUID, char: CBUUID, _ value: Data) -> (FrameType, Data)? {
        var linkMap = writeReassembly[link] ?? [:]
        var state = linkMap[char] ?? ReassemblyState()
        let completed = ingest(value, into: &state)
        linkMap[char] = state
        writeReassembly[link] = linkMap
        return completed
    }

    #if DEBUG
    // Test-only accessors — DEBUG builds ONLY, never compiled into Release, so
    // the shipping reassembly surface stays private. They give the desk tests
    // @testable reach into `ingestNotify`/`ingestWrite` and the inner map, and
    // return the FrameType as its raw byte so `FrameType` itself stays private.
    func _testIngestNotify(link: UUID, char: CBUUID, _ v: Data) -> (UInt8, Data)? {
        ingestNotify(link: link, char: char, v).map { ($0.0.rawValue, $0.1) }
    }
    func _testIngestWrite(link: UUID, char: CBUUID, _ v: Data) -> (UInt8, Data)? {
        ingestWrite(link: link, char: char, v).map { ($0.0.rawValue, $0.1) }
    }
    /// Live inner-char entries for a link's NOTIFY reassembly (0 if none).
    func _testNotifyCharCount(_ link: UUID) -> Int { notifyReassembly[link]?.count ?? 0 }
    /// Runs the exact per-link disconnect cleanup the delegate uses.
    func _testDropNotifyLink(_ link: UUID) { notifyReassembly[link] = nil }
    #endif

    // MARK: - Transmit: Envelope (relayable) — broadcast to all links
    public func send(_ envelope: Envelope) async throws {
        let frame = Self.frame(.envelope, envelope.wireData())
        try await broadcast(frame, label: "envelope id=\(envelope.id)")
    }

    // MARK: - Transmit: Envelope RELAY (split-horizon) — Phase 7b.1a
    /// Forward an inbound envelope onward, EXCLUDING every link that belongs to
    /// the source peer, so a relay never echoes a message back to where it came
    /// from. `excluded` is identity-scoped (computed above us, in Security): a
    /// peer is reachable over up to two ephemeral ids — its peripheral id and
    /// its central id — and BOTH must be excluded, or the message storms back
    /// over the other GATT role. Best-effort + non-throwing: if there is no one
    /// left to forward to (the 2-node case), this does nothing, which is exactly
    /// right — that is what kills the relay storm.
    public func relay(_ envelope: Envelope, excludingLinks excluded: Set<UUID>) async {
        let frame = Self.frame(.envelope, envelope.wireData())
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            cbQueue.async { [weak self] in
                guard let self, self.started else { cont.resume(); return }

                // central → peripheral writes: forward to every write target
                // that is NOT one of the source peer's links.
                var writeCount = 0
                for (id, _) in self.writeTargets where !excluded.contains(id) {
                    if self.writeFrameToPeer(frame, id: id) { writeCount += 1 }
                }

                // peripheral → central notify: a characteristic update is
                // broadcast-to-all, so we cannot target one subscriber without
                // per-central queues. If EVERY current subscriber is excluded
                // (the 2-node case), skip notify entirely — this is what stops
                // the storm. Otherwise notify all; an excluded subscriber simply
                // dedups its own echo upstream, which is loop-safe.
                let remaining = self.subscribedCentrals.subtracting(excluded)
                let notified = !remaining.isEmpty
                if notified { self.notifySubscribers(frame) }

                self.log.info("RELAY \(envelope.id) → \(writeCount) write + \(notified ? self.subscribedCentrals.count : 0) notify (excluded \(excluded.count))")
                cont.resume()
            }
        }
    }

    // MARK: - Transmit: Bundle (first contact) — to ONE specific link
    /// Send a carrier-neutral prekey bundle to a single linked peer. First
    /// contact is point-to-point, not a broadcast.
    public func sendBundle(_ data: Data, toLink id: UUID) async throws {
        let frame = Self.frame(.bundle, data)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            cbQueue.async { [weak self] in
                guard let self else { cont.resume(); return }
                guard self.started else { cont.resume(throwing: TransportError.notStarted); return }
                if self.sendFrameToLink(frame, id: id) {
                    self.log.info("TX bundle \(data.count) bytes → link \(id)")
                    cont.resume()
                } else {
                    cont.resume(throwing: TransportError.noReachablePeers)
                }
            }
        }
    }

    // MARK: - Transmit: Reconnect (closed-contact auth) — to ONE specific link
    /// Send a link-local reconnect frame (0x03) to a single linked peer. Carries
    /// the opaque reconnect bytes already assembled by the coordinator (the
    /// 1-byte inner discriminator + payload — knob A lives above the transport).
    /// Point-to-point like `sendBundle`: NEVER broadcast, NEVER relayed, NEVER
    /// handed to MessageRouter (RECONNECT_AUTH_WIRING_5d.md §2.1).
    public func sendReconnect(_ data: Data, toLink id: UUID) async throws {
        let frame = Self.frame(.reconnect, data)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            cbQueue.async { [weak self] in
                guard let self else { cont.resume(); return }
                guard self.started else { cont.resume(throwing: TransportError.notStarted); return }
                if self.sendFrameToLink(frame, id: id) {
                    self.log.info("TX reconnect \(data.count) bytes → link \(id)")
                    cont.resume()
                } else {
                    cont.resume(throwing: TransportError.noReachablePeers)
                }
            }
        }
    }

    /// Broadcast a frame to every linked peer, using whichever direction that
    /// link supports (write if we're its central; notify if it's our subscriber).
    private func broadcast(_ frame: Data, label: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            cbQueue.async { [weak self] in
                guard let self else { cont.resume(); return }
                guard self.started else { cont.resume(throwing: TransportError.notStarted); return }

                let haveWriteTargets = !self.writeTargets.isEmpty
                let haveSubscribers = !self.subscribedCentrals.isEmpty
                guard haveWriteTargets || haveSubscribers else {
                    cont.resume(throwing: TransportError.noReachablePeers); return
                }

                // central → peripheral writes
                for (id, _) in self.writeTargets {
                    _ = self.writeFrameToPeer(frame, id: id)
                }
                // peripheral → central notifications
                if haveSubscribers {
                    self.notifySubscribers(frame)
                }
                self.log.info("TX \(label) (\(frame.count) bytes) to \(self.writeTargets.count) write + \(self.subscribedCentrals.count) notify")
                cont.resume()
            }
        }
    }

    /// Send a frame to one link by whichever direction is available. cbQueue.
    private func sendFrameToLink(_ frame: Data, id: UUID) -> Bool {
        if writeTargets[id] != nil {
            return writeFrameToPeer(frame, id: id)
        }
        if subscribedCentrals.contains(id) {
            notifySubscribers(frame)   // notify is broadcast to subscribers
            return true
        }
        return false
    }

    /// central → peripheral: enqueue a frame for chunked, flow-controlled
    /// GATT write-with-response delivery (ISSUE-11). Chunks leave strictly one
    /// at a time — the next departs only after `didWriteValueFor` acks the
    /// previous — so a failure is attributed to exactly ONE frame (see
    /// `writeErrorCounts`). Returning true means ENQUEUED, not delivered;
    /// send() has always been fire-and-forget at this layer. cbQueue.
    @discardableResult
    private func writeFrameToPeer(_ frame: Data, id: UUID) -> Bool {
        guard let peer = peers[id], writeTargets[id] != nil else { return false }
        let maxChunk = max(20, peer.maximumWriteValueLength(for: .withResponse))
        var chunks: [Data] = []
        var offset = 0
        while offset < frame.count {
            let end = min(offset + maxChunk, frame.count)
            chunks.append(frame.subdata(in: offset..<end))
            offset = end
        }
        writeQueues[id, default: []].append(chunks)
        pumpWriteQueue(id)
        return true
    }

    /// Send the head chunk of the head frame unless one is already in flight
    /// (also used to RESEND the head chunk after a transient failure, which
    /// deliberately does not pop it). cbQueue.
    private func pumpWriteQueue(_ id: UUID) {
        guard !writeInFlight.contains(id),
              let peer = peers[id], let ch = writeTargets[id],
              let chunk = writeQueues[id]?.first?.first else { return }
        writeInFlight.insert(id)
        peer.writeValue(chunk, for: ch, type: .withResponse)
    }

    /// Pop the acked head chunk (and its frame, once empty), then send the
    /// next. cbQueue.
    private func advanceWriteQueue(_ id: UUID) {
        if var frames = writeQueues[id], !frames.isEmpty {
            frames[0].removeFirst()
            if frames[0].isEmpty { frames.removeFirst() }
            writeQueues[id] = frames.isEmpty ? nil : frames
        }
        pumpWriteQueue(id)
    }

    /// Drop the head frame WHOLE after its chunk retries are exhausted — a
    /// partial frame would corrupt the peer's sequential reassembly — and move
    /// on to the next queued frame. cbQueue.
    private func failHeadFrame(_ id: UUID) {
        if var frames = writeQueues[id], !frames.isEmpty {
            frames.removeFirst()
            writeQueues[id] = frames.isEmpty ? nil : frames
        }
        pumpWriteQueue(id)
    }

    /// peripheral → central: chunked notify with backpressure. cbQueue.
    ///
    /// STRICT FIFO under backpressure: notify slices for a given link must reach
    /// the peer in the exact order produced, because the peer reassembles each
    /// frame sequentially ([type][len][payload]). A single sealed message is one
    /// frame, but a media transfer is hundreds of frames sent back-to-back —
    /// enough to keep the TX queue full. If a later frame were allowed to call
    /// `updateValue` while an earlier frame's tail still sat in
    /// `pendingNotifications`, the two would interleave on the wire and corrupt
    /// the peer's reassembly. So: once ANY backlog exists, every new slice goes
    /// behind it, and `peripheralManagerIsReady` drains strictly from the front.
    private func notifySubscribers(_ frame: Data) {
        guard let peripheral, let mailbox else { return }
        // Conservative chunk for notify; updateValue caps near the ATT MTU.
        let maxChunk = 180

        // Slice the whole frame up front, in order.
        var slices: [Data] = []
        var offset = 0
        while offset < frame.count {
            let end = min(offset + maxChunk, frame.count)
            slices.append(frame.subdata(in: offset..<end))
            offset = end
        }

        // If a backlog already exists, this frame MUST queue behind it — never
        // send ahead of pending bytes, or the peer's sequential reassembly
        // corrupts. The ready-callback drains the queue in order.
        if !pendingNotifications.isEmpty {
            pendingNotifications.append(contentsOf: slices)
            log.info("notify queued behind backlog — \(self.pendingNotifications.count) chunks pending")
            return
        }

        // No backlog: send directly. On the first refusal, stash this slice and
        // every slice after it (still in order) for the drain.
        for (i, slice) in slices.enumerated() {
            let ok = peripheral.updateValue(slice, for: mailbox, onSubscribedCentrals: nil)
            if !ok {
                pendingNotifications.append(contentsOf: slices[i...])
                log.info("notify queue full — \(self.pendingNotifications.count) chunks pending")
                return
            }
        }
    }
}

// MARK: - Central role: scan, connect, discover, subscribe
extension BLEMeshTransport: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            // BLE off / resetting / unauthorized: CoreBluetooth invalidates every
            // connection WITHOUT delivering per-peripheral didDisconnect callbacks,
            // so writeTargets would otherwise keep its entries and presence would
            // stick — a zombie link that only clears on relaunch. Tear down the
            // central-side link state and re-emit so reachability drops NOW. The
            // .poweredOn branch below re-scans and rebuilds it when the radio returns.
            log.error("central state not poweredOn: \(central.state.rawValue) → clearing central-side presence")
            peers.removeAll()
            writeTargets.removeAll()
            notifyReassembly.removeAll()
            writeErrorCounts.removeAll()
            writeQueues.removeAll()
            writeInFlight.removeAll()
            chunkRetriesLeft.removeAll()
            reconnectAttempts.removeAll()
            reconnectHoldoff.removeAll()
            emitReachable()
            return
        }
        log.info("central poweredOn → scanning for AeroNyra service")
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        guard peers[peripheral.identifier] == nil else { return }
        // ISSUE-11: in post-teardown holdoff? Skip — the delayed rescan
        // scheduled at teardown restarts the scan session once the holdoff
        // ends (duplicates are disabled, so a running session won't re-report
        // this peer; the session restart is what re-reports it).
        if let until = reconnectHoldoff[peripheral.identifier], DispatchTime.now() < until {
            log.info("discovered \(peripheral.identifier) but in reconnect holdoff → skipping")
            return
        }
        reconnectHoldoff[peripheral.identifier] = nil
        log.info("discovered peer \(peripheral.identifier) rssi \(RSSI) → connecting")
        peers[peripheral.identifier] = peripheral
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log.info("connected to \(peripheral.identifier) → discovering service")
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        log.error("failed to connect \(peripheral.identifier): \(error?.localizedDescription ?? "nil")")
        peers[peripheral.identifier] = nil
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        log.info("disconnected \(peripheral.identifier) → rescanning")
        peers[peripheral.identifier] = nil
        writeTargets[peripheral.identifier] = nil
        notifyReassembly[peripheral.identifier] = nil
        writeErrorCounts[peripheral.identifier] = nil
        writeQueues[peripheral.identifier] = nil
        writeInFlight.remove(peripheral.identifier)
        chunkRetriesLeft[peripheral.identifier] = nil
        emitReachable()
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }
}

// MARK: - Central role: GATT discovery, subscribe, receive notifications
extension BLEMeshTransport: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == Self.serviceUUID {
            peripheral.discoverCharacteristics([Self.characteristicUUID], for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        guard let chars = service.characteristics else { return }
        for ch in chars where ch.uuid == Self.characteristicUUID {
            writeTargets[peripheral.identifier] = ch
            emitReachable()
            peripheral.setNotifyValue(true, for: ch)
            log.info("LINK READY → mailbox on \(peripheral.identifier). Ready + subscribing.")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error {
            log.error("notify-state error on \(peripheral.identifier): \(error.localizedDescription)")
        } else {
            log.info("subscribed for notify on \(peripheral.identifier)")
        }
    }

    /// Inbound NOTIFICATION (peripheral → us). Reassemble + demux by frame type.
    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error {
            log.error("notify value error on \(peripheral.identifier): \(error.localizedDescription)")
            return
        }
        guard let value = characteristic.value else { return }
        if let (type, payload) = ingestNotify(link: peripheral.identifier,
                                              char: characteristic.uuid, value) {
            dispatchFrame(type, payload, from: peripheral.identifier)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        let id = peripheral.identifier
        writeInFlight.remove(id)

        // SUCCESS: the link is demonstrably alive. Clear the failed-frame
        // streak and the chunk retry budget, then advance the FIFO. (HEAD had
        // NO success branch — the if-let-error had no else — so the counter
        // needs this to be a true "consecutive" measure.)
        guard let error else {
            if writeErrorCounts[id] != nil { writeErrorCounts[id] = 0 }
            chunkRetriesLeft[id] = nil
            reconnectAttempts[id] = nil   // proven alive → backoff starts over
            advanceWriteQueue(id)
            return
        }

        // FAILURE. A write-with-response error is either a genuinely dead link
        // (peer turned Bluetooth OFF — CoreBluetooth invalidates the connection
        // WITHOUT delivering didDisconnectPeripheral, the same gap the power-off
        // handlers guard against, so the link goes ZOMBIE and the router never
        // gets noReachablePeers → never falls back to the relay) OR a transient
        // ATT/backpressure hiccup mid-burst. We DISCRIMINATE by error domain
        // and code (ISSUE-11):
        //
        //   • conclusive link-dead CBError code → tear down now.
        //   • CBATTError — an ATT-level response from the peer's stack. The
        //     old `error as? CBError` cast NEVER matched these (different
        //     domain), routing every ATT rejection down the transient path: a
        //     dead link failing each write with "Unknown ATT error" was kept
        //     alive indefinitely — the ISSUE-11 loop (HW log: confirmed links
        //     failing writes 30s post-arm, never tearing down). Only genuine
        //     backpressure statuses are transient; every other ATT status —
        //     including codes outside the standard table, which localize as
        //     "Unknown ATT error" — is CONCLUSIVE → tear down now.
        //   • otherwise (transient) → resend the chunk up to chunkRetryLimit,
        //     then fail the FRAME (one strike); the frame streak crossing
        //     writeErrorTeardownThreshold is the backstop for the silent
        //     power-off, whose code isn't guaranteed to be conclusive.
        let linkDead: Bool
        if let cb = error as? CBError {
            switch cb.code {
            case .peripheralDisconnected, .connectionTimeout,
                 .notConnected, .connectionFailed:
                linkDead = true
            default:
                linkDead = false
            }
        } else if let att = error as? CBATTError {
            switch att.code {
            case .insufficientResources, .prepareQueueFull:
                linkDead = false   // TX backpressure — the retry rides it out
            default:
                linkDead = true    // fatal or unknown ATT status — conclusive
            }
        } else {
            linkDead = false
        }

        if !linkDead {
            // Transient: burn a resend on the CURRENT head chunk first (it was
            // not popped, so the pump re-sends the same bytes).
            let retries = chunkRetriesLeft[id] ?? Self.chunkRetryLimit
            if retries > 0 {
                chunkRetriesLeft[id] = retries - 1
                log.error("write chunk failed to \(id): \(error.localizedDescription) → retrying (\(retries) left)")
                pumpWriteQueue(id)
                return
            }
            // Retries exhausted → the FRAME fails and counts ONE strike.
            chunkRetriesLeft[id] = nil
            let count = (writeErrorCounts[id] ?? 0) + 1
            writeErrorCounts[id] = count
            guard count >= Self.writeErrorTeardownThreshold else {
                // Below threshold: keep the link — drop this frame whole and
                // move on, so the burst survives the hiccup.
                log.error("write frame failed to \(id): \(error.localizedDescription) (transient \(count)/\(Self.writeErrorTeardownThreshold)) → keeping link")
                failHeadFrame(id)
                return
            }
        }

        // Genuinely dead: conclusive code, or the frame-failure streak crossed
        // the threshold. Tear the link down (mirroring didDisconnectPeripheral)
        // so reachability drops immediately and the next send routes over Nostr;
        // cancel + rescan so we rediscover the peer if its radio returns.
        let reason = linkDead ? "link-dead code" : "\(writeErrorCounts[id] ?? 0) consecutive frame failures"
        log.error("write failed to \(id): \(error.localizedDescription) (\(reason)) → dropping dead link")
        peers[id] = nil
        writeTargets[id] = nil
        notifyReassembly[id] = nil
        writeErrorCounts[id] = nil
        writeQueues[id] = nil
        chunkRetriesLeft[id] = nil
        central?.cancelPeripheralConnection(peripheral)
        emitReachable()

        // ISSUE-11: back off before chasing this peer again. An immediate
        // rescan re-discovers, re-connects, and re-greets the same dead link
        // within ~a second — the infinite write-fail loop. Exponential
        // per-peer holdoff (NostrTransport idiom); the scan restart is
        // deferred to the holdoff deadline because duplicate reports are
        // disabled — restarting the session is what makes CoreBluetooth
        // re-report the peer. NOTE: the cancel above fires
        // didDisconnectPeripheral, which must not (and does not) clear these
        // two maps. Reachability still dropped ABOVE, immediately — the
        // holdoff delays re-admission only, so ISSUE-3b's departure-triggered
        // Nostr re-drive fires on schedule.
        let attempt = (reconnectAttempts[id] ?? 0) + 1
        reconnectAttempts[id] = attempt
        let delay = min(Self.maxReconnectDelay,
                        Self.baseReconnectDelay * pow(2, Double(attempt - 1)))
        reconnectHoldoff[id] = .now() + delay
        log.info("reconnect holdoff for \(id): \(delay)s (teardown #\(attempt))")
        cbQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.started, self.central?.state == .poweredOn else { return }
            self.central?.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        }
    }
}

// MARK: - Peripheral role: advertise, subscribers, receive writes, drain notify
extension BLEMeshTransport: CBPeripheralManagerDelegate {

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            // Same failure mode as the central side: no per-central didUnsubscribe
            // fires on a power-off, so subscribedCentrals would stick and presence
            // would zombie. Clear the peripheral-side link state (plus the now-
            // invalid mailbox and any queued notify bytes for links that are gone)
            // and re-emit. The .poweredOn branch below re-adds the service and
            // re-advertises, repopulating subscribers when the radio returns.
            log.error("peripheral state not poweredOn: \(peripheral.state.rawValue) → clearing peripheral-side presence")
            subscribedCentrals.removeAll()
            writeReassembly.removeAll()
            pendingNotifications.removeAll()
            mailbox = nil
            emitReachable()
            return
        }
        let mailbox = CBMutableCharacteristic(
            type: Self.characteristicUUID,
            properties: [.write, .writeWithoutResponse, .notify],
            value: nil,
            permissions: [.writeable]
        )
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [mailbox]
        self.mailbox = mailbox
        peripheral.add(service)
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: "AeroNyra"
        ])
        log.info("peripheral poweredOn → service added, advertising")
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager,
                                  central: CBCentral,
                                  didSubscribeTo characteristic: CBCharacteristic) {
        subscribedCentrals.insert(central.identifier)
        emitReachable()
        log.info("central \(central.identifier) subscribed → peripheral-side presence")
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager,
                                  central: CBCentral,
                                  didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.remove(central.identifier)
        writeReassembly[central.identifier] = nil
        emitReachable()
        log.info("central \(central.identifier) unsubscribed → presence removed")
    }

    /// Inbound WRITE (central → us). Reassemble + demux by frame type.
    public func peripheralManager(_ peripheral: CBPeripheralManager,
                                  didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            guard let value = r.value else { continue }
            if let (type, payload) = ingestWrite(link: r.central.identifier,
                                                 char: r.characteristic.uuid, value) {
                dispatchFrame(type, payload, from: r.central.identifier)
            }
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    /// TX queue drained — flush any notifications we stashed under backpressure.
    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard let mailbox else { return }
        while !pendingNotifications.isEmpty {
            let slice = pendingNotifications[0]
            let ok = peripheral.updateValue(slice, for: mailbox, onSubscribedCentrals: nil)
            if ok {
                pendingNotifications.removeFirst()
            } else {
                return   // still full; wait for the next ready callback
            }
        }
    }
}

// MARK: - Frame dispatch (shared by both inbound directions)
extension BLEMeshTransport {

    /// Route a completed frame by type. Envelopes → router; bundles → first
    /// contact. cbQueue.
    private func dispatchFrame(_ type: FrameType, _ payload: Data, from link: UUID) {
        switch type {
        case .envelope:
            guard let envelope = Envelope(wire: payload) else {
                log.error("RX envelope frame (\(payload.count) bytes) failed to parse")
                return
            }
            log.info("RX envelope id=\(envelope.id) bytes=\(envelope.ciphertext.count) from link \(link) → yielding")
            inbound.yield((link: link, envelope: envelope))
        case .bundle:
            log.info("RX bundle \(payload.count) bytes from link \(link) → yielding")
            bundlesCont.yield((link: link, data: payload))
        case .reconnect:
            log.info("RX reconnect \(payload.count) bytes from link \(link) → yielding")
            reconnectsCont.yield((link: link, data: payload))
        }
    }
}
