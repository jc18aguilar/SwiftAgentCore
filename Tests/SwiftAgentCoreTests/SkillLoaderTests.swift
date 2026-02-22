import Foundation
import XCTest
@testable import SwiftAgentCore

final class SkillLoaderTests: XCTestCase {
    func testLoadSkillsSortsByNameAndFiltersMarkdownExtensions() throws {
        try withTemporaryDirectory { directory in
            try writeSkill(
                """
                ---
                name: zeta
                description: zeta skill
                ---
                zeta body
                """,
                named: "zeta.md",
                in: directory
            )
            try writeSkill(
                """
                ---
                name: alpha
                description: alpha skill
                ---
                alpha body
                """,
                named: "alpha.markdown",
                in: directory
            )
            try writeSkill(
                """
                ---
                name: ignored
                ---
                ignored
                """,
                named: "ignored.txt",
                in: directory
            )
            try writeSkill(
                """
                ---
                name: hidden
                ---
                hidden
                """,
                named: ".hidden.md",
                in: directory
            )

            let loader = SkillLoader()
            let skills = try loader.loadSkills(from: directory)

            XCTAssertEqual(skills.map(\.name), ["alpha", "zeta"])
        }
    }

    func testLoadSkillNamedReturnsExpectedSkill() throws {
        try withTemporaryDirectory { directory in
            try writeSkill(
                """
                ---
                name: summarize
                description: summarize text
                ---
                summarize body
                """,
                named: "summarize.md",
                in: directory
            )
            try writeSkill(
                """
                ---
                name: translate
                ---
                translate body
                """,
                named: "translate.md",
                in: directory
            )

            let loader = SkillLoader()
            let skill = try loader.loadSkill(named: "translate", from: directory)

            XCTAssertNotNil(skill)
            XCTAssertEqual(skill?.name, "translate")
            XCTAssertEqual(skill?.systemPromptContent, "translate body")
        }
    }

    func testLoadSkillParsesFrontMatterAndBody() throws {
        try withTemporaryDirectory { directory in
            let fileURL = directory.appendingPathComponent("summarize.md")
            try writeSkill(
                """
                ---
                name: summarize
                description: Summarize user text concisely
                disable-model-invocation: true
                ---
                Line 1
                Line 2
                """,
                named: "summarize.md",
                in: directory
            )

            let loader = SkillLoader()
            let skill = try loader.loadSkill(at: fileURL)

            XCTAssertEqual(skill?.name, "summarize")
            XCTAssertEqual(skill?.description, "Summarize user text concisely")
            XCTAssertEqual(skill?.disableModelInvocation, true)
            XCTAssertEqual(skill?.systemPromptContent, "Line 1\nLine 2")
        }
    }

    func testLoadSkillWithoutNameReturnsNil() throws {
        try withTemporaryDirectory { directory in
            let fileURL = directory.appendingPathComponent("invalid.md")
            try writeSkill(
                """
                ---
                description: missing name
                ---
                body
                """,
                named: "invalid.md",
                in: directory
            )

            let loader = SkillLoader()
            let skill = try loader.loadSkill(at: fileURL)

            XCTAssertNil(skill)
        }
    }

    func testLoadSkillsMissingDirectoryReturnsEmpty() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("non-existent-\(UUID().uuidString)")
        let loader = SkillLoader()

        let skills = try loader.loadSkills(from: directory)

        XCTAssertEqual(skills, [])
    }

    func testSkillRegistryLoadAllMergesDirectoriesWithLaterOverride() throws {
        try withTemporaryDirectory { firstDirectory in
            try withTemporaryDirectory { secondDirectory in
                try writeSkill(
                    """
                    ---
                    name: shared
                    description: first version
                    ---
                    from first
                    """,
                    named: "shared.md",
                    in: firstDirectory
                )
                try writeSkill(
                    """
                    ---
                    name: shared
                    description: second version
                    ---
                    from second
                    """,
                    named: "shared.md",
                    in: secondDirectory
                )
                try writeSkill(
                    """
                    ---
                    name: local-only
                    description: only here
                    ---
                    second only
                    """,
                    named: "local-only.md",
                    in: secondDirectory
                )

                let registry = SkillRegistry(directories: [firstDirectory, secondDirectory])
                let skills = try registry.loadAll()

                XCTAssertEqual(skills.map(\.name), ["local-only", "shared"])
                XCTAssertEqual(skills.first(where: { $0.name == "shared" })?.description, "second version")
                XCTAssertEqual(skills.first(where: { $0.name == "shared" })?.systemPromptContent, "from second")
            }
        }
    }

    func testSkillRegistrySummaryExcludesHiddenByDefault() throws {
        try withTemporaryDirectory { directory in
            try writeSkill(
                """
                ---
                name: visible
                description: visible skill
                ---
                visible body
                """,
                named: "visible.md",
                in: directory
            )
            try writeSkill(
                """
                ---
                name: hidden
                description: hidden skill
                disable-model-invocation: true
                ---
                hidden body
                """,
                named: "hidden.md",
                in: directory
            )

            let registry = SkillRegistry(directories: [directory])
            let visibleSummary = registry.skillsSummary()
            let fullSummary = registry.skillsSummary(excludeHidden: false)

            XCTAssertEqual(visibleSummary, "- visible: visible skill")
            XCTAssertTrue(fullSummary.contains("- hidden: hidden skill"))
        }
    }

    func testSkillRegistrySummaryReturnsDefaultTextWhenNoSkillsVisible() throws {
        try withTemporaryDirectory { directory in
            try writeSkill(
                """
                ---
                name: hidden
                description: hidden skill
                disable-model-invocation: true
                ---
                hidden body
                """,
                named: "hidden.md",
                in: directory
            )

            let registry = SkillRegistry(directories: [directory])

            XCTAssertEqual(registry.skillsSummary(), "No skills available.")
        }
    }

    func testReadSkillToolReturnsFoundPayload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swiftagentcore-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeSkill(
            """
            ---
            name: summarize
            description: concise summary
            disable-model-invocation: true
            ---
            summarize content
            """,
            named: "summarize.md",
            in: directory
        )

        let registry = SkillRegistry(directories: [directory])
        let tool = ReadSkillTool(registry: registry)

        let output = try await tool.execute(input: ["name": .string("summarize")])
        let payload = try XCTUnwrap(try parseJSONObject(output))

        XCTAssertEqual(payload["name"] as? String, "summarize")
        XCTAssertEqual(payload["description"] as? String, "concise summary")
        XCTAssertEqual(payload["content"] as? String, "summarize content")
        XCTAssertEqual(payload["disable_model_invocation"] as? Bool, true)
        XCTAssertEqual(payload["found"] as? Bool, true)
    }

    func testReadSkillToolReturnsNotFoundPayload() async throws {
        let registry = SkillRegistry(directories: [])
        let tool = ReadSkillTool(registry: registry)

        let output = try await tool.execute(input: ["name": .string("missing")])
        let payload = try XCTUnwrap(try parseJSONObject(output))

        XCTAssertEqual(payload["name"] as? String, "missing")
        XCTAssertEqual(payload["found"] as? Bool, false)
    }

    func testReadSkillToolThrowsWhenMissingName() async {
        let registry = SkillRegistry(directories: [])
        let tool = ReadSkillTool(registry: registry)

        do {
            _ = try await tool.execute(input: [:])
            XCTFail("Expected execute to throw when name is missing")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Missing required parameter: name")
        }
    }
}

private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swiftagentcore-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private func writeSkill(_ content: String, named fileName: String, in directory: URL) throws {
    let fileURL = directory.appendingPathComponent(fileName)
    try content.write(to: fileURL, atomically: true, encoding: .utf8)
}

private func parseJSONObject(_ text: String) throws -> [String: Any]? {
    guard let data = text.data(using: .utf8) else {
        return nil
    }
    return try JSONSerialization.jsonObject(with: data) as? [String: Any]
}
