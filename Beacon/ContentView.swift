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
//  The BLE transport is started here at launch and lives for the whole
//  app lifetime. Its live reachability feeds a MeshPresence, injected
//  into the environment so the Nearby screen can show real radar/presence.
//
//  The secure-session store (libsignal) is also built here, from the SAME
//  loaded identity, so there is ONE identity end to end (no separate test
//  identity for the session layer). This is the seam the first-contact
//  handshake and the send path build on.
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
    /// once we reach .ready. nil until then. Owns prekeys, sessions, and the
    /// libsignal engine behind the SecureSessionStore boundary.
    @State private var sessionStore: SignalSessionStore?

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
                MainTabView()
                    .modelContainer(container)
            }
        }
        .preferredColorScheme(.dark)
        .environment(presence)
        .task {
            // Bring the radio up, then keep MeshPresence in sync with the live
            // set of linked peers. This .task is main-actor isolated (Views
            // are @MainActor), so touching `presence` here is safe.
            do {
                try await transport.start()
            } catch {
                print("BLE start failed: \(error)")
            }
            for await ids in transport.reachabilityUpdates {
                presence.reachableIDs = ids
            }
        }
        .task {
            // Inbound diagnostics until the send path routes envelopes into the
            // real transcript. Harmless logging — not a temporary trigger.
            for await envelope in transport.incoming {
                print("inbound envelope id=\(envelope.id) bytes=\(envelope.ciphertext.count)")
            }
        }
    }

    private var launchScreen: some View {
        Color.bgApp.ignoresSafeArea()
    }

    // MARK: - Bootstrap

    /// Try to load an existing identity. If found, build the persistent
    /// ModelContainer + secure-session store and enter .ready. If not, route
    /// to Onboarding.
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
            makeSessionStore(identity: identity)
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
    /// Persist it, build the container + secure-session store, enter .ready.
    private func completeOnboarding(identity: IdentityKeypair,
                                    store: IdentityStore) {
        do {
            try store.save(identity, overwrite: true)
            let container = try makeModelContainer()
            makeSessionStore(identity: identity)
            phase = .ready(identity, container, store)
        } catch {
            // Stay in onboarding so the user can tap again. A real UX
            // would surface the error; logging suffices for now.
            print("Bootstrap save failed: \(error)")
        }
    }

    // MARK: - Construction

    /// Build the secure-session store from the loaded identity, so the session
    /// layer uses the SAME (Enclave-bound) identity as the rest of the app —
    /// one identity end to end. Held for the app's lifetime.
    private func makeSessionStore(identity: IdentityKeypair) {
        let secure = SignalSessionStore(appIdentity: identity)
        sessionStore = secure
        print("session store ready · identity \(secure.localIdentity.userIDHex.prefix(16))…")
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
