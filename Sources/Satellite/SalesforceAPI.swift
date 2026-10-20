import Foundation
import WebKit

/// Read-only SOQL for extensions with the "salesforce" permission. The query runs here, with the `sid` cookie the
/// signed-in user already has for the page's org, so the session never reaches a webpage; only the records do.
@MainActor
enum SalesforceAPI {
    static let apiVersion = "v62.0"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// The session goes only to the org's own host, never to wherever a redirect points.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// The My Domain host that serves the REST API for a page: orgcs.lightning.force.com and orgcs.my.salesforce.com
    /// both give orgcs.my.salesforce.com, and a sandbox's x--uat.sandbox.lightning.force.com gives x--uat.sandbox.my.salesforce.com.
    nonisolated static func apiHost(forPageHost host: String) -> String? {
        let host = host.lowercased()
        for suffix in [".lightning.force.com", ".my.salesforce.com"] where host.hasSuffix(suffix) {
            let org = host.dropLast(suffix.count)
            return org.isEmpty ? nil : org + ".my.salesforce.com"
        }
        return nil
    }

    /// Whether the browser would send `cookie` to https://`host`/.
    nonisolated static func cookie(_ cookie: HTTPCookie, appliesTo host: String) -> Bool {
        let domain = cookie.domain.lowercased()
        guard domain.hasPrefix(".") else { return domain == host }
        return host == domain.dropFirst() || host.hasSuffix(domain)
    }

    /// Runs `soql` against the REST API and returns its response (`{ totalSize, done, records }`) as JSON text.
    static func query(_ soql: String, pageHost: String) async throws -> String {
        guard let host = apiHost(forPageHost: pageHost) else {
            throw Failure(message: "Salesforce queries work only on Salesforce Lightning or My Domain pages.")
        }
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        guard let sid = cookies.filter({ $0.name == "sid" && cookie($0, appliesTo: host) })
            .max(by: { $0.domain.count < $1.domain.count })?.value else {
            throw Failure(message: "No Salesforce session for \(host). Sign in to Salesforce in Satellite, then reload the page.")
        }

        // urlQueryAllowed keeps "+", which Salesforce would read as a space.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        guard let q = soql.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://\(host)/services/data/\(apiVersion)/query?q=\(q)") else {
            throw Failure(message: "The SOQL query could not be encoded.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(sid)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure(message: errorMessage(data, status: status)) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Salesforce answers errors with `[{ "errorCode": ..., "message": ... }]`.
    private static func errorMessage(_ data: Data, status: Int) -> String {
        let first = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first
        let code = first?["errorCode"] as? String ?? "HTTP \(status)"
        let message = first?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
        if code == "INVALID_SESSION_ID" {
            return "\(code): \(message). Your Salesforce session expired; sign in again, then reload the page."
        }
        return "\(code): \(message)"
    }
}
