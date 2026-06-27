//
//  BLEMeshTransport.swift
//  Core/Routing
//

import Foundation
import CoreBluetooth
import os

/// Concrete BLE mesh transport conforming to `MeshTransport`.
///
/// STAGE 2 + SYMMETRIC PRESENCE: real transmit + reassembly, plus a
/// `reachabilityUpdates` stream that publishes the set of currently-linked
/// peers so the UI can show live radar/presence — from BOTH roles:
///
///   • CENTRAL side: a peripheral we connected to and found the mailbox on.
///   • PERIPHERAL side: a central that subscribed to our notify characteristic.
///
/// Tracking both is what makes presence symmetric: the phone that DIALED OUT and
/// the phone that was DIALED INTO both register the link off the single
/// connection that forms, instead of depending on both phones independently
/// connecting outward (which is flaky on iOS).
///
/// NOTE: these are EPHEMERAL CoreBluetooth ids, NOT cryptographic identities,
/// and a phone has a different id in each role. So if BOTH phones' centrals
/// fully connect, one physical peer can momentarily count twice. The binary
/// "someone is here" is always correct; exact de-duplication arrives with the
/// identity exchange (above this layer).
///
/// The notify characteristic added here also opens the PERIPHERAL → CENTRAL
/// data direction (via `updateValue`), which the real bidirectional send path
/// will need. Not wired for data yet — only subscription presence.
///
/// `send(_:)` frames an envelope as [4-byte big-endian total length][wireData]
/// and writes it to every connected peer in MTU-sized chunks. The peripheral
/// side accumulates chunks per peer, and once the declared length has arrived,
/// reassembles, parses `Envelope(wire:)`, and yields it into `incoming`.
///
/// WRITE MODE: write-WITH-response (built-in flow control; nothing silently
/// dropped). Revisit only if throughput matters.
///
/// CONCURRENCY: not an actor. ALL mutable state is confined to `cbQueue`;
/// nothing touches it off that queue, which is what makes `@unchecked Sendable`
/// honest (the protocol allows "actor OR otherwise internally synchronized").
public final class BLEMeshTransport: NSObject, MeshTransport, @unchecked Sendable {

    // MARK: - Protocol: identity
    public let kind: TransportKind = .ble

    // MARK: - Protocol: inbound stream
    public let incoming: AsyncStream<Envelope>
    private let inbound: AsyncStream<Envelope>.Continuation

    // MARK: - Presence: linked peers (ephemeral BLE ids, NOT crypto identities)
    public let reachabilityUpdates: AsyncStream<[UUID]>
    private let reachabilityCont: AsyncStream<[UUID]>.Continuation

    // MARK: - Protocol constants (permanent, like a port number — NOT placeholder)
    /// The AeroNyra mesh GATT service every peer advertises and scans for.
    static let serviceUUID = CBUUID(string: "5218EF92-305F-41B0-B29E-D0215FF59B8D")
    /// The single writable + notifiable characteristic that carries envelope chunks.
    static let characteristicUUID = CBUUID(string: "2496E79A-7D3F-4AB1-B6AE-DE940F1597D1")

    /// Bytes of length-prefix framing prepended to each envelope on the wire.
    private static let lengthPrefixBytes = 4   // UInt32 big-endian total length

    // MARK: - Queue confinement
    /// Every line of CoreBluetooth state below lives ONLY on this serial queue.
    private let cbQueue = DispatchQueue(label: "com.aeronyra.ble.transport")

    // MARK: - Central (scanner) side
    private var central: CBCentralManager?
    /// Discovered peers must be retained by us — CoreBluetooth does not.
    private var peers: [UUID: CBPeripheral] = [:]
    /// Remote mailboxes we can write to once discovered. Keyed by peripheral id.
    private var writeTargets: [UUID: CBCharacteristic] = [:]

    // MARK: - Peripheral (advertiser) side
    private var peripheral: CBPeripheralManager?
    private var mailbox: CBMutableCharacteristic?
    /// Centrals currently subscribed to our notify characteristic. Keyed by
    /// central id. This is the peripheral-side half of presence.
    private var subscribedCentrals: Set<UUID> = []
    /// Per-sender reassembly buffers, keyed by the writing central's id.
    private var reassembly: [UUID: (total: Int, buffer: Data)] = [:]

    private var started = false
    private let log = Logger(subsystem: "com.aeronyra.app", category: "BLE")

    // MARK: - Init
    public override init() {
        var inb: AsyncStream<Envelope>.Continuation!
        self.incoming = AsyncStream<Envelope> { inb = $0 }
        self.inbound = inb

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
            self.reassembly.removeAll()
            self.started = false
            self.emitReachable()
            self.log.info("stop(): radios torn down")
        }
    }

    /// Publish the current linked-peer set to the UI. Union of both roles:
    /// peripherals we connected to + centrals subscribed to us. Always called
    /// on cbQueue.
    private func emitReachable() {
        let ids = Set(writeTargets.keys).union(subscribedCentrals)
        reachabilityCont.yield(Array(ids))
    }

    // MARK: - Transmit
    public func send(_ envelope: Envelope) async throws {
        // Snapshot what we need off the cbQueue, then perform the writes there.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            cbQueue.async { [weak self] in
                guard let self else { cont.resume(); return }
                guard self.started else {
                    cont.resume(throwing: TransportError.notStarted); return
                }
                let targets = self.writeTargets.compactMap { (id, ch) -> (CBPeripheral, CBCharacteristic)? in
                    guard let p = self.peers[id] else { return nil }
                    return (p, ch)
                }
                guard !targets.isEmpty else {
                    cont.resume(throwing: TransportError.noReachablePeers); return
                }

                // Frame: [UInt32 big-endian total length][wireData].
                let wire = envelope.wireData()
                var framed = Data()
                var len = UInt32(wire.count).bigEndian
                withUnsafeBytes(of: &len) { framed.append(contentsOf: $0) }
                framed.append(wire)

                // Write to every connected peer, chunked to that peer's MTU.
                for (peer, ch) in targets {
                    let maxChunk = max(20, peer.maximumWriteValueLength(for: .withResponse))
                    var offset = 0
                    while offset < framed.count {
                        let end = min(offset + maxChunk, framed.count)
                        let slice = framed.subdata(in: offset..<end)
                        peer.writeValue(slice, for: ch, type: .withResponse)
                        offset = end
                    }
                    self.log.info("TX \(framed.count) bytes in chunks of \(maxChunk) → \(peer.identifier)")
                }
                cont.resume()
            }
        }
    }
}

// MARK: - Central role: scan, connect, discover the remote mailbox
extension BLEMeshTransport: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            log.error("central state not poweredOn: \(central.state.rawValue)")
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
        peers[peripheral.identifier] = peripheral   // retain before connect
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
        emitReachable()
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }
}

// MARK: - Central role: walk the connected peer's GATT, subscribe for notify
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
            // Subscribe so the OTHER phone's peripheral learns we're here
            // (fires its didSubscribeTo) and so it can push to us later.
            peripheral.setNotifyValue(true, for: ch)
            log.info("LINK READY → mailbox found on \(peripheral.identifier). Ready to send + subscribing.")
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

    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error {
            log.error("write failed to \(peripheral.identifier): \(error.localizedDescription)")
        }
    }
}

// MARK: - Peripheral role: advertise, track subscribers, receive/reassemble
extension BLEMeshTransport: CBPeripheralManagerDelegate {

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            log.error("peripheral state not poweredOn: \(peripheral.state.rawValue)")
            return
        }
        let mailbox = CBMutableCharacteristic(
            type: Self.characteristicUUID,
            properties: [.write, .writeWithoutResponse, .notify],
            value: nil,                       // must be nil for a dynamic (writable/notify) value
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
        emitReachable()
        log.info("central \(central.identifier) unsubscribed → presence removed")
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager,
                                  didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            guard let value = r.value else { continue }
            ingest(value, from: r.central.identifier)
        }
        // Respond once to the first request; that acknowledges the whole batch.
        // Required for write-with-response — without it the central stalls.
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    /// Accumulate chunks from a single sender until the declared total arrives,
    /// then reassemble → parse → yield. The 4-byte big-endian length prefix is
    /// stripped from the front of the first chunk.
    ///
    /// SPIKE SCOPE: assumes one envelope in flight per sender at a time.
    /// Stage-3 framing (per-message ids in the chunk header) lifts that.
    private func ingest(_ chunk: Data, from sender: UUID) {
        var entry = reassembly[sender] ?? (total: -1, buffer: Data())
        entry.buffer.append(chunk)

        // Need the 4-byte length prefix before we know how much to expect.
        if entry.total < 0 {
            guard entry.buffer.count >= Self.lengthPrefixBytes else {
                reassembly[sender] = entry
                return
            }
            let prefix = entry.buffer.prefix(Self.lengthPrefixBytes)
            let total = prefix.reduce(0) { ($0 << 8) | Int($1) }   // big-endian
            entry.total = total
            entry.buffer.removeFirst(Self.lengthPrefixBytes)
        }

        // Not all bytes yet — keep waiting.
        guard entry.buffer.count >= entry.total else {
            reassembly[sender] = entry
            return
        }

        // Exactly (or over) the declared length: take the envelope's bytes.
        let wire = entry.buffer.prefix(entry.total)
        reassembly[sender] = nil   // reset for the next message from this sender

        guard let envelope = Envelope(wire: Data(wire)) else {
            log.error("RX reassembled \(entry.total) bytes but Envelope(wire:) failed to parse")
            return
        }
        log.info("RX complete → envelope id=\(envelope.id) bytes=\(envelope.ciphertext.count) → yielding")
        inbound.yield(envelope)
    }
}
