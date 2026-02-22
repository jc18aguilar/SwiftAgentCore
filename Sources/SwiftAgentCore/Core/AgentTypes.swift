import Foundation

public struct AgentLoopConfig {
    public var provider: LLMProvider
    public var tools: [AgentTool]
    public var buildSystemPrompt: () async -> String
    public var confirmationHandler: (String, String) async -> Bool
    public var getSteeringMessages: () async -> [LLMMessage]
    public var getFollowUpMessages: () async -> [LLMMessage]
    public var maxRetries: Int
    public var retryDelay: TimeInterval
    public var llmCallTimeout: TimeInterval?
    public var totalTimeout: TimeInterval?

    public init(
        provider: LLMProvider,
        tools: [AgentTool],
        buildSystemPrompt: @escaping () async -> String,
        confirmationHandler: @escaping (String, String) async -> Bool,
        getSteeringMessages: @escaping () async -> [LLMMessage] = { [] },
        getFollowUpMessages: @escaping () async -> [LLMMessage] = { [] },
        maxRetries: Int = 2,
        retryDelay: TimeInterval = 1.0,
        llmCallTimeout: TimeInterval? = nil,
        totalTimeout: TimeInterval? = nil
    ) {
        self.provider = provider
        self.tools = tools
        self.buildSystemPrompt = buildSystemPrompt
        self.confirmationHandler = confirmationHandler
        self.getSteeringMessages = getSteeringMessages
        self.getFollowUpMessages = getFollowUpMessages
        self.maxRetries = max(0, maxRetries)
        self.retryDelay = max(0, retryDelay)
        self.llmCallTimeout = llmCallTimeout
        self.totalTimeout = totalTimeout
    }
}
