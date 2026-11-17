// Castellum - Keychain-backed licence store (S61).
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Riera Technologies Ltd
//
// Mirrors `AccountStore`'s exact shape: a `kSecClassGenericPassword` item,
// namespaced per profile via `AccountStore.service(forProfileDirectory:)`
// (reused directly — it's a `static func`, not a duplicated helper), so a
// test's temp-profile `LicenseStore` can never read or write the real
// profile's licence item, matching CLAUDE.md gotcha #2's Keychain-testing
// discipline. Licence key and trial/expiry state are stored ONLY here — never
// in `UserDefaults`/`Preferences.swift`, never logged: a licence key is a
// secret, same handling class as an IMAP/SMTP password.
//
// task 2505: same leak pattern as #2499 (see `KeychainBacking.swift`),
// at much larger scale — `AppModel.init` unconditionally does a
// `licenseStore.load()` + (on first launch) `licenseStore.save()` against the
// REAL Keychain, and every one of the ~18 test files that construct an
// `AppModel` triggered that, not just the license-specific test files
// (2113 stale `com.castellum.license.profile.*` items vs #2499's 17-18).
// Routed through the same `KeychainBacking` protocol AccountStore uses —
// it's already a generic seam over `(service, account) -> Data`, so it needs
// no changes, just reuse. This store never calls `SecItem*` directly, so
// under XCTest (`TestHost.isActive`) it is architecturally impossible for
// `LicenseStoreTests`/`LicenseAppModelTests` to reach the real login
// Keychain and hang the way `AccountStoreTests` used to.

import Foundation
import Security

struct LicenseStore {
    /// Keychain service namespace. Overridable so tests use an isolated
    /// namespace (mirrors `AccountStore`'s own `init(service:)` test seam).
    private let service: String
    /// The four SecItem* primitives, behind a protocol. See `KeychainBacking.swift`.
    private let keychain: KeychainBacking
    /// The single fixed Keychain "account" name within `service` — there is
    /// only ever one licence record per profile, unlike `AccountStore`'s
    /// one-item-per-mail-account shape.
    private static let account = "castellum-license"

    /// The real profile's namespace. Licence records created by shipped
    /// builds live here.
    static let defaultService = "com.castellum.license"

    /// `keychain`'s default mirrors `AccountStore.init`'s fix for #2499:
    /// under XCTest OR the S64 GUI launch probe
    /// (`TestHost.usesInMemoryKeychain`) it routes to the process-wide
    /// in-memory backing (shared with `AccountStore` — different service
    /// namespaces keep the two stores' items apart within it), so no test —
    /// `LicenseStoreTests`, `LicenseAppModelTests`, or any future test that
    /// just calls `LicenseStore(service:)`/`LicenseStore(profileDirectory:)`
    /// or builds an `AppModel` — can reach a real `SecItem*` call. Production
    /// (`TestHost.usesInMemoryKeychain == false`) gets a fresh
    /// `RealKeychainBacking()`, behaviourally identical to the inline
    /// `SecItem*` calls this file made before.
    init(
        service: String = LicenseStore.defaultService,
        keychain: KeychainBacking = TestHost.usesInMemoryKeychain
            ? InMemoryKeychainBacking.shared : RealKeychainBacking()
    ) {
        self.service = service
        self.keychain = keychain
    }

    /// The Keychain namespace this store reads and writes.
    var serviceName: String { service }

    /// Keychain namespace for a profile, mirroring `AccountStore.service(forProfileDirectory:)`
    /// exactly (same derivation, different base name) so the real profile
    /// and every test/disposable profile get independent namespaces for
    /// BOTH stores from the same profile directory.
    init(
        profileDirectory: URL?,
        keychain: KeychainBacking = TestHost.usesInMemoryKeychain
            ? InMemoryKeychainBacking.shared : RealKeychainBacking()
    ) {
        self.init(service: LicenseStore.service(forProfileDirectory: profileDirectory), keychain: keychain)
    }

    static func service(forProfileDirectory dir: URL?) -> String {
        guard let dir else { return defaultService }
        let base = AccountStore.service(forProfileDirectory: dir)
        // Re-derive relative to OUR default rather than reusing AccountStore's
        // hash verbatim, so a licence namespace never collides with an
        // account namespace even if both derivations ever changed to agree.
        let suffix = base.hasPrefix(AccountStore.defaultService)
            ? String(base.dropFirst(AccountStore.defaultService.count))
            : base
        return "\(defaultService)\(suffix)"
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
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

    /// The stored licence record, or `nil` if this profile has never had one
    /// saved (genuinely first launch).
    func load() throws -> LicenseRecord? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = keychain.copyMatching(query as CFDictionary, result: &item)
        switch status {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.decode }
            return try Self.decoder.decode(LicenseRecord.self, from: data)
        default:
            throw KeychainError.status(status)
        }
    }

    /// Store (or replace) the licence record. Always writes the FULL record
    /// the caller passes — this store stays a dumb store; the "never reset
    /// the trial clock" invariant lives in the caller's call discipline
    /// (`AppModel`'s first-launch-only trial start), matching `AccountStore`'s
    /// own division of responsibility.
    func save(_ record: LicenseRecord) throws {
        let data = try Self.encoder.encode(record)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = keychain.update(baseQuery as CFDictionary, attributesToUpdate: update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = keychain.add(add as CFDictionary)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        default:
            throw KeychainError.status(status)
        }
    }

    /// Test seam: write raw bytes as the stored item, so a test can plant a
    /// corrupt or future-format blob and prove the app never overwrites it.
    func writeRawForTesting(_ data: Data) throws {
        var add = baseQuery
        add[kSecValueData as String] = data
        let status = keychain.add(add as CFDictionary)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    /// Remove the licence record in this store's namespace. For tests and
    /// disposable profiles; never called on the default namespace by the
    /// app (deactivation clears the licence FIELDS via `save`, it does not
    /// delete the whole record — see `AppModel.deactivateLicense`).
    func deleteAll() throws {
        let status = keychain.delete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}
