import XCTest
@testable import SwiftAgentCore

final class AgentLoopTests: XCTestCase {
    func testEmitsLifecycleAndToolExecutionEventsForApprovedConfirmation() async {
        let provider = SequenceProvider(
            responses: [
                LLMResponse(
                    contentBlocks: [
                        .text("Working on it..."),
                        .toolUse(id: "call-1", name: "confirm_echo", input: ["message": .string("hello")]),
                    ],
                    stopReason: .toolUse
                ),
                LLMResponse(
                    contentBlocks: [.text("Done.")],
                    stopReason: .endTurn
                ),
            ]
        )
        let toolState = ToolExecutionCounter()
        let tool = ConfirmEchoTool(state: toolState)

        let stream = runAgentLoop(
            config: AgentLoopConfig(
                provider: provider,
                tools: [tool],
                buildSystemPrompt: { "system" },
                confirmationHandler: { _, _ in true }
            ),
            initialMessages: [.text(role: .user, "Run the tool.")],
            onEvent: { _ in }
        )

        let events = await collectEvents(from: stream)
        let kinds = eventKinds(events)
        assertOrderedSubsequence(
            [
                "agentStart",
                "turnStart:1",
                "messageStart:assistant",
                "messageTextDelta",
                "messageEnd",
                "confirmationRequired:confirm_echo",
                "confirmationResolved:true",
                "toolExecutionStart:confirm_echo",
                "toolExecutionEnd:confirm_echo:false",
                "messageStart:assistant",
                "messageTextDelta",
                "messageEnd",
                "turnEnd:1",
                "agentEnd",
            ],
            in: kinds
        )

        let executeCount = await toolState.value()
        XCTAssertEqual(executeCount, 1)

        let requestCount = await provider.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testDeclinedConfirmationSkipsToolExecutionAndReturnsErrorToolResult() async {
        let provider = SequenceProvider(
            responses: [
                LLMResponse(
                    contentBlocks: [
                        .toolUse(id: "call-1", name: "confirm_echo", input: ["message": .string("hello")]),
                    ],
                    stopReason: .toolUse
                ),
                LLMResponse(contentBlocks: [.text("Acknowledged.")], stopReason: .endTurn),
            ]
        )
        let toolState = ToolExecutionCounter()
        let tool = ConfirmEchoTool(state: toolState)

        let stream = runAgentLoop(
            config: AgentLoopConfig(
                provider: provider,
                tools: [tool],
                buildSystemPrompt: { "system" },
                confirmationHandler: { _, _ in false }
            ),
            initialMessages: [.text(role: .user, "Run the tool.")],
            onEvent: { _ in }
        )

        _ = await collectEvents(from: stream)

        let executeCount = await toolState.value()
        XCTAssertEqual(executeCount, 0)

        let secondRequest = await provider.request(at: 1)
        let result = firstToolResult(in: secondRequest.messages)
        XCTAssertEqual(result?.content, "User declined execution.")
        XCTAssertEqual(result?.isError, true)
    }

    func testUnknownToolProducesErrorToolResultAndContinues() async {
        let provider = SequenceProvider(
            responses: [
                LLMResponse(
                    contentBlocks: [
                        .toolUse(id: "call-1", name: "missing_tool", input: [:]),
                    ],
                    stopReason: .toolUse
                ),
                LLMResponse(contentBlocks: [.text("No further action.")], stopReason: .endTurn),
            ]
        )

        let stream = runAgentLoop(
            config: AgentLoopConfig(
                provider: provider,
                tools: [],
                buildSystemPrompt: { "system" },
                confirmationHandler: { _, _ in true }
            ),
            initialMessages: [.text(role: .user, "Run the missing tool.")],
            onEvent: { _ in }
        )

        let events = await collectEvents(from: stream)
        let secondRequest = await provider.request(at: 1)
        let result = firstToolResult(in: secondRequest.messages)

        XCTAssertEqual(result?.isError, true)
        XCTAssertEqual(result?.content, "Tool 'missing_tool' is not registered.")
        XCTAssertTrue(
            events.contains { event in
                if case .toolExecutionEnd(let name, let text, let isError) = event {
                    return name == "missing_tool" && isError && text.contains("not registered")
                }
                return false
            }
        )
    }

    func testFollowUpMessagesStartSecondTurn() async {
        let provider = SequenceProvider(
            responses: [
                LLMResponse(contentBlocks: [.text("Turn 1 complete.")], stopReason: .endTurn),
                LLMResponse(contentBlocks: [.text("Turn 2 complete.")], stopReason: .endTurn),
            ]
        )
        let followUp = FollowUpQueue()

        let stream = runAgentLoop(
            config: AgentLoopConfig(
                provider: provider,
                tools: [],
                buildSystemPrompt: { "system" },
                confirmationHandler: { _, _ in true },
                getFollowUpMessages: { await followUp.next() }
            ),
            initialMessages: [.text(role: .user, "Turn 1 please.")],
            onEvent: { _ in }
        )

        let events = await collectEvents(from: stream)
        let turnStarts = events.compactMap { event -> Int? in
            if case .turnStart(let turnIndex) = event { return turnIndex }
            return nil
        }
        let turnEnds = events.compactMap { event -> Int? in
            if case .turnEnd(let turnIndex) = event { return turnIndex }
            return nil
        }

        XCTAssertEqual(turnStarts, [1, 2])
        XCTAssertEqual(turnEnds, [1, 2])
        let requestCount = await provider.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testRetriesRetryableProviderErrorAndEventuallySucceeds() async {
        let provider = RetryThenSuccessProvider(
            failuresRemaining: 1,
            statusCode: 429,
            retryAfter: nil,
            response: LLMResponse(contentBlocks: [.text("Recovered.")], stopReason: .endTurn)
        )

        let stream = runAgentLoop(
            config: AgentLoopConfig(
                provider: provider,
                tools: [],
                buildSystemPrompt: { "system" },
                confirmationHandler: { _, _ in true },
                maxRetries: 1,
                retryDelay: 0
            ),
            initialMessages: [.text(role: .user, "Say hi.")],
            onEvent: { _ in }
        )

        let events = await collectEvents(from: stream)
        let requestCount = await provider.requestCount()
        XCTAssertEqual(requestCount, 2)
        XCTAssertFalse(events.contains { event in
            if case .error = event { return true }
            return false
        })
    }

    func testDoesNotRetryNonRetryableProviderError() async {
        let provider = AlwaysFailProvider(statusCode: 400)

        let stream = runAgentLoop(
            config: AgentLoopConfig(
                provider: provider,
                tools: [],
                buildSystemPrompt: { "system" },
                confirmationHandler: { _, _ in true },
                maxRetries: 3,
                retryDelay: 0
            ),
            initialMessages: [.text(role: .user, "Say hi.")],
            onEvent: { _ in }
        )

        let events = await collectEvents(from: stream)
        let requestCount = await provider.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertNotNil(firstError(in: events))
    }

    func testLLMCallTimeoutEmitsError() async {
        let provider = SlowSuccessProvider(
            delay: 0.25,
            response: LLMResponse(contentBlocks: [.text("Late response")], stopReason: .endTurn)
        )

        let stream = runAgentLoop(
            config: AgentLoopConfig(
                provider: provider,
                tools: [],
                buildSystemPrompt: { "system" },
                confirmationHandler: { _, _ in true },
                llmCallTimeout: 0.05
            ),
            initialMessages: [.text(role: .user, "Say hi.")],
            onEvent: { _ in }
        )

        let events = await collectEvents(from: stream)
        let requestCount = await provider.requestCount()
        XCTAssertEqual(requestCount, 1)
        let message = firstError(in: events)?.localizedDescription ?? ""
        XCTAssertTrue(message.contains("LLM call timed out"))
    }

    func testTotalTimeoutStopsRetryLoop() async {
        let provider = AlwaysFailProvider(statusCode: 500)

        let stream = runAgentLoop(
            config: AgentLoopConfig(
                provider: provider,
                tools: [],
                buildSystemPrompt: { "system" },
                confirmationHandler: { _, _ in true },
                maxRetries: 5,
                retryDelay: 0.2,
                totalTimeout: 0.25
            ),
            initialMessages: [.text(role: .user, "Say hi.")],
            onEvent: { _ in }
        )

        let events = await collectEvents(from: stream)
        let requestCount = await provider.requestCount()
        XCTAssertEqual(requestCount, 2)
        let message = firstError(in: events)?.localizedDescription ?? ""
        XCTAssertTrue(message.contains("Agent loop timed out"))
    }
}

private actor SequenceProvider: LLMProvider {
    nonisolated let providerType: LLMProviderType = .openAICompatible
    nonisolated let displayName: String = "sequence-provider"

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
        let response = responses.isEmpty
            ? LLMResponse(contentBlocks: [], stopReason: .endTurn)
            : responses.removeFirst()
        for block in response.contentBlocks {
            if case .text(let text) = block {
                onTextDelta(text)
            }
        }
        return response
    }

    func requestCount() -> Int { requests.count }
    func request(at index: Int) -> Request { requests[index] }
}

private struct ConfirmEchoTool: AgentTool {
    let name = "confirm_echo"
    let description = "Echoes a message with confirmation."
    let safetyLevel: ToolSafetyLevel = .needsConfirmation
    let state: ToolExecutionCounter
    let inputSchema: JSONObject = [
        "type": .string("object"),
        "properties": .object([
            "message": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("message")]),
    ]

    func execute(input: JSONObject) async throws -> String {
        await state.increment()
        return "echo: \(input["message"]?.stringValue ?? "")"
    }

    func humanReadableSummary(for input: JSONObject) -> String {
        "Echo '\(input["message"]?.stringValue ?? "")'"
    }
}

private actor ToolExecutionCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

private actor FollowUpQueue {
    private var emitted = false

    func next() -> [LLMMessage] {
        if emitted {
            return []
        }
        emitted = true
        return [.text(role: .user, "Please do one more turn.")]
    }
}

private actor RetryThenSuccessProvider: LLMProvider {
    nonisolated let providerType: LLMProviderType = .openAICompatible
    nonisolated let displayName: String = "retry-then-success"

    private var failuresRemaining: Int
    private let statusCode: Int
    private let retryAfter: TimeInterval?
    private let response: LLMResponse
    private var count = 0

    init(
        failuresRemaining: Int,
        statusCode: Int,
        retryAfter: TimeInterval?,
        response: LLMResponse
    ) {
        self.failuresRemaining = max(0, failuresRemaining)
        self.statusCode = statusCode
        self.retryAfter = retryAfter
        self.response = response
    }

    func checkAvailability() async -> Bool { true }
    func availableModels() async throws -> [LLMModelInfo] { [] }

    func sendMessage(
        system _: String,
        messages _: [LLMMessage],
        tools _: [ToolDefinition],
        onTextDelta: @escaping (String) -> Void
    ) async throws -> LLMResponse {
        count += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw OpenAICompatibleProviderError.requestFailed(
                statusCode: statusCode,
                body: "temporary",
                retryAfter: retryAfter
            )
        }
        for block in response.contentBlocks {
            if case .text(let text) = block {
                onTextDelta(text)
            }
        }
        return response
    }

    func requestCount() -> Int { count }
}

private actor AlwaysFailProvider: LLMProvider {
    nonisolated let providerType: LLMProviderType = .openAICompatible
    nonisolated let displayName: String = "always-fail"

    private let statusCode: Int
    private var count = 0

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    func checkAvailability() async -> Bool { true }
    func availableModels() async throws -> [LLMModelInfo] { [] }

    func sendMessage(
        system _: String,
        messages _: [LLMMessage],
        tools _: [ToolDefinition],
        onTextDelta _: @escaping (String) -> Void
    ) async throws -> LLMResponse {
        count += 1
        throw OpenAICompatibleProviderError.requestFailed(
            statusCode: statusCode,
            body: "failure",
            retryAfter: nil
        )
    }

    func requestCount() -> Int { count }
}

private actor SlowSuccessProvider: LLMProvider {
    nonisolated let providerType: LLMProviderType = .openAICompatible
    nonisolated let displayName: String = "slow-success"

    private let delay: TimeInterval
    private let response: LLMResponse
    private var count = 0

    init(delay: TimeInterval, response: LLMResponse) {
        self.delay = delay
        self.response = response
    }

    func checkAvailability() async -> Bool { true }
    func availableModels() async throws -> [LLMModelInfo] { [] }

    func sendMessage(
        system _: String,
        messages _: [LLMMessage],
        tools _: [ToolDefinition],
        onTextDelta: @escaping (String) -> Void
    ) async throws -> LLMResponse {
        count += 1
        try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
        for block in response.contentBlocks {
            if case .text(let text) = block {
                onTextDelta(text)
            }
        }
        return response
    }

    func requestCount() -> Int { count }
}

private func collectEvents(from stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}

private func firstError(in events: [AgentEvent]) -> Error? {
    for event in events {
        if case .error(let error) = event {
            return error
        }
    }
    return nil
}

private func firstToolResult(in messages: [LLMMessage]) -> (content: String, isError: Bool)? {
    for message in messages.reversed() where message.role == .tool {
        for block in message.contentBlocks {
            if case .toolResult(_, let content, let isError) = block {
                return (content, isError)
            }
        }
    }
    return nil
}

private func eventKinds(_ events: [AgentEvent]) -> [String] {
    events.map { event in
        switch event {
        case .agentStart:
            return "agentStart"
        case .agentEnd:
            return "agentEnd"
        case .turnStart(let turnIndex):
            return "turnStart:\(turnIndex)"
        case .turnEnd(let turnIndex):
            return "turnEnd:\(turnIndex)"
        case .messageStart(let role):
            return "messageStart:\(role)"
        case .messageTextDelta:
            return "messageTextDelta"
        case .messageEnd:
            return "messageEnd"
        case .toolExecutionStart(let name, _):
            return "toolExecutionStart:\(name)"
        case .toolExecutionEnd(let name, _, let isError):
            return "toolExecutionEnd:\(name):\(isError)"
        case .confirmationRequired(let toolName, _):
            return "confirmationRequired:\(toolName)"
        case .confirmationResolved(let approved):
            return "confirmationResolved:\(approved)"
        case .usageUpdated:
            return "usageUpdated"
        case .error:
            return "error"
        }
    }
}

private func assertOrderedSubsequence(_ expected: [String], in actual: [String], file: StaticString = #filePath, line: UInt = #line) {
    var searchStart = 0
    for target in expected {
        guard let matchIndex = actual[searchStart...].firstIndex(of: target) else {
            XCTFail("Missing expected event kind '\(target)' in \(actual)", file: file, line: line)
            return
        }
        searchStart = matchIndex + 1
    }
}
