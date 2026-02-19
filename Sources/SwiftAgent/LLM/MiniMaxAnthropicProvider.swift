import Foundation

public enum MiniMaxAnthropicProviderError: LocalizedError {
    case invalidHTTPResponse
    case invalidResponseBody(body: String)
    case requestFailed(statusCode: Int, body: String, retryAfter: TimeInterval?)

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            return "Received an invalid HTTP response from MiniMax Anthropic API."
        case .invalidResponseBody(let body):
            return "MiniMax Anthropic API returned an invalid response body: \(body)"
        case .requestFailed(let statusCode, let body, let retryAfter):
            if let retryAfter {
                return
                    "MiniMax Anthropic request failed (\(statusCode)): \(body). Retry after \(Int(retryAfter))s."
            }
            return "MiniMax Anthropic request failed (\(statusCode)): \(body)"
        }
    }
}

/// LLM provider for MiniMax Anthropic-compatible API (`/anthropic/v1/messages`).
public final actor MiniMaxAnthropicProvider: LLMProvider {
    public nonisolated let providerType: LLMProviderType = .claude
    public nonisolated let displayName: String

    public static let defaultBaseURL = URL(string: "https://api.minimaxi.com/anthropic")!
    public static let defaultModels: [LLMModelInfo] = [
        LLMModelInfo(id: "MiniMax-M2.5", name: "MiniMax-M2.5"),
        LLMModelInfo(id: "MiniMax-M2.5-highspeed", name: "MiniMax-M2.5-highspeed"),
        LLMModelInfo(id: "MiniMax-M2.1", name: "MiniMax-M2.1"),
        LLMModelInfo(id: "MiniMax-M2.1-highspeed", name: "MiniMax-M2.1-highspeed"),
        LLMModelInfo(id: "MiniMax-M2", name: "MiniMax-M2"),
    ]

    private static let anthropicVersion = "2023-06-01"
    private static let defaultMaxTokens = 4096

    private var config: LLMProviderConfig

    public init(
        apiKey: String,
        model: String,
        baseURL: URL = MiniMaxAnthropicProvider.defaultBaseURL,
        headers: [String: String] = [:],
        displayName: String = "MiniMax API"
    ) {
        self.displayName = displayName
        self.config = LLMProviderConfig(
            baseURL: baseURL,
            authMethod: .apiKey(apiKey),
            model: model,
            headers: headers
        )
    }

    public init(
        config: LLMProviderConfig,
        displayName: String = "MiniMax API"
    ) {
        self.displayName = displayName
        self.config = config
    }

    public func updateConfig(_ config: LLMProviderConfig) {
        self.config = config
    }

    public func checkAvailability() async -> Bool {
        var request = URLRequest(url: config.baseURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15
        Self.applyAuthHeaders(to: &request, auth: config.authMethod)
        for (key, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode < 500
        } catch {
            return false
        }
    }

    public func availableModels() async throws -> [LLMModelInfo] {
        Self.defaultModels
    }

    public func sendMessage(
        system: String,
        messages: [LLMMessage],
        tools: [ToolDefinition],
        onTextDelta: @escaping (String) -> Void
    ) async throws -> LLMResponse {
        let url = Self.messagesEndpoint(baseURL: config.baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeoutInterval(for: config.baseURL)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        Self.applyAuthHeaders(to: &request, auth: config.authMethod)
        for (key, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let payload = Self.buildPayload(model: config.model, system: system, messages: messages, tools: tools)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MiniMaxAnthropicProviderError.invalidHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = Self.errorBodyString(from: data)
            throw MiniMaxAnthropicProviderError.requestFailed(
                statusCode: http.statusCode,
                body: body,
                retryAfter: Self.retryAfterSeconds(from: http)
            )
        }

        let decoded: MessageResponse
        do {
            decoded = try JSONDecoder().decode(MessageResponse.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MiniMaxAnthropicProviderError.invalidResponseBody(body: body)
        }

        var blocks: [ContentBlock] = []
        var hasToolUse = false
        for block in decoded.content ?? [] {
            switch block.type {
            case "text":
                guard let text = block.text, !text.isEmpty else { continue }
                blocks.append(.text(text))
                onTextDelta(text)
            case "tool_use":
                guard let name = block.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
                else { continue }
                let id = block.id?.isEmpty == false ? block.id! : UUID().uuidString
                blocks.append(.toolUse(id: id, name: name, input: block.input ?? [:]))
                hasToolUse = true
            default:
                continue
            }
        }

        let stopReason: LLMStopReason
        if hasToolUse || decoded.stopReason == "tool_use" {
            stopReason = .toolUse
        } else {
            stopReason = .endTurn
        }

        let usage = decoded.usage.map { usage in
            let total: Int?
            if let input = usage.inputTokens, let output = usage.outputTokens {
                total = input + output
            } else {
                total = nil
            }
            return LLMUsage(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                totalTokens: total
            )
        }

        return LLMResponse(contentBlocks: blocks, stopReason: stopReason, usage: usage)
    }

    private static func buildPayload(
        model: String,
        system: String,
        messages: [LLMMessage],
        tools: [ToolDefinition]
    ) -> [String: Any] {
        let systemPrompt = combinedSystemPrompt(system: system, messages: messages)
        var payload: [String: Any] = [
            "model": model,
            "max_tokens": Self.defaultMaxTokens,
            "messages": toAnthropicMessages(messages.filter { $0.role != .system }),
        ]

        if !systemPrompt.isEmpty {
            payload["system"] = systemPrompt
        }

        if !tools.isEmpty {
            payload["tools"] = tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.inputSchema.mapValues(\.anyValue),
                ]
            }
            payload["tool_choice"] = ["type": "auto"]
        }

        return payload
    }

    private static func combinedSystemPrompt(system: String, messages: [LLMMessage]) -> String {
        let pieces = ([system] + messages.compactMap { message -> String? in
            guard message.role == .system else { return nil }
            return message.textContent
        })
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        return pieces.joined(separator: "\n\n")
    }

    private static func toAnthropicMessages(_ messages: [LLMMessage]) -> [[String: Any]] {
        var output: [[String: Any]] = []

        for message in messages {
            switch message.role {
            case .system:
                continue
            case .user:
                let textBlocks = message.contentBlocks.compactMap { block -> [String: Any]? in
                    guard case .text(let text) = block, !text.isEmpty else { return nil }
                    return ["type": "text", "text": text]
                }
                if !textBlocks.isEmpty {
                    output.append(["role": "user", "content": textBlocks])
                }
            case .assistant:
                var blocks: [[String: Any]] = []
                for block in message.contentBlocks {
                    switch block {
                    case .text(let text):
                        guard !text.isEmpty else { continue }
                        blocks.append(["type": "text", "text": text])
                    case .toolUse(let id, let name, let input):
                        blocks.append([
                            "type": "tool_use",
                            "id": id,
                            "name": name,
                            "input": input.mapValues(\.anyValue),
                        ])
                    case .toolResult:
                        continue
                    }
                }
                if !blocks.isEmpty {
                    output.append(["role": "assistant", "content": blocks])
                }
            case .tool:
                var toolResults: [[String: Any]] = []
                for block in message.contentBlocks {
                    guard case .toolResult(let toolUseId, let content, let isError) = block else {
                        continue
                    }
                    var result: [String: Any] = [
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "content": content,
                    ]
                    if isError {
                        result["is_error"] = true
                    }
                    toolResults.append(result)
                }
                if !toolResults.isEmpty {
                    output.append(["role": "user", "content": toolResults])
                }
            }
        }

        if output.isEmpty {
            return [["role": "user", "content": [["type": "text", "text": ""]]]]
        }
        return output
    }

    private static func messagesEndpoint(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("v1/messages")
    }

    private static func timeoutInterval(for baseURL: URL) -> TimeInterval {
        let host = (baseURL.host ?? "").lowercased()
        if host == "127.0.0.1" || host == "localhost" {
            return 300
        }
        return 120
    }

    private static func applyAuthHeaders(to request: inout URLRequest, auth: LLMAuthMethod) {
        switch auth {
        case .none:
            break
        case .apiKey(let key):
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .oauth(let credentials):
            if !credentials.accessToken.isEmpty {
                request.setValue(
                    "Bearer \(credentials.accessToken)",
                    forHTTPHeaderField: "Authorization")
            }
        case .custom(let headers):
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
    }

    private static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        if let value = response.value(forHTTPHeaderField: "retry-after"),
            let seconds = TimeInterval(value)
        {
            return max(0, seconds)
        }
        return nil
    }

    private static func errorBodyString(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
            let message = envelope.error?.message,
            !message.isEmpty
        {
            return message
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private struct MessageResponse: Decodable {
        let content: [ResponseContentBlock]?
        let stopReason: String?
        let usage: UsagePayload?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
            case usage
        }
    }

    private struct ResponseContentBlock: Decodable {
        let type: String
        let text: String?
        let id: String?
        let name: String?
        let input: JSONObject?
    }

    private struct UsagePayload: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    private struct ErrorEnvelope: Decodable {
        struct ErrorPayload: Decodable {
            let message: String?
        }

        let error: ErrorPayload?
    }
}
