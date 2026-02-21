import Foundation

public struct ToolRegistry {
    private var byName: [String: AgentTool]

    public init(tools: [AgentTool]) {
        self.byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    }

    public func tool(named name: String) -> AgentTool? {
        byName[name]
    }

    public var definitions: [ToolDefinition] {
        byName.values
            .sorted { $0.name < $1.name }
            .map {
                ToolDefinition(name: $0.name, description: $0.description, inputSchema: $0.inputSchema)
            }
    }
}
