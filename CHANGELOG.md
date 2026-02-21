# Changelog

All notable changes to this project are documented in this file.

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
