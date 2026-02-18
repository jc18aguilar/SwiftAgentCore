import Foundation

public enum LLMAuthMethod: Sendable, Equatable {
    case none
    case apiKey(String)
    case oauth(OAuthCredentials)
    case custom(headers: [String: String])
}

extension LLMAuthMethod: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case apiKey
        case oauth
        case headers
    }

    private enum Kind: String, Codable {
        case none
        case apiKey
        case oauth
        case custom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .none:
            self = .none
        case .apiKey:
            self = .apiKey(try container.decode(String.self, forKey: .apiKey))
        case .oauth:
            self = .oauth(try container.decode(OAuthCredentials.self, forKey: .oauth))
        case .custom:
            self = .custom(headers: try container.decode([String: String].self, forKey: .headers))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case .apiKey(let value):
            try container.encode(Kind.apiKey, forKey: .kind)
            try container.encode(value, forKey: .apiKey)
        case .oauth(let credentials):
            try container.encode(Kind.oauth, forKey: .kind)
            try container.encode(credentials, forKey: .oauth)
        case .custom(let headers):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(headers, forKey: .headers)
        }
    }
}

public struct OAuthCredentials: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var extra: [String: String]?

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        extra: [String: String]? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.extra = extra
    }

    public var isExpired: Bool {
        Date() >= expiresAt
    }
}

public protocol OAuthProvider {
    var providerId: String { get }
    var displayName: String { get }

    func buildAuthorizationURL() -> (URL, state: String, codeVerifier: String)
    func exchangeCode(_ code: String, codeVerifier: String) async throws -> OAuthCredentials
    func refreshToken(_ credentials: OAuthCredentials) async throws -> OAuthCredentials
    func apiKey(from credentials: OAuthCredentials) -> String
}

public enum OAuthError: LocalizedError {
    case invalidResponse
    case serverError(String)
    case missingAccessToken
    case missingRefreshToken
    case callbackTimedOut
    case callbackError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "OAuth response was invalid."
        case .serverError(let value):
            return "OAuth server error: \(value)"
        case .missingAccessToken:
            return "OAuth access token is missing."
        case .missingRefreshToken:
            return "OAuth refresh token is missing."
        case .callbackTimedOut:
            return "OAuth callback timed out."
        case .callbackError(let value):
            return "OAuth callback returned error: \(value)"
        }
    }
}
