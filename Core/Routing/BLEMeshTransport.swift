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

    // MARK: - Queue confinement
    private let cbQueue = DispatchQueue(label: "com.aeronyra.ble.transport")

    // MARK: - Central (scanner) side
    private var central: CBCentralManager?
    private var peers: [UUID: CBPeripheral] = [:]
    private var writeTargets: [UUID: CBCharacteristic] = [:]
    /// Reassembly buffers for inbound notifications (peripheral → us), keyed by
    /// the remote peripheral's id.
    private var notifyReassembly: [UUID: ReassemblyState] = [:]

    // MARK: - Peripheral (advertiser) side
    private var peripheral: CBPeripheralManager?
    private var mailbox: CBMutableCharacteristic?
    private var subscribedCentrals: Set<UUID> = []
    /// Reassembly buffers for inbound writes (central → us), keyed by central id.
    private var writeReassembly: [UUID: ReassemblyState] = [:]
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
            state.declaredLength = prefix.reduce(0) { ($0 << 8) | Int($1) }
            state.buffer.removeFirst(Self.lengthPrefixBytes)
        }

        // 3) payload
        guard state.buffer.count >= state.declaredLength else { return nil }
        let payload = Data(state.buffer.prefix(state.declaredLength))
        let type = state.type!
        state = ReassemblyState()   // reset for the next frame from this source
        return (type, payload)
    }

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

    /// central → peripheral: chunked GATT write-with-response. cbQueue.
    @discardableResult
    private func writeFrameToPeer(_ frame: Data, id: UUID) -> Bool {
        guard let peer = peers[id], let ch = writeTargets[id] else { return false }
        let maxChunk = max(20, peer.maximumWriteValueLength(for: .withResponse))
        var offset = 0
        while offset < frame.count {
            let end = min(offset + maxChunk, frame.count)
            peer.writeValue(frame.subdata(in: offset..<end), for: ch, type: .withResponse)
            offset = end
        }
        return true
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
        var state = notifyReassembly[peripheral.identifier] ?? ReassemblyState()
        let completed = ingest(value, into: &state)
        notifyReassembly[peripheral.identifier] = state
        if let (type, payload) = completed {
            dispatchFrame(type, payload, from: peripheral.identifier)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error {
            log.error("write failed to \(peripheral.identifier): \(error.localizedDescription)")
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
            var state = writeReassembly[r.central.identifier] ?? ReassemblyState()
            let completed = ingest(value, into: &state)
            writeReassembly[r.central.identifier] = state
            if let (type, payload) = completed {
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
