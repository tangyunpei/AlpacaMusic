import Foundation

enum SpotifyAPIError: LocalizedError, Sendable, Equatable {
    case unauthorized
    case forbidden(String)
    case rateLimited(retryAfter: Double)
    case quotaExceeded(retryAfter: Double)
    case noActiveDevice
    case invalidRequest
    case invalidResponse
    case unsafeAddress
    case incompleteCollection
    case network
    case http(Int)

    var isUnauthorized: Bool { self == .unauthorized }
    var errorDescription: String? {
        switch self {
        case .unauthorized: "Spotify 登录已失效，请重新连接账号。"
        case .forbidden(let context): context
        case .rateLimited(let seconds): "Spotify 请求过于频繁，请至少等待 \(Int(min(seconds.rounded(.up), 31_536_000))) 秒后重试。"
        case .quotaExceeded(let seconds): "Spotify 开发者账号的共享调用配额已用尽，请至少等待 \(Int(min(seconds.rounded(.up), 31_536_000))) 秒后重试；切换同一开发者的 Client ID 不会重置配额。"
        case .noActiveDevice: "Spotify 没有可控制的播放设备。请先打开官方 Spotify App 并播放一首歌，再重试。"
        case .invalidRequest: "Spotify 请求参数不完整或无效。"
        case .invalidResponse: "Spotify 返回的资料无法读取，请稍后重试。"
        case .unsafeAddress: "已阻止 Spotify 请求跳转到未授权地址。"
        case .incompleteCollection: "Spotify 未完整返回列表，本次未导入。请刷新后重试。"
        case .network: "无法连接 Spotify，请检查网络后重试。"
        case .http(let status): "Spotify 未完成请求（HTTP \(status)），请稍后重试。"
        }
    }
}

struct SpotifyDevice: Decodable, Sendable, Equatable, Identifiable {
    let id: String?
    let name: String
    let type: String
    let isActive: Bool
    let isRestricted: Bool
    let volumePercent: Int?
    let supportsVolume: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, type
        case isActive = "is_active", isRestricted = "is_restricted"
        case volumePercent = "volume_percent", supportsVolume = "supports_volume"
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Spotify"
        type = try values.decodeIfPresent(String.self, forKey: .type) ?? "Unknown"
        isActive = try values.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        isRestricted = try values.decodeIfPresent(Bool.self, forKey: .isRestricted) ?? false
        volumePercent = try values.decodeIfPresent(Int.self, forKey: .volumePercent)
        supportsVolume = try values.decodeIfPresent(Bool.self, forKey: .supportsVolume) ?? false
    }
}

struct SpotifyPlaybackState: Sendable {
    let isPlaying: Bool
    let progressMilliseconds: Int
    let item: Track?
    let device: SpotifyDevice?
    var progress: Double { Double(max(0, progressMilliseconds)) / 1_000 }
    var duration: Double { item?.duration ?? 0 }
    var trackID: String? { item?.sourceID }
    var deviceID: String? { device?.id }
    var deviceName: String? { device?.name }
    var volume: Double? { device?.volumePercent.map { Double(min(100, max(0, $0))) / 100 } }
    var supportsVolume: Bool { device?.supportsVolume ?? false }
}

/// Spotify Web API metadata and remote playback. No audio URL, browser session,
/// secret, or long-lived credential is owned by this client.
actor SpotifyAPIClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private var blockedUntil: Date?
    private var quotaBlocked = false
    private static let maximumBytes = 8 * 1024 * 1024
    private static let maximumCollectionItems = 20_000
    private static let maximumPages = 400

    init(transport: Transport? = nil) { self.transport = transport ?? Self.fetch }

    func profile(accessToken: String) async throws -> MusicAccountProfile {
        let data = try await request(path: "/v1/me", accessToken: accessToken)
        let profile: SpotifyProfileResponse = try Self.decode(data)
        let identifier = [profile.accountID, profile.id].compactMap { $0 }.first { !$0.isEmpty }
        guard let identifier else { throw SpotifyAPIError.invalidResponse }
        let name = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return MusicAccountProfile(id: identifier, displayName: name.flatMap { $0.isEmpty ? nil : $0 } ?? profile.id ?? identifier)
    }

    func search(_ query: String, accessToken: String, limit: Int = 30) async throws -> [Track] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        guard query.utf8.count <= 2_048 else { throw SpotifyAPIError.invalidRequest }
        let count = min(30, max(1, limit))
        var offset = 0
        var tracks: [Track] = []
        var seen = Set<String>()
        // Development mode allows at most ten results per request as of Feb 2026.
        while offset < count {
            let data = try await request(path: "/v1/search", query: [
                .init(name: "q", value: query), .init(name: "type", value: "track"),
                .init(name: "limit", value: String(min(10, count - offset))),
                .init(name: "offset", value: String(offset))
            ], accessToken: accessToken)
            let response: SpotifySearchResponse = try Self.decode(data)
            guard response.tracks.offset == offset, response.tracks.items.count <= 10 else { throw SpotifyAPIError.invalidResponse }
            for value in response.tracks.items {
                if let track = value?.track, seen.insert(track.id).inserted { tracks.append(track) }
            }
            offset += response.tracks.items.count
            if response.tracks.items.isEmpty || response.tracks.next == nil || offset >= response.tracks.total { break }
        }
        return tracks
    }

    func playlists(accessToken: String) async throws -> [RemoteMusicPlaylist] {
        let values: [SpotifyPlaylistResponse?] = try await collection(path: "/v1/me/playlists", accessToken: accessToken)
        return values.compactMap { value in
            guard let value, !value.id.isEmpty else { return nil }
            return RemoteMusicPlaylist(id: value.id, name: value.name,
                                       trackCount: value.items?.total ?? value.tracks?.total ?? 0,
                                       artworkURL: value.images?.first?.secureURL, source: .spotify)
        }
    }

    func tracks(in playlist: RemoteMusicPlaylist, accessToken: String) async throws -> [Track] {
        guard playlist.source == .spotify, Self.validIdentifier(playlist.id) else { throw SpotifyAPIError.invalidRequest }
        // The renamed /items endpoint returns `item`; extended-quota responses
        // may still carry the older `track` field, accepted by the decoder below.
        let values: [SpotifyItemResponse?] = try await collection(path: "/v1/playlists/\(playlist.id)/items", accessToken: accessToken)
        return values.compactMap { $0?.track }
    }

    func savedTracks(accessToken: String) async throws -> [Track] {
        let values: [SpotifyItemResponse?] = try await collection(path: "/v1/me/tracks", accessToken: accessToken)
        return values.compactMap { $0?.track }
    }

    func devices(accessToken: String) async throws -> [SpotifyDevice] {
        let data = try await request(path: "/v1/me/player/devices", accessToken: accessToken)
        let response: SpotifyDevicesResponse = try Self.decode(data)
        return response.devices
    }

    func playbackState(accessToken: String) async throws -> SpotifyPlaybackState? {
        let data = try await request(path: "/v1/me/player", accessToken: accessToken, allowsEmpty: true)
        guard !data.isEmpty else { return nil }
        let response: SpotifyPlaybackResponse = try Self.decode(data)
        return SpotifyPlaybackState(isPlaying: response.isPlaying,
                                    progressMilliseconds: response.progressMilliseconds ?? 0,
                                    item: response.item?.track, device: response.device)
    }

    func play(trackID: String? = nil, deviceID: String? = nil, position: Double? = nil, accessToken: String) async throws {
        var body: [String: Any] = [:]
        if let trackID {
            guard Self.validIdentifier(trackID) else { throw SpotifyAPIError.invalidRequest }
            body["uris"] = ["spotify:track:" + trackID]
        }
        if let position { body["position_ms"] = try Self.milliseconds(position) }
        let data = body.isEmpty ? nil : try JSONSerialization.data(withJSONObject: body)
        _ = try await request(path: "/v1/me/player/play", query: try Self.deviceQuery(deviceID), method: "PUT", body: data, accessToken: accessToken, allowsEmpty: true)
    }

    func pause(deviceID: String? = nil, accessToken: String) async throws {
        _ = try await request(path: "/v1/me/player/pause", query: try Self.deviceQuery(deviceID), method: "PUT", accessToken: accessToken, allowsEmpty: true)
    }

    func seek(to position: Double, deviceID: String? = nil, accessToken: String) async throws {
        let query = try Self.deviceQuery(deviceID) + [.init(name: "position_ms", value: String(Self.milliseconds(position)))]
        _ = try await request(path: "/v1/me/player/seek", query: query, method: "PUT", accessToken: accessToken, allowsEmpty: true)
    }

    func setVolume(_ value: Double, deviceID: String? = nil, accessToken: String) async throws {
        guard value.isFinite, (0...1).contains(value) else { throw SpotifyAPIError.invalidRequest }
        let query = try Self.deviceQuery(deviceID) + [.init(name: "volume_percent", value: String(Int((value * 100).rounded())))]
        _ = try await request(path: "/v1/me/player/volume", query: query, method: "PUT", accessToken: accessToken, allowsEmpty: true)
    }

    private func collection<Item: Decodable & Sendable>(path: String, accessToken: String) async throws -> [Item] {
        var url = try Self.url(path: path, query: [.init(name: "limit", value: "50"), .init(name: "offset", value: "0")])
        var values: [Item] = []
        var visited = Set<String>()
        var offset = 0
        for _ in 0..<Self.maximumPages {
            try Self.validateAddress(url, path: path)
            guard visited.insert(url.absoluteString).inserted else { throw SpotifyAPIError.incompleteCollection }
            let data = try await request(url: url, accessToken: accessToken)
            let page: SpotifyPage<Item> = try Self.decode(data)
            guard page.offset == offset, page.total >= 0, page.total <= Self.maximumCollectionItems,
                  page.items.count <= 50, values.count + page.items.count <= Self.maximumCollectionItems else {
                throw SpotifyAPIError.incompleteCollection
            }
            values.append(contentsOf: page.items)
            offset += page.items.count
            guard let next = page.next else {
                guard offset >= page.total else { throw SpotifyAPIError.incompleteCollection }
                return values
            }
            guard !page.items.isEmpty, let nextURL = URL(string: next) else { throw SpotifyAPIError.incompleteCollection }
            try Self.validateAddress(nextURL, path: path)
            let nextOffsets = URLComponents(url: nextURL, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "offset" } ?? []
            guard nextOffsets.count == 1, nextOffsets.first?.value == String(offset) else { throw SpotifyAPIError.incompleteCollection }
            url = nextURL
        }
        throw SpotifyAPIError.incompleteCollection
    }

    private func request(path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil,
                         accessToken: String, allowsEmpty: Bool = false) async throws -> Data {
        try await request(url: Self.url(path: path, query: query), method: method, body: body, accessToken: accessToken, allowsEmpty: allowsEmpty)
    }

    private func request(url: URL, method: String = "GET", body: Data? = nil, accessToken: String, allowsEmpty: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        try Self.validateAddress(url, path: url.path)
        guard !accessToken.isEmpty, accessToken.utf8.count <= 16_384,
              !accessToken.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value >= 0x7F }) else { throw SpotifyAPIError.unauthorized }
        if let blockedUntil, blockedUntil > Date() {
            throw quotaBlocked ? SpotifyAPIError.quotaExceeded(retryAfter: blockedUntil.timeIntervalSinceNow)
                               : SpotifyAPIError.rateLimited(retryAfter: blockedUntil.timeIntervalSinceNow)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = method; request.httpBody = body; request.httpShouldHandleCookies = false
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as SpotifyAPIError { throw error }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw SpotifyAPIError.network }
        try Task.checkCancellation()
        guard let responseURL = response.url else { throw SpotifyAPIError.invalidResponse }
        try Self.validateAddress(responseURL, path: url.path)
        guard data.count <= Self.maximumBytes else { throw SpotifyAPIError.invalidResponse }
        switch response.statusCode {
        case 200..<300:
            guard allowsEmpty || !data.isEmpty else { throw SpotifyAPIError.invalidResponse }
            return data
        case 401: throw SpotifyAPIError.unauthorized
        case 403:
            let context: String
            if url.path.hasPrefix("/v1/me/player") {
                context = "Spotify 拒绝播放控制。此功能需要 Spotify Premium、播放控制授权和可控制的官方设备；开发模式还需将账号加入应用允许名单。"
            } else if url.path.hasPrefix("/v1/playlists/") {
                context = "Spotify 拒绝读取此歌单。开发模式仅支持读取自己创建或参与协作的歌单内容；还需有歌单读取授权，并将账号加入应用允许名单。"
            } else {
                context = "Spotify 拒绝访问。请确认账号已加入应用允许名单、已授予所需权限，且开发模式应用所有者拥有有效 Premium。"
            }
            throw SpotifyAPIError.forbidden(context)
        case 404 where url.path.hasPrefix("/v1/me/player"): throw SpotifyAPIError.noActiveDevice
        case 429:
            let delay = Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After"))
            blockedUntil = Date().addingTimeInterval(delay)
            quotaBlocked = (try? JSONDecoder().decode(SpotifyErrorResponse.self, from: data).error.reason) == "QUOTA_EXCEEDED"
            if quotaBlocked { throw SpotifyAPIError.quotaExceeded(retryAfter: delay) }
            throw SpotifyAPIError.rateLimited(retryAfter: delay)
        default: throw SpotifyAPIError.http(response.statusCode)
        }
    }

    private static func url(path: String, query: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"; components.host = "api.spotify.com"; components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw SpotifyAPIError.invalidRequest }
        return url
    }
    private static func validateAddress(_ url: URL, path: String) throws {
        guard url.scheme == "https", url.host == "api.spotify.com", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.fragment == nil, url.path == path, path.hasPrefix("/v1/"),
              !url.absoluteString.contains("\\") else { throw SpotifyAPIError.unsafeAddress }
    }
    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
    }
    private static func deviceQuery(_ deviceID: String?) throws -> [URLQueryItem] {
        guard let deviceID else { return [] }
        guard validIdentifier(deviceID) else { throw SpotifyAPIError.invalidRequest }
        return [.init(name: "device_id", value: deviceID)]
    }
    private static func milliseconds(_ value: Double) throws -> Int {
        guard value.isFinite, (0...2_147_483).contains(value) else { throw SpotifyAPIError.invalidRequest }
        return Int((value * 1_000).rounded())
    }
    private static func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw SpotifyAPIError.invalidResponse }
    }
    private static func retryDelay(_ header: String?) -> Double {
        guard let header else { return 60 }
        if let seconds = Double(header), seconds.isFinite, seconds >= 0 { return min(31_536_000, max(1, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: header).map { min(31_536_000, max(1, $0.timeIntervalSinceNow)) } ?? 60
    }
    private static func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: SpotifyAPIRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= Self.maximumBytes else { throw SpotifyAPIError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < Self.maximumBytes else { throw SpotifyAPIError.invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }
}

private final class SpotifyAPIRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // API endpoints are canonical; do not forward bearer tokens on redirects.
        completionHandler(nil)
    }
}

private struct SpotifyProfileResponse: Decodable {
    let id: String?
    let accountID: String?
    let displayName: String?
    private enum CodingKeys: String, CodingKey { case id; case accountID = "account_id"; case displayName = "display_name" }
}
private struct SpotifyErrorResponse: Decodable {
    struct Detail: Decodable { let reason: String? }
    let error: Detail
}
private struct SpotifyPage<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
    let next: String?
    let offset: Int
    let total: Int
}
private struct SpotifySearchResponse: Decodable { let tracks: SpotifyPage<SpotifyTrackResponse?> }
private struct SpotifyCountResponse: Decodable, Sendable { let total: Int? }
private struct SpotifyPlaylistResponse: Decodable, Sendable {
    let id: String
    let name: String
    let images: [SpotifyImageResponse]?
    let items: SpotifyCountResponse?
    let tracks: SpotifyCountResponse?
}
private struct SpotifyImageResponse: Decodable, Sendable {
    let url: String?
    var secureURL: URL? {
        guard let url, let value = URL(string: url), value.scheme == "https", value.user == nil, value.password == nil else { return nil }
        return value
    }
}
private struct SpotifyArtistResponse: Decodable, Sendable { let name: String? }
private struct SpotifyAlbumResponse: Decodable, Sendable { let name: String?; let images: [SpotifyImageResponse]? }
private struct SpotifyTrackResponse: Decodable, Sendable {
    let id: String?
    let type: String?
    let name: String?
    let artists: [SpotifyArtistResponse]?
    let album: SpotifyAlbumResponse?
    let durationMilliseconds: Int?
    let isLocal: Bool?
    let isPlayable: Bool?
    private enum CodingKeys: String, CodingKey {
        case id, type, name, artists, album
        case durationMilliseconds = "duration_ms", isLocal = "is_local", isPlayable = "is_playable"
    }
    var track: Track? {
        guard type == "track", isLocal != true, let id, !id.isEmpty, let name, !name.isEmpty else { return nil }
        let duration = max(0, Double(durationMilliseconds ?? 0) / 1_000)
        return Track(id: "spotify:" + id, title: name,
                     artist: artists?.compactMap(\.name).joined(separator: " / ") ?? "未知歌手",
                     album: album?.name ?? "", duration: duration, source: .spotify, sourceID: id,
                     artworkURL: album?.images?.first?.secureURL, unavailable: isPlayable == false)
    }
}
private struct SpotifyItemResponse: Decodable, Sendable {
    let item: SpotifyTrackResponse?
    let legacyTrack: SpotifyTrackResponse?
    let isLocal: Bool?
    private enum CodingKeys: String, CodingKey { case item; case legacyTrack = "track"; case isLocal = "is_local" }
    var track: Track? { isLocal == true ? nil : (item ?? legacyTrack)?.track }
}
private struct SpotifyDevicesResponse: Decodable { let devices: [SpotifyDevice] }
private struct SpotifyPlaybackResponse: Decodable {
    let isPlaying: Bool
    let progressMilliseconds: Int?
    let item: SpotifyTrackResponse?
    let device: SpotifyDevice?
    private enum CodingKeys: String, CodingKey {
        case item, device
        case isPlaying = "is_playing", progressMilliseconds = "progress_ms"
    }
}
