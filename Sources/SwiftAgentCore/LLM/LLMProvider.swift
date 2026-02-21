import Foundation

public protocol LLMProvider {
    var providerType: LLMProviderType { get }
    var displayName: String { get }

    func checkAvailability() async -> Bool
    func availableModels() async throws -> [LLMModelInfo]

    func sendMessage(
        system: String,
        messages: [LLMMessage],
        tools: [ToolDefinition],
        onTextDelta: @escaping (String) -> Void
    ) async throws -> LLMResponse
}
