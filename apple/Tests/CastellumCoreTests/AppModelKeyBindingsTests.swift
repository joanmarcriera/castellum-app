// Castellum - AppModel.paletteContext + AppModel.keyBindings wiring.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Riera Technologies Ltd

import XCTest
@testable import Castellum

@MainActor
final class AppModelKeyBindingsTests: XCTestCase {
    private var models: [AppModel] = []

    private func makeModel() -> AppModel {
        let dir = TestScratch.root
            .appendingPathComponent("castellum-applekeybindings-test-\(UUID().uuidString)", isDirectory: true)
        let model = AppModel(profileDirectory: dir)
        models.append(model)
        return model
    }

    override func tearDown() async throws {
        for model in models {
            XCTAssertNotEqual(model.accountStore.serviceName, AccountStore.defaultService)
            try model.accountStore.deleteAll()
        }
        models = []
        try await super.tearDown()
    }

    func testKeyBindingsDirectoryMatchesTheProfileDirectory() {
        let model = makeModel()
        XCTAssertEqual(model.keyBindings.directory, model.profileDirectory)
    }

    func testFreshModelHasNoSelectionAndAiFollowsPreferences() {
        let model = makeModel()
        XCTAssertFalse(model.paletteContext.hasSelectedMessage)
        XCTAssertFalse(model.paletteContext.messageBodyAvailable)
        XCTAssertEqual(model.paletteContext.aiEnabled, Preferences.shared.aiEnabled)
    }
}
