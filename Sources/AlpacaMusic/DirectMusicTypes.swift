import Foundation

struct MusicSessionCookie: Codable, Sendable, Equatable {
    var name: String
    var value: String
    var domain: String
    var path: String = "/"
    var secure: Bool = true
    var expires: Date? = nil

    init(name: String, value: String, domain: String, path: String = "/", secure: Bool = true, expires: Date? = nil) {
        self.name = name; self.value = value; self.domain = domain; self.path = path; self.secure = secure; self.expires = expires
    }
    init(_ cookie: HTTPCookie) {
        self.init(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, secure: cookie.isSecure, expires: cookie.expiresDate)
    }
    func matches(_ url: URL, now: Date = Date()) -> Bool {
        guard let host = url.host?.lowercased(), expires.map({ $0 > now }) ?? true,
              !secure || url.scheme == "https", !name.isEmpty,
              !name.contains(where: { $0.isWhitespace || $0 == ";" || $0 == "=" }),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0.value == 0x3B }) else { return false }
        let clean = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let domainMatch = domain.hasPrefix(".") ? host == clean || host.hasSuffix("." + clean) : host == clean
        let requestPath = url.path.isEmpty ? "/" : url.path
        let cookiePath = path.isEmpty ? "/" : path
        let pathMatch = requestPath == cookiePath || (requestPath.hasPrefix(cookiePath) && (cookiePath.hasSuffix("/") || requestPath.dropFirst(cookiePath.count).hasPrefix("/")))
        return domainMatch && pathMatch
    }
}

struct MusicAccountProfile: Codable, Sendable, Equatable {
    var id: String
    var displayName: String
}

struct RemoteMusicPlaylist: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var trackCount: Int
    var artworkURL: URL? = nil
    var source: MusicSource
}

protocol DirectMusicProvider: Sendable {
    var source: MusicSource { get }
    func profile(cookies: [MusicSessionCookie]) async throws -> MusicAccountProfile
    func search(_ query: String, cookies: [MusicSessionCookie]) async throws -> [Track]
    func playlists(profile: MusicAccountProfile, cookies: [MusicSessionCookie]) async throws -> [RemoteMusicPlaylist]
    func tracks(in playlist: RemoteMusicPlaylist, cookies: [MusicSessionCookie]) async throws -> [Track]
    /// Refresh expiring share metadata before opening media. Most platforms
    /// resolve URLs separately and keep the imported track unchanged.
    func preparePlayback(_ track: Track, cookies: [MusicSessionCookie]) async throws -> Track
    func resolve(_ track: Track, cookies: [MusicSessionCookie]) async throws -> URL
    func lyrics(_ track: Track, cookies: [MusicSessionCookie]) async throws -> LyricsPayload?
}
extension DirectMusicProvider {
    func preparePlayback(_ track: Track, cookies: [MusicSessionCookie]) async throws -> Track { track }
    func lyrics(_ track: Track, cookies: [MusicSessionCookie]) async throws -> LyricsPayload? { nil }
}

struct LyricsSessionScope: Hashable, Sendable {
    let source: MusicSource
    let generation: UUID
}

enum DirectMusicAccess {
    static let sources: [MusicSource] = [.netease, .qq, .soda]
    static var visibleSources: [MusicSource] { sources.filter(MusicSourceAvailability.isVisible) }
    static func allowedAPIHost(_ host: String, source: MusicSource) -> Bool {
        let hosts: Set<String>
        switch source {
        case .netease: hosts = ["music.163.com", "interface.music.163.com", "interface3.music.163.com"]
        case .qq: hosts = ["y.qq.com", "c.y.qq.com", "u.y.qq.com", "u6.y.qq.com"]
        case .soda: hosts = ["api.qishui.com", "beta-luna.douyin.com"]
        default: return false
        }
        return hosts.contains(host.lowercased())
    }
    static func sessionCookies(_ cookies: [MusicSessionCookie], for source: MusicSource) -> [MusicSessionCookie] {
        let names: Set<String>
        let domains: Set<String>
        switch source {
        case .netease:
            names = ["MUSIC_U", "__csrf", "MUSIC_A", "NMTID", "__remember_me"]
            domains = ["music.163.com", "interface.music.163.com", "interface3.music.163.com"]
        case .qq:
            names = ["uin", "qqmusic_uin", "qm_keyst", "qqmusic_key", "music_key", "wxskey", "p_skey", "p_uin", "skey", "p_lskey", "lskey", "qqmusic_guid", "wxuin", "wxopenid", "wxunionid", "login_type", "tmeLoginType", "music_ignore_pskey"]
            domains = ["qq.com", "y.qq.com", "c.y.qq.com", "u.y.qq.com", "u6.y.qq.com"]
        case .soda:
            names = ["sessionid", "sessionid_ss", "sid_guard", "sid_tt", "uid_tt", "uid_tt_ss", "passport_csrf_token", "passport_csrf_token_default", "ssid_ucp_v1", "session_tlb_tag"]
            domains = ["qishui.com", "api.qishui.com", "bff-pc.qishui.com", "beta-luna.douyin.com"]
        default: return []
        }
        return cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domains.contains(domain) && names.contains(cookie.name) && (cookie.expires.map { $0 > Date() } ?? true) && cookie.value.utf8.count <= 16384
        }
    }
    /// Request bodies and Cookie headers must use the same scope and precedence.
    static func requestCookies(_ cookies: [MusicSessionCookie], for source: MusicSource, url: URL) -> [MusicSessionCookie] {
        sessionCookies(cookies, for: source).filter { $0.matches(url) }.sorted { $0.path.count > $1.path.count }
    }
}

/// No shared browser storage, ambient credentials, or off-platform cookie redirects.
struct NativeMusicHTTP: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    init(transport: Transport? = nil) {
        self.transport = transport ?? { request in
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
            let delegate = NativeMusicRedirectGuard(host: request.url?.host ?? "")
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw MusicError.message(L10n.string("音乐平台返回了无效响应")) }
            guard response.expectedContentLength <= 8 * 1024 * 1024 else { throw MusicError.message(L10n.string("音乐平台响应过大")) }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 8 * 1024 * 1024 else { throw MusicError.message(L10n.string("音乐平台响应过大")) }
                data.append(byte)
            }
            return (data, response)
        }
    }
    func data(for request: URLRequest, source: MusicSource, cookies: [MusicSessionCookie]) async throws -> Data {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host, DirectMusicAccess.allowedAPIHost(host, source: source) else { throw MusicError.message(L10n.string("已阻止非音乐平台的连接")) }
        var request = request
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let values = DirectMusicAccess.requestCookies(cookies, for: source, url: url)
        request.setValue(values.isEmpty ? nil : values.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        do {
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            guard data.count <= 8 * 1024 * 1024 else { throw MusicError.message(L10n.string("音乐平台响应过大")) }
            guard response.url?.host == host else {
                throw MusicError.message(L10n.string("已阻止偏离\(source.title)原请求地址的响应（HTTP \(String(response.statusCode))）"))
            }
            guard (200..<300).contains(response.statusCode) else {
                let reason: String
                switch response.statusCode {
                case 401: reason = L10n.string("请求需要有效登录，请在音源页重新登录后重试")
                case 403: reason = L10n.string("平台拒绝访问，请在官网确认账号权限或验证提示；具体原因未确认")
                case 404: reason = L10n.string("请求的接口或资源未找到，具体原因未确认")
                case 429: reason = L10n.string("请求过于频繁，请稍后重试")
                case 500..<600: reason = L10n.string("平台服务暂时异常，请稍后重试")
                default: reason = L10n.string("平台未能完成请求，请稍后重试")
                }
                throw MusicError.message(L10n.string("\(source.title)：\(reason)（HTTP \(String(response.statusCode))）"))
            }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as MusicError { throw error }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            let reason: String
            switch error.code {
            case .timedOut: reason = L10n.string("请求超时，请重试")
            case .notConnectedToInternet: reason = L10n.string("当前没有网络连接")
            case .networkConnectionLost: reason = L10n.string("网络连接中断，请重试")
            case .cannotFindHost, .dnsLookupFailed: reason = L10n.string("无法解析平台服务器地址，请检查网络或 DNS")
            case .cannotConnectToHost: reason = L10n.string("无法连接平台服务器")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                reason = L10n.string("无法建立可信的 HTTPS 连接，请检查系统时间和网络")
            default: reason = L10n.string("网络请求失败，请重试")
            }
            throw MusicError.message(L10n.string("\(source.title)：\(reason)（网络错误 \(String(error.code.rawValue))）"))
        }
        catch { throw MusicError.message(L10n.string("无法连接\(source.title)，请检查网络后重试")) }
    }
}

private final class NativeMusicRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let host: String
    init(host: String) { self.host = host }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        guard request.url?.scheme == "https", request.url?.host == host else { return nil }
        return request
    }
}
