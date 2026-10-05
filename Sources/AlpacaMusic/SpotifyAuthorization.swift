import AppKit
import CryptoKit
import Foundation
import Network
import Security

struct SpotifyToken: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    var scopes: Set<String>

    func isExpired(at date: Date = Date()) -> Bool { expiresAt.timeIntervalSince(date) <= 60 }
}

enum SpotifyAuthorizationError: Error, LocalizedError, Equatable, Sendable {
    case invalidClientID, randomGenerationFailed, alreadyAuthorizing, browserUnavailable
    case callbackUnavailable, timeout, denied, invalidCallback, invalidToken, expiredSession
    case tokenRequestFailed(Int), network(Int), credentialStorage(Int), invalidStoredCredential

    var errorDescription: String? {
        switch self {
        case .invalidClientID: "请填写 Spotify Developer 应用的 32 位 Client ID"
        case .randomGenerationFailed: "无法生成安全的登录请求，请重试"
        case .alreadyAuthorizing: "Spotify 登录正在进行，请完成或取消后重试"
        case .browserUnavailable: "无法打开默认浏览器，请检查系统的默认浏览器设置"
        case .callbackUnavailable: "无法接收 Spotify 登录结果，本机端口 43821 可能正在使用，请关闭其他登录窗口后重试"
        case .timeout: "Spotify 登录已超时，请重新连接"
        case .denied: "Spotify 授权已取消"
        case .invalidCallback: "Spotify 登录返回的验证信息不匹配，请重新连接"
        case .invalidToken: "Spotify 返回的登录信息无效，请重新连接"
        case .expiredSession: "Spotify 登录已失效，请重新连接"
        case .tokenRequestFailed(let status): "Spotify 登录请求失败（HTTP \(status)），请检查 Client ID 和回调地址设置"
        case .network(let code): "无法连接 Spotify 登录服务，请检查网络后重试（\(code)）"
        case .credentialStorage(let status): "无法访问 Spotify 登录信息（\(status)），请解锁钥匙串后重试"
        case .invalidStoredCredential: "保存的 Spotify 登录信息无法读取，请重新连接"
        }
    }
}

protocol SpotifyAuthorizing: Sendable {
    func authorize(clientID: String) async throws -> SpotifyToken
    func refresh(clientID: String, refreshToken: String) async throws -> SpotifyToken
}

protocol SpotifyCallbackReceiving: Sendable {
    func start(expectedState: String) async throws
    func code() async throws -> String
    func cancel() async
}

/// Native public client: PKCE S256 in the system browser, with a loopback-only
/// callback. Authorization does not persist tokens; callers validate /me first.
actor SpotifyAuthorization: SpotifyAuthorizing {
    static let redirectURI = "http://127.0.0.1:43821/callback"
    static let scopes = ["playlist-read-private", "playlist-read-collaborative", "user-library-read",
                         "user-read-private", "user-read-playback-state", "user-modify-playback-state"]
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias BrowserOpener = @MainActor @Sendable (URL) -> Bool
    typealias CallbackFactory = @Sendable () throws -> any SpotifyCallbackReceiving
    private let transport: Transport
    private let openBrowser: BrowserOpener
    private let callbackFactory: CallbackFactory
    private var authorizing = false

    init(transport: Transport? = nil, openBrowser: BrowserOpener? = nil, callbackFactory: CallbackFactory? = nil) {
        self.transport = transport ?? Self.sendTokenRequest
        self.openBrowser = openBrowser ?? { NSWorkspace.shared.open($0) }
        self.callbackFactory = callbackFactory ?? { SpotifyLoopbackReceiver() }
    }

    static func validatedClientID(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count == 32, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw SpotifyAuthorizationError.invalidClientID
        }
        return value
    }

    static func randomURLSafeString(byteCount: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SpotifyAuthorizationError.randomGenerationFailed
        }
        return urlSafeBase64(Data(bytes))
    }
    static func codeChallenge(for verifier: String) -> String { urlSafeBase64(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    private static func urlSafeBase64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func authorizationURL(clientID: String, state: String, verifier: String) throws -> URL {
        let clientID = try validatedClientID(clientID)
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI), .init(name: "state", value: state),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: codeChallenge(for: verifier)),
            .init(name: "show_dialog", value: "true")
        ]
        return components.url!
    }

    func authorize(clientID: String) async throws -> SpotifyToken {
        let clientID = try Self.validatedClientID(clientID)
        try Task.checkCancellation()
        guard !authorizing else { throw SpotifyAuthorizationError.alreadyAuthorizing }
        authorizing = true
        defer { authorizing = false }
        let verifier = try Self.randomURLSafeString(byteCount: 64)
        let state = try Self.randomURLSafeString()
        let url = try Self.authorizationURL(clientID: clientID, state: state, verifier: verifier)
        let receiver = try callbackFactory()
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await receiver.start(expectedState: state)
                try Task.checkCancellation()
                guard await openBrowser(url) else { throw SpotifyAuthorizationError.browserUnavailable }
                let code = try await receiver.code()
                await receiver.cancel()
                try Task.checkCancellation()
                return try await requestToken(fields: ["grant_type": "authorization_code", "client_id": clientID,
                                                       "redirect_uri": Self.redirectURI, "code": code, "code_verifier": verifier], previousRefreshToken: nil)
            } catch {
                await receiver.cancel()
                throw error
            }
        } onCancel: {
            Task { await receiver.cancel() }
        }
    }

    func refresh(clientID: String, refreshToken: String) async throws -> SpotifyToken {
        let clientID = try Self.validatedClientID(clientID)
        guard !refreshToken.isEmpty, refreshToken.utf8.count <= 16384 else { throw SpotifyAuthorizationError.expiredSession }
        return try await requestToken(fields: ["grant_type": "refresh_token", "client_id": clientID, "refresh_token": refreshToken], previousRefreshToken: refreshToken)
    }

    private func requestToken(fields: [String: String], previousRefreshToken: String?) async throws -> SpotifyToken {
        try Task.checkCancellation()
        let endpoint = URL(string: "https://accounts.spotify.com/api/token")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw SpotifyAuthorizationError.network(error.code.rawValue)
        }
        try Task.checkCancellation()
        guard response.url == endpoint, data.count <= 128 * 1024 else { throw SpotifyAuthorizationError.invalidToken }
        if response.statusCode != 200 {
            let failure = try? JSONDecoder().decode(TokenError.self, from: data)
            if failure?.error == "invalid_grant" { throw SpotifyAuthorizationError.expiredSession }
            throw SpotifyAuthorizationError.tokenRequestFailed(response.statusCode)
        }
        guard let reply = try? JSONDecoder().decode(TokenReply.self, from: data),
              reply.token_type.lowercased() == "bearer", !reply.access_token.isEmpty, reply.access_token.utf8.count <= 16384,
              reply.expires_in > 0, reply.expires_in <= 31_536_000,
              let refresh = reply.refresh_token ?? previousRefreshToken, !refresh.isEmpty, refresh.utf8.count <= 16384 else {
            throw SpotifyAuthorizationError.invalidToken
        }
        return SpotifyToken(accessToken: reply.access_token, refreshToken: refresh,
                            expiresAt: Date().addingTimeInterval(TimeInterval(reply.expires_in)),
                            scopes: Set((reply.scope ?? "").split(separator: " ").map(String.init)))
    }

    private struct TokenReply: Decodable {
        let access_token: String
        let token_type: String
        let expires_in: Int
        let refresh_token: String?
        let scope: String?
    }
    private struct TokenError: Decodable { let error: String }

    private static func sendTokenRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: SpotifyTokenRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= 128 * 1024 else { throw SpotifyAuthorizationError.invalidToken }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 128 * 1024 else { throw SpotifyAuthorizationError.invalidToken }
            data.append(byte)
        }
        return (data, response)
    }
}

private final class SpotifyTokenRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// Receives only a single bounded HTTP callback on IPv4 loopback. Invalid
/// requests cannot consume the pending login or terminate a genuine callback.
actor SpotifyLoopbackReceiver: SpotifyCallbackReceiving {
    static let maximumRequestBytes = 16 * 1024
    static let host = "127.0.0.1:43821"
    private var listener: NWListener?
    private var readyContinuation: CheckedContinuation<Void, any Error>?
    private var codeContinuation: CheckedContinuation<String, any Error>?
    private var result: Result<String, any Error>?
    private var expectedState = ""
    private var connections: [UUID: (connection: NWConnection, data: Data)] = [:]
    private var timeout: Task<Void, Never>?
    private var listenerClosing = false
    private var closingContinuations: [CheckedContinuation<Void, Never>] = []
    private let queue = DispatchQueue(label: "dev.byalpaca.music.spotify-callback")

    func start(expectedState: String) async throws {
        try Task.checkCancellation()
        if let result { _ = try result.get(); throw SpotifyAuthorizationError.invalidCallback }
        guard listener == nil else { throw SpotifyAuthorizationError.alreadyAuthorizing }
        self.expectedState = expectedState
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 43821)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) }
        catch { throw SpotifyAuthorizationError.callbackUnavailable }
        self.listener = listener
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(180)) } catch { return }
            await self?.finish(.failure(SpotifyAuthorizationError.timeout))
        }
        try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { await self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection) }
            }
            listener.start(queue: queue)
        }
    }

    func code() async throws -> String {
        try Task.checkCancellation()
        if let result { return try result.get() }
        guard listener != nil, codeContinuation == nil else { throw SpotifyAuthorizationError.invalidCallback }
        return try await withCheckedThrowingContinuation { codeContinuation = $0 }
    }

    func cancel() async {
        finish(.failure(CancellationError()))
        if listenerClosing { await withCheckedContinuation { closingContinuations.append($0) } }
    }

    private func listenerChanged(_ state: NWListener.State) {
        if case .cancelled = state {
            listener = nil; listenerClosing = false
            closingContinuations.forEach { $0.resume() }; closingContinuations.removeAll()
            finish(.failure(CancellationError()))
            return
        }
        guard result == nil else { return }
        switch state {
        case .ready:
            readyContinuation?.resume(); readyContinuation = nil
        case .failed, .waiting:
            finish(.failure(SpotifyAuthorizationError.callbackUnavailable))
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = (connection, Data())
        connection.start(queue: queue)
        receive(id)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            await self?.discard(id)
        }
    }

    private func receive(_ id: UUID) {
        guard let connection = connections[id]?.connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            Task { await self?.received(data, complete: isComplete, failed: error != nil, id: id) }
        }
    }

    private func received(_ data: Data?, complete: Bool, failed: Bool, id: UUID) {
        guard var entry = connections[id] else { return }
        if let data { entry.data.append(data) }
        connections[id] = entry
        guard !failed, entry.data.count <= Self.maximumRequestBytes else { discard(id); return }
        if entry.data.range(of: Data("\r\n\r\n".utf8)) != nil {
            connections.removeValue(forKey: id)
            let callback = Self.parseRequest(entry.data, expectedState: expectedState)
            let text = callback == nil ? "Invalid login callback. Return to AlpacaMusic and try again." : "Spotify authorization received. You can close this tab and return to AlpacaMusic."
            let html = "<!doctype html><meta charset=utf-8><title>AlpacaMusic</title><p>\(text)</p>"
            let status = callback == nil ? "400 Bad Request" : "200 OK"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\n\r\n\(html)"
            let connection = entry.connection
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if let callback { finish(callback.mapError { $0 as any Error }) }
        } else if complete { discard(id) }
        else { receive(id) }
    }

    private func discard(_ id: UUID) { connections.removeValue(forKey: id)?.connection.cancel() }

    private func finish(_ result: Result<String, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        timeout?.cancel(); timeout = nil
        if let listener { listenerClosing = true; listener.cancel(); self.listener = nil }
        connections.values.forEach { $0.connection.cancel() }; connections.removeAll()
        if let readyContinuation {
            self.readyContinuation = nil
            switch result {
            case .success: readyContinuation.resume()
            case .failure(let error): readyContinuation.resume(throwing: error)
            }
        }
        codeContinuation?.resume(with: result); codeContinuation = nil
    }

    static func parseRequest(_ data: Data, expectedState: String) -> Result<String, SpotifyAuthorizationError>? {
        guard !expectedState.isEmpty, data.count <= maximumRequestBytes,
              let request = String(data: data, encoding: .utf8), let headerEnd = request.range(of: "\r\n\r\n"),
              request[headerEnd.upperBound...].isEmpty else { return nil }
        let lines = request[..<headerEnd.lowerBound].components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1", parts[1].hasPrefix("/callback?"),
              let url = URLComponents(string: "http://\(host)\(parts[1])"), url.path == "/callback", url.fragment == nil else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { return nil }
            let name = line[..<separator].lowercased()
            guard headers[name] == nil else { return nil }
            headers[name] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] == host, headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == "0" else { return nil }
        let items = url.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == expectedState,
              items.filter({ $0.name == "code" }).count <= 1, items.filter({ $0.name == "error" }).count <= 1 else { return nil }
        if items.contains(where: { $0.name == "error" }) {
            guard !items.contains(where: { $0.name == "code" }) else { return nil }
            return .failure(.denied)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty, code.utf8.count <= 8192 else { return nil }
        return .success(code)
    }
}
