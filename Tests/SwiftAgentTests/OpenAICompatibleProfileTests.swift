import XCTest
@testable import SwiftAgent

final class OpenAICompatibleProfileTests: XCTestCase {
    func testProviderMappingForKnownProviders() {
        XCTAssertEqual(OpenAICompatibleProfile.forProviderID("ollama-local").id, "ollama-local")
        XCTAssertEqual(OpenAICompatibleProfile.forProviderID("openai-api").id, "openai-api")
        XCTAssertEqual(OpenAICompatibleProfile.forProviderID("openrouter-api").id, "openrouter-api")
        XCTAssertEqual(OpenAICompatibleProfile.forProviderID("custom-openai-compatible").id, "custom-openai-compatible")
    }

    func testUnsupportedToolsMatcherForOllama() {
        let profile = OpenAICompatibleProfile.forProviderID("ollama-local")
        XCTAssertTrue(
            profile.matchesUnsupportedToolsError(
                statusCode: 400,
                body: "registry.ollama.ai/library/x does not support tools"
            ))
        XCTAssertFalse(profile.matchesUnsupportedToolsError(statusCode: 500, body: "does not support tools"))
    }
}
