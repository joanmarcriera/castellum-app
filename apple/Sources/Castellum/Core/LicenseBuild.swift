// Castellum - licence settings compiled into the build (#2263 S61 slice 1).
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Riera Technologies Ltd
//
// Values come from the xcconfigs through apple/Info-Extras.plist
// (`CastellumTrialEnforced` = $(CASTELLUM_TRIAL_ENFORCED)), not from
// INFOPLIST_KEY_ build settings: Xcode only emits INFOPLIST_KEY_ names it
// knows, so a custom key there would silently be absent. None is a secret.
// Spec: project-docs/specs/2026-10-12/licensing-chain.md (T10, M3).

import Foundation

enum LicenseBuild {
    /// Whether this build lets the 14-day trial run out. Off (NO) in both
    /// configurations for the beta; flipped to YES in DirectRelease.xcconfig
    /// for 1.0. A missing or unexpanded value counts as off.
    static let trialEnforced = isTrialEnforced(info: Bundle.main.infoDictionary)

    /// The pure reading of the flag, for tests.
    static func isTrialEnforced(info: [String: Any]?) -> Bool {
        guard let raw = info?["CastellumTrialEnforced"] else { return false }
        if let flag = raw as? Bool { return flag }
        guard let text = raw as? String else { return false }
        return ["yes", "true", "1"].contains(text.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// The Lemon Squeezy store and products this build accepts a licence for
    /// (#2263 slice 2, T3). Empty = no pin, the check is skipped.
    static let pin = pin(info: Bundle.main.infoDictionary)

    /// Where "Buy a licence..." points; nil (hidden) when unset or not https.
    static let buyURL = buyURL(info: Bundle.main.infoDictionary)

    /// Pure readings, for tests.
    static func pin(info: [String: Any]?) -> LicensePin {
        let store = (info?["CastellumLSStoreID"] as? String).flatMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        let products = ((info?["CastellumLSProductIDs"] as? String) ?? "")
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return LicensePin(storeId: store, productIds: Set(products))
    }

    static func buyURL(info: [String: Any]?) -> URL? {
        guard let text = (info?["CastellumBuyURL"] as? String)?.trimmingCharacters(in: .whitespaces),
              let url = URL(string: text), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

/// The store and products a licence must belong to (T3). A nil / empty part
/// is not enforced, so a build without ids accepts any key the server accepts.
struct LicensePin: Equatable {
    var storeId: Int?
    var productIds: Set<Int>

    static let none = LicensePin(storeId: nil, productIds: [])

    func matches(storeId: Int?, productId: Int?) -> Bool {
        if let pinned = self.storeId, storeId != pinned { return false }
        if !productIds.isEmpty, !(productId.map(productIds.contains) ?? false) { return false }
        return true
    }
}
