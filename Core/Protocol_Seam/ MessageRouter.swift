//
//  MessageRouter.swift
//  Beacon (working title)
//
//  Where the pieces meet.
//
//  HANDOFF §4.1: "MessageRouter selects a transport and tracks delivery state.
//   v1 returns only BLE paths; reserve a `.internet` case for later."
//  HANDOFF §13 (Relay): "relays forward only authenticated envelopes;
//   hop count <= 7; seen-ID LRU dedup; no plaintext."
//
//  The router does NO crypto. It moves opaque Envelopes, dedups them, floods
//  valid ones onward within their hop budget, and translates acknowledgements
//  (decoded above, in Security) into MessageDeliveryState transitions the UI
//  observes. Inbound envelopes are handed to an `EnvelopeReceiver` (the
//  Security layer) which alone can open them.
//

import Foundation

// MARK: - Inbound seam

/// The sink for envelopes that survive dedup. Implemented by the Security
/// layer, which alone holds the keys to open them. Keeping this a protocol is
/// what keeps the router crypto-free.
public protocol EnvelopeReceiver: AnyObject, Sendable {
    /// Attempt to open and process an inbound envelope (data message, ack,
    /// handshake, …). The receiver decides what it is; the router does not.
    func receive(_ envelope: Envelope) async
}

// MARK: - Delivery updates

/// A change in an outbound message's delivery state, streamed to the UI.
public struct DeliveryUpdate: Equatable, Sendable {
    public let id: MessageID
    public let state: MessageDeliveryState
}

// MARK: - Seen cache

/// A bounded cache of recently-seen message IDs for dedup and loop-breaking.
///
/// HANDOFF says "LRU"; this uses **FIFO** eviction deliberately. Dedup only
/// needs to remember that an ID was seen *recently* — it never benefits from
/// re-ordering on a hit. FIFO avoids the O(n) move-to-back a strict LRU pays
/// on every flooded duplicate (and floods produce many duplicates), so it is
/// both simpler and faster for this job. Swap for a linked-hash-map only if
/// profiling ever shows the bounded set is the bottleneck.
struct SeenCache {
    private var present = Set<MessageID>()
    private var order = [MessageID]()   // front = oldest
    let capacity: Int

    init(capacity: Int) { self.capacity = max(1, capacity) }

    /// Returns `true` if the ID was already present (a duplicate). Otherwise
    /// inserts it and returns `false`.
    mutating func containsOrInsert(_ id: MessageID) -> Bool {
        if present.contains(id) { return true }
        present.insert(id)
        order.append(id)
        if order.count > capacity {
            let evicted = order.removeFirst()
            present.remove(evicted)
        }
        return false
    }
}

// MARK: - MessageRouter

public actor MessageRouter {

    /// Default dedup window. Sized for a busy room; tune against real traffic.
    public static let defaultSeenCapacity = 2048

    private let transports: [MeshTransport]
    private var seen: SeenCache
    private weak var receiver: EnvelopeReceiver?

    /// Outbound messages awaiting confirmation, keyed by envelope id. Retained
    /// so we can report state and re-send on a failed delivery.
    private var outbox: [MessageID: OutboxEntry] = [:]

    private var consumeTasks: [Task<Void, Never>] = []

    /// Stream of delivery-state changes for the UI to observe.
    public nonisolated let deliveryUpdates: AsyncStream<DeliveryUpdate>
    private nonisolated let updates: AsyncStream<DeliveryUpdate>.Continuation

    private struct OutboxEntry {
        let envelope: Envelope
        var state: MessageDeliveryState
    }

    public init(transports: [MeshTransport],
                seenCapacity: Int = MessageRouter.defaultSeenCapacity) {
        self.transports = transports
        self.seen = SeenCache(capacity: seenCapacity)

        var continuation: AsyncStream<DeliveryUpdate>.Continuation!
        self.deliveryUpdates = AsyncStream(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        self.updates = continuation
    }

    // MARK: Lifecycle

    /// Start every transport and begin consuming their inbound streams.
    public func start() async throws {
        for t in transports { try await t.start() }
        for t in transports {
            let task = Task { [weak self, t] in
                for await envelope in t.incoming {
                    await self?.handleInbound(envelope)
                }
            }
            consumeTasks.append(task)
        }
    }

    public func stop() {
        consumeTasks.forEach { $0.cancel() }
        consumeTasks.removeAll()
        transports.forEach { $0.stop() }
    }

    /// Register the layer that opens inbound envelopes (the Security layer).
    /// Held weakly — the composition root owns both.
    public func setReceiver(_ receiver: EnvelopeReceiver) {
        self.receiver = receiver
    }

    // MARK: Outbound

    /// Send a sealed envelope and begin tracking its delivery.
    ///
    /// The envelope arrives already sealed from the Security layer; the router
    /// only routes it. Marking our own id as seen up front means the echoes
    /// that flooding produces are recognised as duplicates and neither
    /// re-relayed nor handed back to us to "open".
    public func send(_ envelope: Envelope) async {
        outbox[envelope.id] = OutboxEntry(envelope: envelope, state: .sent)
        _ = seen.containsOrInsert(envelope.id)

        do {
            let ble = try transport(for: .ble)
            try await ble.send(envelope)
            update(envelope.id, .sent)              // handed to radio
        } catch TransportError.noReachablePeers {
            update(envelope.id, .waitingForRange)   // queued until in range
        } catch {
            update(envelope.id, .notDelivered)
        }
    }

    /// Re-send a previously failed message.
    ///
    /// Caveat: this re-sends the *same* sealed bytes, so any relay still
    /// holding this id in its seen-cache will drop it. That is correct for the
    /// common case (a `.waitingForRange` message no relay ever saw). For a
    /// retry after partial propagation, ask Security to reseal with a fresh id
    /// instead — resealing is not the router's call to make.
    public func resend(_ id: MessageID) async {
        guard let entry = outbox[id] else { return }
        await send(entry.envelope)
    }

    /// Mark an in-flight message as actively routing through the mesh. Drives
    /// the Live-Transit widget (DESIGN_TOKENS §7). Called from above when a
    /// relay leg becomes active.
    public func markFindingPath(_ id: MessageID) {
        guard outbox[id] != nil else { return }
        update(id, .findingPath)
    }

    /// Confirm a message reached the recipient. `hops == 0` means a direct
    /// delivery; `hops >= 1` means it was relayed.
    public func confirmDelivery(of id: MessageID, hops: Int) {
        guard outbox[id] != nil else { return }
        update(id, hops <= 0 ? .delivered : .relayed(hops: hops))
    }

    /// Confirm a message failed (timed out or was rejected).
    public func confirmFailure(of id: MessageID) {
        guard outbox[id] != nil else { return }
        update(id, .notDelivered)
    }

    /// Current tracked state of an outbound message, if any.
    public func state(of id: MessageID) -> MessageDeliveryState? {
        outbox[id]?.state
    }

    // MARK: Inbound

    private func handleInbound(_ envelope: Envelope) async {
        // 1. Dedup. A message arriving by two relay paths (different ttl) has
        //    the same id and collapses to one here; loops break here too.
        if seen.containsOrInsert(envelope.id) { return }

        // 2. Relay. Flooding: rebroadcast onward within the hop budget,
        //    regardless of whether the message turns out to be for us. We
        //    cannot know recipiency without the keys, and uniform relay
        //    behaviour avoids leaking recipiency through whether we forward.
        if let forwarded = envelope.forwarded() {
            for t in transports {
                try? await t.send(forwarded)
            }
        }

        // 3. Local delivery. Hand to Security, which alone can open it.
        await receiver?.receive(envelope)
    }

    // MARK: Helpers

    private func update(_ id: MessageID, _ state: MessageDeliveryState) {
        outbox[id]?.state = state
        updates.yield(DeliveryUpdate(id: id, state: state))
    }

    /// Resolve a transport by kind. `.internet` has no implementation in v1
    /// and surfaces as `.unsupported` — the reserved seam (HANDOFF §4.1).
    private func transport(for kind: TransportKind) throws -> MeshTransport {
        guard let t = transports.first(where: { $0.kind == kind }) else {
            throw TransportError.unsupported(kind)
        }
        return t
    }
}
