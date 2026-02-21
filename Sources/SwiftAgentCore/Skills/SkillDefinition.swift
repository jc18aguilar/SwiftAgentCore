import Foundation

public struct SkillDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    public var disableModelInvocation: Bool
    public var filePath: String
    public var systemPromptContent: String

    public init(
        name: String,
        description: String,
        disableModelInvocation: Bool,
        filePath: String,
        systemPromptContent: String
    ) {
        self.name = name
        self.description = description
        self.disableModelInvocation = disableModelInvocation
        self.filePath = filePath
        self.systemPromptContent = systemPromptContent
    }
}
