// Castellum - Tests for the Lemon Squeezy licence API client (S61, #2263
// slice 2). Every request goes through `LicenseServerStub` (URLProtocol, no
// socket); nothing here can reach api.lemonsqueezy.com, and a test asserts it.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Riera Technologies Ltd

import XCTest
@testable import Castellum

final class LicenseActivationClientTests: XCTestCase {
    private let base = LicenseServerStub.base
    private let key = "00000000-1111-2222-3333-444444444444"
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        LicenseServerStub.reset()
        session = LicenseServerStub.session()
    }

    override func tearDown() {
        LicenseServerStub.assertNoRealHostContacted()
        LicenseServerStub.reset()
        session = nil
        super.tearDown()
    }

    private func activate(pin: LicensePin = .none) async throws -> LicenseServerState {
        try await LicenseActivationClient.activate(
            key: key, instanceName: "Castellum 1.0 \u{00B7} deadbeef", base: base, session: session, pin: pin)
    }

    private func expectRejection(
        _ expected: LicenseRejection, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await activate()
            XCTFail("expected a rejection", file: file, line: line)
        } catch LicenseActivationError.rejected(let kind, _) {
            XCTAssertEqual(kind, expected, file: file, line: line)
        } catch {
            XCTFail("expected a rejection, got \(error)", file: file, line: line)
        }
    }

    // MARK: format

    func testUUIDShapedKeyIsPlausible() {
        XCTAssertTrue(LicenseActivationClient.isPlausibleKeyFormat(key))
    }

    func testLegacyCastmKeyIsPlausible() {
        XCTAssertTrue(LicenseActivationClient.isPlausibleKeyFormat("CASTM-AAAA-BBBB-CCCC-DDDD"))
    }

    func testShortOrSpacedKeyIsRejectedWithoutNetwork() async {
        LicenseServerStub.handler = { _ in XCTFail("no network for a bad key"); return .transport(URLError(.badURL)) }
        for bad in ["", "abc", "AAAA-BBBB", "AAAA BBBB CCCC DDDD EEEE", "not-a-key-at-all-really!!", String(repeating: "ABCD-", count: 20) + "ABCD"] {
            XCTAssertFalse(LicenseActivationClient.isPlausibleKeyFormat(bad), bad)
        }
        do {
            _ = try await LicenseActivationClient.activate(
                key: "AAAA BBBB CCCC DDDD EEEE", instanceName: "x", base: base, session: session)
            XCTFail("expected malformedKey")
        } catch LicenseActivationError.malformedKey {
        } catch { XCTFail("got \(error)") }
        XCTAssertTrue(LicenseServerStub.requests.isEmpty)
    }

    func testKeyCaseIsPreserved() async throws {
        let mixed = "AbCd-eFgH-1234-WxYz"
        XCTAssertEqual(LicenseActivationClient.normalizeKey("  \u{201C}\(mixed)\u{201D}\n"), mixed)
        LicenseServerStub.handler = { _ in .json(LicenseServerStub.activated()) }
        _ = try await LicenseActivationClient.activate(key: mixed, instanceName: "n", base: base, session: session)
        XCTAssertEqual(LicenseServerStub.requests.first?.form["license_key"], mixed)
    }

    // MARK: activate

    func testActivateSendsFormEncodedKeyAndInstanceName() async throws {
        LicenseServerStub.handler = { _ in .json(LicenseServerStub.activated()) }
        _ = try await activate()
        let sent = try XCTUnwrap(LicenseServerStub.requests.first)
        XCTAssertEqual(sent.action, "activate")
        XCTAssertEqual(sent.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(sent.headers["Accept"], "application/json")
        XCTAssertEqual(sent.form["license_key"], key)
        XCTAssertEqual(sent.form["instance_name"], "Castellum 1.0 \u{00B7} deadbeef")
        XCTAssertEqual(sent.form.count, 2)
    }

    func testInstanceNameHasNoHostName() {
        let name = LicenseInstanceName.make(version: "1.2.3", tag: LicenseInstanceName.makeTag())
        XCTAssertTrue(name.hasPrefix("Castellum 1.2.3 \u{00B7} "))
        XCTAssertNotNil(name.range(of: #"^Castellum 1\.2\.3 · [0-9a-f]{8}$"#, options: .regularExpression))
        let host = ProcessInfo.processInfo.hostName.lowercased()
        let short = host.split(separator: ".").first.map(String.init) ?? host
        for part in [host, short, NSUserName().lowercased()] where part.count > 2 {
            XCTAssertFalse(name.lowercased().contains(part), "instance name leaks \(part)")
        }
        XCTAssertNotEqual(LicenseInstanceName.makeTag(), LicenseInstanceName.makeTag())
    }

    func testActivateDecodesInstanceAndExpiry() async throws {
        LicenseServerStub.handler = { _ in .json(LicenseServerStub.activated()) }
        let state = try await activate()
        XCTAssertTrue(state.ok)
        XCTAssertEqual(state.instanceId, "inst-1")
        XCTAssertEqual(state.status, "active")
        XCTAssertEqual(state.activationLimit, 3)
        XCTAssertEqual(state.activationUsage, 1)
        XCTAssertEqual(state.storeId, LicenseServerStub.storeId)
        XCTAssertEqual(state.productId, LicenseServerStub.productId)
        XCTAssertEqual(state.expiresAt, ISO8601DateFormatter().date(from: "2027-10-12T09:00:00Z"))
    }

    func testPerpetualKeyHasNoExpiry() async throws {
        LicenseServerStub.handler = { _ in .json(LicenseServerStub.activated(expires: nil)) }
        let state = try await activate()
        XCTAssertNil(state.expiresAt)
    }

    func testActivationLimitReachedMapsToRejection() async {
        LicenseServerStub.handler = { _ in
            .json(LicenseServerStub.rejected("This license key has reached the activation limit.", limit: 3, usage: 3), status: 400)
        }
        await expectRejection(.activationLimitReached)
    }

    func testNotFoundMapsToRejection() async {
        LicenseServerStub.handler = { _ in
            .json(#"{"activated":false,"error":"license_key not found.","license_key":null,"instance":null,"meta":null}"#, status: 404)
        }
        await expectRejection(.notFound)
    }

    func testExpiredAndDisabledStatusMapToRejections() async {
        LicenseServerStub.handler = { _ in .json(LicenseServerStub.rejected("x", status: "expired"), status: 400) }
        await expectRejection(.expired)
        LicenseServerStub.handler = { _ in .json(LicenseServerStub.rejected("x", status: "disabled"), status: 400) }
        await expectRejection(.disabled)
        LicenseServerStub.handler = { _ in .json(LicenseServerStub.rejected("something else"), status: 400) }
        await expectRejection(.other)
    }

    func testRejectionShowsTheServerTextVerbatimInBrackets() async {
        LicenseServerStub.handler = { _ in .json(LicenseServerStub.rejected("Nope, sorry."), status: 400) }
        do { _ = try await activate(); XCTFail("expected rejection") } catch let error as LicenseActivationError {
            XCTAssertTrue(error.localizedMessage.hasSuffix("[Nope, sorry.]"), error.localizedMessage)
        } catch { XCTFail("got \(error)") }
    }

    func testWrongProductIsRejectedAndTheSeatIsReleased() async {
        LicenseServerStub.handler = { request in
            request.action == "activate" ? .json(LicenseServerStub.activated(product: 999)) : .json(LicenseServerStub.deactivated)
        }
        let pin = LicensePin(storeId: LicenseServerStub.storeId, productIds: [LicenseServerStub.productId])
        do {
            _ = try await activate(pin: pin)
            XCTFail("expected wrongProduct")
        } catch LicenseActivationError.rejected(.wrongProduct, _) {
        } catch { XCTFail("got \(error)") }
        let sent = LicenseServerStub.requests
        XCTAssertEqual(sent.map(\.action), ["activate", "deactivate"])
        XCTAssertEqual(sent.last?.form["instance_id"], "inst-1", "the seat just taken is the one released")
        XCTAssertEqual(sent.last?.form["license_key"], key)
    }

    func testWrongStoreIsAlsoRejected() async {
        LicenseServerStub.handler = { request in
            request.action == "activate" ? .json(LicenseServerStub.activated(store: 5)) : .json(LicenseServerStub.deactivated)
        }
        do {
            _ = try await activate(pin: LicensePin(storeId: LicenseServerStub.storeId, productIds: []))
            XCTFail("expected wrongProduct")
        } catch LicenseActivationError.rejected(.wrongProduct, _) {
        } catch { XCTFail("got \(error)") }
    }

    func testEmptyPinSkipsTheCheck() async throws {
        LicenseServerStub.handler = { _ in .json(LicenseServerStub.activated(store: 1, product: 2)) }
        _ = try await activate(pin: .none)
        XCTAssertEqual(LicenseServerStub.requests.map(\.action), ["activate"])
        XCTAssertTrue(LicensePin(storeId: nil, productIds: []).matches(storeId: nil, productId: nil))
        XCTAssertFalse(LicensePin(storeId: nil, productIds: [7]).matches(storeId: 1, productId: nil))
    }

    func test5xxIsANetworkErrorNotARejection() async {
        for status in [500, 502, 503, 429] {
            LicenseServerStub.handler = { _ in .json("{}", status: status) }
            do { _ = try await activate(); XCTFail("expected network error") } catch LicenseActivationError.network {
            } catch { XCTFail("HTTP \(status) gave \(error)") }
        }
    }

    func testTransportFailureIsANetworkError() async {
        LicenseServerStub.handler = { _ in .transport(URLError(.cannotConnectToHost)) }
        do { _ = try await activate(); XCTFail("expected network error") } catch LicenseActivationError.network {
        } catch { XCTFail("got \(error)") }
    }

    func testFractionalSecondDateDecodes() {
        XCTAssertEqual(LicenseActivationClient.parseDate("2026-10-12T09:00:00.000000Z"),
                       ISO8601DateFormatter().date(from: "2026-10-12T09:00:00Z"))
        XCTAssertEqual(LicenseActivationClient.parseDate("2026-10-12T09:00:00Z"),
                       ISO8601DateFormatter().date(from: "2026-10-12T09:00:00Z"))
        XCTAssertNil(LicenseActivationClient.parseDate("next tuesday"))
    }

    func testParseDateAcceptsOffsetsAndAnyFractionLength() {
        let utc = ISO8601DateFormatter().date(from: "2026-10-12T09:00:00Z")
        XCTAssertEqual(LicenseActivationClient.parseDate("2026-10-12T10:00:00+01:00"), utc)
        XCTAssertEqual(LicenseActivationClient.parseDate("2026-10-12T10:00:00.000+01:00"), utc)
        XCTAssertEqual(LicenseActivationClient.parseDate("2026-10-12T09:00:00.123Z")?.timeIntervalSince(utc!) ?? 0, 0.123, accuracy: 0.001)
    }

    func testOnlyTheFlagOfTheCallBeingMadeCounts() async {
        // A validate-shaped body answering an activate must not read as activated.
        LicenseServerStub.handler = { _ in .json(LicenseServerStub.valid()) }
        do { _ = try await activate(); XCTFail("expected rejection") } catch LicenseActivationError.rejected {
        } catch { XCTFail("got \(error)") }
    }

    func testUnparseableExpiryOnActivateReleasesTheGrantedSeat() async {
        LicenseServerStub.handler = { request in
            request.action == "activate" ? .json(LicenseServerStub.activated(expires: "someday")) : .json(LicenseServerStub.deactivated)
        }
        do { _ = try await activate(); XCTFail("expected malformedResponse") } catch LicenseActivationError.malformedResponse {
        } catch { XCTFail("got \(error)") }
        XCTAssertEqual(LicenseServerStub.requests.map(\.action), ["activate", "deactivate"])
        XCTAssertEqual(LicenseServerStub.requests.last?.form["instance_id"], "inst-1")
    }

    func testRealHostGuardCatchesTrailingDotAndSubdomains() {
        for host in ["api.lemonsqueezy.com", "API.LemonSqueezy.com.", "lemonsqueezy.com", "x.api.lemonsqueezy.com"] {
            XCTAssertTrue(LicenseAPI.isProductionHost(URL(string: "https://\(host)/v1")!), host)
        }
        XCTAssertFalse(LicenseAPI.isProductionHost(LicenseServerStub.base))
        XCTAssertFalse(LicenseAPI.isProductionHost(URL(string: "https://notlemonsqueezy.com/")!))
    }

    /// Fail-closed: an empty pin accepts any Lemon Squeezy key from any store, so a
    /// configuration that enforces the trial (1.0) must also pin store and products.
    func testAnEnforcingBuildConfigurationAlwaysPinsStoreAndProducts() throws {
        let configs = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("configs")
        for name in ["Direct.xcconfig", "DirectRelease.xcconfig"] {
            let text = try String(contentsOf: configs.appendingPathComponent(name), encoding: .utf8)
            func value(_ key: String) -> String {
                text.split(separator: "\n").compactMap { line -> String? in
                    let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    return parts.count == 2 && parts[0] == key ? parts[1] : nil
                }.last ?? ""
            }
            if ["YES", "TRUE", "1"].contains(value("CASTELLUM_TRIAL_ENFORCED").uppercased()) {
                XCTAssertFalse(value("CASTELLUM_LS_STORE_ID").isEmpty, "\(name) enforces the trial without a store pin")
                XCTAssertFalse(value("CASTELLUM_LS_PRODUCT_IDS").isEmpty, "\(name) enforces the trial without a product pin")
            }
        }
    }

    func testNonJsonIsMalformedResponse() async {
        for body in ["<html>captive portal</html>", "", "[1,2]"] {
            LicenseServerStub.handler = { _ in .json(body) }
            do { _ = try await activate(); XCTFail("expected malformedResponse") } catch LicenseActivationError.malformedResponse {
            } catch { XCTFail("\(body) gave \(error)") }
        }
        // 4xx with an HTML body is also not a rejection.
        LicenseServerStub.handler = { _ in .json("<html>nope</html>", status: 404) }
        do { _ = try await activate(); XCTFail("expected malformedResponse") } catch LicenseActivationError.malformedResponse {
        } catch { XCTFail("got \(error)") }
    }

    func testUnparseableExpiryIsMalformedNotPerpetual() async {
        LicenseServerStub.handler = { _ in .json(LicenseServerStub.activated(expires: "someday")) }
        do { _ = try await activate(); XCTFail("expected malformedResponse") } catch LicenseActivationError.malformedResponse {
        } catch { XCTFail("got \(error)") }
    }

    // MARK: validate / deactivate wire

    func testValidateAndDeactivateSendInstanceId() async throws {
        LicenseServerStub.handler = { request in
            request.action == "validate" ? .json(LicenseServerStub.valid()) : .json(LicenseServerStub.deactivated)
        }
        let valid = try await LicenseActivationClient.validate(key: key, instanceId: "inst-1", base: base, session: session)
        XCTAssertTrue(valid.ok)
        let gone = try await LicenseActivationClient.deactivate(key: key, instanceId: "inst-1", base: base, session: session)
        XCTAssertTrue(gone.ok)
        let sent = LicenseServerStub.requests
        XCTAssertEqual(sent.map(\.action), ["validate", "deactivate"])
        for request in sent {
            XCTAssertEqual(request.form["instance_id"], "inst-1")
            XCTAssertEqual(request.form["license_key"], key)
            XCTAssertNil(request.form["instance_name"])
        }
    }

    func testValidFalseIsARejectionNotAState() async {
        LicenseServerStub.handler = { _ in
            .json(#"{"valid":false,"error":"license_key not found.","license_key":null,"instance":null,"meta":null}"#, status: 404)
        }
        do {
            _ = try await LicenseActivationClient.validate(key: key, instanceId: "i", base: base, session: session)
            XCTFail("expected rejection")
        } catch LicenseActivationError.rejected(.notFound, _) {
        } catch { XCTFail("got \(error)") }
    }

    // MARK: build (endpoint override, real host)

    func testReleaseIgnoresEndpointOverride() {
        let env = ["CASTELLUM_LICENSE_ENDPOINT": "http://127.0.0.1:9/v1/licenses"]
        XCTAssertEqual(LicenseAPI.resolveBase(env: env, isDebug: false), LicenseAPI.productionBase)
        XCTAssertEqual(LicenseAPI.resolveBase(env: env, isDebug: true).absoluteString, "http://127.0.0.1:9/v1/licenses")
    }

    func testOverrideMustBeAnHttpUrlOtherwiseProductionIsUsed() {
        for bad in ["", "   ", "not a url", "file:///etc/passwd", "ftp://x.invalid/"] {
            XCTAssertEqual(
                LicenseAPI.resolveBase(env: ["CASTELLUM_LICENSE_ENDPOINT": bad], isDebug: true),
                LicenseAPI.productionBase, bad)
        }
        XCTAssertEqual(LicenseAPI.resolveBase(env: [:], isDebug: true), LicenseAPI.productionBase)
        XCTAssertEqual(LicenseAPI.productionBase.absoluteString, "https://api.lemonsqueezy.com/v1/licenses")
    }

    func testNoRequestEverGoesToTheRealHost() async {
        // Even if a test forgot to inject a base, the client refuses the real host.
        LicenseServerStub.handler = { _ in .json(LicenseServerStub.activated()) }
        do {
            _ = try await LicenseActivationClient.activate(
                key: key, instanceName: "n", base: LicenseAPI.productionBase, session: session)
            XCTFail("the production host must be blocked under XCTest")
        } catch LicenseActivationError.network {
        } catch { XCTFail("got \(error)") }
        XCTAssertTrue(LicenseServerStub.requests.isEmpty, "the blocked call must not even reach the stub")
        LicenseServerStub.assertNoRealHostContacted()
    }

    // MARK: build settings

    func testBuildPinAndBuyURLReadTheInfoPlist() {
        XCTAssertEqual(LicenseBuild.pin(info: ["CastellumLSStoreID": "11", "CastellumLSProductIDs": " 22, 33 ,x"]),
                       LicensePin(storeId: 11, productIds: [22, 33]))
        XCTAssertEqual(LicenseBuild.pin(info: ["CastellumLSStoreID": "$(CASTELLUM_LS_STORE_ID)", "CastellumLSProductIDs": ""]), .none)
        XCTAssertEqual(LicenseBuild.pin(info: nil), .none)
        XCTAssertEqual(LicenseBuild.buyURL(info: ["CastellumBuyURL": "https://example.invalid/buy"])?.host, "example.invalid")
        XCTAssertNil(LicenseBuild.buyURL(info: ["CastellumBuyURL": ""]))
        XCTAssertNil(LicenseBuild.buyURL(info: ["CastellumBuyURL": "javascript:alert(1)"]))
        XCTAssertEqual(LicenseBuild.pin, .none, "the beta build has no pin yet")
    }

    func testTimeoutIntervalIsBoundedAndShort() {
        XCTAssertEqual(LicenseActivationClient.timeoutSeconds, 10)
    }
}
