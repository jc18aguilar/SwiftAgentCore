import Foundation

private enum AgentLoopRuntimeError: LocalizedError {
    case llmCallTimedOut(seconds: TimeInterval)
    case totalTimeoutExceeded(seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .llmCallTimedOut(let seconds):
            return "LLM call timed out after \(String(format: "%.2f", seconds))s."
        case .totalTimeoutExceeded(let seconds):
            return "Agent loop timed out after \(String(format: "%.2f", seconds))s."
        }
    }
}

private enum TimeoutKind {
    case llmCall
    case total
}

private func nanoseconds(from seconds: TimeInterval) -> UInt64 {
    guard seconds > 0 else { return 0 }
    let value = seconds * 1_000_000_000
    if value >= Double(UInt64.max) {
        return UInt64.max
    }
    return UInt64(value.rounded())
}

private func retryDelayIfRetryable(error: Error, fallbackDelay: TimeInterval) -> TimeInterval? {
    func decision(statusCode: Int, retryAfter: TimeInterval?) -> TimeInterval? {
        guard statusCode == 429 || statusCode >= 500 else { return nil }
        return max(0, retryAfter ?? fallbackDelay)
    }

    switch error {
    case OpenAICompatibleProviderError.requestFailed(let statusCode, _, let retryAfter):
        return decision(statusCode: statusCode, retryAfter: retryAfter)
    case GeminiProviderError.requestFailed(let statusCode, _, let retryAfter):
        return decision(statusCode: statusCode, retryAfter: retryAfter)
    case MiniMaxAnthropicProviderError.requestFailed(let statusCode, _, let retryAfter):
        return decision(statusCode: statusCode, retryAfter: retryAfter)
    case OpenAIResponsesProviderError.requestFailed(let statusCode, _):
        return decision(statusCode: statusCode, retryAfter: nil)
    default:
        return nil
    }
}

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

            let loopStartedAt = Date()

            func remainingTotalTimeout() -> TimeInterval? {
                guard let totalTimeout = config.totalTimeout else { return nil }
                return totalTimeout - Date().timeIntervalSince(loopStartedAt)
            }

            func ensureTotalTimeoutNotExceeded() throws {
                guard let totalTimeout = config.totalTimeout else { return }
                let elapsed = Date().timeIntervalSince(loopStartedAt)
                if elapsed >= totalTimeout {
                    throw AgentLoopRuntimeError.totalTimeoutExceeded(seconds: totalTimeout)
                }
            }

            func effectiveCallTimeout() throws -> (seconds: TimeInterval, kind: TimeoutKind)? {
                let llmCallTimeout = config.llmCallTimeout
                guard let remaining = remainingTotalTimeout() else {
                    guard let llmCallTimeout else { return nil }
                    if llmCallTimeout <= 0 {
                        throw AgentLoopRuntimeError.llmCallTimedOut(seconds: llmCallTimeout)
                    }
                    return (llmCallTimeout, .llmCall)
                }

                guard let totalTimeout = config.totalTimeout else { return nil }
                if remaining <= 0 {
                    throw AgentLoopRuntimeError.totalTimeoutExceeded(seconds: totalTimeout)
                }

                guard let llmCallTimeout else {
                    return (remaining, .total)
                }

                if llmCallTimeout <= 0 {
                    throw AgentLoopRuntimeError.llmCallTimedOut(seconds: llmCallTimeout)
                }

                if llmCallTimeout <= remaining {
                    return (llmCallTimeout, .llmCall)
                }
                return (remaining, .total)
            }

            func sendMessageWithTimeout(
                system: String,
                messages: [LLMMessage],
                tools: [ToolDefinition],
                onTextDelta: @escaping (String) -> Void
            ) async throws -> LLMResponse {
                guard let timeout = try effectiveCallTimeout() else {
                    return try await config.provider.sendMessage(
                        system: system,
                        messages: messages,
                        tools: tools,
                        onTextDelta: onTextDelta
                    )
                }

                return try await withThrowingTaskGroup(of: LLMResponse.self) { group in
                    group.addTask {
                        try await config.provider.sendMessage(
                            system: system,
                            messages: messages,
                            tools: tools,
                            onTextDelta: onTextDelta
                        )
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: nanoseconds(from: timeout.seconds))
                        switch timeout.kind {
                        case .llmCall:
                            throw AgentLoopRuntimeError.llmCallTimedOut(seconds: timeout.seconds)
                        case .total:
                            throw AgentLoopRuntimeError.totalTimeoutExceeded(
                                seconds: config.totalTimeout ?? timeout.seconds
                            )
                        }
                    }

                    guard let result = try await group.next() else {
                        throw AgentLoopRuntimeError.llmCallTimedOut(seconds: timeout.seconds)
                    }
                    group.cancelAll()
                    return result
                }
            }

            func sendMessageWithRetry(
                system: String,
                messages: [LLMMessage],
                tools: [ToolDefinition],
                onTextDelta: @escaping (String) -> Void
            ) async throws -> LLMResponse {
                var retriesRemaining = config.maxRetries

                while true {
                    try ensureTotalTimeoutNotExceeded()
                    do {
                        return try await sendMessageWithTimeout(
                            system: system,
                            messages: messages,
                            tools: tools,
                            onTextDelta: onTextDelta
                        )
                    } catch {
                        guard !Task.isCancelled else { throw error }
                        guard retriesRemaining > 0 else { throw error }
                        guard
                            let retryDelay = retryDelayIfRetryable(
                                error: error,
                                fallbackDelay: config.retryDelay
                            )
                        else {
                            throw error
                        }

                        retriesRemaining -= 1
                        guard retryDelay > 0 else { continue }

                        if let remaining = remainingTotalTimeout() {
                            let totalTimeout = config.totalTimeout ?? retryDelay
                            if remaining <= 0 || remaining < retryDelay {
                                throw AgentLoopRuntimeError.totalTimeoutExceeded(seconds: totalTimeout)
                            }
                        }

                        try await Task.sleep(nanoseconds: nanoseconds(from: retryDelay))
                    }
                }
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
                        try ensureTotalTimeoutNotExceeded()
                        let systemPrompt = await config.buildSystemPrompt()
                        let response = try await sendMessageWithRetry(
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
                            try ensureTotalTimeoutNotExceeded()
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
