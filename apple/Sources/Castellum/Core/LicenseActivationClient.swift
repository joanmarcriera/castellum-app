// Castellum - Lemon Squeezy licence API client (S61, #2263 slice 2).
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Riera Technologies Ltd
//
// Speaks the three public Lemon Squeezy License API calls (activate,
// validate, deactivate; no API key needed) straight from the app - decision
// T1 of project-docs/specs/2026-10-12/licensing-chain.md. Nothing here runs
// on its own: activation and deactivation follow an explicit user click, and
// the weekly re-check (slice 3) is the only automatic caller.
//
// Rules this file keeps:
// - The licence key travels only in the POST body, is never logged and never
//   put in an error message.
// - A definite server answer is a state or a rejection; a transport failure,
//   a 5xx/429 or an undecodable body (captive portal HTML) is never a
//   rejection, so an unreachable server cannot take a licence away.
// - Tests and UIT-1 never reach the real host: `LicenseAPI.base` is a
//   compiled constant that only a Debug build lets an env var override, and
//   `call` refuses the production host while a test host or UI script runs.
//
// The field names below come from memory of the Lemon Squeezy docs, not a
// live sample; slice 4 captures real test-mode responses. A differing field
// is a change in `Wire` only.

import Foundation

// MARK: - Endpoint

enum LicenseAPI {
    static let productionBase = URL(string: "https://api.lemonsqueezy.com/v1/licenses")!

    /// Debug builds honour CASTELLUM_LICENSE_ENDPOINT (tests, UIT-1, a local
    /// mock); Release never does (T4), so `defaults write` or a launch
    /// environment cannot point a shipped app at a fake server.
    static var base: URL {
        #if DEBUG
        return resolveBase(env: ProcessInfo.processInfo.environment, isDebug: true)
        #else
        return productionBase
        #endif
    }

    /// The pure rule behind `base`, so the Release branch is testable from a
    /// Debug test host. An override must be an http(s) URL with a host.
    static func resolveBase(env: [String: String], isDebug: Bool) -> URL {
        guard isDebug,
              let raw = env["CASTELLUM_LICENSE_ENDPOINT"]?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return productionBase }
        return url
    }

    /// The host no test or UI script may contact.
    static func isProductionHost(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == "lemonsqueezy.com" || host.hasSuffix(".lemonsqueezy.com")
    }
}

// MARK: - Results and errors

/// What the server said about a key, whichever of the three calls it was.
struct LicenseServerState: Equatable {
    let ok: Bool               // activated / valid / deactivated
    let status: String?        // license_key.status: inactive | active | expired | disabled
    let expiresAt: Date?       // license_key.expires_at
    let instanceId: String?    // instance.id
    let activationLimit: Int?
    let activationUsage: Int?
    let storeId: Int?          // meta.store_id
    let productId: Int?        // meta.product_id
    let serverError: String?   // error, verbatim
}

enum LicenseRejection: Equatable {
    case notFound, activationLimitReached, expired, disabled, wrongProduct, other
}

enum LicenseActivationError: Error, Equatable {
    /// Failed the lenient client-side format check; never touched the network.
    case malformedKey
    /// The server answered with something that is not the documented JSON.
    case malformedResponse
    /// Transport failure, timeout, 5xx or 429 (offline, blocked, overloaded).
    case network(String)
    /// The server definitely said no.
    case rejected(LicenseRejection, serverText: String?)

    /// The text shown to the user. Localised; the server's own English text
    /// follows in brackets, verbatim, and is never matched against.
    var localizedMessage: String {
        switch self {
        case .malformedKey:
            return String(localized: "That doesn't look like a Castellum licence key. Copy it again from your purchase email.")
        case .malformedResponse:
            return String(localized: "The licence server sent back something Castellum couldn't understand. Try again later.")
        case .network(let reason):
            return String(localized: "Couldn't reach the licence server. Check your connection and try again.") + " (\(reason))"
        case .rejected(let kind, let serverText):
            let base: String
            switch kind {
            case .notFound:
                base = String(localized: "That licence key wasn't found. Check it and try again.")
            case .activationLimitReached:
                base = String(localized: "This licence is already active on the most Macs it allows. Deactivate it on another Mac, or contact support.")
            case .expired:
                base = String(localized: "That licence has expired.")
            case .disabled:
                base = String(localized: "That licence has been disabled. Contact support if you think this is a mistake.")
            case .wrongProduct:
                base = String(localized: "That key is for a different product, not Castellum.")
            case .other:
                base = String(localized: "The licence server didn't accept that key.")
            }
            if let serverText, !serverText.isEmpty { return "\(base) [\(serverText)]" }
            return base
        }
    }
}

// MARK: - Client

enum LicenseActivationClient {
    /// Never let a slow or unreachable licence host wedge the UI (same
    /// precedent as the RFC 8058 unsubscribe call's timeout).
    static let timeoutSeconds: TimeInterval = 10

    /// Shape-agnostic key check (T2): 3 to 8 hyphen-joined groups of 4+
    /// letters or digits, 19 to 64 characters, case kept as typed. Accepts a
    /// UUID-shaped key and the retired four-group shape alike; the server is the
    /// real check.
    static func isPlausibleKeyFormat(_ key: String) -> Bool {
        guard (19...64).contains(key.count) else { return false }
        return key.range(
            of: "^[A-Za-z0-9]{4,}(-[A-Za-z0-9]{4,}){2,7}$", options: .regularExpression) != nil
    }

    /// Trims whitespace, line breaks and the quotes an email client may put
    /// around a pasted key. Never changes case.
    static func normalizeKey(_ raw: String) -> String {
        let junk = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\"'`\u{201C}\u{201D}\u{2018}\u{2019}"))
        return raw.trimmingCharacters(in: junk)
    }

    /// Activates `key` for this Mac. `pin` is checked on the answer; on a
    /// mismatch the instance just created is released (best effort) so a
    /// foreign key does not cost a seat, then `.rejected(.wrongProduct)`.
    static func activate(
        key: String, instanceName: String, base: URL, session: URLSession,
        pin: LicensePin = .none
    ) async throws -> LicenseServerState {
        guard isPlausibleKeyFormat(key) else { throw LicenseActivationError.malformedKey }
        let state = try await call(
            "activate", ["license_key": key, "instance_name": instanceName], base: base, session: session)
        guard pin.matches(storeId: state.storeId, productId: state.productId) else {
            if let instanceId = state.instanceId {
                _ = try? await deactivate(key: key, instanceId: instanceId, base: base, session: session)
            }
            throw LicenseActivationError.rejected(.wrongProduct, serverText: nil)
        }
        return state
    }

    static func validate(
        key: String, instanceId: String, base: URL, session: URLSession
    ) async throws -> LicenseServerState {
        try await call("validate", ["license_key": key, "instance_id": instanceId], base: base, session: session)
    }

    static func deactivate(
        key: String, instanceId: String, base: URL, session: URLSession
    ) async throws -> LicenseServerState {
        try await call("deactivate", ["license_key": key, "instance_id": instanceId], base: base, session: session)
    }

    // MARK: Wire

    /// The documented response, every field optional so a missing one is a
    /// value and not a decode failure. The three booleans are the per-call
    /// success flag.
    private struct Wire: Decodable {
        struct Key: Decodable {
            let status: String?
            let expires_at: String?
            let activation_limit: Int?
            let activation_usage: Int?
        }
        struct Instance: Decodable { let id: String? }
        struct Meta: Decodable {
            let store_id: Int?
            let product_id: Int?
        }
        let activated: Bool?
        let valid: Bool?
        let deactivated: Bool?
        let error: String?
        let license_key: Key?
        let instance: Instance?
        let meta: Meta?
    }

    private static func call(
        _ action: String, _ fields: [String: String], base: URL, session: URLSession
    ) async throws -> LicenseServerState {
        guard !(LicenseAPI.isProductionHost(base) && TestHost.suppressesLaunchSideEffects) else {
            // Hard stop: no test run or UI script ever reaches the real API.
            throw LicenseActivationError.network("the real licence server is blocked in tests")
        }
        var request = URLRequest(url: base.appendingPathComponent(action))
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formEncode(fields).utf8)

        let data: Data
        let status: Int
        do {
            let (body, response) = try await session.data(for: request)
            data = body
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw LicenseActivationError.network(error.localizedDescription)
        }
        if status == 429 || status >= 500 { throw LicenseActivationError.network("HTTP \(status)") }

        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            throw LicenseActivationError.malformedResponse
        }
        // Only the flag of the call being made counts.
        let flag = action == "activate" ? wire.activated : action == "validate" ? wire.valid : wire.deactivated
        var expiresAt: Date?
        if let text = wire.license_key?.expires_at, !text.isEmpty {
            guard let date = parseDate(text) else {
                // The server may already have granted a seat: give it back before failing.
                if action == "activate", flag == true, let instanceId = wire.instance?.id, let key = fields["license_key"] {
                    _ = try? await deactivate(key: key, instanceId: instanceId, base: base, session: session)
                }
                throw LicenseActivationError.malformedResponse
            }
            expiresAt = date
        }
        let state = LicenseServerState(
            ok: flag ?? false,
            status: wire.license_key?.status, expiresAt: expiresAt, instanceId: wire.instance?.id,
            activationLimit: wire.license_key?.activation_limit,
            activationUsage: wire.license_key?.activation_usage,
            storeId: wire.meta?.store_id, productId: wire.meta?.product_id, serverError: wire.error)
        if state.ok && (200..<300).contains(status) { return state }
        throw LicenseActivationError.rejected(
            rejection(for: state, httpStatus: status), serverText: state.serverError)
    }

    /// Never string-matches the English error text.
    private static func rejection(for state: LicenseServerState, httpStatus: Int) -> LicenseRejection {
        if httpStatus == 404 { return .notFound }
        if state.status == "expired" { return .expired }
        if state.status == "disabled" { return .disabled }
        if let limit = state.activationLimit, let usage = state.activationUsage, limit > 0, usage >= limit {
            return .activationLimitReached
        }
        return .other
    }

    /// ISO 8601 with or without fractional seconds
    /// (`2026-10-12T09:00:00.000000Z` and `2026-10-12T09:00:00Z`).
    static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    /// application/x-www-form-urlencoded: everything but the unreserved set
    /// is percent-escaped, so the instance name's spaces and middle dot are safe.
    private static func formEncode(_ fields: [String: String]) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return fields.sorted { $0.key < $1.key }.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }
}

/// The instance name Lemon Squeezy shows in its dashboard (T5): app version
/// and a random tag, nothing that identifies the person or the machine.
enum LicenseInstanceName {
    static func makeTag() -> String {
        String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    }

    static func make(version: String, tag: String) -> String {
        "Castellum \(version) \u{00B7} \(tag)"
    }
}
