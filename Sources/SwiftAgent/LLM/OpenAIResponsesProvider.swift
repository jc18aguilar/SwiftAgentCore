import Foundation

public enum OpenAIResponsesProviderError: LocalizedError {
    case invalidHTTPResponse
    case requestFailed(statusCode: Int, body: String)
    case streamFailed(message: String)
    case invalidModelsResponse(body: String)

    public var errorDescription: String? {
        switch self {
        case .invalidHTTPResponse:
            return "Received an invalid HTTP response from OpenAI Responses API."
        case .requestFailed(let statusCode, let body):
            return "Responses API request failed (\(statusCode)): \(body)"
        case .streamFailed(let message):
            return "Responses API stream error: \(message)"
        case .invalidModelsResponse(let body):
            return "Responses API returned an invalid models payload: \(body)"
        }
    }
}

/// LLM provider for the OpenAI Responses API (`chatgpt.com/backend-api/codex/responses`).
/// Used by ChatGPT Plus/Pro OAuth users via the Codex OAuth flow.
public final actor OpenAIResponsesProvider: LLMProvider {
    public nonisolated let providerType: LLMProviderType = .openAICompatible
    public nonisolated let displayName: String = "OpenAI Codex"

    private static let endpointURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    private static let modelsEndpointURL = URL(string: "https://chatgpt.com/backend-api/codex/models")!
    private static let fallbackModels: [LLMModelInfo] = [
        LLMModelInfo(id: "codex-mini-latest", name: "Codex Mini (latest)"),
        LLMModelInfo(id: "gpt-4o", name: "GPT-4o"),
        LLMModelInfo(id: "gpt-4o-mini", name: "GPT-4o mini"),
        LLMModelInfo(id: "o1", name: "o1"),
        LLMModelInfo(id: "o3-mini", name: "o3-mini"),
        LLMModelInfo(id: "o4-mini", name: "o4-mini"),
    ]

    private var credentials: OAuthCredentials
    private let oauthProvider: OAuthProvider
    private let model: String
    private let codexClientVersion: String?
    private let onCredentialsUpdated: ((OAuthCredentials) async -> Void)?

    public init(
        credentials: OAuthCredentials,
        oauthProvider: OAuthProvider,
        model: String,
        codexClientVersion: String? = nil,
        onCredentialsUpdated: ((OAuthCredentials) async -> Void)? = nil
    ) {
        self.credentials = credentials
        self.oauthProvider = oauthProvider
        self.model = model
        self.codexClientVersion = codexClientVersion
        self.onCredentialsUpdated = onCredentialsUpdated
    }

    public func checkAvailability() async -> Bool {
        true  // remote cloud endpoint
    }

    public func availableModels() async throws -> [LLMModelInfo] {
        let token = try await resolvedAccessToken()

        var components = URLComponents(
            url: Self.modelsEndpointURL,
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "client_version", value: resolvedCodexClientVersion())
        ]

        guard let url = components.url else {
            return Self.fallbackModels
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = Self.openAICodexAccountID(from: credentials) {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIResponsesProviderError.invalidHTTPResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIResponsesProviderError.requestFailed(
                statusCode: http.statusCode,
                body: body
            )
        }

        if let decoded = try? JSONDecoder().decode(CodexModelsResponse.self, from: data) {
            let models = decoded.models
                .filter { ($0.supportedInAPI ?? true) && Self.modelVisibilityAllowsListing($0.visibility) }
                .sorted { ($0.priority ?? Int.max) < ($1.priority ?? Int.max) }
                .compactMap { $0.slug?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { LLMModelInfo(id: $0, name: $0) }
            if !models.isEmpty {
                return Self.dedupedModels(models)
            }
        }

        if let decoded = try? JSONDecoder().decode(OpenAIModelsResponse.self, from: data) {
            let models = decoded.data
                .map(\.id)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { LLMModelInfo(id: $0, name: $0) }
            if !models.isEmpty {
                return Self.dedupedModels(models)
            }
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        throw OpenAIResponsesProviderError.invalidModelsResponse(body: body)
    }

    public func sendMessage(
        system: String,
        messages: [LLMMessage],
        tools: [ToolDefinition],
        onTextDelta: @escaping (String) -> Void
    ) async throws -> LLMResponse {
        let token = try await resolvedAccessToken()

        var request = URLRequest(url: Self.endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let payload = buildPayload(system: system, messages: messages, tools: tools)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        fputs("[LLM] → POST \(Self.endpointURL) model=\(model)\n", stderr)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIResponsesProviderError.invalidHTTPResponse
        }

        fputs("[LLM] ← HTTP \(http.statusCode)\n", stderr)

        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line }
            fputs("[LLM] ✗ error body: \(body)\n", stderr)
            throw OpenAIResponsesProviderError.requestFailed(
                statusCode: http.statusCode, body: body)
        }

        var textBuffer = ""
        var completedToolCalls: [CompletedFunctionCall] = []
        var usage: LLMUsage?

        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let content = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty, content != "[DONE]" else { continue }
            guard let data = content.data(using: .utf8),
                let event = try? JSONDecoder().decode(ResponsesStreamEvent.self, from: data)
            else { continue }

            switch event.type {
            case "response.output_text.delta":
                if let delta = event.delta {
                    textBuffer += delta
                    onTextDelta(delta)
                }
            case "response.output_item.done":
                if let item = event.item,
                    item.type == "function_call",
                    let name = item.name,
                    let callId = item.callId,
                    let arguments = item.arguments
                {
                    completedToolCalls.append(
                        CompletedFunctionCall(id: callId, name: name, arguments: arguments))
                }
            case "response.completed", "response.done":
                if let u = event.response?.usage {
                    usage = LLMUsage(
                        inputTokens: u.inputTokens,
                        outputTokens: u.outputTokens,
                        totalTokens: u.totalTokens
                    )
                }
            case "response.failed":
                let msg = event.response?.error?.message ?? "Unknown stream error"
                throw OpenAIResponsesProviderError.streamFailed(message: msg)
            default:
                break
            }
        }

        var blocks: [ContentBlock] = []
        if !textBuffer.isEmpty { blocks.append(.text(textBuffer)) }
        for call in completedToolCalls {
            blocks.append(
                .toolUse(id: call.id, name: call.name, input: parseJSONObject(from: call.arguments))
            )
        }

        return LLMResponse(
            contentBlocks: blocks,
            stopReason: completedToolCalls.isEmpty ? .endTurn : .toolUse,
            usage: usage
        )
    }

    // MARK: - Private helpers

    private func resolvedAccessToken() async throws -> String {
        if credentials.isExpired {
            let refreshed = try await oauthProvider.refreshToken(credentials)
            credentials = refreshed
            await onCredentialsUpdated?(refreshed)
        }
        return credentials.accessToken
    }

    private func resolvedCodexClientVersion() -> String {
        if let codexClientVersion {
            let trimmed = codexClientVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        let envValue = ProcessInfo.processInfo.environment["MAI_CODEX_CLIENT_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let envValue, !envValue.isEmpty { return envValue }

        if let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String
        {
            let trimmed = appVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        return "0.0.0"
    }

    private func buildPayload(
        system: String,
        messages: [LLMMessage],
        tools: [ToolDefinition]
    ) -> [String: Any] {
        var instructionParts: [String] = []
        if !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            instructionParts.append(system)
        }
        for msg in messages where msg.role == .system {
            let t = msg.textContent
            if !t.isEmpty { instructionParts.append(t) }
        }
        let instructions = instructionParts.joined(separator: "\n\n")

        let input = toResponsesInput(messages: messages.filter { $0.role != .system })

        var payload: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input,
            "stream": true,
            "store": false,
        ]

        if !tools.isEmpty {
            payload["tools"] = tools.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.inputSchema.mapValues(\.anyValue),
                ]
            }
            payload["tool_choice"] = "auto"
        }

        return payload
    }

    private func toResponsesInput(messages: [LLMMessage]) -> [[String: Any]] {
        var items: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case .system:
                break
            case .user:
                let text = message.textContent
                if !text.isEmpty {
                    items.append([
                        "type": "message",
                        "role": "user",
                        "content": [["type": "input_text", "text": text] as [String: Any]],
                    ])
                }
            case .assistant:
                let text = message.textContent
                if !text.isEmpty {
                    items.append([
                        "type": "message",
                        "role": "assistant",
                        "content": [["type": "output_text", "text": text] as [String: Any]],
                    ])
                }
                for block in message.contentBlocks {
                    if case .toolUse(let id, let name, let input) = block {
                        let argsData = try? JSONSerialization.data(
                            withJSONObject: input.mapValues(\.anyValue))
                        let args = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        items.append([
                            "type": "function_call",
                            "name": name,
                            "arguments": args,
                            "call_id": id,
                        ])
                    }
                }
            case .tool:
                for block in message.contentBlocks {
                    if case .toolResult(let toolUseId, let content, _) = block {
                        items.append([
                            "type": "function_call_output",
                            "call_id": toolUseId,
                            "output": content,
                        ])
                    }
                }
            }
        }
        return items
    }

    private func parseJSONObject(from raw: String) -> JSONObject {
        guard let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ["_raw": .string(raw)]
        }
        return object.mapValues(JSONValue.from(any:))
    }

    private static func dedupedModels(_ values: [LLMModelInfo]) -> [LLMModelInfo] {
        var deduped: [LLMModelInfo] = []
        var seen = Set<String>()
        for model in values where seen.insert(model.id).inserted {
            deduped.append(model)
        }
        return deduped
    }

    private static func modelVisibilityAllowsListing(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.lowercased() != "hidden"
    }

    private static func openAICodexAccountID(from credentials: OAuthCredentials) -> String? {
        if let accountID = credentials.extra?["chatgpt_account_id"], !accountID.isEmpty {
            return accountID
        }
        if let claims = authClaims(fromJWT: credentials.accessToken),
            let accountID = claims["chatgpt_account_id"] as? String,
            !accountID.isEmpty
        {
            return accountID
        }
        return nil
    }

    private static func authClaims(fromJWT jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload),
            let rawObject = try? JSONSerialization.jsonObject(with: data),
            let rawDict = rawObject as? [String: Any]
        else {
            return nil
        }

        if let nested = rawDict["https://api.openai.com/auth"] as? [String: Any] {
            return nested
        }
        return rawDict
    }

    // MARK: - SSE decode types

    private struct CodexModelsResponse: Decodable {
        let models: [CodexModel]
    }

    private struct CodexModel: Decodable {
        let slug: String?
        let supportedInAPI: Bool?
        let visibility: String?
        let priority: Int?

        enum CodingKeys: String, CodingKey {
            case slug
            case supportedInAPI = "supported_in_api"
            case visibility
            case priority
        }
    }

    private struct OpenAIModelsResponse: Decodable {
        let data: [OpenAIModel]
    }

    private struct OpenAIModel: Decodable {
        let id: String
    }

    private struct ResponsesStreamEvent: Decodable {
        let type: String
        let delta: String?
        let item: ResponseItemPartial?
        let response: ResponsePartial?
    }

    private struct ResponseItemPartial: Decodable {
        let type: String
        let name: String?
        let callId: String?
        let arguments: String?

        enum CodingKeys: String, CodingKey {
            case type, name, arguments
            case callId = "call_id"
        }
    }

    private struct ResponsePartial: Decodable {
        let usage: UsagePartial?
        let error: ErrorPartial?
    }

    private struct UsagePartial: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case totalTokens = "total_tokens"
        }
    }

    private struct ErrorPartial: Decodable {
        let message: String?
        let code: String?
    }

    private struct CompletedFunctionCall {
        let id: String
        let name: String
        let arguments: String
    }
}
