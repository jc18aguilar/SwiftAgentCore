import Foundation
import Network

public enum OAuthCallbackServerError: LocalizedError {
    case invalidPort
    case serverAlreadyRunning
    case timeout
    case malformedRequest

    public var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "OAuth callback server port is invalid."
        case .serverAlreadyRunning:
            return "OAuth callback server is already running."
        case .timeout:
            return "Timed out waiting for OAuth callback."
        case .malformedRequest:
            return "Malformed OAuth callback request."
        }
    }
}

public actor OAuthCallbackServer {
    private var listener: NWListener?
    private var queue: DispatchQueue?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?

    public init() {}

    public func start(port: Int, timeoutSeconds: TimeInterval = 180) async throws -> String {
        guard listener == nil else {
            throw OAuthCallbackServerError.serverAlreadyRunning
        }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw OAuthCallbackServerError.invalidPort
        }

        let listener = try NWListener(using: .tcp, on: nwPort)
        let queue = DispatchQueue(label: "dev.mai.swiftagent.oauth.callback")
        self.listener = listener
        self.queue = queue

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let error):
                    Task {
                        await self?.finish(with: .failure(error))
                    }
                case .cancelled:
                    Task {
                        await self?.finish(with: .failure(OAuthCallbackServerError.timeout))
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task {
                    await self?.handle(connection: connection)
                }
            }

            listener.start(queue: queue)

            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                await self?.finish(with: .failure(OAuthCallbackServerError.timeout))
            }
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        queue = nil
    }

    private func handle(connection: NWConnection) {
        guard let queue else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            Task {
                guard let self else {
                    connection.cancel()
                    return
                }
                let result = await self.extractCode(from: data)
                switch result {
                case .success(let code):
                    self.respondSuccess(on: connection)
                    await self.finish(with: .success(code))
                case .failure(let error):
                    self.respondFailure(on: connection, error: error.localizedDescription)
                    await self.finish(with: .failure(error))
                }
                connection.cancel()
            }
        }
    }

    private func extractCode(from data: Data?) -> Result<String, Error> {
        guard let data, let request = String(data: data, encoding: .utf8) else {
            return .failure(OAuthCallbackServerError.malformedRequest)
        }

        guard let firstLine = request.split(separator: "\n").first else {
            return .failure(OAuthCallbackServerError.malformedRequest)
        }

        let pieces = firstLine.split(separator: " ")
        guard pieces.count >= 2 else {
            return .failure(OAuthCallbackServerError.malformedRequest)
        }

        let target = String(pieces[1])
        guard let components = URLComponents(string: "http://127.0.0.1\(target)") else {
            return .failure(OAuthCallbackServerError.malformedRequest)
        }

        if let error = components.queryItems?.first(where: { $0.name == "error" })?.value {
            return .failure(OAuthError.callbackError(error))
        }

        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            return .failure(OAuthCallbackServerError.malformedRequest)
        }

        return .success(code)
    }

    nonisolated private func respondSuccess(on connection: NWConnection) {
        let html = "<html><body><h3>Authorization complete</h3><p>You can close this window and return to Mai.</p></body></html>"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in })
    }

    nonisolated private func respondFailure(on connection: NWConnection, error: String) {
        let html = "<html><body><h3>Authorization failed</h3><p>\(error)</p></body></html>"
        let response = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in })
    }

    private func finish(with result: Result<String, Error>) {
        guard let continuation else {
            stop()
            return
        }

        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        listener?.cancel()
        listener = nil
        queue = nil

        switch result {
        case .success(let code):
            continuation.resume(returning: code)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
