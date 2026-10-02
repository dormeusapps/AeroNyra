// LeftoverSweep.swift
// Security/Wipe
//
// FAILED-ERASE LEFTOVERS — swept before onboarding.
//
// Onboarding is reachable only when the identity load returned `.notFound`
// (BootRouter). So anything else still on this device — a sealed store and
// its key, the session store, the Nostr secret, the SwiftData store, device
// residue — belongs to a PREVIOUS identity: an erase that did not finish and
// was then closed, or a restore onto a new device (the store files and
// UserDefaults come back; the ThisDeviceOnly keys do not). Without this sweep
// the new identity's first boot opens every store with `loadOrCreate` and can
// pick those up: the old allowlist with its verified states, the old Nostr
// secret (the relays then link old and new), the old ledgers and chats.
//
// ORDER: every KEY first (the session DEK, then each store — whose `wipe()`
// is itself key-before-file — then the Nostr secret), then the remaining
// files. A step that fails does not stop the rest; every error is collected,
// and the caller must not route to onboarding over a partial sweep.
//
// On a genuinely fresh install every step is a no-op.
//

import CryptoKit
import Foundation

struct LeftoverSweep {

    /// The Keychain services the sweep targets. The session-key and Nostr
    /// services come from the composition root (the SAME values it loads
    /// with — no second copy of the strings); the stores' default to their own
    /// constants. Tests inject throwaway names so they never touch real items.
    struct Services {
        var sessionKey: String
        var nostrIdentity: String
        var contactAllowlist = ContactAllowlistStore.defaultKeychainService
        var pendingInvites = PendingInvitesStore.defaultKeychainService
        var blockedContacts = BlockedContactsStore.defaultKeychainService
        var eventLedger = ProcessedEventLedgerStore.defaultKeychainService
        var blockHistory = BlockHistoryStore.defaultKeychainService
    }

    /// Deletes the libsignal snapshot file without opening the store.
    struct SessionStoreFileWipe: Wipeable {
        let directory: URL
        func wipe() async throws { try PersistentBeaconStore.removeStoreFile(in: directory) }
    }

    let steps: [any Wipeable]

    /// The full sweep over the real locations. `storeDirectory` is where the
    /// sealed stores and the session snapshot live; `swiftData` and `residue`
    /// are injectable so tests stay off the real app state.
    static func standard(storeDirectory: URL,
                         services: Services,
                         swiftData: any Wipeable,
                         residue: any Wipeable = DeviceResidueWipe()) throws -> LeftoverSweep {
        // The stores are opened with a THROWAWAY key: `wipe()` never reads the
        // file, it destroys the Keychain DEK by service and then removes the
        // file, so nothing here creates a Keychain item.
        let scratch = SymmetricKey(size: .bits256)
        return LeftoverSweep(steps: [
            SessionKeyWipe(service: services.sessionKey),
            try ContactAllowlistStore(directory: storeDirectory, dek: scratch,
                                      keychainService: services.contactAllowlist),
            try PendingInvitesStore(directory: storeDirectory, dek: scratch,
                                    keychainService: services.pendingInvites),
            try BlockedContactsStore(directory: storeDirectory, dek: scratch,
                                     keychainService: services.blockedContacts),
            try ProcessedEventLedgerStore(directory: storeDirectory, dek: scratch,
                                          keychainService: services.eventLedger),
            // v68 §5a: wiped WITHOUT opening (its init would read the file).
            BlockHistoryStore.LeftoverWipe(directory: storeDirectory,
                                           keychainService: services.blockHistory),
            NostrIdentityWipe(service: services.nostrIdentity),
            SessionStoreFileWipe(directory: storeDirectory),
            swiftData,
            residue,
        ])
    }

    /// Run EVERY step, in order, whatever fails; return all errors.
    func run() async -> [Error] {
        var errors: [Error] = []
        for step in steps {
            do { try await step.wipe() } catch { errors.append(error) }
        }
        return errors
    }
}
