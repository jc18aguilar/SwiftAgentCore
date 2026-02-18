import Foundation

public enum SkillLoaderError: LocalizedError {
    case invalidFrontMatter(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFrontMatter(let path):
            return "Invalid skill frontmatter: \(path)"
        }
    }
}

public struct SkillLoader {
    public init() {}

    public func loadSkills(from directory: URL) throws -> [SkillDefinition] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let markdownFiles = files.filter { file in
            let ext = file.pathExtension.lowercased()
            return ext == "md" || ext == "markdown"
        }

        return try markdownFiles.compactMap(loadSkill(at:))
            .sorted { $0.name < $1.name }
    }

    public func loadSkill(named name: String, from directory: URL) throws -> SkillDefinition? {
        try loadSkills(from: directory).first(where: { $0.name == name })
    }

    public func loadSkill(at fileURL: URL) throws -> SkillDefinition? {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let parsed = parseSkill(content: content)

        guard let name = parsed.frontMatter["name"], !name.isEmpty else {
            return nil
        }

        return SkillDefinition(
            name: name,
            description: parsed.frontMatter["description"] ?? "",
            disableModelInvocation: (parsed.frontMatter["disable-model-invocation"] ?? "false").lowercased() == "true",
            filePath: fileURL.path,
            systemPromptContent: parsed.body
        )
    }

    private func parseSkill(content: String) -> (frontMatter: [String: String], body: String) {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return ([:], content.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var frontMatter: [String: String] = [:]
        var index = 1

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line == "---" {
                index += 1
                break
            }

            if let splitIndex = line.firstIndex(of: ":") {
                let key = String(line[..<splitIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: splitIndex)...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    frontMatter[key.lowercased()] = value
                }
            }
            index += 1
        }

        let body = lines[index...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (frontMatter, body)
    }
}
