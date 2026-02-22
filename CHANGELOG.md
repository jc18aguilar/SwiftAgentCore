# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

- No changes yet.

## [1.3.0] - 2026-02-22

### Added

- Added `SkillRegistry` for multi-directory skill loading with deterministic override behavior (later directories override earlier ones).
- Added built-in `ReadSkillTool` (`read_skill`) so models can fetch full skill content by name at runtime.
- Added `AgentLoop` auto-registration of `read_skill` when `AgentLoopConfig.skillRegistry` is provided.
- Added tests for `SkillRegistry`, `ReadSkillTool`, and loop-level auto-injection of `read_skill`.

### Changed

- Extended `AgentLoopConfig` with optional `skillRegistry`.
- Marked `SkillLoader` as `Sendable` for Swift concurrency correctness.

### Docs

- Updated README to describe the Skill system (`SkillRegistry` + built-in `ReadSkillTool`) and system prompt integration workflow.

## [1.2.0] - 2026-02-22

### Added

- Added loop-level LLM retry controls to `AgentLoopConfig` (`maxRetries`, `retryDelay`) with automatic retry for retryable provider errors.
- Added per-call and whole-loop timeout controls to `AgentLoopConfig` (`llmCallTimeout`, `totalTimeout`).
- Added `AgentLoop` tests for retry behavior, non-retryable failures, and timeout handling.

### Changed

- Updated `runAgentLoop` to apply retry/timeout behavior around provider `sendMessage` calls while keeping tool execution retry policy unchanged.

### Removed

- Removed `Examples/MinimalCLI` executable target and related package/example references.

### Docs

- Updated README features section wording and formatting.
- Added DeepWiki badge and explicit platform badge (`macOS 13+ | iOS 16+`).
- Updated roadmap entries to include optional MCP client and context-window management items.

## [1.1.0] - 2026-02-21

### Added

- Added `MinimalAgentDemo` executable target under `Examples/MinimalCLI` for a deterministic 3-minute CLI walkthrough.
- Added core `AgentLoop` tests for lifecycle events, confirmation handling, unknown tools, and follow-up turns.
- Added core `SkillLoader` tests for markdown filtering, sorting, front matter parsing, and missing-directory behavior.

### Docs

- Added README examples section with `swift run MinimalAgentDemo`.
- Added README system structure diagram covering internal modules and external integrations.
- Updated v1.1 roadmap checklist progress for examples/tests.

## [1.0.1] - 2026-02-21

### Added

- Added GitHub Actions CI workflow (`.github/workflows/ci.yml`) to run `swift build` and `swift test` on macOS 14.
- Added MIT license file for package distribution clarity.

### Fixed

- Fixed Swift 6 concurrency capture in `OAuthCallbackServer` callback handling.

### Docs

- Fixed README installation dependency URL to use the real org path (`herrkaefer`).
- Added v1.1 roadmap section to README covering demo app, architecture diagram, AgentLoop/SkillLoader tests, and memory/context improvements.

## [1.0.0] - 2026-02-20

### Added

- Initial public package release with README and Swift Package Index metadata.
