import Foundation

enum OpenAICompatibleCore {
    static func checkAvailability(
        baseURL: URL,
        auth: LLMAuthMethod,
        headers: [String: String]
    ) async -> Bool {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "HEAD"
        applyAuthHeaders(to: &request, auth: auth)
        for (key, value) in headers {
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

    static func availableModels(
        baseURL: URL,
        auth: LLMAuthMethod,
        headers: [String: String]
    ) async throws -> [LLMModelInfo] {
        let url = endpoint(baseURL: baseURL, path: "models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuthHeaders(to: &request, auth: auth)
        for (key, value) in headers {
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
                retryAfter: retryAfterSeconds(from: http)
            )
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map { LLMModelInfo(id: $0.id, name: $0.id, contextWindow: nil) }
    }

    static func sendMessage(
        baseURL: URL,
        model: String,
        auth: LLMAuthMethod,
        headers: [String: String],
        system: String,
        messages: [LLMMessage],
        tools: [ToolDefinition],
        onTextDelta: @escaping (String) -> Void
    ) async throws -> LLMResponse {
        let url = endpoint(baseURL: baseURL, path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval(for: baseURL)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        applyAuthHeaders(to: &request, auth: auth)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let payload = try buildPayload(system: system, messages: messages, tools: tools, model: model)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let requestStartedAt = Date()
        debugLog(
            "request prepared model=\(model) timeout=\(Int(request.timeoutInterval))s messages=\(messages.count) tools=\(tools.count)"
        )

        fputs("[LLM] → POST \(url) model=\(model)\n", stderr)

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            let elapsed = Date().timeIntervalSince(requestStartedAt)
            debugLog("request transport failed after \(String(format: "%.3f", elapsed))s error=\(error)")
            throw error
        }
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
        fputs(
            "[LLM] ← HTTP \(http.statusCode)\(rateLimitHeaders.isEmpty ? "" : " [\(rateLimitHeaders)]")\n",
            stderr)
        debugLog("response headers received status=\(http.statusCode)")

        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line
            }
            fputs("[LLM] ✗ error body: \(body)\n", stderr)
            let elapsed = Date().timeIntervalSince(requestStartedAt)
            debugLog(
                "request failed status=\(http.statusCode) elapsed=\(String(format: "%.3f", elapsed))s body_chars=\(body.count)"
            )
            throw OpenAICompatibleProviderError.requestFailed(
                statusCode: http.statusCode,
                body: body,
                retryAfter: retryAfterSeconds(from: http)
            )
        }

        var text = ""
        var toolCalls: [Int: PartialToolCall] = [:]
        var stopReason: LLMStopReason = .endTurn
        var usage: LLMUsage?
        var sseLineCount = 0
        var sseDataCount = 0
        var decodeFailureCount = 0
        var textDeltaCount = 0
        var textDeltaChars = 0
        var toolDeltaCount = 0
        var firstDataAt: Date?
        var firstTextDeltaAt: Date?

        for try await rawLine in bytes.lines {
            sseLineCount += 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            sseDataCount += 1
            if firstDataAt == nil {
                firstDataAt = Date()
                let sinceRequest = firstDataAt!.timeIntervalSince(requestStartedAt)
                debugLog("first sse data received after \(String(format: "%.3f", sinceRequest))s")
            }

            let content = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if content == "[DONE]" {
                debugLog("stream received [DONE]")
                break
            }

            guard let data = String(content).data(using: .utf8) else { continue }
            guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else {
                decodeFailureCount += 1
                if decodeFailureCount <= 3 {
                    let preview = String(content.prefix(160))
                    debugLog("stream chunk decode failed preview=\(preview)")
                }
                continue
            }

            if let payloadUsage = chunk.usage {
                usage = LLMUsage(
                    inputTokens: payloadUsage.promptTokens,
                    outputTokens: payloadUsage.completionTokens,
                    totalTokens: payloadUsage.totalTokens
                )
            }

            for choice in chunk.choices {
                if let piece = choice.delta.content, !piece.isEmpty {
                    if firstTextDeltaAt == nil {
                        firstTextDeltaAt = Date()
                        let sinceRequest = firstTextDeltaAt!.timeIntervalSince(requestStartedAt)
                        debugLog("first text delta after \(String(format: "%.3f", sinceRequest))s")
                    }
                    textDeltaCount += 1
                    textDeltaChars += piece.count
                    text += piece
                    onTextDelta(piece)
                }

                if let deltas = choice.delta.toolCalls {
                    toolDeltaCount += deltas.count
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
                    debugLog("finish_reason=tool_calls")
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

        let elapsed = Date().timeIntervalSince(requestStartedAt)
        debugLog(
            "stream completed elapsed=\(String(format: "%.3f", elapsed))s lines=\(sseLineCount) data=\(sseDataCount) decode_failures=\(decodeFailureCount) text_deltas=\(textDeltaCount) text_chars=\(textDeltaChars) tool_deltas=\(toolDeltaCount) stop=\(stopReason)"
        )

        return LLMResponse(contentBlocks: blocks, stopReason: stopReason, usage: usage)
    }

    private static func endpoint(baseURL: URL, path: String) -> URL {
        let normalized = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appendingPathComponent(normalized)
    }

    private static func timeoutInterval(for baseURL: URL) -> TimeInterval {
        let host = (baseURL.host ?? "").lowercased()
        if host == "127.0.0.1" || host == "localhost" {
            return 300
        }
        return 120
    }

    private static var isDebugEnabled: Bool {
        guard
            let raw = ProcessInfo.processInfo.environment["MAI_LLM_DEBUG"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
            !raw.isEmpty
        else {
            return true
        }
        switch raw {
        case "0", "false", "off", "no":
            return false
        default:
            return true
        }
    }

    private static func debugLog(_ message: String) {
        guard isDebugEnabled else { return }
        fputs("[LLM][DEBUG] \(message)\n", stderr)
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
                request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            }
        case .custom(let headers):
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
    }

    private static func buildPayload(
        system: String,
        messages: [LLMMessage],
        tools: [ToolDefinition],
        model: String
    ) throws -> [String: Any] {
        var payload: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": toOpenAIMessages(system: system, messages: messages),
        ]

        if !tools.isEmpty {
            payload["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema.mapValues(\.anyValue),
                    ],
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
                            "arguments": arguments,
                        ],
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
                        "content": content,
                    ])
                }
            }
        }

        return result
    }

    private static func parseJSONObject(from raw: String) -> JSONObject {
        guard let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
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
        "EEE MMM d HH':'mm':'ss yyyy",
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
