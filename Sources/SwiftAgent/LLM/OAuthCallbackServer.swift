import Foundation

#if os(macOS)
import Darwin
#endif

public enum OAuthCallbackServerError: LocalizedError {
    case invalidPort
    case serverAlreadyRunning
    case timeout
    case malformedRequest
    case listenerFailed(String)
    case platformNotSupported

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
        case .listenerFailed(let detail):
            return "OAuth callback server failed to start: \(detail)"
        case .platformNotSupported:
            return "OAuth callback server is not supported on this platform."
        }
    }
}

#if os(macOS)
public actor OAuthCallbackServer {
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var queue: DispatchQueue?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?

    public init() {}

    /// Bind to the given port and start accepting localhost callbacks.
    public func listen(port: Int) async throws {
        // Tear down any leftover listener from a previous attempt.
        if listenFD >= 0 {
            stop()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        guard (1...65_535).contains(port) else {
            throw OAuthCallbackServerError.invalidPort
        }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw OAuthCallbackServerError.listenerFailed(Self.lastPOSIXError("socket() failed"))
        }

        var yes: Int32 = 1
        if setsockopt(
            fd,
            SOL_SOCKET,
            SO_REUSEADDR,
            &yes,
            socklen_t(MemoryLayout<Int32>.size)
        ) < 0 {
            close(fd)
            throw OAuthCallbackServerError.listenerFailed(
                Self.lastPOSIXError("setsockopt(SO_REUSEADDR) failed")
            )
        }

        // Non-blocking listen socket so dispatch source can drain accepts safely.
        let flags = fcntl(fd, F_GETFL, 0)
        if flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 {
            close(fd)
            throw OAuthCallbackServerError.listenerFailed(
                Self.lastPOSIXError("fcntl(O_NONBLOCK) failed")
            )
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw OAuthCallbackServerError.listenerFailed(Self.lastPOSIXError("bind() failed"))
        }

        guard Darwin.listen(fd, SOMAXCONN) == 0 else {
            close(fd)
            throw OAuthCallbackServerError.listenerFailed(Self.lastPOSIXError("listen() failed"))
        }

        let newQueue = DispatchQueue(label: "dev.mai.swiftagent.oauth.callback")
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: newQueue)

        source.setEventHandler { [weak self] in
            Task { await self?.drainAcceptQueue() }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()

        self.listenFD = fd
        self.acceptSource = source
        self.queue = newQueue
    }

    /// Wait for the OAuth callback to arrive. Call this AFTER `listen(port:)` succeeds.
    /// Returns the authorization code string.
    public func waitForCode(timeoutSeconds: TimeInterval = 180) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            self.codeContinuation = continuation

            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                await self?.finish(with: .failure(OAuthCallbackServerError.timeout))
            }
        }
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            listenFD = -1
        }
        codeContinuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        queue = nil
    }

    private func drainAcceptQueue() {
        guard listenFD >= 0 else { return }
        guard let queue else {
            stop()
            return
        }

        while true {
            var addr = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(listenFD, sockPtr, &len)
                }
            }

            if clientFD < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    break
                }
                break
            }

            queue.async { [weak self] in
                self?.handle(clientFD: clientFD)
            }
        }
    }

    nonisolated private func handle(clientFD: Int32) {
        defer { close(clientFD) }

        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) { ptr in
            setsockopt(
                clientFD,
                SOL_SOCKET,
                SO_RCVTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while data.count < 65_536 {
            let readCount = recv(clientFD, &buffer, buffer.count, 0)
            if readCount > 0 {
                data.append(buffer, count: Int(readCount))
                if data.range(of: Data("\r\n\r\n".utf8)) != nil || data.range(of: Data("\n\n".utf8)) != nil {
                    break
                }
                continue
            }
            break
        }

        let result = extractCode(from: data.isEmpty ? nil : data)
        switch result {
        case .success(let code):
            respondSuccess(on: clientFD)
            Task { await self.finish(with: .success(code)) }
        case .failure(let error):
            respondFailure(on: clientFD, error: error.localizedDescription)
            Task { await self.finish(with: .failure(error)) }
        }
    }

    nonisolated private func extractCode(from data: Data?) -> Result<String, Error> {
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

    nonisolated private func respondSuccess(on clientFD: Int32) {
        let html = "<html><body><h3>Authorization complete</h3><p>You can close this window and return to Mai.</p></body></html>"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        sendResponse(response, to: clientFD)
    }

    nonisolated private func respondFailure(on clientFD: Int32, error: String) {
        let html = "<html><body><h3>Authorization failed</h3><p>\(error)</p></body></html>"
        let response = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        sendResponse(response, to: clientFD)
    }

    nonisolated private func sendResponse(_ response: String, to clientFD: Int32) {
        guard var bytes = response.data(using: .utf8) else { return }
        bytes.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            var sent = 0
            while sent < rawBuffer.count {
                let result = Darwin.send(clientFD, base.advanced(by: sent), rawBuffer.count - sent, 0)
                if result <= 0 { break }
                sent += result
            }
        }
    }

    private func finish(with result: Result<String, Error>) {
        guard let codeContinuation else {
            stop()
            return
        }

        self.codeContinuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        queue = nil

        switch result {
        case .success(let code):
            codeContinuation.resume(returning: code)
        case .failure(let error):
            codeContinuation.resume(throwing: error)
        }
    }

    nonisolated private static func lastPOSIXError(_ prefix: String) -> String {
        let message = String(cString: strerror(errno))
        return "\(prefix): \(message)"
    }
}
#else
public actor OAuthCallbackServer {
    public init() {}

    public func listen(port: Int) async throws {
        throw OAuthCallbackServerError.platformNotSupported
    }

    public func waitForCode(timeoutSeconds: TimeInterval = 180) async throws -> String {
        throw OAuthCallbackServerError.platformNotSupported
    }

    public func stop() {}
}
#endif
