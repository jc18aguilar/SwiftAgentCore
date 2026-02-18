import Foundation

public enum StructuredToolFallbackError: LocalizedError {
    case invalidStructuredOutput(preview: String)

    public var errorDescription: String? {
        switch self {
        case .invalidStructuredOutput(let preview):
            return "Model did not return valid structured tool output. Preview: \(preview)"
        }
    }
}

public enum StructuredToolNonCompliancePolicy: Sendable, Equatable {
    case fail
    case degradeToPlainText(notice: String)
}

public struct StructuredToolFallbackConfig: Sendable, Equatable {
    public var maxCorrectionAttempts: Int
    public var nonCompliancePolicy: StructuredToolNonCompliancePolicy

    public init(
        maxCorrectionAttempts: Int = 1,
        nonCompliancePolicy: StructuredToolNonCompliancePolicy = .degradeToPlainText(
            notice: StructuredToolFallbackProvider.defaultDegradeNotice)
    ) {
        self.maxCorrectionAttempts = max(0, maxCorrectionAttempts)
        self.nonCompliancePolicy = nonCompliancePolicy
    }
}

/// Wrapper that emulates tool-calling over structured JSON envelopes for models
/// that do not support native tool calling.
public final actor StructuredToolFallbackProvider: LLMProvider {
    public nonisolated let providerType: LLMProviderType
    public nonisolated let displayName: String

    public static let defaultDegradeNotice =
        "[Tool fallback] This model did not return a valid structured tool_call envelope. Continuing without tools."

    private let base: any LLMProvider
    private let config: StructuredToolFallbackConfig

    public init(
        base: any LLMProvider,
        config: StructuredToolFallbackConfig = StructuredToolFallbackConfig()
    ) {
        self.base = base
        self.config = config
        self.providerType = base.providerType
        self.displayName = "\(base.displayName)-structured-tools"
    }

    public func checkAvailability() async -> Bool {
        await base.checkAvailability()
    }

    public func availableModels() async throws -> [LLMModelInfo] {
        try await base.availableModels()
    }

    public func sendMessage(
        system: String,
        messages: [LLMMessage],
        tools: [ToolDefinition],
        onTextDelta: @escaping (String) -> Void
    ) async throws -> LLMResponse {
        debugLog("structured fallback started messages=\(messages.count) tools=\(tools.count)")

        let injectedSystem = Self.structuredToolSystemPrompt(originalSystem: system, tools: tools)
        let sanitized = sanitizedMessages(messages)
        let maxAttempts = max(1, config.maxCorrectionAttempts + 1)

        var lastRawText = ""
        var lastResponse: LLMResponse?

        for attempt in 0..<maxAttempts {
            let correctionHint: String? =
                attempt == 0
                ? nil
                : "Your previous response was not valid JSON. Reply with exactly one JSON object only."
            let result = try await requestStructuredResponse(
                system: injectedSystem,
                messages: sanitized,
                correctionHint: correctionHint
            )

            lastRawText = result.rawText
            lastResponse = result.response

            let envelope = Self.decodeEnvelope(from: lastRawText)
            debugLog(
                "attempt=\(attempt + 1)/\(maxAttempts) chars=\(lastRawText.count) parsed=\(envelope == nil ? "no" : "yes")"
            )

            guard let envelope else {
                continue
            }

            switch envelope {
            case .toolCall(let id, let name, let input):
                debugLog("parsed tool_call name=\(name) input_keys=\(input.keys.sorted())")
                return LLMResponse(
                    contentBlocks: [.toolUse(id: id, name: name, input: input)],
                    stopReason: .toolUse,
                    usage: result.response.usage
                )
            case .final(let text):
                debugLog("parsed final text chars=\(text.count)")
                if !text.isEmpty {
                    onTextDelta(text)
                    return LLMResponse(
                        contentBlocks: [.text(text)],
                        stopReason: .endTurn,
                        usage: result.response.usage
                    )
                }
                return LLMResponse(
                    contentBlocks: [],
                    stopReason: .endTurn,
                    usage: result.response.usage
                )
            }
        }

        switch config.nonCompliancePolicy {
        case .fail:
            let preview = Self.preview(lastRawText)
            debugLog("non-compliant after retries; throwing error preview=\(preview)")
            throw StructuredToolFallbackError.invalidStructuredOutput(preview: preview)
        case .degradeToPlainText(let notice):
            let fallbackText = Self.composeDegradedText(notice: notice, rawText: lastRawText)
            debugLog("non-compliant after retries; degrading to plain text chars=\(fallbackText.count)")
            if !fallbackText.isEmpty {
                onTextDelta(fallbackText)
                return LLMResponse(
                    contentBlocks: [.text(fallbackText)],
                    stopReason: .endTurn,
                    usage: lastResponse?.usage
                )
            }
            return LLMResponse(contentBlocks: [], stopReason: .endTurn, usage: lastResponse?.usage)
        }
    }

    private func requestStructuredResponse(
        system: String,
        messages: [LLMMessage],
        correctionHint: String?
    ) async throws -> (response: LLMResponse, rawText: String) {
        let startedAt = Date()
        var captured = ""
        var input = messages
        if let correctionHint, !correctionHint.isEmpty {
            input.append(.text(role: .user, correctionHint))
        }

        let response = try await base.sendMessage(
            system: system,
            messages: input,
            tools: [],
            onTextDelta: { captured += $0 }
        )
        let raw = captured.isEmpty ? response.textContent : captured
        let elapsed = Date().timeIntervalSince(startedAt)
        debugLog(
            "upstream response elapsed=\(String(format: "%.3f", elapsed))s captured=\(captured.count) block_text=\(response.textContent.count)"
        )
        return (response, raw)
    }

    private func sanitizedMessages(_ messages: [LLMMessage]) -> [LLMMessage] {
        var sanitized: [LLMMessage] = []
        for message in messages {
            switch message.role {
            case .assistant:
                let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    sanitized.append(.text(role: .assistant, text))
                }
                for block in message.contentBlocks {
                    guard case .toolUse(let id, let name, let input) = block else { continue }
                    let payload: [String: Any] = [
                        "type": "tool_call",
                        "id": id,
                        "name": name,
                        "input": input.mapValues(\.anyValue),
                    ]
                    sanitized.append(.text(role: .assistant, Self.serializeJSONObject(payload)))
                }
            case .tool:
                for block in message.contentBlocks {
                    guard case .toolResult(let toolUseId, let content, let isError) = block else {
                        continue
                    }
                    let payload: [String: Any] = [
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "is_error": isError,
                        "content": content,
                    ]
                    sanitized.append(.text(role: .user, Self.serializeJSONObject(payload)))
                }
            default:
                sanitized.append(message)
            }
        }
        return sanitized
    }

    private enum Envelope {
        case toolCall(id: String, name: String, input: JSONObject)
        case final(text: String)
    }

    private struct EnvelopePayload: Decodable {
        let type: String
        let id: String?
        let name: String?
        let input: JSONObject?
        let text: String?
    }

    private static func decodeEnvelope(from text: String) -> Envelope? {
        let candidate = extractJSONCandidate(from: text)
        guard !candidate.isEmpty else { return nil }
        guard let data = candidate.data(using: .utf8),
            let payload = try? JSONDecoder().decode(EnvelopePayload.self, from: data)
        else {
            return nil
        }

        switch payload.type.lowercased() {
        case "tool_call":
            guard let rawName = payload.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                !rawName.isEmpty
            else {
                return nil
            }
            let id = payload.id?.isEmpty == false ? payload.id! : UUID().uuidString
            return .toolCall(id: id, name: rawName, input: payload.input ?? [:])
        case "final":
            return .final(text: payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        default:
            return nil
        }
    }

    private static func structuredToolSystemPrompt(
        originalSystem: String,
        tools: [ToolDefinition]
    ) -> String {
        let catalog = tools.sorted { $0.name < $1.name }.map { tool in
            let schema = jsonObjectString(tool.inputSchema.mapValues(\.anyValue))
            return "- \(tool.name): \(tool.description)\n  input_schema: \(schema)"
        }.joined(separator: "\n")

        let protocolBlock = """
            Structured tool protocol:
            You MUST reply with exactly one JSON object and no markdown/code fences.
            Allowed shapes:
            {"type":"tool_call","id":"optional-id","name":"tool_name","input":{...}}
            {"type":"final","text":"final user-facing answer"}
            If tool use is required, return type=\"tool_call\" with valid name/input fields only.
            Do not invent tool names.
            """

        if originalSystem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(protocolBlock)\n\nTools:\n\(catalog)"
        }
        return "\(originalSystem)\n\n\(protocolBlock)\n\nTools:\n\(catalog)"
    }

    private static func extractJSONCandidate(from raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if let fenced = extractFencedJSON(from: text) {
            return fenced
        }
        if text.first == "{", text.last == "}" {
            return text
        }
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            return String(text[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private static func extractFencedJSON(from text: String) -> String? {
        guard let startFence = text.range(of: "```") else { return nil }
        let remainder = text[startFence.upperBound...]
        guard let endFence = remainder.range(of: "```") else { return nil }

        var body = String(remainder[..<endFence.lowerBound]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        if body.hasPrefix("json") {
            body = String(body.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return body.isEmpty ? nil : body
    }

    private static func composeDegradedText(notice: String, rawText: String) -> String {
        let cleanNotice = notice.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRaw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanNotice.isEmpty {
            return cleanRaw
        }
        if cleanRaw.isEmpty {
            return cleanNotice
        }
        return "\(cleanNotice)\n\n\(cleanRaw)"
    }

    private static func jsonObjectString(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private static func serializeJSONObject(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private static func preview(_ raw: String) -> String {
        let compact = raw.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(compact.prefix(180))
    }

    private var isDebugEnabled: Bool {
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

    private func debugLog(_ message: String) {
        guard isDebugEnabled else { return }
        fputs("[StructuredFallback][DEBUG] \(message)\n", stderr)
    }
}

private extension LLMResponse {
    var textContent: String {
        contentBlocks.compactMap { block in
            if case .text(let text) = block { return text }
            return nil
        }.joined()
    }
}
