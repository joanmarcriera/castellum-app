// Castellum - Tests for S61's AppModel licence wiring: first-launch trial
// start, activation success/failure, and deactivation. Every AppModel here
// uses its own temp profile directory (isolated Keychain namespace, per
// CLAUDE.md gotcha #2) and every network-touching test stubs the transport
// via URLProtocol — never a real endpoint.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Riera Technologies Ltd

import XCTest
@testable import Castellum

@MainActor
final class LicenseAppModelTests: XCTestCase {
    private var models: [AppModel] = []

    private let key = "00000000-1111-2222-3333-444444444444"

    private func stubbedSession() -> URLSession { LicenseServerStub.session() }

    /// An AppModel whose licence calls go to the stub and nowhere else.
    private func appModel(dir: URL, clock: @escaping () -> Date = Date.init, enforced: Bool = true,
                          pin: LicensePin = .none) -> AppModel {
        let m = AppModel(
            profileDirectory: dir, clock: clock, licenseActivationSession: stubbedSession(),
            trialEnforced: enforced, licenseBase: LicenseServerStub.base, licensePin: pin)
        models.append(m)
        return m
    }

    private func makeModel(
        clock: @escaping () -> Date = Date.init
    ) -> AppModel {
        let dir = TestScratch.root
            .appendingPathComponent("castellum-license-\(UUID().uuidString)")
        return appModel(dir: dir, clock: clock)
    }

    override func setUp() async throws {
        try await super.setUp()
        LicenseServerStub.reset()
    }

    override func tearDown() async throws {
        for model in models {
            XCTAssertNotEqual(model.licenseStore.serviceName, LicenseStore.defaultService)
            try? model.licenseStore.deleteAll()
        }
        models = []
        LicenseServerStub.assertNoRealHostContacted()
        LicenseServerStub.reset()
        try await super.tearDown()
    }

    // MARK: - First-launch trial start

    func testFreshProfileStartsAFourteenDayTrialImmediately() {
        let model = makeModel()
        XCTAssertEqual(model.licenseState, .trial(daysRemaining: 14))
    }

    func testTwoDifferentProfilesEachGetTheirOwnFreshTrial() {
        let a = makeModel()
        let b = makeModel()
        XCTAssertEqual(a.licenseState, .trial(daysRemaining: 14))
        XCTAssertEqual(b.licenseState, .trial(daysRemaining: 14))
        XCTAssertNotEqual(a.licenseStore.serviceName, b.licenseStore.serviceName)
    }

    /// Re-opening the SAME profile directory must load the existing record,
    /// never start a second, later trial — the invariant this stage exists
    /// to protect (a naive UserDefaults reset must not reset the trial).
    func testReopeningTheSameProfileNeverResetsTheTrialClock() throws {
        let dir = TestScratch.root
            .appendingPathComponent("castellum-license-reopen-\(UUID().uuidString)")
        var day = Date(timeIntervalSince1970: 1_700_000_000)
        let first = appModel(dir: dir, clock: { day })
        XCTAssertEqual(first.licenseState, .trial(daysRemaining: 14))

        // "Relaunch" 5 days later, same profile directory.
        day = day.addingTimeInterval(5 * 86400)
        let second = appModel(dir: dir, clock: { day })
        XCTAssertEqual(second.licenseState, .trial(daysRemaining: 9))
        XCTAssertEqual(try second.licenseStore.load()?.trialStartedAt,
                        Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: - Activation (#2263 slice 2: Lemon Squeezy)

    /// Activate answers with an instance, deactivate with "deactivated".
    private func serveActivation(
        instance: String = "inst-1", expires: String? = "2027-10-12T09:00:00.000000Z"
    ) {
        LicenseServerStub.handler = { request in
            request.action == "deactivate"
                ? .json(LicenseServerStub.deactivated)
                : .json(LicenseServerStub.activated(instance: instance, expires: expires))
        }
    }

    func testActivateStoresInstanceIdAndExpiry() async throws {
        let model = makeModel()
        serveActivation()
        let error = await model.activateLicense(key: key)
        XCTAssertNil(error)
        let stored = try XCTUnwrap(try model.licenseStore.load())
        XCTAssertEqual(stored.licenseKey, key)
        XCTAssertEqual(stored.instanceId, "inst-1")
        XCTAssertEqual(stored.licenseExpiresAt, ISO8601DateFormatter().date(from: "2027-10-12T09:00:00Z"))
        XCTAssertNotNil(stored.lastValidatedAt)
        XCTAssertNotNil(stored.instanceTag)
        XCTAssertEqual(model.licenseState, .licensed(expiresAt: stored.licenseExpiresAt))
    }

    func testActivationSendsTheTaggedInstanceNameAndTheNormalisedKey() async throws {
        let model = makeModel()
        serveActivation()
        _ = await model.activateLicense(key: "  \"\(key)\"\n")
        let sent = try XCTUnwrap(LicenseServerStub.requests.first)
        XCTAssertEqual(sent.form["license_key"], key, "whitespace and quotes trimmed, case kept")
        let tag = try XCTUnwrap(try model.licenseStore.load()?.instanceTag)
        XCTAssertTrue(sent.form["instance_name"]?.hasSuffix("\u{00B7} \(tag)") ?? false, "\(sent.form)")
    }

    func testReactivatingTheSameKeyValidatesTheHeldInstanceAndTakesNoSecondSeat() async throws {
        let model = makeModel()
        serveActivation()
        _ = await model.activateLicense(key: key)
        let before = try model.licenseStore.load()
        LicenseServerStub.reset()
        LicenseServerStub.handler = { request in
            request.action == "validate" ? .json(LicenseServerStub.valid()) : .transport(URLError(.badURL))
        }
        let error = await model.activateLicense(key: key)
        XCTAssertNil(error)
        XCTAssertEqual(LicenseServerStub.requests.map(\.action), ["validate"], "no activate, no deactivate")
        XCTAssertEqual(LicenseServerStub.requests.first?.form["instance_id"], "inst-1")
        let after = try model.licenseStore.load()
        XCTAssertEqual(after?.instanceId, before?.instanceId)
        XCTAssertEqual(after?.instanceTag, before?.instanceTag)
    }

    func testReactivatingWhenTheServerForgotTheInstanceActivatesAfresh() async throws {
        let model = makeModel()
        serveActivation(instance: "inst-old")
        _ = await model.activateLicense(key: key)
        let tag = try model.licenseStore.load()?.instanceTag
        LicenseServerStub.reset()
        LicenseServerStub.handler = { request in
            request.action == "validate"
                ? .json(#"{"valid":false,"error":"instance not found.","license_key":null,"meta":null}"#, status: 404)
                : .json(LicenseServerStub.activated(instance: "inst-new"))
        }
        let error = await model.activateLicense(key: key)
        XCTAssertNil(error)
        XCTAssertEqual(LicenseServerStub.requests.map(\.action), ["validate", "activate"])
        XCTAssertEqual(try model.licenseStore.load()?.instanceId, "inst-new")
        XCTAssertEqual(try model.licenseStore.load()?.instanceTag, tag, "the tag is reused")
    }

    func testReactivatingOfflineChangesNothing() async throws {
        let model = makeModel()
        serveActivation()
        _ = await model.activateLicense(key: key)
        let before = try model.licenseStore.load()
        LicenseServerStub.handler = { _ in .transport(URLError(.notConnectedToInternet)) }
        let error = await model.activateLicense(key: key)
        XCTAssertTrue(error?.contains("Couldn't reach") ?? false)
        XCTAssertEqual(try model.licenseStore.load(), before)
    }

    func testFailedActivationLeavesTrialStateUntouchedAndSurfacesTheServerText() async throws {
        let model = makeModel()
        LicenseServerStub.handler = { _ in
            .json(#"{"activated":false,"error":"license_key not found.","license_key":null,"instance":null,"meta":null}"#, status: 404)
        }
        let error = await model.activateLicense(key: key)
        XCTAssertTrue(error?.hasSuffix("[license_key not found.]") ?? false, "got: \(error ?? "nil")")
        XCTAssertEqual(model.licenseState, .trial(daysRemaining: 14))
        XCTAssertNil(try model.licenseStore.load()?.licenseKey)
    }

    func testNetworkFailureDuringActivationLeavesStateUntouchedAndReturnsAFriendlyMessage() async throws {
        let model = makeModel()
        LicenseServerStub.handler = { _ in .transport(URLError(.notConnectedToInternet)) }
        let error = await model.activateLicense(key: key)
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("Couldn't reach") ?? false, "got: \(error ?? "nil")")
        XCTAssertEqual(model.licenseState, .trial(daysRemaining: 14))
        XCTAssertNil(try model.licenseStore.load()?.licenseKey)
    }

    func testMalformedKeyNeverConsumesTrialAndReturnsAFormatError() async throws {
        let model = makeModel()
        LicenseServerStub.handler = { _ in XCTFail("malformed key must never reach the network"); return .transport(URLError(.badURL)) }
        let error = await model.activateLicense(key: "not-a-key")
        XCTAssertNotNil(error)
        XCTAssertEqual(model.licenseState, .trial(daysRemaining: 14))
    }

    func testWrongProductIsRejectedAndTheSeatIsReleased() async throws {
        let dir = TestScratch.root.appendingPathComponent("castellum-license-pin-\(UUID().uuidString)")
        let model = appModel(dir: dir, pin: LicensePin(storeId: 11, productIds: [22]))
        LicenseServerStub.handler = { request in
            request.action == "deactivate" ? .json(LicenseServerStub.deactivated) : .json(LicenseServerStub.activated(product: 999))
        }
        let error = await model.activateLicense(key: key)
        XCTAssertNotNil(error)
        XCTAssertNil(try model.licenseStore.load()?.licenseKey)
        XCTAssertEqual(LicenseServerStub.requests.map(\.action), ["activate", "deactivate"])
    }

    func testActivationWithAnAlreadyPastExpiryIsRefusedAndTheSeatReleased() async throws {
        let model = makeModel()
        serveActivation(expires: "2001-01-01T00:00:00.000000Z")
        let message = await model.activateLicense(key: key)
        XCTAssertNotNil(message)
        XCTAssertNil(try model.licenseStore.load()?.licenseKey, "an expired key must not be stored as activated")
        XCTAssertEqual(LicenseServerStub.requests.map(\.action), ["activate", "deactivate"])
    }

    func testReplacingAKeyDeactivatesTheOldInstance() async throws {
        let model = makeModel()
        serveActivation(instance: "inst-old")
        _ = await model.activateLicense(key: key)
        let newKey = "AAAA-BBBB-CCCC-DDDD-EEEE"
        LicenseServerStub.reset()
        serveActivation(instance: "inst-new")
        let error = await model.activateLicense(key: newKey)
        XCTAssertNil(error)
        let sent = LicenseServerStub.requests
        XCTAssertEqual(sent.map(\.action), ["activate", "deactivate"])
        XCTAssertEqual(sent.last?.form["license_key"], key)
        XCTAssertEqual(sent.last?.form["instance_id"], "inst-old")
        XCTAssertEqual(try model.licenseStore.load()?.licenseKey, newKey)
        XCTAssertEqual(try model.licenseStore.load()?.instanceId, "inst-new")
    }

    func testAFailedReplacementKeepsTheWorkingLicence() async throws {
        let model = makeModel()
        serveActivation()
        _ = await model.activateLicense(key: key)
        LicenseServerStub.reset()
        LicenseServerStub.handler = { _ in .json(LicenseServerStub.rejected("nope"), status: 400) }
        let error = await model.activateLicense(key: "AAAA-BBBB-CCCC-DDDD-EEEE")
        XCTAssertNotNil(error)
        XCTAssertEqual(LicenseServerStub.requests.map(\.action), ["activate"], "the old seat is not touched")
        XCTAssertEqual(try model.licenseStore.load()?.licenseKey, key)
    }

    // MARK: - Deactivation

    func testDeactivateReleasesTheSeatThenClearsLocally() async throws {
        let model = makeModel()
        serveActivation()
        _ = await model.activateLicense(key: key)
        LicenseServerStub.reset()
        LicenseServerStub.handler = { _ in .json(LicenseServerStub.deactivated) }
        let trialStartedAt = try model.licenseStore.load()?.trialStartedAt

        let outcome = await model.deactivateLicense()
        XCTAssertEqual(outcome, .released)
        let sent = try XCTUnwrap(LicenseServerStub.requests.first)
        XCTAssertEqual(sent.action, "deactivate")
        XCTAssertEqual(sent.form["instance_id"], "inst-1")
        XCTAssertEqual(model.licenseState, .trial(daysRemaining: 14))
        let stored = try model.licenseStore.load()
        XCTAssertNil(stored?.licenseKey)
        XCTAssertNil(stored?.instanceId)
        XCTAssertNotNil(stored?.instanceTag, "the tag survives for the next activation")
        XCTAssertEqual(stored?.trialStartedAt, trialStartedAt, "never resets the original trial start")
    }

    func testDeactivateOfflineKeepsTheLicence() async throws {
        let model = makeModel()
        serveActivation()
        _ = await model.activateLicense(key: key)
        LicenseServerStub.handler = { _ in .transport(URLError(.notConnectedToInternet)) }
        let outcome = await model.deactivateLicense()
        guard case .failed(let message) = outcome else { return XCTFail("expected .failed, got \(outcome)") }
        XCTAssertTrue(message.contains("Couldn't reach"), message)
        XCTAssertEqual(try model.licenseStore.load()?.licenseKey, key, "record untouched")
        XCTAssertEqual(model.licenseState, .licensed(expiresAt: ISO8601DateFormatter().date(from: "2027-10-12T09:00:00Z")))
    }

    func testForceLocalClearsWithoutNetwork() async throws {
        let model = makeModel()
        serveActivation()
        _ = await model.activateLicense(key: key)
        LicenseServerStub.reset()
        LicenseServerStub.handler = { _ in XCTFail("forceLocal must not contact the server"); return .transport(URLError(.badURL)) }
        let outcome = await model.deactivateLicense(forceLocal: true)
        guard case .releasedLocallyOnly = outcome else { return XCTFail("expected .releasedLocallyOnly, got \(outcome)") }
        XCTAssertNil(try model.licenseStore.load()?.licenseKey)
        XCTAssertEqual(model.licenseState, .trial(daysRemaining: 14))
        XCTAssertTrue(LicenseServerStub.requests.isEmpty)
    }

    func testDeactivateWhenServerNoLongerKnowsTheInstanceClearsLocally() async throws {
        let model = makeModel()
        serveActivation()
        _ = await model.activateLicense(key: key)
        LicenseServerStub.handler = { _ in
            .json(#"{"deactivated":false,"error":"license_key or instance not found.","license_key":null,"meta":null}"#, status: 404)
        }
        let outcome = await model.deactivateLicense()
        XCTAssertEqual(outcome, .released)
        XCTAssertNil(try model.licenseStore.load()?.licenseKey)
    }

    func testDeactivatingARecordFromBeforeSliceTwoNeedsNoServer() async throws {
        let dir = TestScratch.root.appendingPathComponent("castellum-license-legacy-\(UUID().uuidString)")
        let model = appModel(dir: dir)
        let existing = try XCTUnwrap(try model.licenseStore.load())
        var legacy = existing
        legacy.licenseKey = "CASTM-AAAA-BBBB-CCCC-DDDD"
        try model.licenseStore.save(legacy)
        LicenseServerStub.reset()
        let outcome = await model.deactivateLicense()
        XCTAssertEqual(outcome, .released)
        XCTAssertTrue(LicenseServerStub.requests.isEmpty)
        XCTAssertNil(try model.licenseStore.load()?.licenseKey)
    }

    func testDeactivationAfterTrialExpiryFallsBackToExpiredNeverCrashes() async throws {
        var day = Date(timeIntervalSince1970: 1_700_000_000)
        let model = makeModel(clock: { day })
        serveActivation(expires: nil)
        _ = await model.activateLicense(key: key)
        day = day.addingTimeInterval(20 * 86400) // well past the 14-day trial window
        let outcome = await model.deactivateLicense()
        XCTAssertEqual(outcome, .released)
        XCTAssertEqual(model.licenseState, .trialExpired)
    }

    func testRefreshLicenseStatePicksUpADayBoundaryCrossedSinceLaunch() {
        var day = Date(timeIntervalSince1970: 1_700_000_000)
        let model = makeModel(clock: { day })
        XCTAssertEqual(model.licenseState, .trial(daysRemaining: 14))
        day = day.addingTimeInterval(14 * 86400)
        // licenseState does not silently tick on its own (no timer, Assumption 6).
        XCTAssertEqual(model.licenseState, .trial(daysRemaining: 14))
        model.refreshLicenseState()
        XCTAssertEqual(model.licenseState, .trialExpired)
    }

    // MARK: - Audit #3390 / #3391 / #3447

    func testUnreadableLicenceRecordIsNeverOverwrittenWithAFreshTrial() async throws {
        let dir = TestScratch.root.appendingPathComponent("castellum-license-\(UUID().uuidString)")
        let planted = Data("not json - a corrupt or future-format record".utf8)
        try LicenseStore(profileDirectory: dir).writeRawForTesting(planted)
        let model = appModel(dir: dir)
        XCTAssertTrue(model.licenseStorageUnreadable)
        XCTAssertThrowsError(try model.licenseStore.load(), "the planted blob must still be there, unreadable")
        // deactivate must report the read failure, not pretend it worked
        let outcome = await model.deactivateLicense()
        guard case .failed = outcome else { return XCTFail("expected .failed, got \(outcome)") }
    }

    func testClockRolledBackDoesNotRestartAnExpiredTrial() {
        var day = Date(timeIntervalSince1970: 1_700_000_000)
        let model = makeModel(clock: { day })
        day = day.addingTimeInterval(20 * 86400)
        model.refreshLicenseState()
        XCTAssertEqual(model.licenseState, .trialExpired)
        day = day.addingTimeInterval(-19 * 86400) // user sets the date back
        model.refreshLicenseState()
        XCTAssertEqual(model.licenseState, .trialExpired, "a high-water mark stops a rollback extending the trial")
    }

    // MARK: - #2263 slice 1: trial enforcement is a build setting

    private func model(dir: URL, at day: Date, enforced: Bool) -> AppModel {
        appModel(dir: dir, clock: { day }, enforced: enforced)
    }

    func testABetaBuildNeverExpiresTheTrial() {
        let dir = TestScratch.root.appendingPathComponent("castellum-license-beta-\(UUID().uuidString)")
        let day0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = model(dir: dir, at: day0, enforced: false)
        let later = model(dir: dir, at: day0.addingTimeInterval(30 * 86400), enforced: false)
        XCTAssertEqual(later.licenseState, .trial(daysRemaining: 14), "no banner on a 30-day-old beta profile")
    }

    func testFirstEnforcingLaunchRestartsTheTrialOnceThenKeepsTheClock() throws {
        let dir = TestScratch.root.appendingPathComponent("castellum-license-enforce-\(UUID().uuidString)")
        let day0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = model(dir: dir, at: day0, enforced: false)
        let day30 = day0.addingTimeInterval(30 * 86400)
        let first = model(dir: dir, at: day30, enforced: true)
        XCTAssertEqual(first.licenseState, .trial(daysRemaining: 14), "a fresh 14 days on the first enforcing launch")
        XCTAssertEqual(try first.licenseStore.load()?.trialEnforcedSince, day30)
        let second = model(dir: dir, at: day30.addingTimeInterval(5 * 86400), enforced: true)
        XCTAssertEqual(second.licenseState, .trial(daysRemaining: 9), "the restart is granted only once")
        let expired = model(dir: dir, at: day30.addingTimeInterval(20 * 86400), enforced: true)
        XCTAssertEqual(expired.licenseState, .trialExpired)
    }

    func testAFreshEnforcingProfileIsNotRestartedOnItsNextLaunch() throws {
        let dir = TestScratch.root.appendingPathComponent("castellum-license-fresh-\(UUID().uuidString)")
        let day0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = model(dir: dir, at: day0, enforced: true)
        let later = model(dir: dir, at: day0.addingTimeInterval(20 * 86400), enforced: true)
        XCTAssertEqual(later.licenseState, .trialExpired)
    }

    func testTheBuildFlagReadsYesAndTreatsAnythingElseAsOff() {
        XCTAssertTrue(LicenseBuild.isTrialEnforced(info: ["CastellumTrialEnforced": "YES"]))
        XCTAssertTrue(LicenseBuild.isTrialEnforced(info: ["CastellumTrialEnforced": true]))
        XCTAssertFalse(LicenseBuild.isTrialEnforced(info: ["CastellumTrialEnforced": "NO"]))
        XCTAssertFalse(LicenseBuild.isTrialEnforced(info: ["CastellumTrialEnforced": "$(CASTELLUM_TRIAL_ENFORCED)"]))
        XCTAssertFalse(LicenseBuild.isTrialEnforced(info: [:]))
        XCTAssertFalse(LicenseBuild.isTrialEnforced(info: nil))
        // This Debug test host is built with NO.
        XCTAssertFalse(LicenseBuild.trialEnforced)
    }
}
