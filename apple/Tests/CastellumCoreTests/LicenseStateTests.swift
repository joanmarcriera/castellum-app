// Castellum - Tests for S61's licence state machine. Pure logic, injected
// `now`; no Date() calls and no Keychain access anywhere in this file.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Riera Technologies Ltd

import XCTest
@testable import Castellum

final class LicenseStateTests: XCTestCase {
    private let day: TimeInterval = 86400
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(
        trialStartedAt: Date? = nil, licenseKey: String? = nil,
        licenseExpiresAt: Date? = nil, lastValidatedAt: Date? = nil
    ) -> LicenseRecord {
        LicenseRecord(
            trialStartedAt: trialStartedAt ?? start, licenseKey: licenseKey,
            licenseExpiresAt: licenseExpiresAt, lastValidatedAt: lastValidatedAt)
    }

    // MARK: - Trial day boundaries

    func testDayZeroOfAFreshTrialIsFourteenDaysRemaining() {
        let r = record()
        XCTAssertEqual(r.status(now: start), .trial(daysRemaining: 14))
        XCTAssertTrue(r.isEntitled(now: start))
    }

    func testDayThirteenStillHasOneDayRemaining() {
        let r = record()
        let now = start.addingTimeInterval(13 * day)
        XCTAssertEqual(r.status(now: now), .trial(daysRemaining: 1))
        XCTAssertTrue(r.isEntitled(now: now))
    }

    func testDayFourteenTrialHasExpired() {
        let r = record()
        let now = start.addingTimeInterval(14 * day)
        XCTAssertEqual(r.status(now: now), .trialExpired)
        XCTAssertFalse(r.isEntitled(now: now))
    }

    func testDayFifteenTrialStaysExpired() {
        let r = record()
        let now = start.addingTimeInterval(15 * day)
        XCTAssertEqual(r.status(now: now), .trialExpired)
        XCTAssertFalse(r.isEntitled(now: now))
    }

    func testJustBeforeTrialEndStillCountsAFullDayRemaining() {
        let r = record()
        let now = start.addingTimeInterval(14 * day - 1)
        XCTAssertEqual(r.status(now: now), .trial(daysRemaining: 1))
        XCTAssertTrue(r.isEntitled(now: now))
    }

    // MARK: - Perpetual licence

    func testPerpetualLicenseStaysLicensedIndefinitely() {
        let r = record(licenseKey: "CASTM-AAAA-BBBB-CCCC-DDDD", licenseExpiresAt: nil,
                        lastValidatedAt: start)
        XCTAssertEqual(r.status(now: start), .licensed(expiresAt: nil))
        let farFuture = start.addingTimeInterval(3650 * day)
        XCTAssertEqual(r.status(now: farFuture), .licensed(expiresAt: nil))
        XCTAssertTrue(r.isEntitled(now: farFuture))
    }

    func testActivatedLicenseAlwaysOverridesAnOtherwiseExpiredTrial() {
        // Trial started long ago and would already be expired on its own.
        let trialStart = start.addingTimeInterval(-30 * day)
        let expiresAt = start.addingTimeInterval(365 * day)
        let r = record(trialStartedAt: trialStart, licenseKey: "CASTM-AAAA-BBBB-CCCC-DDDD",
                        licenseExpiresAt: expiresAt, lastValidatedAt: start)
        XCTAssertEqual(r.status(now: start), .licensed(expiresAt: expiresAt))
        XCTAssertTrue(r.isEntitled(now: start))
    }

    // MARK: - Expiring licence: grace and expiry

    func testExpiredLicenseWithLastValidatedWithinGraceIsInGrace() {
        let expiresAt = start
        let lastValidatedAt = start.addingTimeInterval(-1 * day)
        let r = record(licenseKey: "CASTM-AAAA-BBBB-CCCC-DDDD", licenseExpiresAt: expiresAt,
                        lastValidatedAt: lastValidatedAt)
        // 5 days after expiry, but only 6 days past lastValidatedAt — within
        // the 14-day grace window anchored on lastValidatedAt.
        let now = start.addingTimeInterval(5 * day)
        XCTAssertEqual(r.status(now: now), .licensedInGrace(graceDaysRemaining: 8))
        XCTAssertTrue(r.isEntitled(now: now))
    }

    func testExpiredLicensePastGraceIsLicenseExpired() {
        let expiresAt = start
        let lastValidatedAt = start
        let r = record(licenseKey: "CASTM-AAAA-BBBB-CCCC-DDDD", licenseExpiresAt: expiresAt,
                        lastValidatedAt: lastValidatedAt)
        let now = start.addingTimeInterval(15 * day) // 1 day past the 14-day grace
        XCTAssertEqual(r.status(now: now), .licenseExpired)
        XCTAssertFalse(r.isEntitled(now: now))
    }

    func testExpiredLicenseWithNoLastValidatedAtHasNoGraceToFallBackOn() {
        // Activation somehow succeeded without ever setting lastValidatedAt
        // (shouldn't happen in practice, but the state machine must still be
        // total and correct): no grace anchor means straight to expired.
        let r = record(licenseKey: "CASTM-AAAA-BBBB-CCCC-DDDD",
                        licenseExpiresAt: start, lastValidatedAt: nil)
        let now = start.addingTimeInterval(1 * day)
        XCTAssertEqual(r.status(now: now), .licenseExpired)
    }

    func testExactGraceBoundaryDayFourteenPastLastValidatedIsExpired() {
        let expiresAt = start
        let lastValidatedAt = start
        let r = record(licenseKey: "CASTM-AAAA-BBBB-CCCC-DDDD", licenseExpiresAt: expiresAt,
                        lastValidatedAt: lastValidatedAt)
        let now = start.addingTimeInterval(14 * day)
        XCTAssertEqual(r.status(now: now), .licenseExpired)
        let justBefore = start.addingTimeInterval(14 * day - 1)
        if case .licensedInGrace = r.status(now: justBefore) {
            // expected
        } else {
            XCTFail("expected grace just before the 14-day boundary, got \(r.status(now: justBefore))")
        }
    }

    // MARK: - isEntitled

    func testIsEntitledMatchesEachStatusCase() {
        XCTAssertTrue(LicenseStatus.trial(daysRemaining: 1).isEntitled)
        XCTAssertFalse(LicenseStatus.trialExpired.isEntitled)
        XCTAssertTrue(LicenseStatus.licensed(expiresAt: nil).isEntitled)
        XCTAssertTrue(LicenseStatus.licensedInGrace(graceDaysRemaining: 1).isEntitled)
        XCTAssertFalse(LicenseStatus.licenseExpired.isEntitled)
    }

    func testStatusNeverUsesATimeEarlierThanTheHighWaterMark() {
        var r = record()
        r.lastSeenAt = start.addingTimeInterval(20 * day)
        XCTAssertEqual(r.status(now: start), .trialExpired)
        XCTAssertNil(r.advancingLastSeen(to: start), "an earlier time is not worth persisting")
        XCTAssertEqual(record().advancingLastSeen(to: start)?.lastSeenAt, start)
    }

    func testRecordsSavedBeforeLastSeenAtExistedStillDecode() throws {
        let json = #"{"trialStartedAt":"2023-11-14T22:13:20Z"}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let r = try d.decode(LicenseRecord.self, from: Data(json.utf8))
        XCTAssertNil(r.lastSeenAt)
    }

    // MARK: - #2263 slice 1

    func testNotEnforcedNeverExpiresTheTrial() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let r = LicenseRecord(trialStartedAt: start, licenseKey: nil, licenseExpiresAt: nil, lastValidatedAt: nil)
        let later = start.addingTimeInterval(400 * 86400)
        XCTAssertEqual(r.status(now: later, trialEnforced: false), .trial(daysRemaining: LicenseRecord.trialDays))
        XCTAssertEqual(r.status(now: later), .trialExpired, "the pure default still enforces")
    }

    func testNotEnforcedStillHonoursAnActiveOrExpiredLicence() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let licensed = LicenseRecord(trialStartedAt: start, licenseKey: "K", licenseExpiresAt: nil, lastValidatedAt: start)
        XCTAssertEqual(licensed.status(now: start, trialEnforced: false), .licensed(expiresAt: nil))
        let lapsed = LicenseRecord(trialStartedAt: start, licenseKey: "K",
                                   licenseExpiresAt: start.addingTimeInterval(86400), lastValidatedAt: nil)
        XCTAssertEqual(lapsed.status(now: start.addingTimeInterval(2 * 86400), trialEnforced: false), .licenseExpired)
    }

    func testOldRecordWithoutTheNewFieldDecodes() throws {
        let json = #"{"trialStartedAt":721692800}"#
        let r = try JSONDecoder().decode(LicenseRecord.self, from: Data(json.utf8))
        XCTAssertNil(r.trialEnforcedSince)
    }
}
