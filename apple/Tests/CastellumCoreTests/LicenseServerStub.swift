// Castellum - shared in-process stand-in for the Lemon Squeezy licence API
// (#2263 slice 2). A URLProtocol, not a socket: deterministic, no port, and a
// session built on it can reach nothing else. Every request is recorded so a
// test can assert on the form body, and every contacted host is kept so
// `assertNoRealHostContacted` can prove nothing went to api.lemonsqueezy.com.
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Riera Technologies Ltd

import XCTest
@testable import Castellum

final class LicenseServerStub: URLProtocol {
    struct Recorded {
        let url: URL
        /// "activate", "validate" or "deactivate" (the last path component).
        let action: String
        let form: [String: String]
        let headers: [String: String]
    }

    enum Reply {
        case json(String, status: Int = 200)
        case transport(Error)
    }

    nonisolated(unsafe) private static let lock = NSLock()
    nonisolated(unsafe) private static var _requests: [Recorded] = []
    nonisolated(unsafe) private static var _handler: ((Recorded) -> Reply)?

    static var requests: [Recorded] { lock.lock(); defer { lock.unlock() }; return _requests }
    static var handler: ((Recorded) -> Reply)? {
        get { lock.lock(); defer { lock.unlock() }; return _handler }
        set { lock.lock(); _handler = newValue; lock.unlock() }
    }

    static let base = URL(string: "https://license.invalid/v1/licenses")!

    static func reset() {
        lock.lock(); _requests = []; _handler = nil; lock.unlock()
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LicenseServerStub.self]
        return URLSession(configuration: config)
    }

    /// Fails the test when any request reached the production host.
    static func assertNoRealHostContacted(file: StaticString = #filePath, line: UInt = #line) {
        let real = requests.filter { LicenseAPI.isProductionHost($0.url) }
        XCTAssertTrue(real.isEmpty, "a request went to api.lemonsqueezy.com", file: file, line: line)
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Recorded(
            url: request.url!, action: request.url!.lastPathComponent,
            form: Self.parseForm(Self.bodyData(of: request)),
            headers: request.allHTTPHeaderFields ?? [:])
        Self.lock.lock(); Self._requests.append(recorded); Self.lock.unlock()
        switch Self.handler?(recorded) ?? .transport(URLError(.notConnectedToInternet)) {
        case .transport(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .json(let body, let status):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    private static func parseForm(_ data: Data) -> [String: String] {
        var out: [String: String] = [:]
        for pair in String(decoding: data, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            out[String(parts[0])] = String(parts[1]).removingPercentEncoding ?? String(parts[1])
        }
        return out
    }

    // MARK: Canned bodies (shape from memory of the Lemon Squeezy docs; see
    // LicenseActivationClient's header, slice 4 captures real samples).

    static let storeId = 11, productId = 22

    static func activated(
        instance: String = "inst-1", expires: String? = "2027-10-12T09:00:00.000000Z",
        status: String = "active", limit: Int = 3, usage: Int = 1,
        store: Int = storeId, product: Int = productId
    ) -> String {
        let exp = expires.map { "\"\($0)\"" } ?? "null"
        return """
        {"activated":true,"error":null,"license_key":{"id":1,"status":"\(status)","key":"k",\
        "activation_limit":\(limit),"activation_usage":\(usage),"created_at":"2026-10-12T09:00:00.000000Z",\
        "expires_at":\(exp)},"instance":{"id":"\(instance)","name":"n","created_at":"2026-10-12T09:00:00.000000Z"},\
        "meta":{"store_id":\(store),"order_id":5,"product_id":\(product),"product_name":"Castellum"}}
        """
    }

    static func valid(expires: String? = "2027-10-12T09:00:00.000000Z") -> String {
        activated(expires: expires).replacingOccurrences(of: "\"activated\"", with: "\"valid\"")
    }

    static let deactivated = """
    {"deactivated":true,"error":null,"license_key":{"id":1,"status":"inactive","activation_limit":3,\
    "activation_usage":0,"expires_at":null},"meta":{"store_id":11,"product_id":22}}
    """

    static func rejected(_ error: String, status: String = "active", limit: Int = 3, usage: Int = 1) -> String {
        """
        {"activated":false,"error":"\(error)","license_key":{"id":1,"status":"\(status)",\
        "activation_limit":\(limit),"activation_usage":\(usage),"expires_at":null},"instance":null,\
        "meta":{"store_id":11,"product_id":22}}
        """
    }
}
