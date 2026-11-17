// Castellum - Tests for S61's Keychain licence store. Every test uses an
// isolated per-test Keychain service namespace (mirrors AccountStoreTests)
// so it never touches the real profile's licence item, and tears the
// namespace down in tearDown — see CLAUDE.md gotcha #2 and the
// castellum-tests-touched-real-keychain lesson.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Riera Technologies Ltd

import XCTest
@testable import Castellum

final class LicenseStoreTests: XCTestCase {
    private var service = ""
    private var store: LicenseStore!

    override func setUp() {
        super.setUp()
        service = "com.castellum.license.test.\(UUID().uuidString)"
        store = LicenseStore(service: service)
    }

    override func tearDown() {
        try? store.deleteAll()
        super.tearDown()
    }

    private func record(day offset: TimeInterval = 0) -> LicenseRecord {
        LicenseRecord(
            trialStartedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            licenseKey: nil, licenseExpiresAt: nil, lastValidatedAt: nil)
    }

    func testLoadOnAFreshNamespaceReturnsNil() throws {
        XCTAssertNil(try store.load())
    }

    func testSaveThenLoadRoundTripsExactly() throws {
        let r = LicenseRecord(
            trialStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
            licenseKey: "CASTM-AAAA-BBBB-CCCC-DDDD",
            licenseExpiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastValidatedAt: Date(timeIntervalSince1970: 1_700_050_000))
        try store.save(r)
        XCTAssertEqual(try store.load(), r)
    }

    func testSaveReplacesTheExistingRecord() throws {
        try store.save(record(day: 0))
        try store.save(record(day: 1))
        XCTAssertEqual(try store.load(), record(day: 1))
    }

    func testDeleteAllLeavesLoadReturningNil() throws {
        try store.save(record())
        try store.deleteAll()
        XCTAssertNil(try store.load())
    }

    func testDeleteAllOnAnEmptyNamespaceIsNotAnError() throws {
        XCTAssertNoThrow(try store.deleteAll())
    }

    /// The 0.3.5-lesson case for AccountStore, replayed for LicenseStore: two
    /// different namespaces (as two different profile directories would
    /// derive) must never see each other's record.
    func testTwoStoresWithDifferentNamespacesNeverSeeEachOthersRecord() throws {
        let other = LicenseStore(service: service + ".other")
        defer { try? other.deleteAll() }
        try store.save(record(day: 0))
        try other.save(record(day: 99))
        XCTAssertEqual(try store.load(), record(day: 0))
        XCTAssertEqual(try other.load(), record(day: 99))
    }

    /// Same profile directory must always derive the same namespace (stable
    /// across process restarts — the Keychain item must be found again);
    /// different profile directories must derive different, isolated
    /// namespaces — mirroring `AccountStoreTests.testServiceIsScopedToTheProfileDirectory`.
    func testServiceIsScopedToTheProfileDirectoryAndIsolated() throws {
        XCTAssertEqual(LicenseStore.service(forProfileDirectory: nil), LicenseStore.defaultService)

        let a = URL(fileURLWithPath: "/tmp/castellum-license-a", isDirectory: true)
        let b = URL(fileURLWithPath: "/tmp/castellum-license-b", isDirectory: true)
        let serviceA = LicenseStore.service(forProfileDirectory: a)
        XCTAssertNotEqual(serviceA, LicenseStore.defaultService)
        XCTAssertEqual(serviceA, LicenseStore.service(forProfileDirectory: a))
        XCTAssertEqual(
            serviceA,
            LicenseStore.service(forProfileDirectory: URL(fileURLWithPath: "/tmp/./castellum-license-a/")))
        XCTAssertNotEqual(serviceA, LicenseStore.service(forProfileDirectory: b))
        // Never collides with AccountStore's own namespace for the same dir.
        XCTAssertNotEqual(serviceA, AccountStore.service(forProfileDirectory: a))

        let storeA = LicenseStore(profileDirectory: a)
        let storeB = LicenseStore(profileDirectory: b)
        defer { try? storeA.deleteAll(); try? storeB.deleteAll() }
        try storeA.save(record(day: 1))
        try storeB.save(record(day: 2))
        XCTAssertEqual(try storeA.load(), record(day: 1))
        XCTAssertEqual(try storeB.load(), record(day: 2))
    }
}
