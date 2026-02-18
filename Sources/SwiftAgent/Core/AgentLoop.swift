import Foundation

public func runAgentLoop(
    config: AgentLoopConfig,
    initialMessages: [LLMMessage],
    onEvent: @escaping (AgentEvent) -> Void
) -> AsyncStream<AgentEvent> {
    AsyncStream { continuation in
        let task = Task {
            func emit(_ event: AgentEvent) {
                onEvent(event)
                continuation.yield(event)
            }

            emit(.agentStart)

            let registry = ToolRegistry(tools: config.tools)
            var pendingMessages = initialMessages
            var conversation: [LLMMessage] = []
            var turnIndex = 0

            while !pendingMessages.isEmpty && !Task.isCancelled {
                turnIndex += 1
                emit(.turnStart(turnIndex: turnIndex))

                conversation.append(contentsOf: pendingMessages)
                pendingMessages.removeAll()

                var shouldContinueTurn = true
                while shouldContinueTurn && !Task.isCancelled {
                    let steeringBefore = await config.getSteeringMessages()
                    if !steeringBefore.isEmpty {
                        conversation.append(contentsOf: steeringBefore)
                    }

                    emit(.messageStart(role: .assistant))

                    do {
                        let systemPrompt = await config.buildSystemPrompt()
                        let response = try await config.provider.sendMessage(
                            system: systemPrompt,
                            messages: conversation,
                            tools: registry.definitions,
                            onTextDelta: { delta in
                                emit(.messageTextDelta(delta))
                            }
                        )
                        emit(.messageEnd)
                        if let usage = response.usage {
                            emit(.usageUpdated(usage))
                        }

                        let assistantMessage = LLMMessage(role: .assistant, contentBlocks: response.contentBlocks)
                        conversation.append(assistantMessage)

                        let toolUses: [(id: String, name: String, input: JSONObject)] = response.contentBlocks.compactMap { block in
                            guard case .toolUse(let id, let name, let input) = block else { return nil }
                            return (id, name, input)
                        }

                        if toolUses.isEmpty {
                            shouldContinueTurn = false
                            break
                        }

                        var results: [ContentBlock] = []

                        for toolCall in toolUses where !Task.isCancelled {
                            guard let tool = registry.tool(named: toolCall.name) else {
                                let text = "Tool '\(toolCall.name)' is not registered."
                                emit(.toolExecutionEnd(name: toolCall.name, result: text, isError: true))
                                results.append(.toolResult(toolUseId: toolCall.id, content: text, isError: true))
                                continue
                            }

                            if tool.safetyLevel == .needsConfirmation {
                                let summary = tool.humanReadableSummary(for: toolCall.input)
                                emit(.confirmationRequired(toolName: tool.name, summary: summary))
                                let approved = await config.confirmationHandler(tool.name, summary)
                                emit(.confirmationResolved(approved: approved))
                                guard !Task.isCancelled else {
                                    shouldContinueTurn = false
                                    break
                                }
                                guard approved else {
                                    let declined = "User declined execution."
                                    emit(.toolExecutionEnd(name: tool.name, result: declined, isError: true))
                                    results.append(.toolResult(toolUseId: toolCall.id, content: declined, isError: true))
                                    continue
                                }
                            }

                            emit(.toolExecutionStart(name: tool.name, input: toolCall.input))
                            do {
                                let result = try await tool.execute(input: toolCall.input)
                                emit(.toolExecutionEnd(name: tool.name, result: result, isError: false))
                                results.append(.toolResult(toolUseId: toolCall.id, content: result, isError: false))
                            } catch {
                                let message = error.localizedDescription
                                emit(.toolExecutionEnd(name: tool.name, result: message, isError: true))
                                results.append(.toolResult(toolUseId: toolCall.id, content: message, isError: true))
                            }
                        }

                        if !results.isEmpty {
                            conversation.append(LLMMessage(role: .tool, contentBlocks: results))
                        }

                        let steeringAfter = await config.getSteeringMessages()
                        if !steeringAfter.isEmpty {
                            conversation.append(contentsOf: steeringAfter)
                        }
                    } catch {
                        emit(.error(error))
                        shouldContinueTurn = false
                        pendingMessages.removeAll()
                    }
                }

                emit(.turnEnd(turnIndex: turnIndex))

                let followUp = await config.getFollowUpMessages()
                if !followUp.isEmpty {
                    pendingMessages.append(contentsOf: followUp)
                }
            }

            emit(.agentEnd)
            continuation.finish()
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}
