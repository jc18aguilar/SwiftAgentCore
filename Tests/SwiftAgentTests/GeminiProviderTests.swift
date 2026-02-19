import Foundation
import XCTest
@testable import SwiftAgent

final class GeminiProviderTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        URLProtocolGeminiMock.register()
    }

    override class func tearDown() {
        URLProtocolGeminiMock.unregister()
        super.tearDown()
    }

    override func tearDown() {
        URLProtocolGeminiMock.clear()
        super.tearDown()
    }

    func testSendMessageUsesGeminiNativeEndpointAndPayload() async throws {
        var capturedURL: URL?
        var capturedGoogAPIKey: String?
        var capturedPayload: [String: Any] = [:]

        URLProtocolGeminiMock.setHandler { request in
            capturedURL = request.url
            capturedGoogAPIKey = request.value(forHTTPHeaderField: "x-goog-api-key")
            if let body = Self.requestBodyData(from: request),
                let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            {
                capturedPayload = object
            }

            return URLProtocolGeminiMock.Response(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: Self.sse([
                    #"{"candidates":[{"content":{"parts":[{"text":"gemini "}]}}]}"#,
                    #"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}],"usageMetadata":{"promptTokenCount":7,"candidatesTokenCount":3,"totalTokenCount":10}}"#,
                ])
            )
        }

        let provider = GeminiProvider(apiKey: "test-key", model: "gemini-2.0-flash")
        var streamed = ""
        let response = try await provider.sendMessage(
            system: "System prompt",
            messages: [.text(role: .user, "Hello")],
            tools: [],
            onTextDelta: { streamed += $0 }
        )

        XCTAssertEqual(
            capturedURL?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:streamGenerateContent?alt=sse"
        )
        XCTAssertEqual(capturedGoogAPIKey, "test-key")

        let systemInstruction = capturedPayload["systemInstruction"] as? [String: Any]
        let systemParts = systemInstruction?["parts"] as? [[String: Any]]
        XCTAssertEqual(systemParts?.first?["text"] as? String, "System prompt")

        let contents = capturedPayload["contents"] as? [[String: Any]]
        XCTAssertEqual(contents?.count, 1)
        XCTAssertEqual(contents?.first?["role"] as? String, "user")
        let firstParts = contents?.first?["parts"] as? [[String: Any]]
        XCTAssertEqual(firstParts?.first?["text"] as? String, "Hello")

        XCTAssertEqual(streamed, "gemini ok")
        XCTAssertEqual(response.stopReason, .endTurn)
        XCTAssertEqual(response.contentBlocks, [.text("gemini ok")])
        XCTAssertEqual(response.usage?.inputTokens, 7)
        XCTAssertEqual(response.usage?.outputTokens, 3)
        XCTAssertEqual(response.usage?.totalTokens, 10)
    }

    func testSendMessageParsesFunctionCall() async throws {
        var capturedPayload: [String: Any] = [:]
        URLProtocolGeminiMock.setHandler { request in
            if let body = Self.requestBodyData(from: request),
                let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            {
                capturedPayload = object
            }
            return URLProtocolGeminiMock.Response(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: Self.sse([
                    #"{"candidates":[{"content":{"parts":[{"functionCall":{"name":"ping_test_tool","args":{"message":"hello"}}}]}}]}"#
                ])
            )
        }

        let provider = GeminiProvider(apiKey: "test-key", model: "gemini-2.0-flash")
        let response = try await provider.sendMessage(
            system: "",
            messages: [.text(role: .user, "Call the tool")],
            tools: [
                ToolDefinition(
                    name: "ping_test_tool",
                    description: "Echo input",
                    inputSchema: ["type": .string("object")]
                )
            ],
            onTextDelta: { _ in }
        )

        XCTAssertEqual(response.stopReason, .toolUse)
        guard case .toolUse(_, let name, let input)? = response.contentBlocks.first else {
            XCTFail("Expected first block to be toolUse")
            return
        }
        XCTAssertEqual(name, "ping_test_tool")
        XCTAssertEqual(input["message"]?.stringValue, "hello")

        let tools = capturedPayload["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        let toolConfig = capturedPayload["toolConfig"] as? [String: Any]
        let functionCallingConfig = toolConfig?["functionCallingConfig"] as? [String: Any]
        XCTAssertEqual(functionCallingConfig?["mode"] as? String, "AUTO")
    }

    func testAvailableModelsParsesGeminiList() async throws {
        URLProtocolGeminiMock.setHandler { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://generativelanguage.googleapis.com/v1beta/models?pageSize=100"
            )
            return URLProtocolGeminiMock.Response(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    #"""
                    {
                      "models": [
                        {
                          "name": "models/gemini-2.0-flash",
                          "displayName": "Gemini 2.0 Flash",
                          "inputTokenLimit": 1048576,
                          "supportedGenerationMethods": ["generateContent", "countTokens"]
                        },
                        {
                          "name": "models/embedding-001",
                          "displayName": "Embedding",
                          "supportedGenerationMethods": ["embedContent"]
                        }
                      ]
                    }
                    """#.utf8)
            )
        }

        let provider = GeminiProvider(apiKey: "test-key", model: "gemini-2.0-flash")
        let models = try await provider.availableModels()

        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.id, "gemini-2.0-flash")
        XCTAssertEqual(models.first?.name, "Gemini 2.0 Flash")
        XCTAssertEqual(models.first?.contextWindow, 1_048_576)
    }

    private static func sse(_ events: [String]) -> Data {
        var payload = events.map { "data: \($0)\n\n" }.joined()
        payload += "data: [DONE]\n\n"
        return Data(payload.utf8)
    }

    private static func requestBodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        let bufferSize = 16 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}

private final class URLProtocolGeminiMock: URLProtocol {
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
        URLProtocolGeminiMock.lock.lock()
        let current = URLProtocolGeminiMock.handler
        URLProtocolGeminiMock.lock.unlock()

        guard let current else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "URLProtocolGeminiMock", code: -1))
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
