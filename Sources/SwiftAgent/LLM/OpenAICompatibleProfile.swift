import Foundation

public struct OpenAICompatibleProfile: Sendable, Equatable {
    public let id: String
    public let defaultHeaders: [String: String]
    public let supportsNativeToolsByDefault: Bool
    public let unsupportedToolsBodyPatterns: [String]

    public init(
        id: String,
        defaultHeaders: [String: String] = [:],
        supportsNativeToolsByDefault: Bool = true,
        unsupportedToolsBodyPatterns: [String] = []
    ) {
        self.id = id
        self.defaultHeaders = defaultHeaders
        self.supportsNativeToolsByDefault = supportsNativeToolsByDefault
        self.unsupportedToolsBodyPatterns = unsupportedToolsBodyPatterns
    }

    public func mergedHeaders(with extraHeaders: [String: String]) -> [String: String] {
        var headers = defaultHeaders
        for (key, value) in extraHeaders {
            headers[key] = value
        }
        return headers
    }

    public func matchesUnsupportedToolsError(statusCode: Int, body: String) -> Bool {
        guard statusCode == 400 else { return false }
        let normalized = body.lowercased()
        return unsupportedToolsBodyPatterns.contains { normalized.contains($0.lowercased()) }
    }

    public static func forProviderID(_ providerID: String) -> OpenAICompatibleProfile {
        switch providerID {
        case "ollama-local":
            return .ollama
        case "openrouter-api":
            return .openRouter
        case "openai-api":
            return .openAIAPI
        case "deepseek-api":
            return .deepSeek
        case "groq-api":
            return .groq
        case "custom-openai-compatible":
            return .customOpenAICompatible
        default:
            return .generic(providerID)
        }
    }

    public static var openAIAPI: OpenAICompatibleProfile {
        OpenAICompatibleProfile(
            id: "openai-api",
            unsupportedToolsBodyPatterns: [
                "does not support tools",
                "tool calls are not supported",
                "tool_choice",
            ]
        )
    }

    public static var openRouter: OpenAICompatibleProfile {
        OpenAICompatibleProfile(
            id: "openrouter-api",
            unsupportedToolsBodyPatterns: [
                "does not support tools",
                "tool calls are not supported",
                "tool_choice",
            ]
        )
    }

    public static var deepSeek: OpenAICompatibleProfile {
        OpenAICompatibleProfile(
            id: "deepseek-api",
            unsupportedToolsBodyPatterns: [
                "does not support tools",
                "tool calls are not supported",
                "tool_choice",
            ]
        )
    }

    public static var groq: OpenAICompatibleProfile {
        OpenAICompatibleProfile(
            id: "groq-api",
            unsupportedToolsBodyPatterns: [
                "does not support tools",
                "tool calls are not supported",
                "tool_choice",
            ]
        )
    }

    public static var ollama: OpenAICompatibleProfile {
        OpenAICompatibleProfile(
            id: "ollama-local",
            unsupportedToolsBodyPatterns: [
                "does not support tools",
                "tool calls are not supported",
                "does not support function calling",
                "tool_choice",
            ]
        )
    }

    public static var customOpenAICompatible: OpenAICompatibleProfile {
        OpenAICompatibleProfile(
            id: "custom-openai-compatible",
            unsupportedToolsBodyPatterns: [
                "does not support tools",
                "tool calls are not supported",
                "tool_choice",
            ]
        )
    }

    public static func generic(_ providerID: String) -> OpenAICompatibleProfile {
        OpenAICompatibleProfile(
            id: providerID,
            unsupportedToolsBodyPatterns: [
                "does not support tools",
                "tool calls are not supported",
                "tool_choice",
            ]
        )
    }
}
