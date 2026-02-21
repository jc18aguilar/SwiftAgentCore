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
