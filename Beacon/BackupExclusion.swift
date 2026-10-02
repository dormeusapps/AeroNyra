//
//  BackupExclusion.swift
//  Beacon
//
//  Keeps the app's data out of device and iCloud backups. INVARIANT: nothing
//  readable leaves the device. Every store the app writes lives under Library/
//  Application Support — the SwiftData store (messages, contacts, media) with
//  its -wal/-shm sidecars, BeaconSignalStore/ (the sealed stores and session
//  snapshot), the terms acceptance — so the whole folder is marked excluded
//  from backup, in place, at every launch before any store is opened
//  (`ContentView.bootstrap()`, first line). A folder's exclusion covers what is
//  in it, including files created later. Idempotent and cheap: one attribute
//  write and one read.
//
//  A failure never blocks launch: it logs one line (no path, no identifier)
//  and boot continues. The app then works as before; only the backup
//  exclusion is missing for this launch, and the next launch tries again.
//
//  Not covered here (later work): UserDefaults (Library/Preferences), which
//  iOS backs up and which cannot be excluded this way. Keychain items are
//  ThisDeviceOnly and never sync (see their stores).
//
//  Lives in Beacon/ (a synchronized folder), not Screens/ (a classic group).
//

import Foundation

enum BackupExclusion {

    /// Marks `directory` (created if missing) excluded from backup and returns
    /// the value read back: true when it is excluded. Never throws: a failure
    /// logs one line and returns false, so the caller can keep booting.
    @discardableResult
    static func excludeFromBackup(_ directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            url.removeAllCachedResourceValues()
            return try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
        } catch {
            RedactLog.event("backup: exclusion FAILED — app data may be included in backups", "\(type(of: error))")
            return false
        }
    }

    /// The boot entry: excludes Library/Application Support. Called first in
    /// `ContentView.bootstrap()`, before the terms gate reads its file and
    /// before the model container or the session stack is built.
    static func excludeApplicationSupport() {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else {
            RedactLog.event("backup: exclusion FAILED — app data may be included in backups", "no folder")
            return
        }
        let excluded = excludeFromBackup(appSupport)
        #if DEBUG
        RedactLog.event("backup: Application Support excluded=\(excluded)", "")
        #else
        _ = excluded
        #endif
    }
}
