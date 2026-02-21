import Foundation

public struct AgentLoopConfig {
    public var provider: LLMProvider
    public var tools: [AgentTool]
    public var buildSystemPrompt: () async -> String
    public var confirmationHandler: (String, String) async -> Bool
    public var getSteeringMessages: () async -> [LLMMessage]
    public var getFollowUpMessages: () async -> [LLMMessage]

    public init(
        provider: LLMProvider,
        tools: [AgentTool],
        buildSystemPrompt: @escaping () async -> String,
        confirmationHandler: @escaping (String, String) async -> Bool,
        getSteeringMessages: @escaping () async -> [LLMMessage] = { [] },
        getFollowUpMessages: @escaping () async -> [LLMMessage] = { [] }
    ) {
        self.provider = provider
        self.tools = tools
        self.buildSystemPrompt = buildSystemPrompt
        self.confirmationHandler = confirmationHandler
        self.getSteeringMessages = getSteeringMessages
        self.getFollowUpMessages = getFollowUpMessages
    }
}
