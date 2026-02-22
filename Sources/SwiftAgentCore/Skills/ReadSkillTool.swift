import Foundation

private enum ReadSkillToolError: LocalizedError {
    case missingName

    var errorDescription: String? {
        switch self {
        case .missingName:
            return "Missing required parameter: name"
        }
    }
}

public final class ReadSkillTool: AgentTool {
    public let name = "read_skill"
    public let description = "Read a skill definition by skill name"
    public let safetyLevel: ToolSafetyLevel = .safe
    public let inputSchema: JSONObject = [
        "type": .string("object"),
        "properties": .object([
            "name": .object(["type": .string("string")])
        ]),
        "required": .array([.string("name")])
    ]

    private let registry: SkillRegistry

    public init(registry: SkillRegistry) {
        self.registry = registry
    }

    public func execute(input: JSONObject) async throws -> String {
        guard let requestedName = input["name"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !requestedName.isEmpty
        else {
            throw ReadSkillToolError.missingName
        }

        guard let skill = try registry.find(named: requestedName) else {
            return jsonObjectString([
                "found": false,
                "name": requestedName
            ])
        }

        let payload: [String: Any] = [
            "content": skill.systemPromptContent,
            "description": skill.description,
            "disable_model_invocation": skill.disableModelInvocation,
            "file_path": skill.filePath,
            "found": true,
            "name": skill.name
        ]
        return jsonObjectString(payload)
    }

    public func humanReadableSummary(for input: JSONObject) -> String {
        "Read skill \(input["name"]?.stringValue ?? "(unknown)")"
    }

    private func jsonObjectString(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys]
            ),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }
}
