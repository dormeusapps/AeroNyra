//
//  MessageRouter.swift
//  Core/Routing
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
//  WIRED (Phase 7b.1): this is now the Envelope I/O layer in BOTH directions.
//  Inbound — the router consumes each transport's `incoming`, dedups (which also
//  collapses the notify+write duplicate-envelope quirk), relays within the hop
//  budget, and hands survivors to the receiver. Outbound — the Security layer
//  (FirstContactCoordinator) seals an Envelope and calls `send`, so OUR OWN id
//  is marked seen up front and the echoes that flooding produces are recognised
//  as duplicates rather than re-relayed or handed back to us to "open".
//
//  DELIVERY STATE (Phase 7b.2b): a TRACKED send (a real outbound message) arms a
//  stuck-send timeout — if no confirmation lands within `deliveryTimeout`, the
//  message is reported `.notDelivered`. A delivery ack decoded by the Security
//  layer calls `confirmDelivery`, which cancels that timeout and reports
//  `.delivered` / `.relayed(hops)`. Control envelopes that are not themselves
//  messages — delivery acks, and the manifest/chunk envelopes of a media
//  transfer — send UNTRACKED: still flooded and marked seen, but with no outbox
//  entry, no delivery update, and no timeout. (Media gets its own message-level
//  tracking + acks in Phase 7b.2c.)
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

    /// Which links a relay of an envelope that arrived on `link` must NOT go
    /// back out (split-horizon, Phase 7b.1a). The receiver alone knows identity,
    /// so it maps the source link to its peer and returns ALL of that peer's
    /// links — a peer is reachable over up to two ephemeral ids (peripheral +
    /// central), and both must be excluded or the message storms back over the
    /// other GATT role. The router stays crypto-free by asking, not resolving.
    func relayExclusions(forSourceLink link: UUID) async -> Set<UUID>
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

    /// How long a tracked outbound message may sit on `.sent` (handed to the
    /// radio, awaiting a delivery ack) before the router gives up and reports it
    /// `.notDelivered`. A direct hop confirms in well under a second; a multi-hop
    /// relay path is slower, so this is generous on purpose — too short would
    /// false-fail a legitimate 7-hop delivery. Tune against real mesh traffic.
    public static let deliveryTimeout: Duration = .seconds(45)

    private let transports: [MeshTransport]
    private var seen: SeenCache
    private weak var receiver: EnvelopeReceiver?

    /// Outbound messages awaiting confirmation, keyed by envelope id. Retained
    /// so we can report state and re-send on a failed delivery. Only TRACKED
    /// sends land here; untracked control envelopes (acks, media chunks) do not.
    private var outbox: [MessageID: OutboxEntry] = [:]

    /// Per-message stuck-send timers, keyed by envelope id. Armed when a tracked
    /// send reaches `.sent`; cancelled the instant a terminal state (delivered /
    /// relayed / notDelivered) is recorded for that id. A fired timer flips a
    /// still-unconfirmed message to `.notDelivered`.
    private var timeouts: [MessageID: Task<Void, Never>] = [:]

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
                for await (link, envelope) in t.incoming {
                    await self?.handleInbound(link: link, envelope)
                }
            }
            consumeTasks.append(task)
        }
    }

    public func stop() {
        consumeTasks.forEach { $0.cancel() }
        consumeTasks.removeAll()
        for t in timeouts.values { t.cancel() }
        timeouts.removeAll()
        transports.forEach { $0.stop() }
    }

    /// Register the layer that opens inbound envelopes (the Security layer).
    /// Held weakly — the composition root owns both.
    public func setReceiver(_ receiver: EnvelopeReceiver) {
        self.receiver = receiver
    }

    // MARK: Outbound

    /// Send a sealed envelope and (when `tracked`) begin tracking its delivery.
    ///
    /// The envelope arrives already sealed from the Security layer; the router
    /// only routes it. Marking our own id as seen up front means the echoes
    /// that flooding produces are recognised as duplicates and neither
    /// re-relayed nor handed back to us to "open" — so seen-marking happens for
    /// EVERY send, tracked or not.
    ///
    /// `tracked` (default true) distinguishes a real outbound MESSAGE from a
    /// control envelope:
    ///   • tracked   — a text/data message. Gets an outbox entry, emits a
    ///                 `DeliveryUpdate`, and arms the stuck-send timeout.
    ///   • untracked — a delivery ack, or a media manifest/chunk. Flooded and
    ///                 seen-marked, but no outbox entry, no update, no timeout.
    ///                 (These are not individually confirmable messages; media
    ///                 gets message-level tracking in 7b.2c.)
    ///
    /// Returns the IMMEDIATE routing outcome so a synchronous caller can react:
    ///   • `.sent`            — handed to the radio for broadcast.
    ///   • `.waitingForRange` — no peer reachable; queued in the outbox.
    ///   • `.notDelivered`    — the transport rejected it.
    /// Asynchronous transitions — `.delivered` / `.relayed` once an ack lands,
    /// or `.notDelivered` on timeout — are reported via `deliveryUpdates`.
    /// `@discardableResult` so `resend` and any fire-and-forget caller compile.
    @discardableResult
    public func send(_ envelope: Envelope, tracked: Bool = true) async -> MessageDeliveryState {
        if tracked {
            outbox[envelope.id] = OutboxEntry(envelope: envelope, state: .sent)
        }
        _ = seen.containsOrInsert(envelope.id)

        let resulting: MessageDeliveryState
        do {
            let ble = try transport(for: .ble)
            try await ble.send(envelope)
            resulting = .sent                 // handed to radio
        } catch TransportError.noReachablePeers {
            resulting = .waitingForRange       // queued until in range
        } catch {
            resulting = .notDelivered
        }

        if tracked {
            update(envelope.id, resulting)
            if resulting == .sent { armTimeout(for: envelope.id) }
        }
        return resulting
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
    /// delivery; `hops >= 1` means it was relayed. Cancels the stuck-send
    /// timeout for this id (via `update`'s terminal handling).
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

    private func handleInbound(link: UUID, _ envelope: Envelope) async {
        // 1. Dedup. A message arriving by two relay paths (different ttl) has
        //    the same id and collapses to one here; loops break here too. This
        //    is also where the transport's notify+write duplicate of a single
        //    envelope is folded to one.
        if seen.containsOrInsert(envelope.id) { return }

        // 2. Relay (split-horizon). Flooding: rebroadcast onward within the hop
        //    budget, regardless of whether the message turns out to be for us —
        //    uniform relay avoids leaking recipiency through whether we forward.
        //    But NEVER back to the source peer: ask the receiver (which alone
        //    knows identity) for every link belonging to that peer and exclude
        //    them all. In a 2-node mesh that leaves no one to forward to, which
        //    is exactly what stops the relay storm (Phase 7b.1a).
        if let forwarded = envelope.forwarded() {
            let exclusions = await receiver?.relayExclusions(forSourceLink: link) ?? [link]
            for t in transports {
                await t.relay(forwarded, excludingLinks: exclusions)
            }
        }

        // 3. Local delivery. Hand to Security, which alone can open it.
        await receiver?.receive(envelope)
    }

    // MARK: Helpers

    private func update(_ id: MessageID, _ state: MessageDeliveryState) {
        outbox[id]?.state = state
        if state.isTerminal { cancelTimeout(for: id) }
        updates.yield(DeliveryUpdate(id: id, state: state))
    }

    /// Arm (or re-arm) the stuck-send timer for a tracked, just-sent message.
    /// Fires once after `deliveryTimeout`; a terminal state cancels it first.
    private func armTimeout(for id: MessageID) {
        cancelTimeout(for: id)
        timeouts[id] = Task { [weak self] in
            try? await Task.sleep(for: MessageRouter.deliveryTimeout)
            guard !Task.isCancelled else { return }
            await self?.timeoutFired(for: id)
        }
    }

    /// The timer elapsed without a confirmation: if the message is still
    /// non-terminal, surface it as `.notDelivered` so it stops sitting on
    /// "handed to radio" and offers the user a resend.
    private func timeoutFired(for id: MessageID) {
        timeouts[id] = nil
        guard let entry = outbox[id], !entry.state.isTerminal else { return }
        update(id, .notDelivered)
    }

    private func cancelTimeout(for id: MessageID) {
        timeouts[id]?.cancel()
        timeouts[id] = nil
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
