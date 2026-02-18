import Foundation

public enum MessageRole: Sendable, Equatable {
    case system
    case user
    case assistant
    case tool
}

public enum AgentEvent {
    case agentStart
    case agentEnd
    case turnStart(turnIndex: Int)
    case turnEnd(turnIndex: Int)
    case messageStart(role: MessageRole)
    case messageTextDelta(String)
    case messageEnd
    case toolExecutionStart(name: String, input: JSONObject)
    case toolExecutionEnd(name: String, result: String, isError: Bool)
    case confirmationRequired(toolName: String, summary: String)
    case confirmationResolved(approved: Bool)
    case usageUpdated(LLMUsage)
    case error(Error)
}
