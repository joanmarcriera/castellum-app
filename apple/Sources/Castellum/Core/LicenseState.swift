// Castellum - licence state machine (S61).
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Riera Technologies Ltd
//
// Pure logic: every function here is a function of stored state plus an
// injected `now: Date`, never `Date()` — see `LicenseStateTests` for the day
// boundaries this must get right. `LicenseStore` (Keychain persistence) and
// `LicenseActivationClient` (the network contract) build on top of this.

import Foundation

/// The entire persisted licence record — one JSON blob in the Keychain (see
/// `LicenseStore`). A perpetual licence has `licenseExpiresAt == nil`.
struct LicenseRecord: Codable, Equatable {
    /// Set exactly once, on this profile's first launch, and never
    /// overwritten afterwards (see `LicenseStore`'s doc comment — the
    /// "never reset the trial clock" invariant lives in the caller's
    /// discipline, not in the store).
    var trialStartedAt: Date
    var licenseKey: String?
    /// `nil` = perpetual licence (never expires by date alone).
    var licenseExpiresAt: Date?
    /// Set at successful activation, and by any future explicit re-check.
    /// `nil` until a licence has ever been activated.
    var lastValidatedAt: Date?
    /// High-water mark of the wall clock this record has seen (audit #3391).
    /// `status(now:)` never uses a `now` earlier than this, so setting the
    /// system date back no longer extends the trial or the grace window.
    /// Optional with a nil default so records saved before this field existed
    /// still decode.
    var lastSeenAt: Date? = nil
    /// When a build that enforces the trial first ran on this profile
    /// (#2263 slice 1, T10). nil = never: beta builds keep the trial clock
    /// off, and the first enforcing launch restarts the 14 days once, so a
    /// beta tester does not open 1.0 already expired.
    var trialEnforcedSince: Date? = nil
    /// Lemon Squeezy instance id of this Mac's activation (#2263 slice 2):
    /// needed to validate and deactivate. nil = never activated against the
    /// live API (a pre-slice-2 record), which counts as not yet activated.
    var instanceId: String? = nil
    /// The 8 random hex of the instance name (T5), generated once and reused
    /// on re-activation so the same Mac keeps one recognisable label.
    var instanceTag: String? = nil

    /// Trial length (Assumption 1 of the S61 plan): the 2026-09-18 roadmap
    /// row says "14-day trial" explicitly, superseding the Electron-era
    /// design's 30 days (`project-docs/electron-feature-harvest.md`).
    static let trialDays = 14
    /// Offline-grace length (Assumption 2): chosen by the S61 plan itself,
    /// by analogy with the trial length — no current source specifies a
    /// number (the Electron harvest doc's 60 days is a different product
    /// era's figure and is not carried over). One named constant so it's a
    /// one-line change later if Marc wants a different number.
    static let offlineGraceDays = 14

    /// The status this record resolves to at `now`, per Assumption 7's
    /// transition rules:
    /// - a licence key with an unexpired (or absent/perpetual) expiry ALWAYS
    ///   wins, regardless of trial state;
    /// - a licence key past its expiry falls back to grace for
    ///   `offlineGraceDays` past `lastValidatedAt`, then `.licenseExpired`;
    /// - no licence key at all falls back to the trial window from
    ///   `trialStartedAt`.
    /// `trialEnforced == false` (beta builds, `LicenseBuild.trialEnforced`)
    /// never lets the trial run out: with no licence key the status is a
    /// full trial. The pure function defaults to enforcing.
    func status(now rawNow: Date, trialEnforced: Bool = true) -> LicenseStatus {
        // Clock-rollback guard: time never runs backwards for the licence.
        let now = max(rawNow, lastSeenAt ?? rawNow)
        if licenseKey != nil {
            if let expiresAt = licenseExpiresAt {
                if now < expiresAt {
                    return .licensed(expiresAt: expiresAt)
                }
                // Past expiry: fall back to grace, anchored on the last
                // successful validation. Unreachable from this stage's own
                // code paths (nothing re-validates yet, per Assumption 6),
                // but must still be correct for the revalidation stage that
                // plugs into this function unchanged.
                if let lastValidatedAt {
                    let graceEnd = lastValidatedAt.addingTimeInterval(
                        TimeInterval(Self.offlineGraceDays) * 86400)
                    if now < graceEnd {
                        let remaining = daysRemaining(until: graceEnd, from: now)
                        return .licensedInGrace(graceDaysRemaining: remaining)
                    }
                }
                return .licenseExpired
            }
            // No expiry at all: a perpetual licence.
            return .licensed(expiresAt: nil)
        }
        guard trialEnforced else { return .trial(daysRemaining: Self.trialDays) }
        let trialEnd = trialStartedAt.addingTimeInterval(TimeInterval(Self.trialDays) * 86400)
        if now < trialEnd {
            return .trial(daysRemaining: daysRemaining(until: trialEnd, from: now))
        }
        return .trialExpired
    }

    /// This record with `lastSeenAt` advanced to `now`, or `nil` when `now` is
    /// not later than what it already holds (nothing to persist).
    func advancingLastSeen(to now: Date) -> LicenseRecord? {
        if let lastSeenAt, now <= lastSeenAt { return nil }
        var copy = self
        copy.lastSeenAt = now
        return copy
    }

    /// Whole days remaining until `end`, rounded up so "any part of a day
    /// left" still reads as at least 1 day, and never negative.
    private func daysRemaining(until end: Date, from now: Date) -> Int {
        let seconds = end.timeIntervalSince(now)
        guard seconds > 0 else { return 0 }
        return Int((seconds / 86400).rounded(.up))
    }

    var isEntitled: Bool {
        status(now: Date()).isEntitled
    }

    /// Same as `isEntitled` but with an injected clock — prefer this in any
    /// code that already has `now` in hand (tests, `AppModel`).
    func isEntitled(now: Date) -> Bool {
        status(now: now).isEntitled
    }
}

/// A closed, exhaustively-rendered set of licence states — the UI switches
/// over this, never over a stringly-typed status.
enum LicenseStatus: Equatable {
    case trial(daysRemaining: Int)
    case trialExpired
    case licensed(expiresAt: Date?)
    case licensedInGrace(graceDaysRemaining: Int)
    case licenseExpired

    var isEntitled: Bool {
        switch self {
        case .trial, .licensed, .licensedInGrace:
            return true
        case .trialExpired, .licenseExpired:
            return false
        }
    }
}
