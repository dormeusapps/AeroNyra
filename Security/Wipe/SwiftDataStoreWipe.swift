//
//  SwiftDataStoreWipe.swift
//  Security/Wipe
//
//  CRYPTO-ERASE, message-store step (STEP 7b-2 · GROUND_TRUTH §3.7).
//
//  A `Wipeable` that erases the app's SwiftData message store by DELETING its
//  on-disk files. This is the honest, deliberate posture for message bodies at
//  this stage — NOT a cryptographic shred:
//
//    • The store (`default.store` + its `-wal` / `-shm` sidecars) is protected
//      at rest by iOS Data Protection (the composition root tags it
//      `.completeUntilFirstUserAuthentication`), NOT by an app-held destroyable
//      DEK. There is no key we can throw away to make these bytes unreadable, so
//      the honest erase is to delete the files. This mirrors Signal's posture —
//      it does not crypto-shred its message DB either.
//
//    • The stronger "messages under an app-held DEK" (true instant crypto-erase
//      of bodies) is a real persistence re-architecture, deferred to the end of
//      the roadmap (GROUND_TRUTH §3.7 / deferred-to-last). When that lands, this
//      step is replaced by a DEK destroy; the wipe wiring above it does not change.
//
//  WHERE THE STORE LIVES. The app builds its `ModelContainer` with a DEFAULT
//  `ModelConfiguration` (no custom `url:`), so SwiftData uses its default store
//  location: `Application Support/default.store`, with `-wal` and `-shm`
//  sidecars alongside. `ContentView.makeModelContainer()` resolves Application
//  Support as `FileManager.url(for: .applicationSupportDirectory, in:
//  .userDomainMask, …)` and tags exactly those three filenames. This type
//  resolves the SAME directory and targets the SAME three names, so the two
//  definitions of "where the store is" stay in lockstep. If the container is
//  ever moved to a custom `ModelConfiguration(url:)`, this resolver must move
//  with it (see `Self.defaultStoreDirectory()`).
//
//  CONTAINER LIFECYCLE (residual risk, tracked for 7b-3). A live `ModelContainer`
//  / `ModelContext` may still hold the store open or hold unflushed WAL pages when
//  these files are deleted; a background write could in principle recreate a
//  sidecar after deletion. This type does NOT reach into the SwiftUI view state
//  that owns the container (`ReadyView`) to tear it down — that is neither
//  reachable from here nor this step's job. The mitigation is the emergency
//  wipe's own lifecycle contract: after a wipe the app routes back to onboarding
//  / terminates (see EmergencyWipe header), which releases `ReadyView` and its
//  container. The exact delete-then-teardown ORDERING is decided when the
//  composition root constructs and invokes the wipe (7b-3); this step provides
//  the durable file erasure the ordering builds on. Recorded as an accepted,
//  to-be-sequenced exposure in the 7b-3 threat note.
//
//  IDEMPOTENT. A missing file is success (nothing to erase is a clean erase), so
//  re-wiping already-wiped state does not throw — satisfying the `Wipeable`
//  contract. A real filesystem failure (a file exists but cannot be removed) IS
//  surfaced, so `EmergencyWipe`'s best-effort collector records it.
//

import Foundation

/// Erases the app's SwiftData message store (Peer / Conversation / Message rows)
/// by deleting `default.store` and its `-wal` / `-shm` sidecars. See file header
/// for why this is a file-delete and not a crypto-shred.
public struct SwiftDataStoreWipe: Wipeable {

    /// The directory holding the store files. Injectable for tests; defaults to
    /// the real Application Support directory the `ModelContainer` uses.
    private let directory: URL

    /// The three files a default SwiftData store comprises. `default.store` is
    /// the primary DB; `-wal` (write-ahead log) and `-shm` (shared memory) are
    /// SQLite sidecars that may or may not exist at any given moment.
    private static let storeFileNames = [
        "default.store",
        "default.store-wal",
        "default.store-shm",
    ]

    /// - Parameter directory: the folder containing the store files. Defaults to
    ///   the real Application Support directory (resolved identically to the
    ///   composition root). Tests pass a temporary directory.
    public init(directory: URL? = nil) throws {
        if let directory {
            self.directory = directory
        } else {
            self.directory = try Self.defaultStoreDirectory()
        }
    }

    /// The default SwiftData store directory — Application Support in the user
    /// domain, resolved the SAME way `ContentView.makeModelContainer()` does so
    /// the two agree on the store location. `create: false` here: we are erasing,
    /// never provisioning. If Application Support does not exist at all, there is
    /// nothing to wipe (handled as clean success in `wipe()`).
    public static func defaultStoreDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: false)
    }

    /// Delete the store and its sidecars. Best-effort per file: a file that does
    /// not exist is skipped (clean), a file that exists but cannot be removed
    /// throws — and because every file is attempted before rethrowing, one
    /// stubborn sidecar does not leave the primary store behind.
    public func wipe() async throws {
        let fm = FileManager.default
        var firstError: Error?

        for name in Self.storeFileNames {
            let url = directory.appendingPathComponent(name)
            // Missing file → nothing to erase → clean. Only attempt removal for
            // files that actually exist, so absence never manufactures an error.
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
            } catch {
                // Record the first real failure but keep deleting the rest, so a
                // single un-removable sidecar can't strand the primary store.
                if firstError == nil { firstError = error }
            }
        }

        if let firstError { throw firstError }
    }
}
