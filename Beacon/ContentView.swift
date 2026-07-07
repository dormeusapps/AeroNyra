//
//  ContentView.swift
//
//  Composition root. Decides whether the user enters Onboarding or the
//  main app based on whether a long-term identity exists in the
//  Keychain, and constructs the persistent SwiftData ModelContainer the
//  rest of the app reads from.
//
//  Three phases:
//   1. .launching   — checking the Keychain. Brief.
//   2. .onboarding  — no identity yet. OnboardingView generates one on
//                     user tap; we save it, then transition to .ready.
//   3. .ready       — identity loaded; render the main tabbed app.
//
//  Identity persistence goes through IdentityStore. On a real device
//  the long-term identity is Enclave-wrapped; on the simulator (no
//  Enclave) the wrapper resolves to nil and the blob lives under
//  Keychain Data Protection only — which is fine for development.
//
//  Wiring owned here:
//   • BLE transport — started at launch, lives the whole app lifetime.
//   • MeshPresence  — fed from the transport's reachability (link ids) AND,
//     via ReadyView, from the coordinator's identity-resolved presence (peer
//     keys). Read by Nearby (blips + count) and by per-conversation presence.
//   • SignalSessionStore — built from the SAME loaded identity (one identity
//     end to end).
//   • FirstContactCoordinator — marries transport + store for carrier-neutral
//     first contact. Consumes the transport's BUNDLE + REACHABILITY streams
//     (first contact + presence); ENVELOPE I/O now runs through MessageRouter.
//   • MessageRouter (Phase 7b.1) — the Envelope I/O layer: it consumes the
//     transport's `incoming`, dedups + relays (multi-hop, max 7 hops), and
//     hands survivors to the coordinator (its `EnvelopeReceiver`). Outbound
//     seals also go through it. The router is the SOLE consumer of
//     `transport.incoming` — nothing else may read that stream. Its
//     `deliveryUpdates` stream (Phase 7b.2a) is likewise single-consumer and
//     is read only by ReadyView, which feeds it into the MessageInbox.
//   • MessageInbox — owned by ReadyView (below), on the main actor, so the
//     coordinator's SessionEvents become SwiftData Peer/Conversation/Message.
//   • Presence-by-identity — ReadyView consumes the coordinator's
//     `reachablePeers` stream and mirrors it into MeshPresence.
//   • EmergencyWipe (STEP 7b-3) — constructed here with every live secret-bearing
//     component (identity store, session store, shared Enclave wrapper, session
//     DEK, Nostr secret, contact allowlist, SwiftData message store). Held on the
//     view and invoked via `performEmergencyWipe()`. NO gesture yet (that is 7d);
//     this makes crypto-erase constructible and callable. See EMERGENCY_WIPE_7b3.md.
//   • EnrollmentService (STEP 7c-1) — the single serializing owner of the live
//     ContactAllowlist. Constructed here with the same allowlist store + coordinator,
//     seeded from the loaded paired set. Held on the view; the pairing UI (7d) drives
//     enroll/markVerified/revoke. No caller yet. See ENROLLMENT_7c1.md.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    
    private enum Phase {
        case launching
        case onboarding(IdentityStore)
        case ready(IdentityKeypair, ModelContainer, IdentityStore)
    }
    
    @State private var phase: Phase = .launching
    
    /// The single long-lived BLE transport, started at launch.
    @State private var transport = BLEMeshTransport()
    
    /// Live radio presence, fed from the transport and read by the Chats list
    /// and conversation headers (identity-resolved reachability).
    @State private var presence = MeshPresence()
    
    /// The single secure-session store, built from the real loaded identity
    /// once we reach .ready. nil until then.
    @State private var sessionStore: SignalSessionStore?
    
    /// Drives carrier-neutral first contact (bundle exchange + establishment).
    @State private var coordinator: FirstContactCoordinator?
    
    /// The mesh router (Phase 7b.1): dedup + multi-hop relay + Envelope I/O.
    /// Built alongside the coordinator once we reach .ready; nil until then.
    @State private var router: MessageRouter?
    
    /// The persisted closed-contact allowlist store (STEP 7a). Loaded at launch to
    /// seed reconnect (warmInboundSessions + enableReconnect) and held so later
    /// enrollment can save to it and EmergencyWipe can crypto-erase it. nil until
    /// .ready.
    @State private var contactAllowlistStore: ContactAllowlistStore?
    
    /// The device's Nostr identity (Phase 8a): a persistent secp256k1 secret,
    /// load-or-created at launch alongside the session store. Held so the
    /// internet pillar (Phase 8) has its identity ready; its npub lights up once
    /// the public key is derived (Phase 8b). nil until .ready.
    @State private var nostrIdentity: NostrIdentity?
    
    /// The assembled crypto-erase (STEP 7b-3). Constructed in `makeSessionStack`
    /// with every live secret-bearing component and invoked by
    /// `performEmergencyWipe()`. nil until .ready. No trigger is wired yet — the
    /// triple-tap gesture is 7d; this only makes the wipe callable.
    @State private var emergencyWipe: EmergencyWipe?
    
    /// The enrollment seam (STEP 7c-1): the single serializing owner of the live
    /// ContactAllowlist. Constructed in `makeSessionStack` from the same allowlist
    /// store + coordinator, seeded with the loaded paired set. nil until .ready. No
    /// caller yet — the pairing UI (7d) drives enroll/markVerified/revoke.
    @State private var enrollmentService: EnrollmentService?
    
    /// The pairing façade (STEP 7d): builds our QR/invite payload on demand and
    /// mints single-use invites via the enrollment seam. Constructed in
    /// `makeSessionStack`; injected by ReadyView; driven by PairingView. nil until .ready.
    @State private var pairingService: PairingService?
    
    var body: some View {
        Group {
            switch phase {
            case .launching:
                launchScreen
                    .task { bootstrap() }
                
            case .onboarding(let store):
                OnboardingView { identity in
                    completeOnboarding(identity: identity, store: store)
                }
                
            case .ready(_, let container, _):
                // ReadyView owns the main-actor MessageInbox for this phase.
                // coordinator + router are set together in makeSessionStack, so
                // unwrapping both here is safe — whenever one is non-nil, so is
                // the other.
                if let coordinator, let router, let pairingService {
                    ReadyView(container: container,
                              coordinator: coordinator,
                              router: router,
                              pairingService: pairingService)
                } else {
                    launchScreen   // unreachable: both are set before .ready
                }
            }
        }
        .preferredColorScheme(.dark)
        .environment(presence)
        .environment(\.eraseEverything) { eraseEverything() }
        .task {
            // Start the radio, then keep presence in sync AND feed the
            // coordinator newly-reachable links. Main-actor isolated, so
            // touching `presence` here is safe; coordinator calls hop to it.
            // (transport.start() is idempotent; the router may also start it.)
            do {
                try await transport.start()
            } catch {
                print("BLE start failed: \(error)")
            }
            for await ids in transport.reachabilityUpdates {
                presence.reachableIDs = ids
                await coordinator?.onReachable(ids)
            }
        }
        .task {
            // Inbound prekey bundles → first contact. (Envelopes are NOT read
            // here any more — the router owns `transport.incoming`.)
            for await item in transport.bundles {
                await coordinator?.onBundle(link: item.link, data: item.data)
            }
        }
        .task {
            // Inbound reconnect frames (0x03) → closed-contact auth handshake
            // (5d). Link-local; the coordinator owns the 1-byte inner
            // discriminator (beacon-set vs it's-me).
            for await item in transport.reconnects {
                await coordinator?.onReconnectFrame(link: item.link, data: item.data)
            }
        }
    }
    
    private var launchScreen: some View {
        Color.bgApp.ignoresSafeArea()
    }
    
    // MARK: - Bootstrap
    
    /// Try to load an existing identity. If found, build the persistent
    /// ModelContainer + secure-session store + coordinator and enter .ready.
    /// If not, route to Onboarding.
    private func bootstrap() {
        let wrapper = try? SecureEnclaveWrapper(service: enclaveService)
        let store = IdentityStore(
            service: identityService,
            protection: .deviceUnlockOnly,
            wrapper: wrapper
        )
        
        do {
            let identity = try store.load()
            let container = try makeModelContainer()
            try makeSessionStack(identity: identity,
                                 identityStore: store,
                                 enclaveWrapper: wrapper)
            phase = .ready(identity, container, store)
        } catch IdentityError.notFound {
            phase = .onboarding(store)
        } catch {
            // Any other error (Keychain quirk, container failure, etc.)
            // falls back to onboarding rather than wedging at launch.
            // A real error UX comes later.
            phase = .onboarding(store)
        }
    }
    
    /// Called once OnboardingView has handed us a fresh IdentityKeypair.
    /// Persist it, build the container + session stack, enter .ready.
    private func completeOnboarding(identity: IdentityKeypair,
                                    store: IdentityStore) {
        do {
            try store.save(identity, overwrite: true)
            let container = try makeModelContainer()
            // Reconstruct the same Enclave wrapper the store uses, so the wipe's
            // safety-net Enclave teardown targets the right key. try? mirrors
            // bootstrap(): absent on the simulator (no Enclave), present on device.
            let wrapper = try? SecureEnclaveWrapper(service: enclaveService)
            try makeSessionStack(identity: identity,
                                 identityStore: store,
                                 enclaveWrapper: wrapper)
            phase = .ready(identity, container, store)
        } catch {
            // Stay in onboarding so the user can tap again. A real UX
            // would surface the error; logging suffices for now.
            print("Bootstrap save failed: \(error)")
        }
    }
    
    // MARK: - Construction
    
    /// Build the secure-session store (from the loaded identity, so the session
    /// layer uses the SAME Enclave-bound identity as the rest of the app), the
    /// first-contact coordinator, and the mesh router that carries Envelopes.
    ///
    /// PASS 2 (Phase 5a.3): the store is PERSISTENT — its libsignal session
    /// state is vault-encrypted to disk under a Keychain-held DEK and survives a
    /// relaunch, so an old peer's traffic decrypts after a restart with no fresh
    /// first-contact. The DEK + store directory are stable across launches.
    ///
    /// PASS 3 (Phase 7b.1): a MessageRouter is built over the transport and the
    /// coordinator is registered as its EnvelopeReceiver. The router consumes
    /// `transport.incoming` (dedup + relay) and the coordinator's outbound seals
    /// flow through `router.send`. Wiring + start happen in a Task because the
    /// actor calls are async; the catch-up `onReachable` runs after.
    ///
    /// STEP 7b-3: `identityStore` + `enclaveWrapper` are threaded in from the
    /// caller (they are provisioned in bootstrap/onboarding, not here) so the
    /// EmergencyWipe assembled at the end of this method can target the long-term
    /// identity item and the shared Enclave key. No trigger is wired — 7d.
    private func makeSessionStack(identity: IdentityKeypair,
                                  identityStore: IdentityStore,
                                  enclaveWrapper: SecureEnclaveWrapper?) throws {
        let dek = try SessionStoreKey.loadOrCreate(service: sessionKeyService)
        let directory = try PersistentBeaconStore.defaultDirectory()
        let secure = try SignalSessionStore(appIdentity: identity,
                                            directory: directory, dek: dek)
        let coord = FirstContactCoordinator(store: secure, transport: transport)
        
        // STEP 7a — persisted closed-contact allowlist. Its own DEK (a distinct
        // Keychain service) seals a distinct file in the same store directory.
        // Loaded now so the paired set seeds reconnect below; held on the view so
        // later enrollment can save to it and EmergencyWipe can crypto-erase it.
        let contactStore = try ContactAllowlistStore(
            directory: directory,
            dek: try SessionStoreKey.loadOrCreate(
                service: ContactAllowlistStore.defaultKeychainService))
        
        // STEP 7c-2 — persisted single-use invite ledger. Own DEK (a distinct
        // Keychain service) seals a distinct file in the same store directory.
        // Registered in EmergencyWipe below so the in-flight-pairing ledger is
        // crypto-erased on wipe; the EnrollmentService adopts it in 7c-2b to own
        // the mint/consume lifecycle (which is where load-time pruning lives).
        let pendingInvitesStore = try PendingInvitesStore(
            directory: directory,
            dek: try SessionStoreKey.loadOrCreate(
                service: PendingInvitesStore.defaultKeychainService))

        // ISSUE-5 — persisted Nostr backlog-replay ledger. Own DEK (a distinct
        // Keychain service) seals a distinct file in the same store directory.
        // Seeds NostrTransport's replay guard below and is registered in
        // EmergencyWipe so it is crypto-erased on wipe. Loaded now; UNLIKE the
        // allowlist a corrupt/failed load is NOT security-critical (a dedup cache
        // — worst case one replay storm), so we boot empty with a warning rather
        // than degrade the mesh.
        let nostrEventLedgerStore = try ProcessedEventLedgerStore(
            directory: directory,
            dek: try SessionStoreKey.loadOrCreate(
                service: ProcessedEventLedgerStore.defaultKeychainService))
        let loadedNostrLedger: ProcessedEventLedger
        do {
            loadedNostrLedger = try nostrEventLedgerStore.load()
            print("nostr replay ledger loaded \u{00B7} \(loadedNostrLedger.count) id(s)")
        } catch {
            print("\u{26A0}\u{FE0F} nostr replay ledger load FAILED \u{2014} booting empty: \(error)")
            loadedNostrLedger = ProcessedEventLedger()
        }
        
        // Load the WHOLE allowlist once: `pairedIdentities` seeds reconnect below,
        // and the full `loadedAllowlist` (with verified-states intact) seeds the
        // EnrollmentService so it starts from the real persisted set, not empty.
        let loadedAllowlist: ContactAllowlist
        let pairedIdentities: [Data]
        do {
            loadedAllowlist = try contactStore.load()
            pairedIdentities = Array(loadedAllowlist.identities)
            print("contact allowlist loaded · \(pairedIdentities.count) paired contact(s)")
        } catch {
            // The store threw rather than silently emptying (its contract). At the
            // composition root we log loudly and boot with an empty set: during
            // coexistence the in-session noteReconnectContact hook still populates
            // reconnect, so an empty seed here does not darken the mesh. When the
            // admission gate is later flipped authoritative, a corrupt load will
            // need a real re-pair recovery path rather than this degrade.
            print("⚠️ contact allowlist load FAILED — booting with empty set: \(error)")
            loadedAllowlist = ContactAllowlist()
            pairedIdentities = []
        }

        // STEP 7f (STRICT-VERIFIED) — the VERIFIED subset seeds the coordinator's
        // admission/presence gate ALONGSIDE the enrolled set below, and MUST be
        // seeded before mesh.start() (same discipline as pairedIdentities) or
        // verified contacts drop from the gate on relaunch and the mesh darkens.
        let verifiedIdentities = pairedIdentities.filter {
            loadedAllowlist.isVerified(identity: $0)
        }
        print("contact allowlist · \(verifiedIdentities.count) verified contact(s)")
        
        // STEP 7c-2 — load the single-use invite ledger once to seed the
        // EnrollmentService, which then OWNS it (mint/redeem, save-then-adopt) and
        // prunes expired ids in RAM at construction. Same loud-degrade posture as
        // the allowlist: the store throws rather than silently emptying, so a
        // corrupt ledger is logged and we boot empty (in-flight remote pairings
        // would just need a fresh invite — acceptable; single-use + SAS still hold).
        let loadedPending: PendingInvites
        do {
            loadedPending = try pendingInvitesStore.load()
            print("pending invite ledger loaded · \(loadedPending.count) in flight")
        } catch {
            print("⚠️ pending invite ledger load FAILED — booting empty: \(error)")
            loadedPending = PendingInvites()
        }
        
        // Nostr identity (Phase 8a): load-or-create the persistent secp256k1
        // secret so the internet pillar has an identity from launch. Best-effort
        // — a failure here must not block the BLE pillar, which is fully
        // functional without it.
        //
        // Loaded BEFORE the router (Phase 8d-3) so PILLAR 2 — a NostrTransport
        // over a single relay — can join the router's transport set when an
        // identity exists. Its raw x-only public key is also hoisted for the
        // coordinator's npub-bootstrap; stays nil if the load fails.
        var ourNostrPubkey: Data?
        var nostrTransport: NostrTransport?
        do {
            let nostr = try NostrIdentity.loadOrCreate(service: nostrIdentityService)
            nostrIdentity = nostr
            ourNostrPubkey = nostr.publicKeyBytes
            if let pub = nostr.publicKeyBytes {
                let relayURLs = nostrRelayURLs.compactMap { URL(string: $0) }
                if !relayURLs.isEmpty {
                    // Seed the ISSUE-5 replay guard from the sealed store and give
                    // the transport a save hook (it debounces + dispatches the seal
                    // off its serial queue, so the write never blocks inbound).
                    nostrTransport = NostrTransport(
                        relayURLs: relayURLs,
                        ourSecretKey: nostr.secretKeyBytes,
                        ourPublicKey: pub,
                        initialLedger: loadedNostrLedger,
                        persistLedger: { [nostrEventLedgerStore] snapshot in
                            try? nostrEventLedgerStore.save(snapshot)
                        })
                }
            }
            // Breadcrumb only. NEVER log any part of nsec/secretKeyBytes — that
            // is private-key material and lands unredacted in the device console
            // and sysdiagnose. The public key is safe as a launch marker; use the
            // already-hoisted `ourNostrPubkey` (== nostr.publicKeyBytes) in hex.
            let npubHex = ourNostrPubkey?.prefix(6).map { String(format: "%02x", $0) }.joined()
            RedactLog.event("nostr identity ready", "npub \(npubHex ?? "?")…")
        } catch {
            print("nostr identity load/create failed (BLE unaffected): \(error)")
        }
        
        // PILLAR 1 (BLE) is always present; PILLAR 2 (Nostr) joins when an
        // identity exists. The router consumes BOTH transports' `incoming`; the
        // relay/TTL bypass for Nostr arrivals lives in the router (Phase 8d-2).
        var transports: [MeshTransport] = [transport]
        if let nostrTransport { transports.append(nostrTransport) }
        let mesh = MessageRouter(transports: transports)
        
        sessionStore = secure
        coordinator = coord
        router = mesh
        contactAllowlistStore = contactStore
        
        // STEP 7c-1/7c-2 — the enrollment seam: the single serializing owner of the
        // live ContactAllowlist AND the single-use invite ledger. Seeded with the
        // real persisted allowlist (verified-states intact) and ledger, sharing the
        // same store instances so its saves land in the same sealed files, and the
        // same coordinator so a new enroll reconnects immediately via
        // `addReconnectContact`. `coord` conforms to `ReconnectEnrolling`. No caller
        // yet — the pairing UI (7d) and echo transport (7c-2 step 5) drive it.
        let enroll = EnrollmentService(
            store: contactStore,
            pendingStore: pendingInvitesStore,
            coordinator: coord,
            initialAllowlist: loadedAllowlist,
            initialPending: loadedPending)
        enrollmentService = enroll
        
        // STEP 7d — the pairing façade. Wraps the session store (a FRESH local
        // prekey bundle per QR/invite), our Nostr public key, and the enrollment
        // seam (mint). Injected by ReadyView; driven by the pairing UI.
        pairingService = PairingService(sessionStore: secure,
                                                coordinator: coord,
                                                enrollment: enroll,
                                                ourNostrPublicKey: ourNostrPubkey)
        
        // STEP 7b-3 — assemble the crypto-erase now that every secret-bearing
        // component exists. Service ids are the SAME `private var` constants used
        // above to PROVISION each secret, so the wipe cannot target the wrong
        // Keychain item (the silent-failure trap in EMERGENCY_WIPE_7b3.md §3):
        //   • core: identity item (unconditional), shared Enclave key (safety net),
        //     session store file (via secure.deleteAllSessions → store.wipe()).
        //   • additional: session DEK, Nostr secret, contact allowlist, invite
        //     ledger, SwiftData message store. Order among additional steps is
        //     immaterial (each is independent + idempotent).
        // SwiftDataStoreWipe() resolves the default store directory the same way
        // makeModelContainer() does; it throws, so it is built inside this
        // throwing method. No trigger is wired — performEmergencyWipe() below is
        // the sole entry point until the 7d gesture calls it.
        emergencyWipe = EmergencyWipe(
            identityStore: identityStore,
            sessionStore: secure,
            sharedEnclaveWrapper: enclaveWrapper,
            additionalSteps: [
                SessionKeyWipe(service: sessionKeyService),
                NostrIdentityWipe(service: nostrIdentityService),
                contactStore,
                pendingInvitesStore,
                nostrEventLedgerStore,
                try SwiftDataStoreWipe(),
                DeviceResidueWipe(),   // self name/photo defaults + notifications + badge
            ]
        )
        
        RedactLog.event("session store ready (persistent) · transports=\(transports.count)", "identity \(secure.localIdentity.userIDHex.prefix(16))…")
        
        // Register the receiver + router and start consuming `incoming`, then
        // catch up on any links that already formed before the coordinator
        // existed (e.g. a peer already in range at launch).
        let ids = presence.reachableIDs
        Task {
            await mesh.setReceiver(coord)
            await coord.setRouter(mesh)
            await coord.setNostrPublicKey(ourNostrPubkey)   // Phase 8d npub-bootstrap
            await coord.setInviteRedeemer(enroll)           // STEP 7c-2 invite-echo redeem (weak)
            
            // Closed-contact reconnect (5d). Warm the trial-decrypt cache from the
            // allowlist (Invariant #1) BEFORE any 0x03 frame can arrive, then
            // enable the handshake with our X25519 agreement key. STEP 7a: the set
            // is now sourced from the PERSISTED ContactAllowlist loaded above, so a
            // paired contact reconnects after a relaunch with no re-exchange. The
            // in-session noteReconnectContact hook still runs alongside during
            // coexistence (it retires with the over-RF bundle path in a later step).
            secure.warmInboundSessions(for: pairedIdentities)
            await coord.enableReconnect(agreementPrivate: identity.agreement,
                                        allowlistIdentities: pairedIdentities,
                                        verifiedIdentities: verifiedIdentities)
            
            do {
                try await mesh.start()   // starts BOTH transports: BLE radio + Nostr relay
            } catch {
                print("router start failed: \(error)")
            }
            await coord.onReachable(ids)
        }
    }
    
    // MARK: - Emergency crypto-erase (STEP 7b-3)
    
    /// Run the assembled crypto-erase, best-effort. Destroys every secret-bearing
    /// component (identity, Enclave key, session store + its DEK, Nostr secret,
    /// contact allowlist, SwiftData message store) and returns the errors from any
    /// steps that failed — an empty array means a fully clean wipe.
    ///
    /// UI-AGNOSTIC ON PURPOSE. No gesture, no confirmation, no navigation lives
    /// here — the 7d trigger owns those. After a wipe the app must route back to
    /// onboarding / terminate (there is no identity left to operate with — see the
    /// EmergencyWipe header and EMERGENCY_WIPE_7b3.md §4.1): that lifecycle step
    /// belongs to the caller, above this method. A no-op (returns []) if the wipe
    /// has not been assembled yet (pre-.ready).
    @discardableResult
    func performEmergencyWipe() async -> [Error] {
        guard let emergencyWipe else { return [] }
        return await emergencyWipe.perform()
    }

    /// Erase everything, then route back to a clean onboarding — there is no
    /// identity left to operate with. Called by SettingsView's erase action (the
    /// `\.eraseEverything` environment action injected on the body). Matches
    /// `bootstrap()`'s store construction; the wiped identity means onboarding
    /// regenerates a fresh one, and leaving `.ready` tears down the stale stack.
    private func eraseEverything() {
        Task { @MainActor in
            _ = await performEmergencyWipe()
            let wrapper = try? SecureEnclaveWrapper(service: enclaveService)
            phase = .onboarding(IdentityStore(service: identityService,
                                              protection: .deviceUnlockOnly,
                                              wrapper: wrapper))
        }
    }
    
    /// Stable bundle-scoped identifier for the Keychain item holding the
    /// long-term identity. Must not change across launches.
    private var identityService: String { "com.aeronyra.identity.v1" }
    
    /// Stable bundle-scoped identifier for the Secure Enclave key
    /// reference. Must not change across launches.
    private var enclaveService: String { "com.aeronyra.enclave.v1" }
    
    /// Stable bundle-scoped identifier for the persistent session store's DEK.
    /// Must not change across launches, or the session store reads as wiped.
    private var sessionKeyService: String { "com.aeronyra.sessionkey.v1" }
    
    /// Stable bundle-scoped identifier for the Nostr identity secret (Phase 8a).
    /// Must not change across launches, or the internet identity reads as absent
    /// and is regenerated. The emergency wipe targets this same id.
    private var nostrIdentityService: String { "com.aeronyra.nostr.v1" }
    
    /// The Nostr relays PILLAR 2 connects to (Phase 8d). Multi-relay for
    /// availability: each relay is an independent websocket, publish fans out to
    /// all, and inbound from all is merged (the router dedups by envelope id), so
    /// one relay having a bad day (e.g. a 503) can't kill the internet pillar.
    /// Widely-used, independently-operated public relays. Both devices sharing the
    /// same list is what makes their subscriptions overlap. A future settings
    /// screen swaps this array — the transport already takes a list.
    private var nostrRelayURLs: [String] {
        [
            "wss://relay.primal.net",
            "wss://nos.lol",
            "wss://relay.damus.io",
        ]
    }
    
    private func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([
            Peer.self,
            Conversation.self,
            Message.self,
        ])
        
        // Force-create Application Support. On a fresh install it may not exist
        // yet and the sandbox blocks creating through a missing parent — the
        // same condition behind the CoreData "Failed to create file; code = 2"
        // spew on first launch. Creating it here (and tagging it with Data
        // Protection) both fixes that and makes the store encrypted at rest.
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        // completeUntilFirstUserAuthentication — NOT complete — because the
        // MessageInbox writes to this store when receiving in the background
        // while the device is locked, which `complete` would forbid. The
        // directory attribute governs files created afterward (e.g. fresh
        // -wal/-shm sidecars); the explicit per-file pass below covers a store
        // that already exists from a prior build. Ledger item 6 (at-rest).
        applyDataProtection(toPath: appSupport.path)
        
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: config)
        
        // Tag the actual store files (the default SwiftData store lives at
        // Application Support/default.store, confirmed by the CoreData logs).
        for name in ["default.store", "default.store-wal", "default.store-shm"] {
            applyDataProtection(toPath: appSupport.appendingPathComponent(name).path)
        }
        return container
    }
    
    /// Best-effort Data Protection tag. `try?` because it's a no-op/unsupported
    /// on some platforms (e.g. the Mac host) and a sidecar may not exist yet.
    private func applyDataProtection(toPath path: String) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: path)
    }
}

// MARK: - ReadyView

/// Owns the main-actor `MessageInbox` for the lifetime of the .ready phase.
///
/// The inbox is built inside a `.task` (guaranteed main actor in SwiftUI) so
/// that accessing `container.mainContext` and constructing the `@MainActor`
/// `MessageInbox` are both isolation-correct under Swift 6 — no main-actor work
/// happens in `bootstrap()`. Once built, the inbox is injected into the
/// environment (for the composer in ConversationView) and its event loop runs.
///
/// PRESENCE-BY-IDENTITY (Phase 7a): ReadyView also consumes the coordinator's
/// `reachablePeers` stream — the BLE-link ↔ crypto-identity resolution — and
/// mirrors it into the environment's `MeshPresence`. This is the lifetime- and
/// isolation-correct home for it: the coordinator is non-optional here, the
/// `.task` runs on the main actor, and `presence` is the same instance ContentView
/// injects above the phase switch. (Done alongside, not inside, the inbox loop —
/// presence flows even before the inbox exists.)
///
/// DELIVERY STATE (Phase 7b.2a): ReadyView also feeds the router's
/// `deliveryUpdates` stream into the inbox, so router-side state transitions land
/// on the matching SwiftData row. Single-consumer: this is the ONLY reader of
/// that stream. Today the stream is effectively inert (the router emits `.sent`
/// echoes only); it becomes meaningful once acks + a delivery timeout land
/// (Phase 7b.2b) and start producing real `.delivered` / `.relayed` /
/// timed-out `.notDelivered` transitions.
private struct ReadyView: View {
    let container: ModelContainer
    let coordinator: FirstContactCoordinator
    let router: MessageRouter
    let pairingService: PairingService
    
    @State private var inbox: MessageInbox?

    /// The shared presence object injected by ContentView. We write its
    /// identity-resolved set from the coordinator's `reachablePeers` stream.
    @Environment(MeshPresence.self) private var presence

    /// Drives the ephemeral-media reaper (SEC-6 / P3): re-run it every time the
    /// app returns to the foreground, so media that crossed its window while the
    /// app was suspended is wiped without waiting for a relaunch or a render.
    @Environment(\.scenePhase) private var scenePhase

    /// The local-notification façade (N1), injected by BeaconApp (which installed
    /// it as the UNUserNotificationCenter delegate at app init). ReadyView owns
    /// the PERMISSION MOMENT: ask the first time the app is foreground with at
    /// least one contact — never on a fresh, contactless install.
    @Environment(LocalNotifier.self) private var notifier
    
    var body: some View {
        Group {
            if let inbox {
                ChatsRootView()
                    .environment(inbox)
                    .environment(pairingService)
                    .task { await inbox.run() }
                    .task { await inbox.runDeliveryUpdates(router.deliveryUpdates) }   // 7b.2a
                    .onOpenURL { url in
                        // STEP 7d-3: a tapped aeronyra://invite/… link. The
                        // pairing service decodes, establishes, echoes, and
                        // enrolls (unverified). Ignored if it isn't an invite.
                        Task { try? await pairingService.redeemInvite(url.absoluteString) }
                    }
            } else {
                Color.bgApp.ignoresSafeArea()
            }
        }
        .modelContainer(container)
        .task {
            if inbox == nil {
                let built = MessageInbox(modelContext: container.mainContext,
                                         coordinator: coordinator,
                                         router: router,
                                         isVerified: { pairingService.isVerified($0) },
                                         notifier: notifier)   // N2 — banner at the persist seams
                inbox = built
                // Ephemeral media reaper (SEC-6 / P3), boot pass: wipe inbound
                // media that crossed its window while the app was closed — the
                // render-time wipes only cover rows that get drawn, so a
                // never-opened conversation is this pass's whole point.
                built.reapExpiredMedia()
                // Boot reconcile (P4): rows a relaunch stranded non-terminal
                // (the router's outbox/timers are in-memory) become
                // .notDelivered so the flush below — and the user's resend
                // affordance — can see them. Persisted .cast rows are left
                // alone (relay-committed; "will surface" stays true).
                // Classify-only: transports may still be starting, no sends.
                built.reconcileBootOrphans()
                // Initial auto-retry: any peers already reachable at launch get
                // their stuck `.notDelivered` messages re-sent now. No-op if the
                // set is empty (presence not resolved yet — the stream trigger
                // below catches it once a peer comes up).
                await built.flushUndelivered(toReachableKeys: presence.reachablePeerKeys)
                // N1 — notification permission. The boot task runs foreground,
                // so this covers the launch-with-contacts case; the scenePhase
                // hook below covers pairing-then-backgrounding. Idempotent: the
                // notifier only prompts while the system status is .notDetermined.
                await requestNotificationAuthIfPaired()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Foreground pass of the reaper (idempotent; nil-safe before the
            // boot task has built the inbox — that task runs its own pass).
            if phase == .active {
                inbox?.reapExpiredMedia()
                // N1 — the other half of the permission moment (see boot task).
                Task { await requestNotificationAuthIfPaired() }
            }
        }
        .task {
            // Mirror identity-resolved presence into MeshPresence for the app's
            // lifetime. Unbounded-buffered upstream, so anything emitted before
            // this starts (e.g. the launch catch-up onReachable) is delivered.
            //
            // AUTO-RETRY (Phase 7c, Tier 3): when the reachable set GAINS a peer
            // (a transition, not every tick), flush any `.notDelivered` messages
            // bound for now-reachable peers. We diff against the previous set so
            // a steady stream of identical presence updates doesn't re-flush.
            //
            // MEDIA RE-DRIVE (ISSUE-3b): the SAME diff, on the LOSS side. When the
            // set drops a peer, re-drive that peer's still-in-flight media rows over
            // Nostr (a transfer that committed to BLE then lost the link mid-burst
            // is stuck at `.sent`, so the gain-side flush never reaches it). This is
            // the media analogue of the coordinator's text `rerouteToNostr`, which
            // fires off the same departure event.
            var previous = Set<Data>()
            for await keys in coordinator.reachablePeers {
                presence.reachablePeerKeys = keys
                let newlyReachable = keys.subtracting(previous)
                let departed = previous.subtracting(keys)
                previous = keys
                if !newlyReachable.isEmpty {
                    await inbox?.flushUndelivered(toReachableKeys: keys)
                }
                if !departed.isEmpty {
                    await inbox?.redriveInFlightMedia(toDepartedKeys: departed)
                }
            }
        }
    }

    /// N1 — the permission moment. Ask for notification authorization only once
    /// the app is foreground AND at least one contact exists (a Peer row —
    /// created at establishment, so "has paired with someone real"). A fresh
    /// install never sees the prompt. Re-invocations are free: the notifier
    /// no-ops unless the system status is still .notDetermined, so the prompt
    /// can never re-appear after the user has answered.
    private func requestNotificationAuthIfPaired() async {
        let contacts = (try? container.mainContext
            .fetchCount(FetchDescriptor<Peer>())) ?? 0
        guard contacts >= 1 else { return }
        await notifier.requestAuthorizationIfNeeded()
    }
}

// MARK: - ChatsRootView

/// The app's single root — the Chats list in one NavigationStack. There is no
/// tab bar: the Nearby/radar screen was removed with the closed-contact pivot
/// (you don't discover strangers; you pair deliberately). Add-contact and
/// Settings live in the Chats top bar. `MeshPresence` is injected above by
/// ContentView and read here for per-row and per-conversation reachability.
private struct ChatsRootView: View {
    var body: some View {
        NavigationStack {
            HomeView()
        }
        .tint(Color.brand)
    }
}
