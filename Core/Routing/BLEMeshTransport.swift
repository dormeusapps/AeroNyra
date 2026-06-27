//
//  BLEMeshTransport.swift
//  Core/Routing
//

import Foundation
import CoreBluetooth
import os

/// Concrete BLE mesh transport conforming to `MeshTransport`.
///
/// STAGE 1 (this file): lifecycle + connection only. Each device runs BOTH
/// roles — peripheral (advertises a service + exposes one writable
/// characteristic) AND central (scans for that service, connects, will write).
/// Two phones thus form a peer link. Actual byte transmit + reassembly land in
/// Stage 2; `send(_:)` is a deliberate stub until then.
///
/// CONCURRENCY: this is not an actor. CoreBluetooth delegates are NSObject
/// callbacks delivered on a queue we choose, so we confine ALL mutable state to
/// `cbQueue` and nothing touches it off that queue. That confinement is what
/// makes `@unchecked Sendable` honest here (the protocol explicitly allows
/// "actor OR otherwise internally synchronized").
public final class BLEMeshTransport: NSObject, MeshTransport, @unchecked Sendable {

    // MARK: - Protocol: identity
    public let kind: TransportKind = .ble

    // MARK: - Protocol: inbound stream
    public let incoming: AsyncStream<Envelope>
    private let inbound: AsyncStream<Envelope>.Continuation

    // MARK: - Protocol constants (permanent, like a port number — NOT placeholder)
    /// The AeroNyra mesh GATT service every peer advertises and scans for.
    static let serviceUUID = CBUUID(string: "5218EF92-305F-41B0-B29E-D0215FF59B8D")
    /// The single writable characteristic that carries envelope chunks.
    static let characteristicUUID = CBUUID(string: "2496E79A-7D3F-4AB1-B6AE-DE940F1597D1")

    // MARK: - Queue confinement
    /// Every line of CoreBluetooth state below lives ONLY on this serial queue.
    private let cbQueue = DispatchQueue(label: "com.aeronyra.ble.transport")

    // MARK: - Central (scanner) side
    private var central: CBCentralManager?
    /// Discovered peers must be retained by us — CoreBluetooth does not.
    private var peers: [UUID: CBPeripheral] = [:]
    /// Remote mailboxes we can write to once discovered (Stage 2 uses these).
    private var writeTargets: [UUID: CBCharacteristic] = [:]

    // MARK: - Peripheral (advertiser) side
    private var peripheral: CBPeripheralManager?
    private var mailbox: CBMutableCharacteristic?

    private var started = false
    private let log = Logger(subsystem: "com.aeronyra.app", category: "BLE")

    // MARK: - Init
    public override init() {
        var c: AsyncStream<Envelope>.Continuation!
        self.incoming = AsyncStream<Envelope> { c = $0 }
        self.inbound = c
        super.init()
    }

    // MARK: - Lifecycle
    public func start() async throws {
        cbQueue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            // Creating the managers triggers the powerOn callbacks below, where
            // advertising and scanning actually begin.
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
            self.started = false
            self.log.info("stop(): radios torn down")
        }
    }

    // MARK: - Transmit
    public func send(_ envelope: Envelope) async throws {
        // ───────────────────────────────────────────────────────────────────
        // STAGE 2 IMPLEMENTS THIS. The transmit path is: envelope.wireData()
        // → length-prefixed chunking across the negotiated MTU → write each
        // chunk to every writeTargets characteristic. Not wired in Stage 1, so
        // we honestly report "no transmit path yet" via .noReachablePeers
        // (maps to UI .waitingForRange — harmless, not a hard failure).
        // ───────────────────────────────────────────────────────────────────
        throw TransportError.noReachablePeers
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
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }
}

// MARK: - Central role: walk the connected peer's GATT to find the mailbox
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
            log.info("LINK READY → mailbox found on \(peripheral.identifier). Stage 2 can write.")
        }
    }
}

// MARK: - Peripheral role: advertise the service + expose the mailbox
extension BLEMeshTransport: CBPeripheralManagerDelegate {

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            log.error("peripheral state not poweredOn: \(peripheral.state.rawValue)")
            return
        }
        let mailbox = CBMutableCharacteristic(
            type: Self.characteristicUUID,
            properties: [.write, .writeWithoutResponse],
            value: nil,                       // must be nil for a writable (dynamic) value
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
                                  didReceiveWrite requests: [CBATTRequest]) {
        // STAGE 2: accumulate length-prefixed chunks here, reassemble, then
        //   Envelope(wire:) and inbound.yield(envelope). Stage 1 just confirms
        //   the mailbox receives bytes at all.
        for r in requests {
            log.info("RX \(r.value?.count ?? 0) bytes on mailbox (Stage 2 reassembles)")
            peripheral.respond(to: r, withResult: .success)
        }
    }
}
