import Foundation

public enum OpenAICompatibleProviderError: LocalizedError {
    case invalidBaseURL
    case invalidHTTPResponse
    case requestFailed(statusCode: Int, body: String, retryAfter: TimeInterval?)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Provider base URL is invalid."
        case .invalidHTTPResponse:
            return "Received an invalid HTTP response from provider."
        case .requestFailed(let statusCode, let body, let retryAfter):
            if let retryAfter {
                return "Provider request failed (\(statusCode)): \(body). Retry after \(Int(retryAfter))s."
            }
            return "Provider request failed (\(statusCode)): \(body)"
        }
    }
}

public final actor OpenAICompatibleProvider: LLMProvider {
    public nonisolated let providerType: LLMProviderType = .openAICompatible
    public nonisolated let displayName: String
    public nonisolated let profile: OpenAICompatibleProfile

    private var config: LLMProviderConfig
    private let oauthProvider: OAuthProvider?
    private let onOAuthCredentialsUpdated: ((OAuthCredentials) async -> Void)?

    public init(
        displayName: String = "OpenAI Compatible",
        profile: OpenAICompatibleProfile = .generic("openai-compatible"),
        config: LLMProviderConfig,
        oauthProvider: OAuthProvider? = nil,
        onOAuthCredentialsUpdated: ((OAuthCredentials) async -> Void)? = nil
    ) {
        self.displayName = displayName
        self.profile = profile
        self.config = config
        self.oauthProvider = oauthProvider
        self.onOAuthCredentialsUpdated = onOAuthCredentialsUpdated
    }

    public func updateConfig(_ config: LLMProviderConfig) {
        self.config = config
    }

    public func checkAvailability() async -> Bool {
        let headers = profile.mergedHeaders(with: config.headers)
        return await OpenAICompatibleCore.checkAvailability(
            baseURL: config.baseURL,
            auth: config.authMethod,
            headers: headers
        )
    }

    public func availableModels() async throws -> [LLMModelInfo] {
        let auth = try await resolveAuthMethod()
        let headers = profile.mergedHeaders(with: config.headers)
        return try await OpenAICompatibleCore.availableModels(
            baseURL: config.baseURL,
            auth: auth,
            headers: headers
        )
    }

    public func sendMessage(
        system: String,
        messages: [LLMMessage],
        tools: [ToolDefinition],
        onTextDelta: @escaping (String) -> Void
    ) async throws -> LLMResponse {
        let auth = try await resolveAuthMethod()
        let headers = profile.mergedHeaders(with: config.headers)
        return try await OpenAICompatibleCore.sendMessage(
            baseURL: config.baseURL,
            model: config.model,
            auth: auth,
            headers: headers,
            system: system,
            messages: messages,
            tools: tools,
            onTextDelta: onTextDelta
        )
    }

    private func resolveAuthMethod() async throws -> LLMAuthMethod {
        switch config.authMethod {
        case .oauth(let credentials) where credentials.isExpired:
            guard let oauthProvider else {
                return config.authMethod
            }
            let refreshed = try await oauthProvider.refreshToken(credentials)
            config.authMethod = .oauth(refreshed)
            await onOAuthCredentialsUpdated?(refreshed)
            return config.authMethod
        default:
            return config.authMethod
        }
    }
}
