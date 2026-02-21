import Foundation

public enum ToolSafetyLevel: Sendable, Equatable {
    case safe
    case needsConfirmation
}

public protocol AgentTool {
    var name: String { get }
    var description: String { get }
    var inputSchema: JSONObject { get }
    var safetyLevel: ToolSafetyLevel { get }

    func execute(input: JSONObject) async throws -> String
    func humanReadableSummary(for input: JSONObject) -> String
}
