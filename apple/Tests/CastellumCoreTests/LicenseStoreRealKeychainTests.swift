// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Riera Technologies Ltd
import XCTest
@testable import Castellum

/// task 2505's explicit, opt-in coverage of the REAL Keychain code path,
/// mirroring `AccountStoreRealKeychainTests`.
///
/// Every other `LicenseStore` test runs against `InMemoryKeychainBacking`
/// (the `LicenseStore.init` default under `TestHost.isActive` — see
/// `KeychainBacking.swift`), so this is the only place `RealKeychainBacking`
/// — and therefore the actual `SecItemAdd`/`Update`/`CopyMatching`/`Delete`
/// calls — still run for `LicenseStore`. It exists so that path keeps real
/// coverage without reintroducing the leak/hang risk that made #2499 (and,
/// at far larger scale, #2505) dangerous.
///
/// Skipped by default: opt in with `CASTELLUM_RUN_REAL_KEYCHAIN_TEST=1`.
/// Uses its own throwaway `com.castellum.license.test.real-keychain.<uuid>`
/// namespace (never `LicenseStore.defaultService` or a `.profile.*` one) and
/// a tight `executionTimeAllowance`, so a genuinely hung real Keychain call
/// fails fast instead of hanging the whole `xcodebuild test` run.
final class LicenseStoreRealKeychainTests: XCTestCase {
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 20
    }

    func testRoundTripAgainstTheRealKeychain() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CASTELLUM_RUN_REAL_KEYCHAIN_TEST"] == "1",
            "opt-in only; set CASTELLUM_RUN_REAL_KEYCHAIN_TEST=1 to exercise the real Keychain")

        let service = "com.castellum.license.test.real-keychain.\(UUID().uuidString)"
        let store = LicenseStore(service: service, keychain: RealKeychainBacking())
        defer { try? store.deleteAll() }

        XCTAssertNil(try store.load())

        let record = LicenseRecord(
            trialStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
            licenseKey: "CASTM-AAAA-BBBB-CCCC-DDDD",
            licenseExpiresAt: nil, lastValidatedAt: nil)
        try store.save(record)
        XCTAssertEqual(try store.load(), record)

        try store.deleteAll()
        XCTAssertNil(try store.load())
    }
}
