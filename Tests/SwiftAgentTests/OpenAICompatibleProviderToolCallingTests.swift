import Foundation
import XCTest
@testable import SwiftAgent

final class OpenAICompatibleProviderToolCallingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(URLProtocolMock.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(URLProtocolMock.self)
        super.tearDown()
    }

    override func tearDown() {
        URLProtocolMock.clear()
        super.tearDown()
    }

    func testSendMessageIncludesToolsPayload() async throws {
        var capturedPayload: [String: Any] = [:]
        URLProtocolMock.setHandler { request in
            if let body = Self.requestBodyData(from: request),
                let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            {
                capturedPayload = object
            }

            return URLProtocolMock.Response(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: Self.sse([
                    #"{"choices":[{"delta":{"content":"MAI_SMOKE_OK"}}]}"#
                ])
            )
        }

        let provider = makeProvider()
        let tools: [ToolDefinition] = [
            ToolDefinition(
                name: "ping_test_tool",
                description: "Echo input.",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "message": .object(["type": .string("string")])
                    ]),
                ]
            )
        ]

        _ = try await provider.sendMessage(
            system: "Test system prompt",
            messages: [.text(role: .user, "Hello")],
            tools: tools,
            onTextDelta: { _ in }
        )

        XCTAssertEqual(capturedPayload["model"] as? String, "test-model")
        XCTAssertEqual(capturedPayload["tool_choice"] as? String, "auto")
        let rawTools = capturedPayload["tools"] as? [[String: Any]]
        XCTAssertEqual(rawTools?.count, 1)
        let function = rawTools?.first?["function"] as? [String: Any]
        XCTAssertEqual(function?["name"] as? String, "ping_test_tool")
    }

    func testSendMessageParsesToolCallsFromStream() async throws {
        URLProtocolMock.setHandler { _ in
            URLProtocolMock.Response(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: Self.sse([
                    #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"ping_test_tool","arguments":"{\"message\":\"hel"}}]}}]}"#,
                    #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"lo\"}"}}]},"finish_reason":"tool_calls"}]}"#
                ])
            )
        }

        let provider = makeProvider()
        let response = try await provider.sendMessage(
            system: "Tool calling test",
            messages: [.text(role: .user, "Call the tool")],
            tools: [
                ToolDefinition(
                    name: "ping_test_tool",
                    description: "Echo input.",
                    inputSchema: ["type": .string("object")]
                )
            ],
            onTextDelta: { _ in }
        )

        XCTAssertEqual(response.stopReason, .toolUse)
        guard case .toolUse(let id, let name, let input) = response.contentBlocks.first else {
            XCTFail("Expected first block to be toolUse")
            return
        }

        XCTAssertEqual(id, "call_1")
        XCTAssertEqual(name, "ping_test_tool")
        XCTAssertEqual(input["message"]?.stringValue, "hello")
    }

    func testSendMessageThrowsProviderErrorForBadRequest() async {
        URLProtocolMock.setHandler { _ in
            URLProtocolMock.Response(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":{"message":"does not support tools"}}"#.utf8)
            )
        }

        let provider = makeProvider()
        do {
            _ = try await provider.sendMessage(
                system: "Tool calling test",
                messages: [.text(role: .user, "Call tool")],
                tools: [],
                onTextDelta: { _ in }
            )
            XCTFail("Expected error")
        } catch let error as OpenAICompatibleProviderError {
            guard case .requestFailed(let statusCode, let body, _) = error else {
                XCTFail("Expected requestFailed error")
                return
            }
            XCTAssertEqual(statusCode, 400)
            XCTAssertTrue(body.contains("does not support tools"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeProvider() -> OpenAICompatibleProvider {
        let config = LLMProviderConfig(
            baseURL: URL(string: "https://unit.test/v1")!,
            authMethod: .none,
            model: "test-model",
            headers: [:]
        )
        return OpenAICompatibleProvider(
            displayName: "unit",
            profile: .generic("unit"),
            config: config
        )
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

private final class URLProtocolMock: URLProtocol {
    struct Response {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Response)?

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
        URLProtocolMock.lock.lock()
        let current = URLProtocolMock.handler
        URLProtocolMock.lock.unlock()

        guard let current else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "URLProtocolMock", code: -1))
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
