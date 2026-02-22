import Foundation

public final class SkillRegistry: Sendable {
    private let directories: [URL]
    private let loader: SkillLoader

    public init(directories: [URL], loader: SkillLoader = SkillLoader()) {
        self.directories = directories
        self.loader = loader
    }

    public func loadAll() throws -> [SkillDefinition] {
        var merged: [String: SkillDefinition] = [:]
        for directory in directories {
            let skills = try loader.loadSkills(from: directory)
            for skill in skills {
                merged[skill.name] = skill
            }
        }
        return merged.values.sorted { $0.name < $1.name }
    }

    public func find(named: String) throws -> SkillDefinition? {
        try loadAll().first(where: { $0.name == named })
    }

    public func skillsSummary(excludeHidden: Bool = true) -> String {
        guard let skills = try? loadAll() else {
            return "No skills available."
        }

        let visibleSkills: [SkillDefinition]
        if excludeHidden {
            visibleSkills = skills.filter { !$0.disableModelInvocation }
        } else {
            visibleSkills = skills
        }

        guard !visibleSkills.isEmpty else {
            return "No skills available."
        }

        return visibleSkills
            .map { "- \($0.name): \($0.description)" }
            .joined(separator: "\n")
    }
}
