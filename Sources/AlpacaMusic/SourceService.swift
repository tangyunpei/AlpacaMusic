import Foundation

protocol SourceProvider: Sendable {
    func search(_ query: String) async throws -> [Track]
    func resolve(_ track: Track) async throws -> URL
}

struct SourceFailure: LocalizedError, Sendable {
    let message: String
    var status: Int? = nil
    var errorDescription: String? { message }
}

/// Connected platform accounts take precedence. Optional custom endpoints remain
/// isolated and never receive the native account's credentials.
actor SourceService {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private let native: NativeMusicClient?

    init(transport: Transport? = nil, native: NativeMusicClient? = nil) {
        self.native = native
        if let transport { self.transport = transport }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 15
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration)
            self.transport = { request in
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse else { throw SourceFailure(message: "音源返回了无效的响应") }
                guard response.expectedContentLength <= 4 * 1024 * 1024 else { throw SourceFailure(message: "音源响应过大") }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < 4 * 1024 * 1024 else { throw SourceFailure(message: "音源响应过大") }
                    data.append(byte)
                }
                return (data, response)
            }
        }
    }

    static func validatedURL(_ value: String) throws -> URL {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 8192, let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host(), !host.isEmpty, url.user() == nil, url.password() == nil else {
            throw SourceFailure(message: "请输入完整的 HTTP 或 HTTPS 地址，地址中不能包含账号或密码")
        }
        return url
    }

    static func validatedConfigurations(_ input: [SourceConfiguration]) throws -> [SourceConfiguration] {
        guard input.count <= 2, Set(input.map(\.kind)).count == input.count,
              input.allSatisfy({ [.netease, .qq].contains($0.kind) }) else { throw SourceFailure(message: "音源配置格式无效或重复") }
        return try SourceConfiguration.defaults.map { fallback in
            var value = input.first { $0.kind == fallback.kind } ?? fallback
            value.endpoint = value.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.endpoint.isEmpty {
                let url = try validatedURL(value.endpoint)
                guard url.query() == nil, url.fragment() == nil else { throw SourceFailure(message: "请填写服务根地址，不包含查询参数或锚点") }
                value.endpoint = url.absoluteString
                while value.endpoint.hasSuffix("/") { value.endpoint.removeLast() }
            }
            guard !value.enabled || !value.endpoint.isEmpty else { throw SourceFailure(message: "请先填写\(value.name)的服务地址") }
            return value
        }
    }

    func search(_ query: String, configurations: [SourceConfiguration], includeSodaPublicly: Bool = false) async -> [SourceSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 300 else { return [] }
        let enabled: [SourceConfiguration]
        do { enabled = try Self.validatedConfigurations(configurations).filter(\.enabled) }
        catch { return [SourceSearchResult(source: .netease, tracks: [], error: error.localizedDescription)] }
        let transport = self.transport
        let native = self.native
        let connected = await native?.connectedSources() ?? []
        return await withTaskGroup(of: SourceSearchResult.self) { group in
            if let native {
                for source in connected where MusicSourceAvailability.isVisible(source) {
                    group.addTask {
                        do { return SourceSearchResult(source: source, tracks: try await native.search(query, source: source)) }
                        catch is CancellationError { return SourceSearchResult(source: source, tracks: [], error: "搜索已取消") }
                        catch { return SourceSearchResult(source: source, tracks: [], error: error.localizedDescription) }
                    }
                }
            }
            if MusicSourceAvailability.sodaEnabled, includeSodaPublicly, !connected.contains(.soda) {
                group.addTask {
                    do { return SourceSearchResult(source: .soda, tracks: try await SodaDirectProvider().search(query, cookies: [])) }
                    catch is CancellationError { return SourceSearchResult(source: .soda, tracks: [], error: "搜索已取消") }
                    catch { return SourceSearchResult(source: .soda, tracks: [], error: error.localizedDescription) }
                }
            }
            for configuration in enabled where !connected.contains(configuration.kind) {
                group.addTask {
                    do {
                        let provider = try Self.provider(configuration, transport: transport)
                        return SourceSearchResult(source: configuration.kind, tracks: try await provider.search(query))
                    } catch is CancellationError { return SourceSearchResult(source: configuration.kind, tracks: [], error: "搜索已取消") }
                    catch { return SourceSearchResult(source: configuration.kind, tracks: [], error: error.localizedDescription) }
                }
            }
            var results: [SourceSearchResult] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.source.rawValue < $1.source.rawValue }
        }
    }

    func preparePlayback(_ track: Track) async throws -> Track {
        guard track.source == .soda else { return track }
        if let native, await native.connectedSources().contains(.soda) {
            return try await native.preparePlayback(track)
        }
        // The provider validates the source and resource ID. Shared-playlist
        // entries may not have obtained their public playback range yet.
        return try await SodaDirectProvider().preparePlayback(track, cookies: [])
    }

    func resolve(_ track: Track, configurations: [SourceConfiguration]) async throws -> URL {
        switch track.source {
        case .appleMusic:
            throw SourceFailure(message: "Apple Music 由官方播放器处理，无法作为音频直链播放")
        case .spotify:
            throw SourceFailure(message: "Spotify 由官方播放器处理，无法作为音频直链播放")
        case .local:
            guard let bookmark = track.bookmark else { throw SourceFailure(message: "本地文件尚未授权，请重新导入") }
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            return url
        case .demo:
            guard let url = track.url, url.isFileURL else { throw SourceFailure(message: "试听文件不可用") }
            return url
        case .url:
            guard let url = track.url else { throw SourceFailure(message: "歌曲缺少音频链接") }
            return try Self.validatedURL(url.absoluteString)
        case .netease, .qq:
            if let native, await native.connectedSources().contains(track.source) {
                return try await native.resolve(track)
            }
            guard let configuration = try Self.validatedConfigurations(configurations).first(where: { $0.kind == track.source }), configuration.enabled else {
                throw SourceFailure(message: native == nil ? "此音源尚未开启，请在音源设置中配置并启用" : "请先在音源页登录\(track.source.title)")
            }
            return try await Self.provider(configuration, transport: transport).resolve(track)
        case .soda:
            if let native, await native.connectedSources().contains(.soda) {
                return try await native.resolve(track)
            }
            // Public official shares never use or receive a custom endpoint.
            return try await SodaDirectProvider().resolve(track, cookies: [])
        }
    }

    func test(_ configuration: SourceConfiguration) async -> (ok: Bool, message: String) {
        do {
            _ = try await Self.provider(configuration, transport: transport).search("music")
            return (true, "搜索接口连接成功；歌曲播放权限将在选歌时检查")
        } catch { return (false, error.localizedDescription) }
    }

    private static func provider(_ configuration: SourceConfiguration, transport: @escaping Transport) throws -> any SourceProvider {
        let validated = try validatedConfigurations([configuration]).first { $0.kind == configuration.kind }!
        guard !validated.endpoint.isEmpty else { throw SourceFailure(message: "尚未配置音源服务地址") }
        let client = SourceHTTPClient(configuration: validated, transport: transport)
        switch validated.kind {
        case .netease: return NeteaseSource(client: client)
        case .qq: return QQSource(client: client)
        default: throw SourceFailure(message: "不支持的音源类型")
        }
    }
}

private struct SourceHTTPClient: Sendable {
    let configuration: SourceConfiguration
    let transport: SourceService.Transport

    func request<T: Decodable & Sendable>(_ route: String, parameters: [String: String], as type: T.Type) async throws -> T {
        guard var components = URLComponents(string: "\(configuration.endpoint)/\(route)") else { throw SourceFailure(message: "音源地址无效") }
        components.queryItems = parameters.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw SourceFailure(message: "音源请求地址无效") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        do {
            try Task.checkCancellation()
            let (data, response) = try await transport(request)
            guard (200..<300).contains(response.statusCode) else {
                if [401, 403].contains(response.statusCode) { throw SourceFailure(message: "服务拒绝访问，请检查服务端登录状态或歌曲权限", status: response.statusCode) }
                throw SourceFailure(message: "音源服务返回 HTTP \(response.statusCode)，请检查地址及接口版本", status: response.statusCode)
            }
            guard data.count <= 4 * 1024 * 1024 else { throw SourceFailure(message: "音源响应过大") }
            let status = try JSONDecoder().decode(APIStatus.self, from: data)
            let code = configuration.kind == .qq ? status.result ?? status.code ?? 100 : status.code ?? 200
            if [301, 302, 401, 403].contains(code) { throw SourceFailure(message: "服务端尚未登录、会话已过期或当前账号无播放权限", status: code) }
            guard [0, 100, 200].contains(code) else { throw SourceFailure(message: "音源请求失败（状态 \(code)），请检查服务状态和歌曲权限", status: code) }
            return try JSONDecoder().decode(type, from: data)
        } catch let error as SourceFailure { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw SourceFailure(message: "音源请求超时，请检查服务是否可用") }
            if error.code == .appTransportSecurityRequiresSecureConnection { throw SourceFailure(message: "系统限制了此 HTTP 连接，请使用 HTTPS 服务地址") }
            if [.serverCertificateUntrusted, .serverCertificateHasBadDate, .secureConnectionFailed].contains(error.code) { throw SourceFailure(message: "无法验证服务的安全连接，请检查 HTTPS 证书") }
            throw SourceFailure(message: "无法连接音源服务，请检查地址、网络及服务状态")
        } catch is DecodingError { throw SourceFailure(message: "服务返回格式不兼容，请检查 API 类型与版本") }
        catch { throw SourceFailure(message: "无法读取音源服务响应") }
    }
}

private struct APIStatus: Decodable {
    var code: Int?; var result: Int?
    enum CodingKeys: CodingKey { case code, result }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        code = try? values.decode(Int.self, forKey: .code)
        result = try? values.decode(Int.self, forKey: .result)
    }
}
private struct ArtistDTO: Decodable, Sendable { var name: String? }
private struct NeteaseSong: Decodable, Sendable {
    var id: Int64; var name: String?; var ar: [ArtistDTO]?; var artists: [ArtistDTO]?; var al: Album?; var album: Album?; var dt: Double?; var duration: Double?
    struct Album: Decodable, Sendable { var name: String?; var picUrl: String? }
    var track: Track {
        Track(id: "netease:\(id)", title: name ?? "未命名歌曲", artist: (ar ?? artists ?? []).compactMap(\.name).joined(separator: " / ").fallback("未知艺术家"), album: al?.name ?? album?.name ?? "未知专辑", duration: max(0, (dt ?? duration ?? 0) / 1000), source: .netease, sourceID: String(id), artworkURL: (al?.picUrl ?? album?.picUrl).flatMap { try? SourceService.validatedURL($0) })
    }
}
private struct NeteaseSearchDTO: Decodable, Sendable { var result: Result?; struct Result: Decodable, Sendable { var songs: [NeteaseSong]?; var songCount: Int? } }
private struct NeteaseURLsDTO: Decodable, Sendable {
    var data: [Item]?
    struct Item: Decodable, Sendable { var id: Int64?; var code: Int?; var url: String?; var freeTrialInfo: Trial? }
    struct Trial: Decodable, Sendable {}
}
private struct NeteaseSource: SourceProvider {
    let client: SourceHTTPClient
    func search(_ query: String) async throws -> [Track] {
        let data = try await client.request("cloudsearch", parameters: ["keywords": query, "type": "1", "limit": "50"], as: NeteaseSearchDTO.self)
        guard let songs = data.result?.songs ?? (data.result?.songCount == 0 ? [] : nil) else { throw SourceFailure(message: "网易云搜索响应不兼容，需要 /cloudsearch 接口") }
        return songs.map(\.track)
    }
    func resolve(_ track: Track) async throws -> URL {
        guard let id = track.sourceID, !id.isEmpty, id.count <= 200 else { throw SourceFailure(message: "歌曲编号无效") }
        let data: NeteaseURLsDTO
        do { data = try await client.request("song/url/v1", parameters: ["id": id, "level": "standard"], as: NeteaseURLsDTO.self) }
        catch let error as SourceFailure where [404, 405].contains(error.status ?? 0) { data = try await client.request("song/url", parameters: ["id": id, "br": "128000"], as: NeteaseURLsDTO.self) }
        guard let item = data.data?.first(where: { $0.id.map(String.init) == id }), let url = item.url, item.code == nil || item.code == 200 else { throw SourceFailure(message: "该歌曲暂不可播放，可能已下架、受地区限制或需要订阅 / 购买权限") }
        guard item.freeTrialInfo == nil else { throw SourceFailure(message: "音源仅返回试听片段，需要相应订阅 / 购买权限才能播放完整歌曲") }
        return try SourceService.validatedURL(url)
    }
}
private struct QQSong: Decodable, Sendable {
    var songmid: String?; var mid: String?; var songname: String?; var name: String?; var title: String?; var singer: [ArtistDTO]?; var albumname: String?; var albummid: String?; var album: Album?; var interval: Double?
    struct Album: Decodable, Sendable { var name: String?; var mid: String? }
    var track: Track? {
        guard let id = songmid ?? mid, !id.isEmpty else { return nil }
        let art = (albummid ?? album?.mid).flatMap { URL(string: "https://y.gtimg.cn/music/photo_new/T002R300x300M000\($0).jpg") }
        return Track(id: "qq:\(id)", title: songname ?? name ?? title ?? "未命名歌曲", artist: (singer ?? []).compactMap(\.name).joined(separator: " / ").fallback("未知艺术家"), album: albumname ?? album?.name ?? "未知专辑", duration: max(0, interval ?? 0), source: .qq, sourceID: id, artworkURL: art)
    }
}
private struct QQSearchDTO: Decodable, Sendable {
    var data: Result?; var songlist: [QQSong]?
    struct Result: Decodable, Sendable { var list: [QQSong]?; var songlist: [QQSong]?; var song: Song? }
    struct Song: Decodable, Sendable { var list: [QQSong]? }
}
private struct QQURLsDTO: Decodable, Sendable { var data: [String: String]? }
private struct QQSource: SourceProvider {
    let client: SourceHTTPClient
    func search(_ query: String) async throws -> [Track] {
        let data = try await client.request("search", parameters: ["key": query, "pageNo": "1", "pageSize": "50", "t": "0"], as: QQSearchDTO.self)
        guard let songs = data.data?.list ?? data.data?.songlist ?? data.data?.song?.list ?? data.songlist else { throw SourceFailure(message: "QQ 搜索响应不兼容，需要 jsososo /search 接口") }
        return songs.compactMap(\.track)
    }
    func resolve(_ track: Track) async throws -> URL {
        guard let id = track.sourceID, !id.isEmpty, id.count <= 200 else { throw SourceFailure(message: "歌曲编号无效") }
        let data = try await client.request("song/urls", parameters: ["id": id], as: QQURLsDTO.self)
        guard let value = data.data?[id], !value.isEmpty else { throw SourceFailure(message: "QQ 音乐未提供播放地址，请检查服务端登录、订阅 / 购买权限或歌曲是否可用") }
        return try SourceService.validatedURL(value)
    }
}
private extension String { func fallback(_ value: String) -> String { isEmpty ? value : self } }
