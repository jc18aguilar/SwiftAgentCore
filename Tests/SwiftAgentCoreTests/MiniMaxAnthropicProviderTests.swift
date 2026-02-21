import Foundation
import XCTest
@testable import SwiftAgentCore

final class MiniMaxAnthropicProviderTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        URLProtocolMiniMaxMock.register()
    }

    override class func tearDown() {
        URLProtocolMiniMaxMock.unregister()
        super.tearDown()
    }

    override func tearDown() {
        URLProtocolMiniMaxMock.clear()
        super.tearDown()
    }

    func testSendMessageUsesAnthropicEndpointAndPayload() async throws {
        var capturedURL: URL?
        var capturedAuthorization: String?
        var capturedVersion: String?
        var capturedPayload: [String: Any] = [:]

        URLProtocolMiniMaxMock.setHandler { request in
            capturedURL = request.url
            capturedAuthorization = request.value(forHTTPHeaderField: "Authorization")
            capturedVersion = request.value(forHTTPHeaderField: "anthropic-version")
            if let body = Self.requestBodyData(from: request),
                let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            {
                capturedPayload = object
            }

            return URLProtocolMiniMaxMock.Response(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    #"""
                    {
                      "type": "message",
                      "content": [
                        {"type": "text", "text": "mini ok"}
                      ],
                      "stop_reason": "end_turn",
                      "usage": {"input_tokens": 12, "output_tokens": 5}
                    }
                    """#.utf8)
            )
        }

        let provider = MiniMaxAnthropicProvider(apiKey: "test-key", model: "MiniMax-M2.5")
        var streamed = ""
        let response = try await provider.sendMessage(
            system: "System prompt",
            messages: [.text(role: .user, "Hello")],
            tools: [
                ToolDefinition(
                    name: "lookup_note",
                    description: "Find note",
                    inputSchema: ["type": .string("object")]
                )
            ],
            onTextDelta: { streamed += $0 }
        )

        XCTAssertEqual(capturedURL?.absoluteString, "https://api.minimaxi.com/anthropic/v1/messages")
        XCTAssertEqual(capturedAuthorization, "Bearer test-key")
        XCTAssertEqual(capturedVersion, "2023-06-01")
        XCTAssertEqual(capturedPayload["model"] as? String, "MiniMax-M2.5")
        XCTAssertEqual(capturedPayload["system"] as? String, "System prompt")
        XCTAssertEqual(capturedPayload["max_tokens"] as? Int, 4096)

        let messages = capturedPayload["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 1)
        XCTAssertEqual(messages?.first?["role"] as? String, "user")

        let tools = capturedPayload["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual(tools?.first?["name"] as? String, "lookup_note")
        let toolChoice = capturedPayload["tool_choice"] as? [String: Any]
        XCTAssertEqual(toolChoice?["type"] as? String, "auto")

        XCTAssertEqual(streamed, "mini ok")
        XCTAssertEqual(response.stopReason, .endTurn)
        XCTAssertEqual(response.contentBlocks, [.text("mini ok")])
        XCTAssertEqual(response.usage?.inputTokens, 12)
        XCTAssertEqual(response.usage?.outputTokens, 5)
        XCTAssertEqual(response.usage?.totalTokens, 17)
    }

    func testSendMessageParsesToolUseAndSerializesToolResults() async throws {
        var capturedPayload: [String: Any] = [:]
        URLProtocolMiniMaxMock.setHandler { request in
            if let body = Self.requestBodyData(from: request),
                let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            {
                capturedPayload = object
            }
            return URLProtocolMiniMaxMock.Response(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(
                    #"""
                    {
                      "type": "message",
                      "content": [
                        {
                          "type": "tool_use",
                          "id": "call_1",
                          "name": "create_note",
                          "input": {"title": "todo"}
                        }
                      ],
                      "stop_reason": "tool_use",
                      "usage": {"input_tokens": 9, "output_tokens": 2}
                    }
                    """#.utf8)
            )
        }

        let provider = MiniMaxAnthropicProvider(apiKey: "test-key", model: "MiniMax-M2.5")
        let response = try await provider.sendMessage(
            system: "",
            messages: [
                .text(role: .user, "Please use tools"),
                LLMMessage(
                    role: .assistant,
                    contentBlocks: [
                        .toolUse(
                            id: "tool_1",
                            name: "lookup_note",
                            input: ["path": .string("daily/today.md")]
                        )
                    ]
                ),
                LLMMessage(
                    role: .tool,
                    contentBlocks: [
                        .toolResult(
                            toolUseId: "tool_1",
                            content: #"{"found":true}"#,
                            isError: false
                        )
                    ]
                ),
            ],
            tools: [
                ToolDefinition(
                    name: "create_note",
                    description: "Create note",
                    inputSchema: ["type": .string("object")]
                )
            ],
            onTextDelta: { _ in }
        )

        XCTAssertEqual(response.stopReason, .toolUse)
        guard case .toolUse(let id, let name, let input)? = response.contentBlocks.first else {
            XCTFail("Expected toolUse block")
            return
        }
        XCTAssertEqual(id, "call_1")
        XCTAssertEqual(name, "create_note")
        XCTAssertEqual(input["title"]?.stringValue, "todo")

        let messages = capturedPayload["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 3)
        let assistantContent = messages?[1]["content"] as? [[String: Any]]
        XCTAssertEqual(assistantContent?.first?["type"] as? String, "tool_use")
        XCTAssertEqual(assistantContent?.first?["name"] as? String, "lookup_note")

        let toolResultContent = messages?[2]["content"] as? [[String: Any]]
        XCTAssertEqual(messages?[2]["role"] as? String, "user")
        XCTAssertEqual(toolResultContent?.first?["type"] as? String, "tool_result")
        XCTAssertEqual(toolResultContent?.first?["tool_use_id"] as? String, "tool_1")
    }

    func testAvailableModelsReturnsKnownMiniMaxModels() async throws {
        let provider = MiniMaxAnthropicProvider(apiKey: "test-key", model: "MiniMax-M2.5")
        let models = try await provider.availableModels()
        XCTAssertTrue(models.contains(where: { $0.id == "MiniMax-M2.5" }))
        XCTAssertTrue(models.contains(where: { $0.id == "MiniMax-M2.5-highspeed" }))
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

private final class URLProtocolMiniMaxMock: URLProtocol {
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
        URLProtocolMiniMaxMock.lock.lock()
        let current = URLProtocolMiniMaxMock.handler
        URLProtocolMiniMaxMock.lock.unlock()

        guard let current else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(domain: "URLProtocolMiniMaxMock", code: -1)
            )
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
