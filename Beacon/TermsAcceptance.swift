//
//  TermsAcceptance.swift
//  Beacon
//
//  The Terms of Use acceptance record (App Review Guideline 1.2). One small
//  JSON file, `{version, acceptedAt}`, in Application Support:
//
//   • EXCLUDED FROM BACKUP, so a restore (to this or another device) never
//     brings an acceptance back. The record is about THIS install only.
//   • Never in the Keychain, so deleting the app deletes it and a reinstall
//     always shows the terms (Keychain items survive app deletion).
//   • Survives an update, so a user is asked again only when
//     `TermsVersion.current` goes up.
//   • Missing or unreadable means NOT accepted — the gate fails closed.
//
//  Version 1 was a UserDefaults record (`legacyDefaultsKey`). It is never
//  read: everyone who accepted version 1 sees version 2. Recording an
//  acceptance deletes it.
//
//  Erase clears the record (`TermsAcceptanceWipe`, erase steps ONLY). It must
//  never ride `DeviceResidueWipe`: that also runs in the pre-onboarding
//  LeftoverSweep, just AFTER the user accepts, and would delete the fresh
//  acceptance.
//

import Foundation

enum TermsVersion {
    /// Bump when the terms change materially; every install is asked again.
    static let current = 2
}

struct TermsAcceptanceRecord: Codable, Equatable, Sendable {
    let version: Int
    let acceptedAt: Date
}

struct TermsAcceptanceStore: Sendable {

    static let fileName = "terms-acceptance.json"

    /// Version 1's UserDefaults key. Never read; removed on acceptance.
    static let legacyDefaultsKey = "aeronyra.eulaAccepted.v1"

    let directory: URL

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// The real location: the Application Support root.
    static func standard() throws -> TermsAcceptanceStore {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return TermsAcceptanceStore(directory: appSupport)
    }

    /// The saved record, or nil when there is none or it can't be read.
    func load() -> TermsAcceptanceRecord? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? Self.decoder.decode(TermsAcceptanceRecord.self, from: data)
    }

    /// True only when a readable record covers `current`.
    func isAccepted(current: Int = TermsVersion.current) -> Bool {
        guard let record = load() else { return false }
        return record.version >= current
    }

    /// Save an acceptance of `version`, mark the file excluded from backup,
    /// then remove the version 1 defaults record.
    func recordAcceptance(version: Int = TermsVersion.current,
                          at date: Date = Date(),
                          legacyDefaults: UserDefaults = .standard) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(TermsAcceptanceRecord(version: version, acceptedAt: date))
        try data.write(to: fileURL, options: .atomic)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        legacyDefaults.removeObject(forKey: Self.legacyDefaultsKey)
    }

    /// Delete the record. Idempotent: no file is not an error.
    func remove() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Erase step: the next launch shows the terms again (Erase is a fresh
/// start). In the erase's steps ONLY — see the file header.
struct TermsAcceptanceWipe: Wipeable {
    let store: TermsAcceptanceStore
    func wipe() async throws { try store.remove() }
}
