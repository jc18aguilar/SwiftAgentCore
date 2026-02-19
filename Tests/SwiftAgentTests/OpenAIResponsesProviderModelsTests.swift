import Foundation
import XCTest
@testable import SwiftAgent

final class OpenAIResponsesProviderModelsTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        URLProtocolCodexModelsMock.register()
    }

    override class func tearDown() {
        URLProtocolCodexModelsMock.unregister()
        super.tearDown()
    }

    override func tearDown() {
        URLProtocolCodexModelsMock.clear()
        super.tearDown()
    }

    func testAvailableModelsParsesCodexModelsResponse() async throws {
        var capturedPath = ""
        var capturedQuery = ""
        var capturedAccountID: String?

        URLProtocolCodexModelsMock.setHandler { request in
            capturedPath = request.url?.path ?? ""
            capturedQuery = request.url?.query ?? ""
            capturedAccountID = request.value(forHTTPHeaderField: "ChatGPT-Account-Id")
            return URLProtocolCodexModelsMock.Response(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    #"""
                    {
                      "models": [
                        {"slug":"gpt-5.2-codex", "supported_in_api": true, "visibility": "public", "priority": 2},
                        {"slug":"hidden-model", "supported_in_api": true, "visibility": "hidden", "priority": 1},
                        {"slug":"gpt-4o", "supported_in_api": true, "visibility": "public", "priority": 3}
                      ]
                    }
                    """#.utf8)
            )
        }

        let provider = OpenAIResponsesProvider(
            credentials: OAuthCredentials(
                accessToken: "test-access-token",
                refreshToken: "test-refresh-token",
                expiresAt: Date().addingTimeInterval(3600),
                extra: ["chatgpt_account_id": "acct_123"]
            ),
            oauthProvider: StubOAuthProvider(),
            model: "gpt-5.2-codex",
            codexClientVersion: "9.9.9"
        )

        let models = try await provider.availableModels()
        XCTAssertEqual(capturedPath, "/backend-api/codex/models")
        XCTAssertTrue(capturedQuery.contains("client_version=9.9.9"))
        XCTAssertEqual(capturedAccountID, "acct_123")
        XCTAssertEqual(models.map(\.id), ["gpt-5.2-codex", "gpt-4o"])
    }

    func testAvailableModelsParsesOpenAIStyleResponseFallback() async throws {
        URLProtocolCodexModelsMock.setHandler { _ in
            URLProtocolCodexModelsMock.Response(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    #"""
                    {"data":[{"id":"gpt-5.2-codex"},{"id":"gpt-4o"}]}
                    """#.utf8)
            )
        }

        let provider = OpenAIResponsesProvider(
            credentials: OAuthCredentials(
                accessToken: "test-access-token",
                refreshToken: "test-refresh-token",
                expiresAt: Date().addingTimeInterval(3600)
            ),
            oauthProvider: StubOAuthProvider(),
            model: "gpt-5.2-codex",
            codexClientVersion: "1.2.3"
        )

        let models = try await provider.availableModels()
        XCTAssertEqual(models.map(\.id), ["gpt-5.2-codex", "gpt-4o"])
    }
}

private struct StubOAuthProvider: OAuthProvider {
    let providerId: String = "stub"
    let displayName: String = "stub"

    func buildAuthorizationURL() -> (URL, state: String, codeVerifier: String) {
        (URL(string: "https://example.invalid")!, "state", "verifier")
    }

    func exchangeCode(_ code: String, codeVerifier: String) async throws -> OAuthCredentials {
        OAuthCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(3600)
        )
    }

    func refreshToken(_ credentials: OAuthCredentials) async throws -> OAuthCredentials {
        credentials
    }

    func apiKey(from credentials: OAuthCredentials) -> String {
        credentials.accessToken
    }
}

private final class URLProtocolCodexModelsMock: URLProtocol {
    struct Response {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Response)?

    static func register() {
        URLProtocol.registerClass(Self.self)
    }

    static func unregister() {
        URLProtocol.unregisterClass(Self.self)
    }

    static func setHandler(_ newHandler: @escaping (URLRequest) -> Response) {
        lock.lock()
        handler = newHandler
        lock.unlock()
    }

    static func clear() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        URLProtocolCodexModelsMock.lock.lock()
        let current = URLProtocolCodexModelsMock.handler
        URLProtocolCodexModelsMock.lock.unlock()

        guard let current else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "URLProtocolCodexModelsMock", code: -1))
            return
        }

        let result = current(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://unit.test")!,
            statusCode: result.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: result.headers
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
