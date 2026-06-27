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

import SwiftUI
import SwiftData

struct ContentView: View {

    private enum Phase {
        case launching
        case onboarding(IdentityStore)
        case ready(IdentityKeypair, ModelContainer, IdentityStore)
    }

    @State private var phase: Phase = .launching

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
    }

    private var launchScreen: some View {
        Color.bgApp.ignoresSafeArea()
    }

    // MARK: - Bootstrap

    /// Try to load an existing identity. If found, build the persistent
    /// ModelContainer and enter .ready. If not, route to Onboarding.
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
    /// Persist it, build the container, enter .ready.
    private func completeOnboarding(identity: IdentityKeypair,
                                    store: IdentityStore) {
        do {
            try store.save(identity, overwrite: true)
            let container = try makeModelContainer()
            phase = .ready(identity, container, store)
        } catch {
            // Stay in onboarding so the user can tap again. A real UX
            // would surface the error; logging suffices for now.
            print("Bootstrap save failed: \(error)")
        }
    }

    // MARK: - Construction

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
