# SwiftAgentCore

[![](https://img.shields.io/github/v/tag/herrkaefer/SwiftAgentCore?label=version)](https://github.com/herrkaefer/SwiftAgentCore/tags)
[![CI](https://github.com/herrkaefer/SwiftAgentCore/actions/workflows/ci.yml/badge.svg)](https://github.com/herrkaefer/SwiftAgentCore/actions/workflows/ci.yml)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fherrkaefer%2FSwiftAgentCore%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/herrkaefer/SwiftAgentCore)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fherrkaefer%2FSwiftAgentCore%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/herrkaefer/SwiftAgentCore)
[![](https://img.shields.io/badge/platforms-macOS%2013%2B%20%7C%20iOS%2016%2B-0A84FF)](https://swiftpackageindex.com/herrkaefer/SwiftAgentCore)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/herrkaefer/SwiftAgentCore)

SwiftAgentCore is a Swift agent runtime with a unified multi-provider LLM layer, built-in tool execution, and skill loading.

## Features

- **Lightweight & Portable** - Zero external package dependencies. Supports macOS 13+ / iOS 16+.
- **Multi-Provider** - OpenAI-compatible (DeepSeek, Groq, Ollama, OpenRouter), Anthropic, Gemini - unified behind a single provider interface.
- **Runtime Only** - Pure agent runtime with no built-in tools or provider presets. You define every tool and choose your provider - nothing opinionated, fully composable.
- **Streaming-First** - Token-level SSE streaming across all providers, delivered via AsyncStream and callback.
- **Minimal Design** - No class hierarchies, no macros, no result builders. Small API surface, easy to integrate.
- **Built-in OAuth** - PKCE flows for Anthropic Claude and OpenAI Codex with automatic token refresh.
- **Tool Fallback** - Transparent tool-calling emulation for models that don't support it natively.
- **Tool Confirmation** - Safety-level gating on tools with user confirmation before execution.
- **Skill System** - Multi-directory `SkillRegistry` with a built-in `ReadSkillTool`; inject skill summaries into system prompts and let the LLM fetch full skill content on demand.

## Requirements

- Swift 5.9+
- macOS 13+ / iOS 16+

## Installation

Add SwiftAgentCore as a dependency in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/herrkaefer/SwiftAgentCore.git", from: "1.2.0")
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "SwiftAgentCore", package: "SwiftAgentCore")
        ]
    )
]
```

## Quick Start

```swift
import Foundation
import SwiftAgentCore

struct EchoTool: AgentTool {
    let name = "echo"
    let description = "Echo a message."
    let safetyLevel: ToolSafetyLevel = .safe

    let inputSchema: JSONObject = [
        "type": .string("object"),
        "properties": .object([
            "message": .object(["type": .string("string")])
        ]),
        "required": .array([.string("message")])
    ]

    func execute(input: JSONObject) async throws -> String {
        input["message"]?.stringValue ?? ""
    }

    func humanReadableSummary(for input: JSONObject) -> String {
        "Echo message: \(input["message"]?.stringValue ?? "")"
    }
}

let provider = OpenAICompatibleProvider(
    displayName: "OpenAI API",
    profile: .openAIAPI,
    config: LLMProviderConfig(
        baseURL: URL(string: "https://api.openai.com/v1")!,
        authMethod: .apiKey(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""),
        model: "gpt-4o-mini"
    )
)

let config = AgentLoopConfig(
    provider: provider,
    tools: [EchoTool()],
    buildSystemPrompt: { "You are a helpful assistant." },
    confirmationHandler: { _, _ in true }
)

let stream = runAgentLoop(
    config: config,
    initialMessages: [.text(role: .user, "Say hello, then use the echo tool with 'done'.")],
    onEvent: { event in
        if case .messageTextDelta(let delta) = event {
            print(delta, terminator: "")
        }
    }
)

for await _ in stream {}
```

## Agent Loop Architecture

### System Structure (Modules + External Interactions)

```mermaid
flowchart TB
    subgraph HostApp["Host App (CLI / iOS / macOS)"]
        direction LR
        UI["App UI / CLI Entry"]
        Confirm["Confirmation Handler"]
        AppTools["App-defined AgentTool(s)"]
        SkillDirs["Skill Directories (.md files)"]
    end

    subgraph SwiftAgentCore["SwiftAgentCore"]
        direction TB

        subgraph Core["Core"]
            direction LR
            Loop["runAgentLoop"]
            Registry["ToolRegistry"]
            Types["AgentLoopConfig / AgentEvent / LLMMessage"]
        end

        subgraph Skills["Skills"]
            direction LR
            SReg["SkillRegistry"]
            RST["ReadSkillTool (built-in)"]
        end

        subgraph LLM["LLM Layer"]
            direction LR
            Proto["LLMProvider protocol"]
            OAI["OpenAICompatibleProvider"]
            Resp["OpenAIResponsesProvider"]
            Gem["GeminiProvider"]
            Mini["MiniMaxAnthropicProvider"]
            Fallback["StructuredToolFallbackProvider"]
            OAuth["OAuth helpers + callback server"]
        end
    end

    subgraph External["External Systems"]
        direction LR
        OpenAI["OpenAI-compatible APIs"]
        GeminiAPI["Google Gemini API"]
        MiniMaxAPI["MiniMax Anthropic-compatible API"]
        Browser["System Browser (OAuth)"]
        Callback["Local OAuth Callback Endpoint"]
    end

    UI --> Loop
    Confirm --> Loop
    AppTools --> Registry
    SkillDirs --> SReg
    SReg --> Loop
    Loop --> RST
    RST --> SReg

    Loop --> Registry
    Loop --> Types
    Loop --> Proto
    Proto --> OAI
    Proto --> Resp
    Proto --> Gem
    Proto --> Mini
    Proto --> Fallback
    Resp --> OAuth

    OAI --> OpenAI
    Resp --> OpenAI
    Gem --> GeminiAPI
    Mini --> MiniMaxAPI
    OAuth --> Browser
    Browser --> Callback
    Callback --> OAuth
```

## Provider Examples

### OpenAI-compatible

```swift
let provider = OpenAICompatibleProvider(
    profile: .openAIAPI,
    config: LLMProviderConfig(
        baseURL: URL(string: "https://api.openai.com/v1")!,
        authMethod: .apiKey("<API_KEY>"),
        model: "gpt-4o-mini"
    )
)
```

### OpenAI Codex Responses API

```swift
let oauth = OpenAICodexOAuth()
let provider = OpenAIResponsesProvider(
    credentials: oauthCredentials,
    oauthProvider: oauth,
    model: "codex-mini-latest"
)
```

### Gemini

```swift
let provider = GeminiProvider(
    apiKey: "<GEMINI_API_KEY>",
    model: "gemini-2.0-flash"
)
```

### MiniMax Anthropic-compatible

```swift
let provider = MiniMaxAnthropicProvider(
    apiKey: "<MINIMAX_API_KEY>",
    model: "MiniMax-M2.5"
)
```

### Structured Tool Fallback

Wrap any provider to emulate tool calling via JSON envelopes when native tool calling is unavailable:

```swift
let wrapped = StructuredToolFallbackProvider(base: provider)
```

## State Management Notes

SwiftAgentCore includes **runtime conversation state** inside the agent loop:

- Turn index
- Pending follow-up messages
- In-memory conversation history

It does **not** include persistent state storage, database session management, or app-level global store/reducer patterns. Persisting and restoring sessions should be handled by the host app.

## Roadmap

- [ ] Add `Examples/` runnable demos (CLI and UI) with real LLM-triggered tool calling.
- [ ] Add clearer memory/context guidance and APIs for session-level context management.
- [ ] Add an optional MCP (Model Context Protocol) client module for external tool servers.
- [ ] Add context-window management strategies (trimming and summarization) for long conversations.

## Skills

Skills are markdown files with YAML front matter. See the [Agent Skills documentation](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview) for the file format specification.

### SkillRegistry

`SkillRegistry` manages one or more skill directories. Skills in later directories override same-named skills in earlier ones, allowing app-level defaults to be overridden per-project.

```swift
let registry = SkillRegistry(directories: [
    appSkillsDirectory,   // bundled / global skills
    vaultSkillsDirectory  // project-specific skills (override)
])
```

Key methods:

```swift
// List all skills (returns sorted, deduplicated)
let skills = try registry.loadAll()

// Look up a skill by name
let skill = try registry.find(named: "summarize")

// Generate a summary suitable for injection into a system prompt
// excludeHidden: true omits skills with disable-model-invocation: true
let summary = registry.skillsSummary()
```

### LLM Integration via AgentLoopConfig

Pass the registry to `AgentLoopConfig`. The agent loop automatically injects a built-in `read_skill` tool so the LLM can fetch the full content of any skill on demand.

```swift
let registry = SkillRegistry(directories: [skillsDir])

let config = AgentLoopConfig(
    provider: provider,
    tools: myTools,
    skillRegistry: registry,          // auto-injects ReadSkillTool
    buildSystemPrompt: {
        """
        You are a helpful assistant.

        Available skills:
        \(registry.skillsSummary())   // LLM sees skill names + descriptions
        """
    },
    confirmationHandler: { _, _ in true }
)
```

At runtime the LLM calls `read_skill` with a skill name to retrieve its full prompt content before acting on it. Skills with `disable-model-invocation: true` are excluded from `skillsSummary()` by default; they can still be activated programmatically via `registry.find(named:)`.

## Development

Run tests:

```bash
swift test
```

