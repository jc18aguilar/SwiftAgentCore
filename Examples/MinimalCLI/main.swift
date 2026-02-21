import Foundation
import SwiftAgentCore

@main
struct MinimalAgentDemo {
    static func main() async {
        print("SwiftAgentCore Minimal CLI Demo")
        print("This demo runs without API keys and shows message -> tool -> confirmation -> final response.\n")

        let provider = ScriptedProvider()
        let tool = EchoTool()

        let config = AgentLoopConfig(
            provider: provider,
            tools: [tool],
            buildSystemPrompt: { "You are a concise assistant." },
            confirmationHandler: { toolName, summary in
                print("[confirmation] \(toolName): \(summary) -> approved")
                return true
            }
        )

        let stream = runAgentLoop(
            config: config,
            initialMessages: [.text(role: .user, "Say hello, then call the echo tool with 'done'.")],
            onEvent: renderEvent
        )

        for await _ in stream {}
        print("\nDemo complete.")
    }

    private static func renderEvent(_ event: AgentEvent) {
        switch event {
        case .agentStart:
            print("[event] agentStart")
        case .agentEnd:
            print("[event] agentEnd")
        case .turnStart(let turnIndex):
            print("[event] turnStart #\(turnIndex)")
        case .turnEnd(let turnIndex):
            print("[event] turnEnd #\(turnIndex)")
        case .messageStart(let role):
            print("[event] messageStart role=\(role)")
        case .messageTextDelta(let delta):
            print(delta, terminator: "")
        case .messageEnd:
            print("\n[event] messageEnd")
        case .toolExecutionStart(let name, let input):
            print("[event] toolExecutionStart \(name) input=\(input)")
        case .toolExecutionEnd(let name, let result, let isError):
            print("[event] toolExecutionEnd \(name) isError=\(isError) result=\(result)")
        case .confirmationRequired(let toolName, let summary):
            print("[event] confirmationRequired \(toolName): \(summary)")
        case .confirmationResolved(let approved):
            print("[event] confirmationResolved approved=\(approved)")
        case .usageUpdated(let usage):
            print("[event] usageUpdated input=\(usage.inputTokens ?? 0) output=\(usage.outputTokens ?? 0)")
        case .error(let error):
            print("[event] error \(error.localizedDescription)")
        }
    }
}

private struct EchoTool: AgentTool {
    let name = "echo"
    let description = "Echoes a short message."
    let safetyLevel: ToolSafetyLevel = .needsConfirmation
    let inputSchema: JSONObject = [
        "type": .string("object"),
        "properties": .object([
            "message": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("message")]),
    ]

    func execute(input: JSONObject) async throws -> String {
        "echo-result: \(input["message"]?.stringValue ?? "")"
    }

    func humanReadableSummary(for input: JSONObject) -> String {
        "Echo message '\(input["message"]?.stringValue ?? "")'"
    }
}

private actor ScriptedProvider: LLMProvider {
    nonisolated let providerType: LLMProviderType = .openAICompatible
    nonisolated let displayName: String = "Scripted Demo Provider"
    private var callCount = 0

    func checkAvailability() async -> Bool { true }
    func availableModels() async throws -> [LLMModelInfo] {
        [LLMModelInfo(id: "scripted-demo", name: "Scripted Demo")]
    }

    func sendMessage(
        system: String,
        messages: [LLMMessage],
        tools: [ToolDefinition],
        onTextDelta: @escaping (String) -> Void
    ) async throws -> LLMResponse {
        _ = system
        _ = tools
        callCount += 1

        if callCount == 1 {
            let intro = "Hello! I will call the echo tool now.\n"
            onTextDelta(intro)
            return LLMResponse(
                contentBlocks: [
                    .text(intro),
                    .toolUse(
                        id: "call-1",
                        name: "echo",
                        input: ["message": .string("done")]
                    ),
                ],
                stopReason: .toolUse,
                usage: LLMUsage(inputTokens: 20, outputTokens: 12, totalTokens: 32)
            )
        }

        let toolResult = latestToolResult(in: messages) ?? "(missing tool result)"
        let finalText = "All done. Tool returned: \(toolResult)"
        onTextDelta(finalText)
        return LLMResponse(
            contentBlocks: [.text(finalText)],
            stopReason: .endTurn,
            usage: LLMUsage(inputTokens: 34, outputTokens: 11, totalTokens: 45)
        )
    }

    private func latestToolResult(in messages: [LLMMessage]) -> String? {
        for message in messages.reversed() {
            guard message.role == .tool else { continue }
            for block in message.contentBlocks {
                if case .toolResult(_, let content, _) = block {
                    return content
                }
            }
        }
        return nil
    }
}
