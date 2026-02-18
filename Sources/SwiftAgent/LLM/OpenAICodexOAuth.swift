import Foundation
import CryptoKit

public struct OpenAICodexOAuth: OAuthProvider {
    public let providerId: String = "openai-codex"
    public let displayName: String = "OpenAI"

    public static let defaultClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    public var clientID: String
    public var redirectURI: URL
    public var scopes: [String]

    private let authURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    private let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!

    public init(
        clientID: String = defaultClientID,
        redirectURI: URL = URL(string: "http://localhost:1455/auth/callback")!,
        scopes: [String] = ["openid", "profile", "email", "offline_access"]
    ) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    public func buildAuthorizationURL() -> (URL, state: String, codeVerifier: String) {
        let state = Self.randomURLSafeString(byteCount: 24)
        let codeVerifier = Self.randomURLSafeString(byteCount: 32)
        let challenge = Self.sha256Base64URL(codeVerifier)

        var components = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        return (components.url!, state, codeVerifier)
    }

    public func exchangeCode(_ code: String, codeVerifier: String) async throws -> OAuthCredentials {
        let body = [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
            "code_verifier": codeVerifier
        ]
        return try await requestToken(body: body)
    }

    public func refreshToken(_ credentials: OAuthCredentials) async throws -> OAuthCredentials {
        let body = [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": credentials.refreshToken
        ]
        return try await requestToken(body: body)
    }

    public func apiKey(from credentials: OAuthCredentials) -> String {
        credentials.accessToken
    }

    private func requestToken(body: [String: String]) async throws -> OAuthCredentials {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
            .map { key, value in
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
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

        let refreshToken = token.refreshToken?.isEmpty == false
            ? token.refreshToken!
            : body["refresh_token"]

        guard let refreshToken, !refreshToken.isEmpty else {
            throw OAuthError.missingRefreshToken
        }

        let expiresIn = token.expiresIn ?? 3600
        let extra = Self.buildExtraClaims(idToken: token.idToken, accessToken: accessToken)
        return OAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(max(expiresIn - 30, 30))),
            extra: extra.isEmpty ? nil : extra
        )
    }

    private struct TokenResponse: Decodable {
        let idToken: String?
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private static func buildExtraClaims(idToken: String?, accessToken: String) -> [String: String] {
        var result: [String: String] = [:]

        if let idToken, let claims = authClaims(fromJWT: idToken),
            let accountID = claims["chatgpt_account_id"] as? String, !accountID.isEmpty
        {
            result["chatgpt_account_id"] = accountID
        }

        if let claims = authClaims(fromJWT: accessToken),
            let planType = claims["chatgpt_plan_type"] as? String, !planType.isEmpty
        {
            result["chatgpt_plan_type"] = planType
        }

        return result
    }

    private static func authClaims(fromJWT jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload),
            let raw = try? JSONSerialization.jsonObject(with: data),
            let object = raw as? [String: Any]
        else {
            return nil
        }

        if let nested = object["https://api.openai.com/auth"] as? [String: Any] {
            return nested
        }
        return object
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
