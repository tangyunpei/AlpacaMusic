import Foundation
import MusicKit

struct AppleMusicLibraryPlaylist: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var artworkURL: URL? = nil
    var trackCount: Int? = nil
}

/// Cloud library reads use MusicKit's automatic token handling. No token is
/// requested, persisted or logged by the app, and this client only issues GETs.
@MainActor struct AppleMusicLibraryClient {
    typealias Transport = @MainActor (URLRequest) async throws -> Data
    private let transport: Transport
    private let maximumItems: Int

    init(maximumItems: Int = 10_000, transport: @escaping Transport = Self.musicKitData) {
        self.maximumItems = min(max(1, maximumItems), 10_000)
        self.transport = transport
    }

    func songs(validate: @MainActor () throws -> Void = {}) async throws -> [Track] {
        try await resources(path: "/v1/me/library/songs", kind: L10n.string("个人歌曲"), unique: true, validate: validate).enumerated().map { try $0.element.track(position: $0.offset + 1) }
    }

    func playlists(validate: @MainActor () throws -> Void = {}) async throws -> [AppleMusicLibraryPlaylist] {
        try await resources(path: "/v1/me/library/playlists", kind: L10n.string("歌单列表"), unique: true, validate: validate).map { item in
            guard item.type == "library-playlists", Self.validIdentifier(item.id),
                  let name = item.attributes?.name, !name.isEmpty else {
                throw MusicError.message(L10n.string("Apple Music 返回的歌单资料不完整，本次未导入。"))
            }
            return AppleMusicLibraryPlaylist(id: item.id, name: name,
                                             artworkURL: item.attributes?.artwork?.urlValue,
                                             trackCount: item.attributes?.trackCount)
        }
    }

    func tracks(in playlist: AppleMusicLibraryPlaylist, validate: @MainActor () throws -> Void = {}) async throws -> [Track] {
        guard Self.validIdentifier(playlist.id) else { throw MusicError.message(L10n.string("Apple Music 歌单标识无效，请重新读取歌单。")) }
        return try await resources(path: "/v1/me/library/playlists/\(playlist.id)/tracks", kind: L10n.string("歌单歌曲"), unique: false, validate: validate).enumerated().map { try $0.element.track(position: $0.offset + 1) }
    }

    /// Library IDs must stay in the library namespace, including uploaded or
    /// matched songs that have no catalog equivalent. Decode Apple's original
    /// resource so its opaque play parameters reach MusicKit unchanged.
    func playbackSong(libraryID id: String) async throws -> Song {
        guard Self.validIdentifier(id) else { throw MusicError.message(L10n.string("Apple Music 曲库歌曲标识无效，请重新导入。")) }
        let url = URL(string: "https://api.music.apple.com/v1/me/library/songs/\(id)")!
        let data = try await fetch(url)
        let page: ResourcePage = try decode(data)
        guard page.next == nil, page.data.count == 1, let item = page.data.first,
              item.id == id, item.type == "library-songs" else {
            throw MusicError.message(L10n.string("Apple Music 未返回这首曲库歌曲，请检查歌曲是否仍在当前账户曲库中。"))
        }
        guard item.attributes?.playParams != nil else {
            throw MusicError.message(L10n.string("Apple Music 未提供这首曲库歌曲的播放权限。上传或已失效的歌曲可能无法通过 MusicKit 播放。"))
        }
        do {
            let songs = try JSONDecoder().decode(SongPage.self, from: data).data
            guard let song = songs.first, song.id.rawValue == id, song.playParameters != nil else {
                throw MusicError.message(L10n.string("Apple Music 未提供这首曲库歌曲的有效播放资料。"))
            }
            return song
        } catch let error as MusicError { throw error }
        catch { throw MusicError.message(L10n.string("Apple Music 曲库歌曲的播放资料无法读取，请重试或在音乐 App 中确认是否可播放。")) }
    }

    /// The API resource type defines the namespace; the ID itself is opaque.
    /// Prefix handling is limited to backward compatibility with records saved
    /// before resource kinds were persisted, never new library responses.
    nonisolated static func playbackResource(for track: Track) throws -> AppleMusicResourceKind {
        guard track.source == .appleMusic, let id = track.sourceID, validIdentifier(id) else {
            throw MusicError.message(L10n.string("这首歌曲的 Apple Music 标识无效，请重新搜索或导入。"))
        }
        if let kind = track.appleMusicResourceKind { return kind }
        if id.utf8.allSatisfy({ (48...57).contains($0) }), id.contains(where: { $0 != "0" }) { return .catalogSong }
        if id.hasPrefix("i."), id.count > 2 { return .librarySong }
        throw MusicError.message(L10n.string("这首歌曲尚未记录 Apple Music 资源类型，请重新搜索或导入。"))
    }
    nonisolated private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 200 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 45 || $0 == 95
        } && value != "." && value != ".."
    }

    private func resources(path: String, kind: String, unique: Bool, validate: @MainActor () throws -> Void) async throws -> [Resource] {
        var next: URL? = URL(string: "https://api.music.apple.com\(path)?limit=100")!
        var visited = Set<URL>(), identities = Set<String>()
        var output: [Resource] = []
        var total: Int?
        while let url = next {
            try Task.checkCancellation(); try validate()
            guard visited.insert(url).inserted else { throw paginationError }
            let context = L10n.string("读取\(kind)第 \(visited.count) 页（已读取 \(output.count) 条）")
            let data = try await fetch(url, context: context)
            try validate()
            let page: ResourcePage = try decode(data)
            if let reported = page.meta?.total {
                guard reported >= 0, total == nil || total == reported else { throw paginationError }
                total = reported
                guard reported <= maximumItems else { throw limitError }
            }
            guard output.count + page.data.count <= maximumItems else { throw limitError }
            if unique {
                for item in page.data {
                    guard identities.insert("\(item.type):\(item.id)").inserted else { throw paginationError }
                }
            }
            output.append(contentsOf: page.data)
            if let nextPath = page.next {
                guard !page.data.isEmpty, output.count < maximumItems,
                      let value = URL(string: nextPath, relativeTo: url)?.absoluteURL,
                      let parts = URLComponents(url: value, resolvingAgainstBaseURL: true),
                      parts.scheme == "https", parts.host == "api.music.apple.com", parts.port == nil,
                      parts.user == nil, parts.password == nil, parts.fragment == nil, parts.path == path,
                      let offsets = parts.queryItems?.filter({ $0.name == "offset" }), offsets.count == 1,
                      let offsetValue = offsets.first?.value, let offset = Int(offsetValue), offset == output.count else {
                    if output.count >= maximumItems { throw limitError }
                    throw paginationError
                }
                next = value
            } else { next = nil }
            if let total, output.count > total { throw paginationError }
        }
        guard total == nil || total == output.count else { throw paginationError }
        try Task.checkCancellation()
        return output
    }

    private var paginationError: MusicError { .message(L10n.string("Apple Music 曲库分页不完整或已发生变化，本次未导入，请重新读取。")) }
    private var limitError: MusicError { .message(L10n.string("Apple Music 此次读取超过 10,000 条保护上限，本次未导入。请改为导入较小的歌单。")) }

    private func fetch(_ url: URL, context: String = L10n.string("读取曲库歌曲播放资料")) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url); request.httpMethod = "GET"; request.timeoutInterval = 30
        do {
            let data = try await transport(request)
            try Task.checkCancellation()
            guard data.count <= 16 * 1024 * 1024 else { throw MusicError.message(L10n.string("Apple Music 返回的资料过大，本次未导入。")) }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as MusicDataRequest.Error {
            throw MusicError.message(L10n.string("\(context)：Apple Music 请求失败（HTTP \(String(error.status))，代码 \(String(error.code))），请检查授权后重试。"))
        } catch let error as MusicTokenRequestError {
            throw MusicError.message(L10n.string("\(context)：\(Self.tokenFailureMessage(error))"))
        } catch let error as MusicError { throw MusicError.message(L10n.string("\(context)：\(error.localizedDescription)")) }
        catch let error as URLError {
            let reason = error.code == .timedOut ? L10n.string("网络请求超时，请重试。") : L10n.string("网络连接失败，请重试。")
            throw MusicError.message(L10n.string("\(context)：\(reason)"))
        } catch { throw MusicError.message(L10n.string("\(context)：Apple Music 请求失败，请稍后重试。")) }
    }

    nonisolated private static func tokenFailureMessage(_ error: MusicTokenRequestError) -> String {
        switch error {
        case .unknown:
            L10n.string("系统未说明 Apple Music 认证失败的具体原因，请稍后重试（unknown）。")
        case .permissionDenied:
            L10n.string("本应用未获 Apple Music 访问许可，请在系统设置检查媒体与 Apple Music 权限（permissionDenied）。")
        case .userTokenRevoked:
            L10n.string("当前账户的 Apple Music 授权已失效，请在本应用重新连接（userTokenRevoked）。")
        case .userNotSignedIn:
            L10n.string("Apple Music 尚未登录，请先在音乐 App 中登录订阅账户（userNotSignedIn）。")
        case .privacyAcknowledgementRequired:
            L10n.string("Apple Music 需要确认隐私提示，请打开音乐 App 完成确认后重试（privacyAcknowledgementRequired）。")
        case .developerTokenRequestFailed:
            L10n.string("系统未能获取本应用的 Apple Music 认证，请检查网络及 MusicKit 配置后重试（developerTokenRequestFailed）。")
        case .userTokenRequestFailed:
            L10n.string("系统未能获取当前账户的 Apple Music 授权，请检查音乐 App 的登录及网络后重试（userTokenRequestFailed）。")
        @unknown default:
            L10n.string("系统返回尚未识别的 Apple Music 认证错误，请稍后重试（unrecognizedMusicTokenError）。")
        }
    }

    private func decode(_ data: Data) throws -> ResourcePage {
        do {
            let response = try JSONDecoder().decode(ResourcePage.self, from: data)
            guard response.errors?.isEmpty != false else { throw MusicError.message(L10n.string("Apple Music 未能完整返回曲库资料，本次未导入。")) }
            return response
        } catch let error as MusicError { throw error }
        catch { throw MusicError.message(L10n.string("Apple Music 曲库资料格式无法读取，本次未导入。")) }
    }

    private static func musicKitData(_ request: URLRequest) async throws -> Data {
        let response = try await MusicDataRequest(urlRequest: request).response()
        guard (200..<300).contains(response.urlResponse.statusCode) else {
            throw MusicError.message(L10n.string("读取 Apple Music 曲库失败（HTTP \(String(response.urlResponse.statusCode))），请检查授权后重试。"))
        }
        return response.data
    }

    private struct SongPage: Decodable { let data: [Song] }
    private struct ResourcePage: Decodable {
        let data: [Resource]
        let next: String?
        let meta: Meta?
        let errors: [APIError]?
    }
    private struct APIError: Decodable { }
    private struct Meta: Decodable { let total: Int? }
    private struct Resource: Decodable {
        let id: String
        let type: String
        let attributes: Attributes?
        func track(position: Int) throws -> Track {
            let context = L10n.string("Apple Music 第 \(position) 首歌曲")
            guard type == "library-songs" || type == "songs" else {
                throw MusicError.message(L10n.string("\(context)是当前不支持的非歌曲项目，本次未导入。"))
            }
            let libraryType = type == "library-songs"
            guard AppleMusicLibraryClient.validIdentifier(id) else {
                throw MusicError.message(L10n.string("\(context)标识不能作为安全的资源路径（曲库类型：\(libraryType ? L10n.string("是") : L10n.string("否"))，长度：\(id.count)），本次未导入。"))
            }
            guard let attributes else { throw MusicError.message(L10n.string("\(context)缺少歌曲资料（attributes），本次未导入。")) }
            guard let name = attributes.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MusicError.message(L10n.string("\(context)缺少歌曲名称（name），本次未导入。"))
            }
            // Artist metadata is not used to identify or resolve the song.
            // Preserve the valid identity/name even when the artist is absent.
            let artist = attributes.artistName ?? ""
            let duration = attributes.durationInMillis ?? 0
            guard duration.isFinite, duration >= 0 else { throw MusicError.message(L10n.string("Apple Music 返回的歌曲时长无效，本次未导入。")) }
            return Track(id: libraryType ? "appleMusic:library:\(id)" : "appleMusic:\(id)", title: name, artist: artist, album: attributes.albumName ?? "",
                         duration: duration / 1_000, source: .appleMusic, sourceID: id,
                         appleMusicResourceKind: libraryType ? .librarySong : .catalogSong,
                         artworkURL: attributes.artwork?.urlValue, format: "Apple Music", unavailable: attributes.playParams == nil)
        }
    }
    private struct Attributes: Decodable {
        let name: String?
        let artistName: String?
        let albumName: String?
        let durationInMillis: Double?
        let trackCount: Int?
        let artwork: ArtworkValue?
        let playParams: PlayParameters?
    }
    private struct ArtworkValue: Decodable {
        let url: String
        var urlValue: URL? {
            let value = url.replacingOccurrences(of: "{w}", with: "640").replacingOccurrences(of: "{h}", with: "640")
                .replacingOccurrences(of: "{f}", with: "jpg")
            guard let result = URL(string: value), result.scheme == "https", result.host != nil,
                  result.user == nil, result.password == nil else { return nil }
            return result
        }
    }
}
