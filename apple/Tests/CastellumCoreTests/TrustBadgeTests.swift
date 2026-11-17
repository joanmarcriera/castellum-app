// Castellum - trust badge classification tests (S48).
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Riera Technologies Ltd

import XCTest
@testable import Castellum

final class TrustBadgeTests: XCTestCase {
    func testAllNoneIsUnverified() {
        let trust = TrustSignals(spf: "none", dkim: "none", dmarc: "none", authservId: nil)
        XCTAssertEqual(TrustBadgeKind.classify(trust), .unverified)
    }

    func testAnyPassWithNoFailIsAuthenticated() {
        let trust = TrustSignals(spf: "pass", dkim: "none", dmarc: "none", authservId: "host")
        XCTAssertEqual(TrustBadgeKind.classify(trust), .authenticated)
    }

    func testAnyFailOverridesAPass() {
        let trust = TrustSignals(spf: "pass", dkim: "fail", dmarc: "none", authservId: "host")
        XCTAssertEqual(TrustBadgeKind.classify(trust), .failed, "a failure is never hidden by a pass elsewhere")
    }

    func testNilTrustIsUnverifiedNotCrashing() {
        XCTAssertEqual(TrustBadgeKind.classify(nil), .unverified)
    }

    func testUnrecognisedFutureValueIsTreatedAsNotChecked() {
        let trust = TrustSignals(spf: "temperror", dkim: "none", dmarc: "none", authservId: "host")
        XCTAssertEqual(TrustBadgeKind.classify(trust), .unverified, "an unrecognised token must never read as pass")
    }
}
