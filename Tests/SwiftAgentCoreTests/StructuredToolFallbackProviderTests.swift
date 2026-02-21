import XCTest
@testable import SwiftAgentCore

final class StructuredToolFallbackProviderTests: XCTestCase {
    func testParsesToolCallAndInjectsStructuredProtocol() async throws {
        let mock = MockLLMProvider(
            responses: [
                LLMResponse(
                    contentBlocks: [
                        .text(
                            #"{"type":"tool_call","id":"c1","name":"ping_test_tool","input":{"message":"hello"}}"#
                        )
                    ],
                    stopReason: .endTurn
                )
            ]
        )
        let provider = StructuredToolFallbackProvider(base: mock)
        let tools = [Self.pingTool]

        _ = try await provider.sendMessage(
            system: "base-system",
            messages: [.text(role: .user, "please call tool")],
            tools: tools,
            onTextDelta: { _ in }
        )

        let requestCount = await mock.requestCount()
        XCTAssertEqual(requestCount, 1)
        let request = await mock.request(at: 0)
        XCTAssertEqual(request.tools.count, 0)
        XCTAssertTrue(request.system.contains("Structured tool protocol"))
        XCTAssertTrue(request.system.contains("\"type\":\"tool_call\""))
    }

    func testRetriesWithCorrectionHintAndParsesSecondResponse() async throws {
        let mock = MockLLMProvider(
            responses: [
                LLMResponse(contentBlocks: [.text("not-json")], stopReason: .endTurn),
                LLMResponse(
                    contentBlocks: [
                        .text(
                            #"{"type":"tool_call","name":"ping_test_tool","input":{"message":"ok"}}"#
                        )
                    ],
                    stopReason: .endTurn
                ),
            ]
        )
        let provider = StructuredToolFallbackProvider(
            base: mock,
            config: StructuredToolFallbackConfig(maxCorrectionAttempts: 1, nonCompliancePolicy: .fail)
        )

        let response = try await provider.sendMessage(
            system: "",
            messages: [.text(role: .user, "call tool")],
            tools: [Self.pingTool],
            onTextDelta: { _ in }
        )

        let requestCount = await mock.requestCount()
        XCTAssertEqual(requestCount, 2)
        let second = await mock.request(at: 1)
        XCTAssertTrue(second.messages.last?.textContent.contains("not valid JSON") == true)
        XCTAssertEqual(response.stopReason, .toolUse)
        guard case let .toolUse(_, name, input)? = response.contentBlocks.first else {
            XCTFail("Expected toolUse response")
            return
        }
        XCTAssertEqual(name, "ping_test_tool")
        XCTAssertEqual(input["message"]?.stringValue, "ok")
    }

    func testDegradesToPlainTextWithNoticeWhenStillNonCompliant() async throws {
        let mock = MockLLMProvider(
            responses: [
                LLMResponse(contentBlocks: [.text("first non-json")], stopReason: .endTurn),
                LLMResponse(contentBlocks: [.text("second non-json")], stopReason: .endTurn),
            ]
        )
        let provider = StructuredToolFallbackProvider(
            base: mock,
            config: StructuredToolFallbackConfig(
                maxCorrectionAttempts: 1,
                nonCompliancePolicy: .degradeToPlainText(notice: "NOTICE")
            )
        )

        var streamed = ""
        let response = try await provider.sendMessage(
            system: "",
            messages: [.text(role: .user, "call tool")],
            tools: [Self.pingTool],
            onTextDelta: { streamed += $0 }
        )

        XCTAssertEqual(response.stopReason, .endTurn)
        let text = response.contentBlocks.textContent
        XCTAssertTrue(text.hasPrefix("NOTICE"))
        XCTAssertTrue(text.contains("second non-json"))
        XCTAssertEqual(streamed, text)
    }

    private static var pingTool: ToolDefinition {
        ToolDefinition(
            name: "ping_test_tool",
            description: "Echoes input.",
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "message": .object(["type": .string("string")])
                ]),
            ]
        )
    }
}

private actor MockLLMProvider: LLMProvider {
    nonisolated let providerType: LLMProviderType = .openAICompatible
    nonisolated let displayName: String = "mock"

    struct Request {
        let system: String
        let messages: [LLMMessage]
        let tools: [ToolDefinition]
    }

    private var responses: [LLMResponse]
    private var requests: [Request] = []

    init(responses: [LLMResponse]) {
        self.responses = responses
    }

    func checkAvailability() async -> Bool { true }
    func availableModels() async throws -> [LLMModelInfo] { [] }

    func sendMessage(
        system: String,
        messages: [LLMMessage],
        tools: [ToolDefinition],
        onTextDelta: @escaping (String) -> Void
    ) async throws -> LLMResponse {
        requests.append(Request(system: system, messages: messages, tools: tools))
        let response = responses.isEmpty ? LLMResponse(contentBlocks: [], stopReason: .endTurn) : responses.removeFirst()
        let text = response.contentBlocks.textContent
        if !text.isEmpty {
            onTextDelta(text)
        }
        return response
    }

    func requestCount() -> Int { requests.count }
    func request(at index: Int) -> Request { requests[index] }
}

private extension Array where Element == ContentBlock {
    var textContent: String {
        compactMap { block in
            if case .text(let text) = block {
                return text
            }
            return nil
        }.joined()
    }
}
