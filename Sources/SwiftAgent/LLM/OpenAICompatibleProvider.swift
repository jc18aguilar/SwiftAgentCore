import Foundation

public enum OpenAICompatibleProviderError: LocalizedError {
    case invalidBaseURL
    case invalidHTTPResponse
    case requestFailed(statusCode: Int, body: String, retryAfter: TimeInterval?)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Provider base URL is invalid."
        case .invalidHTTPResponse:
            return "Received an invalid HTTP response from provider."
        case .requestFailed(let statusCode, let body, let retryAfter):
            if let retryAfter {
                return "Provider request failed (\(statusCode)): \(body). Retry after \(Int(retryAfter))s."
            }
            return "Provider request failed (\(statusCode)): \(body)"
        }
    }
}

public final actor OpenAICompatibleProvider: LLMProvider {
    public nonisolated let providerType: LLMProviderType = .openAICompatible
    public nonisolated let displayName: String

    private var config: LLMProviderConfig
    private let oauthProvider: OAuthProvider?
    private let onOAuthCredentialsUpdated: ((OAuthCredentials) async -> Void)?

    public init(
        displayName: String = "OpenAI Compatible",
        config: LLMProviderConfig,
        oauthProvider: OAuthProvider? = nil,
        onOAuthCredentialsUpdated: ((OAuthCredentials) async -> Void)? = nil
    ) {
        self.displayName = displayName
        self.config = config
        self.oauthProvider = oauthProvider
        self.onOAuthCredentialsUpdated = onOAuthCredentialsUpdated
    }

    public func updateConfig(_ config: LLMProviderConfig) {
        self.config = config
    }

    public func checkAvailability() async -> Bool {
        var request = URLRequest(url: config.baseURL)
        request.httpMethod = "HEAD"
        applyAuthHeaders(to: &request, auth: config.authMethod)
        for (key, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return false
            }
            return http.statusCode < 500
        } catch {
            return false
        }
    }

    public func availableModels() async throws -> [LLMModelInfo] {
        let url = endpoint("models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let auth = try await resolveAuthMethod()
        applyAuthHeaders(to: &request, auth: auth)
        for (key, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleProviderError.invalidHTTPResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenAICompatibleProviderError.requestFailed(
                statusCode: http.statusCode,
                body: body,
                retryAfter: Self.retryAfterSeconds(from: http)
            )
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map { LLMModelInfo(id: $0.id, name: $0.id, contextWindow: nil) }
    }

    public func sendMessage(
        system: String,
        messages: [LLMMessage],
        tools: [ToolDefinition],
        onTextDelta: @escaping (String) -> Void
    ) async throws -> LLMResponse {
        let url = endpoint("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let auth = try await resolveAuthMethod()
        applyAuthHeaders(to: &request, auth: auth)
        for (key, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let payload = try buildPayload(system: system, messages: messages, tools: tools, model: config.model)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        fputs("[LLM] → POST \(url) model=\(config.model)\n", stderr)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleProviderError.invalidHTTPResponse
        }

        let rateLimitHeaders = [
            "x-ratelimit-limit-requests", "x-ratelimit-remaining-requests",
            "x-ratelimit-reset-requests", "x-ratelimit-limit-tokens",
            "x-ratelimit-remaining-tokens", "x-ratelimit-reset-tokens",
            "retry-after",
        ].compactMap { key -> String? in
            guard let val = http.value(forHTTPHeaderField: key) else { return nil }
            return "\(key): \(val)"
        }.joined(separator: ", ")
        fputs("[LLM] ← HTTP \(http.statusCode)\(rateLimitHeaders.isEmpty ? "" : " [\(rateLimitHeaders)]")\n", stderr)

        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line
            }
            fputs("[LLM] ✗ error body: \(body)\n", stderr)
            throw OpenAICompatibleProviderError.requestFailed(
                statusCode: http.statusCode,
                body: body,
                retryAfter: Self.retryAfterSeconds(from: http)
            )
        }

        var text = ""
        var toolCalls: [Int: PartialToolCall] = [:]
        var stopReason: LLMStopReason = .endTurn
        var usage: LLMUsage?

        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }

            let content = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if content == "[DONE]" {
                break
            }

            guard let data = String(content).data(using: .utf8) else { continue }
            guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else { continue }

            if let payloadUsage = chunk.usage {
                usage = LLMUsage(
                    inputTokens: payloadUsage.promptTokens,
                    outputTokens: payloadUsage.completionTokens,
                    totalTokens: payloadUsage.totalTokens
                )
            }

            for choice in chunk.choices {
                if let piece = choice.delta.content, !piece.isEmpty {
                    text += piece
                    onTextDelta(piece)
                }

                if let deltas = choice.delta.toolCalls {
                    for delta in deltas {
                        var current = toolCalls[delta.index] ?? PartialToolCall()
                        if let id = delta.id, !id.isEmpty {
                            current.id = id
                        }
                        if let name = delta.function?.name, !name.isEmpty {
                            current.name = name
                        }
                        if let args = delta.function?.arguments, !args.isEmpty {
                            current.arguments.append(args)
                        }
                        toolCalls[delta.index] = current
                    }
                }

                if let finish = choice.finishReason, finish == "tool_calls" {
                    stopReason = .toolUse
                }
            }
        }

        var blocks: [ContentBlock] = []
        if !text.isEmpty {
            blocks.append(.text(text))
        }

        if !toolCalls.isEmpty {
            stopReason = .toolUse
            let sorted = toolCalls.keys.sorted()
            for key in sorted {
                let partial = toolCalls[key] ?? PartialToolCall()
                let id = partial.id.isEmpty ? UUID().uuidString : partial.id
                let name = partial.name.isEmpty ? "unknown_tool" : partial.name
                let input = parseJSONObject(from: partial.arguments)
                blocks.append(.toolUse(id: id, name: name, input: input))
            }
        }

        return LLMResponse(contentBlocks: blocks, stopReason: stopReason, usage: usage)
    }

    private func endpoint(_ path: String) -> URL {
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return config.baseURL.appendingPathComponent(normalized)
    }

    private func resolveAuthMethod() async throws -> LLMAuthMethod {
        switch config.authMethod {
        case .oauth(let credentials) where credentials.isExpired:
            guard let oauthProvider else {
                return config.authMethod
            }
            let refreshed = try await oauthProvider.refreshToken(credentials)
            config.authMethod = .oauth(refreshed)
            await onOAuthCredentialsUpdated?(refreshed)
            return config.authMethod
        default:
            return config.authMethod
        }
    }

    private func applyAuthHeaders(to request: inout URLRequest, auth: LLMAuthMethod) {
        switch auth {
        case .none:
            break
        case .apiKey(let key):
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        case .oauth(let credentials):
            if !credentials.accessToken.isEmpty {
                request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            }
        case .custom(let headers):
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
    }

    private func buildPayload(
        system: String,
        messages: [LLMMessage],
        tools: [ToolDefinition],
        model: String
    ) throws -> [String: Any] {
        var payload: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": Self.toOpenAIMessages(system: system, messages: messages)
        ]

        if !tools.isEmpty {
            payload["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema.mapValues(\.anyValue)
                    ]
                ]
            }
            payload["tool_choice"] = "auto"
        }

        return payload
    }

    private static func toOpenAIMessages(system: String, messages: [LLMMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = []

        if !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(["role": "system", "content": system])
        }

        for message in messages {
            switch message.role {
            case .system:
                if !message.textContent.isEmpty {
                    result.append(["role": "system", "content": message.textContent])
                }
            case .user:
                result.append(["role": "user", "content": message.textContent])
            case .assistant:
                var payload: [String: Any] = ["role": "assistant"]
                let text = message.textContent
                payload["content"] = text.isEmpty ? NSNull() : text

                let toolCalls: [[String: Any]] = message.contentBlocks.compactMap { block in
                    guard case .toolUse(let id, let name, let input) = block else { return nil }
                    let argumentsData = try? JSONSerialization.data(withJSONObject: input.mapValues(\.anyValue))
                    let arguments = argumentsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return [
                        "id": id,
                        "type": "function",
                        "function": [
                            "name": name,
                            "arguments": arguments
                        ]
                    ]
                }
                if !toolCalls.isEmpty {
                    payload["tool_calls"] = toolCalls
                }
                result.append(payload)
            case .tool:
                for block in message.contentBlocks {
                    guard case .toolResult(let toolUseId, let content, _) = block else { continue }
                    result.append([
                        "role": "tool",
                        "tool_call_id": toolUseId,
                        "content": content
                    ])
                }
            }
        }

        return result
    }

    private func parseJSONObject(from raw: String) -> JSONObject {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["_raw": .string(raw)]
        }
        return object.mapValues(JSONValue.from(any:))
    }

    private static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        if let raw = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return max(1, seconds)
            }
            if let date = HTTPDateParser.date(from: raw) {
                let delta = date.timeIntervalSinceNow
                return delta > 0 ? delta : 1
            }
        }
        return nil
    }
}

private enum HTTPDateParser {
    private static let formats = [
        "EEE',' dd MMM yyyy HH':'mm':'ss z",
        "EEEE',' dd-MMM-yy HH':'mm':'ss z",
        "EEE MMM d HH':'mm':'ss yyyy"
    ]

    static func date(from value: String) -> Date? {
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}

private struct ModelsResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}

private struct StreamChunk: Decodable {
    let choices: [StreamChoice]
    let usage: StreamUsage?
}

private struct StreamChoice: Decodable {
    let delta: StreamDelta
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

private struct StreamDelta: Decodable {
    let content: String?
    let toolCalls: [StreamToolCallDelta]?

    enum CodingKeys: String, CodingKey {
        case content
        case toolCalls = "tool_calls"
    }
}

private struct StreamToolCallDelta: Decodable {
    let index: Int
    let id: String?
    let function: StreamToolCallFunctionDelta?
}

private struct StreamToolCallFunctionDelta: Decodable {
    let name: String?
    let arguments: String?
}

private struct StreamUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

private struct PartialToolCall {
    var id: String = ""
    var name: String = ""
    var arguments: String = ""
}
