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
//   • MeshPresence  — fed from the transport's reachability, read by Nearby.
//   • SignalSessionStore — built from the SAME loaded identity (one identity
//     end to end).
//   • FirstContactCoordinator — marries transport + store for carrier-neutral
//     first contact. This view is the SOLE consumer of the transport's three
//     AsyncStreams (each delivers an event once) and fans them out to presence
//     and the coordinator.
//   • MessageInbox — owned by ReadyView (below), on the main actor, so the
//     coordinator's SessionEvents become SwiftData Peer/Conversation/Message.
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

    /// Live radio presence, fed from the transport and read by NearbyView.
    @State private var presence = MeshPresence()

    /// The single secure-session store, built from the real loaded identity
    /// once we reach .ready. nil until then.
    @State private var sessionStore: SignalSessionStore?

    /// Drives carrier-neutral first contact (bundle exchange + establishment).
    @State private var coordinator: FirstContactCoordinator?

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
                if let coordinator {
                    ReadyView(container: container, coordinator: coordinator)
                } else {
                    launchScreen   // unreachable: coordinator is set before .ready
                }
            }
        }
        .preferredColorScheme(.dark)
        .environment(presence)
        .task {
            // Start the radio, then keep presence in sync AND feed the
            // coordinator newly-reachable links. Main-actor isolated, so
            // touching `presence` here is safe; coordinator calls hop to it.
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
            // Inbound sealed envelopes → first-contact / open.
            for await envelope in transport.incoming {
                await coordinator?.onEnvelope(envelope)
            }
        }
        .task {
            // Inbound prekey bundles → first contact.
            for await item in transport.bundles {
                await coordinator?.onBundle(link: item.link, data: item.data)
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
            makeSessionStack(identity: identity)
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
            makeSessionStack(identity: identity)
            phase = .ready(identity, container, store)
        } catch {
            // Stay in onboarding so the user can tap again. A real UX
            // would surface the error; logging suffices for now.
            print("Bootstrap save failed: \(error)")
        }
    }

    // MARK: - Construction

    /// Build the secure-session store (from the loaded identity, so the session
    /// layer uses the SAME Enclave-bound identity as the rest of the app) and
    /// the first-contact coordinator that drives bundle exchange + establishment.
    private func makeSessionStack(identity: IdentityKeypair) {
        let secure = SignalSessionStore(appIdentity: identity)
        let coord = FirstContactCoordinator(store: secure, transport: transport)
        sessionStore = secure
        coordinator = coord
        print("session store ready · identity \(secure.localIdentity.userIDHex.prefix(16))…")
        // Catch up on any links that already formed before the coordinator
        // existed (e.g. a peer already in range at launch).
        let ids = presence.reachableIDs
        Task { await coord.onReachable(ids) }
    }

    /// Stable bundle-scoped identifier for the Keychain item holding the
    /// long-term identity. Must not change across launches.
    private var identityService: String { "com.aeronyra.identity.v1" }

    /// Stable bundle-scoped identifier for the Secure Enclave key
    /// reference. Must not change across launches.
    private var enclaveService: String { "com.aeronyra.enclave.v1" }

    private func makeModelContainer() throws -> ModelContainer {
        let schema = Schema([
            Peer.self,
            Conversation.self,
            Message.self,
        ])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: config)
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
private struct ReadyView: View {
    let container: ModelContainer
    let coordinator: FirstContactCoordinator

    @State private var inbox: MessageInbox?

    var body: some View {
        Group {
            if let inbox {
                MainTabView()
                    .environment(inbox)
                    .task { await inbox.run() }
            } else {
                Color.bgApp.ignoresSafeArea()
            }
        }
        .modelContainer(container)
        .task {
            if inbox == nil {
                inbox = MessageInbox(modelContext: container.mainContext,
                                     coordinator: coordinator)
            }
        }
    }
}

// MARK: - MainTabView

/// The two-tab spine of the app — Chats and Nearby. Each tab gets its
/// own NavigationStack so push state is independent per tab.
private struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                ChatsListView()
            }
            .tabItem {
                Label("Chats", systemImage: "message")
            }

            NavigationStack {
                NearbyView()
            }
            .tabItem {
                Label("Nearby",
                      systemImage: "dot.radiowaves.left.and.right")
            }
        }
        .tint(Color.brand)
    }
}
