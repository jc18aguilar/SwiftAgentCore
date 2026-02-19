import Foundation

public enum GeminiProviderError: LocalizedError {
    case invalidHTTPResponse
    case requestFailed(statusCode: Int, body: String, retryAfter: TimeInterval?)

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            return "Received an invalid HTTP response from Gemini API."
        case .requestFailed(let statusCode, let body, let retryAfter):
            if let retryAfter {
                return "Gemini request failed (\(statusCode)): \(body). Retry after \(Int(retryAfter))s."
            }
            return "Gemini request failed (\(statusCode)): \(body)"
        }
    }
}

/// LLM provider for Google Gemini native REST API.
public final actor GeminiProvider: LLMProvider {
    public nonisolated let providerType: LLMProviderType = .gemini
    public nonisolated let displayName: String

    public static let defaultBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

    private var config: LLMProviderConfig

    public init(
        apiKey: String,
        model: String,
        baseURL: URL = GeminiProvider.defaultBaseURL,
        headers: [String: String] = [:],
        displayName: String = "Gemini API"
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
        displayName: String = "Gemini API"
    ) {
        self.displayName = displayName
        self.config = config
    }

    public func updateConfig(_ config: LLMProviderConfig) {
        self.config = config
    }

    public func checkAvailability() async -> Bool {
        do {
            _ = try await availableModels(pageSize: 1)
            return true
        } catch {
            return false
        }
    }

    public func availableModels() async throws -> [LLMModelInfo] {
        try await availableModels(pageSize: 100)
    }

    public func sendMessage(
        system: String,
        messages: [LLMMessage],
        tools: [ToolDefinition],
        onTextDelta: @escaping (String) -> Void
    ) async throws -> LLMResponse {
        let url = Self.streamEndpoint(baseURL: config.baseURL, model: config.model)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeoutInterval(for: config.baseURL)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        Self.applyAuthHeaders(to: &request, auth: config.authMethod)
        for (key, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let payload = Self.buildPayload(system: system, messages: messages, tools: tools)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiProviderError.invalidHTTPResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line
            }
            throw GeminiProviderError.requestFailed(
                statusCode: http.statusCode,
                body: body,
                retryAfter: Self.retryAfterSeconds(from: http)
            )
        }

        var text = ""
        var usage: LLMUsage?
        var toolCalls: [(name: String, args: JSONObject)] = []
        var toolCallSeen = Set<String>()

        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let content = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty || content == "[DONE]" { continue }
            guard
                let data = String(content).data(using: .utf8),
                let event = try? JSONDecoder().decode(StreamGenerateContentResponse.self, from: data)
            else {
                continue
            }

            if let usageMetadata = event.usageMetadata {
                usage = LLMUsage(
                    inputTokens: usageMetadata.promptTokenCount,
                    outputTokens: usageMetadata.candidatesTokenCount,
                    totalTokens: usageMetadata.totalTokenCount
                )
            }

            for candidate in event.candidates ?? [] {
                for part in candidate.content?.parts ?? [] {
                    if let delta = part.text, !delta.isEmpty {
                        text += delta
                        onTextDelta(delta)
                    }
                    if let functionCall = part.functionCall {
                        let rawName = functionCall.name?.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ) ?? ""
                        guard !rawName.isEmpty else { continue }
                        let args = functionCall.args ?? [:]
                        let dedupeKey = Self.functionCallDedupeKey(name: rawName, args: args)
                        if toolCallSeen.insert(dedupeKey).inserted {
                            toolCalls.append((name: rawName, args: args))
                        }
                    }
                }
            }
        }

        var blocks: [ContentBlock] = []
        if !text.isEmpty {
            blocks.append(.text(text))
        }
        for call in toolCalls {
            blocks.append(.toolUse(id: UUID().uuidString, name: call.name, input: call.args))
        }

        return LLMResponse(
            contentBlocks: blocks,
            stopReason: toolCalls.isEmpty ? .endTurn : .toolUse,
            usage: usage
        )
    }

    private func availableModels(pageSize: Int) async throws -> [LLMModelInfo] {
        let url = Self.modelsEndpoint(baseURL: config.baseURL, pageSize: pageSize)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        Self.applyAuthHeaders(to: &request, auth: config.authMethod)
        for (key, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiProviderError.invalidHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GeminiProviderError.requestFailed(
                statusCode: http.statusCode,
                body: body,
                retryAfter: Self.retryAfterSeconds(from: http)
            )
        }

        let decoded = try JSONDecoder().decode(GeminiModelsResponse.self, from: data)
        let infos = (decoded.models ?? []).compactMap { model -> LLMModelInfo? in
            let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            if let methods = model.supportedGenerationMethods,
                !methods.contains(where: {
                    $0.caseInsensitiveCompare("generateContent") == .orderedSame
                        || $0.caseInsensitiveCompare("streamGenerateContent") == .orderedSame
                })
            {
                return nil
            }

            let id: String
            if name.hasPrefix("models/") {
                id = String(name.dropFirst("models/".count))
            } else {
                id = name
            }

            return LLMModelInfo(
                id: id,
                name: model.displayName?.isEmpty == false ? model.displayName! : id,
                contextWindow: model.inputTokenLimit
            )
        }

        var deduped: [LLMModelInfo] = []
        var seen = Set<String>()
        for model in infos where seen.insert(model.id).inserted {
            deduped.append(model)
        }
        return deduped.sorted { $0.id < $1.id }
    }

    private static func modelsEndpoint(baseURL: URL, pageSize: Int) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("models"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "pageSize", value: "\(max(1, pageSize))")]
        return components.url!
    }

    private static func streamEndpoint(baseURL: URL, model: String) -> URL {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel: String
        if trimmedModel.hasPrefix("models/") {
            normalizedModel = trimmedModel
        } else {
            normalizedModel = "models/\(trimmedModel)"
        }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("\(normalizedModel):streamGenerateContent"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        return components.url!
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
                request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            }
        case .oauth(let credentials):
            if !credentials.accessToken.isEmpty {
                request.setValue(
                    "Bearer \(credentials.accessToken)",
                    forHTTPHeaderField: "Authorization"
                )
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
        tools: [ToolDefinition]
    ) -> [String: Any] {
        let systemTexts = ([system] + messages.compactMap { message -> String? in
            guard message.role == .system else { return nil }
            let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        })
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var payload: [String: Any] = [:]
        if !systemTexts.isEmpty {
            payload["systemInstruction"] = [
                "parts": systemTexts.map { ["text": $0] }
            ]
        }

        let contents = toGeminiContents(messages.filter { $0.role != .system })
        if contents.isEmpty {
            payload["contents"] = [["role": "user", "parts": [["text": ""]]]]
        } else {
            payload["contents"] = contents
        }

        if !tools.isEmpty {
            payload["tools"] = [[
                "functionDeclarations": tools.map { tool in
                    [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.inputSchema.mapValues(\.anyValue),
                    ]
                }
            ]]
            payload["toolConfig"] = [
                "functionCallingConfig": [
                    "mode": "AUTO"
                ]
            ]
        }

        return payload
    }

    private static func toGeminiContents(_ messages: [LLMMessage]) -> [[String: Any]] {
        var contents: [[String: Any]] = []
        var toolNameByID: [String: String] = [:]

        for message in messages {
            switch message.role {
            case .system:
                continue
            case .user:
                let text = message.textContent
                if !text.isEmpty {
                    contents.append(["role": "user", "parts": [["text": text]]])
                }
            case .assistant:
                var parts: [[String: Any]] = []
                let text = message.textContent
                if !text.isEmpty {
                    parts.append(["text": text])
                }

                for block in message.contentBlocks {
                    guard case .toolUse(let id, let name, let input) = block else { continue }
                    toolNameByID[id] = name
                    parts.append([
                        "functionCall": [
                            "name": name,
                            "args": input.mapValues(\.anyValue),
                        ]
                    ])
                }

                if !parts.isEmpty {
                    contents.append(["role": "model", "parts": parts])
                }
            case .tool:
                for block in message.contentBlocks {
                    guard case .toolResult(let toolUseId, let content, let isError) = block else {
                        continue
                    }
                    let toolName = toolNameByID[toolUseId] ?? "unknown_tool"
                    let responsePayload: [String: Any] = [
                        "content": Self.parseJSONIfPossible(content) ?? content,
                        "is_error": isError,
                    ]
                    contents.append([
                        "role": "user",
                        "parts": [[
                            "functionResponse": [
                                "name": toolName,
                                "response": responsePayload,
                            ]
                        ]],
                    ])
                }
            }
        }

        return contents
    }

    private static func parseJSONIfPossible(_ raw: String) -> Any? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func functionCallDedupeKey(name: String, args: JSONObject) -> String {
        let payload = args.mapValues(\.anyValue)
        let serialized: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        {
            serialized = text
        } else {
            serialized = "{}"
        }
        return "\(name)::\(serialized)"
    }

    private static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private struct GeminiModelsResponse: Decodable {
    let models: [GeminiModel]?
}

private struct GeminiModel: Decodable {
    let name: String
    let displayName: String?
    let inputTokenLimit: Int?
    let supportedGenerationMethods: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case displayName
        case inputTokenLimit
        case supportedGenerationMethods
    }
}

private struct StreamGenerateContentResponse: Decodable {
    let candidates: [GeminiCandidate]?
    let usageMetadata: GeminiUsageMetadata?
}

private struct GeminiCandidate: Decodable {
    let content: GeminiContent?
}

private struct GeminiContent: Decodable {
    let parts: [GeminiPart]?
}

private struct GeminiPart: Decodable {
    let text: String?
    let functionCall: GeminiFunctionCall?
}

private struct GeminiFunctionCall: Decodable {
    let name: String?
    let args: JSONObject?
}

private struct GeminiUsageMetadata: Decodable {
    let promptTokenCount: Int?
    let candidatesTokenCount: Int?
    let totalTokenCount: Int?
}
