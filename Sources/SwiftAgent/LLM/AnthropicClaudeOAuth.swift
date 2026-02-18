import Foundation
import CryptoKit

public struct AnthropicClaudeOAuth: OAuthProvider {
    public let providerId: String = "anthropic-claude"
    public let displayName: String = "Anthropic Claude"

    public static let defaultClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    public var clientID: String
    public var redirectURI: URL
    public var scopes: [String]

    private let authURL = URL(string: "https://claude.ai/oauth/authorize")!
    private let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    public init(
        clientID: String = defaultClientID,
        redirectURI: URL = URL(string: "https://console.anthropic.com/oauth/code/callback")!,
        scopes: [String] = ["org:create_api_key", "user:profile", "user:inference"]
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    /// Anthropic special: state == codeVerifier (both are the same value).
    public func buildAuthorizationURL() -> (URL, state: String, codeVerifier: String) {
        let codeVerifier = Self.randomURLSafeString(byteCount: 32)
        let state = codeVerifier
        let challenge = Self.sha256Base64URL(codeVerifier)

        var components = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        return (components.url!, state, codeVerifier)
    }

    /// Anthropic token exchange includes `state` (== codeVerifier) in the request body.
    public func exchangeCode(_ code: String, codeVerifier: String) async throws -> OAuthCredentials {
        let body = [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
            "code_verifier": codeVerifier,
            "state": codeVerifier,
        ]
        return try await requestToken(body: body)
    }

    public func refreshToken(_ credentials: OAuthCredentials) async throws -> OAuthCredentials {
        let body = [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": credentials.refreshToken,
        ]
        return try await requestToken(body: body)
    }

    public func apiKey(from credentials: OAuthCredentials) -> String {
        credentials.accessToken
    }

    /// Parses the `code#state` string that Anthropic displays to the user after server-side callback.
    public func parseCodeAndState(_ input: String) -> (code: String, state: String)? {
        let parts = input.components(separatedBy: "#")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return nil
        }
        return (code: parts[0], state: parts[1])
    }

    private func requestToken(body: [String: String]) async throws -> OAuthCredentials {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
            .map { key, value in
                let encodedValue =
                    value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                return "\(key)=\(encodedValue)"
            }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw OAuthError.serverError(text)
        }

        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let accessToken = token.accessToken, !accessToken.isEmpty else {
            throw OAuthError.missingAccessToken
        }

        let refreshToken =
            token.refreshToken?.isEmpty == false
            ? token.refreshToken!
            : body["refresh_token"]

        guard let refreshToken, !refreshToken.isEmpty else {
            throw OAuthError.missingRefreshToken
        }

        let expiresIn = token.expiresIn ?? 3600
        return OAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(max(expiresIn - 30, 30))),
            extra: nil
        )
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        let data = Data(bytes)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sha256Base64URL(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
