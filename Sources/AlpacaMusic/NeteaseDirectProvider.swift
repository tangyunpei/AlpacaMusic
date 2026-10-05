import Foundation

/// Website protocol only: requests go directly to music.163.com with this app's session.
struct NeteaseDirectProvider: DirectMusicProvider {
    let source: MusicSource = .netease
    private let http: NativeMusicHTTP
    init(http: NativeMusicHTTP = NativeMusicHTTP()) { self.http = http }

    func profile(cookies: [MusicSessionCookie]) async throws -> MusicAccountProfile {
        let result: NEProfileResponse = try await request("w/nuser/account/get", payload: [:], cookies: cookies)
        guard let profile = result.profile, let id = profile.userId, !id.value.isEmpty,
              id.value.contains(where: { $0 != "0" }) else { throw loginError }
        return MusicAccountProfile(id: id.value, displayName: profile.nickname?.nonempty ?? "网易云用户")
    }

    func search(_ query: String, cookies: [MusicSessionCookie]) async throws -> [Track] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let response: NESearchResponse = try await request("cloudsearch/pc", payload: ["s": term, "type": 1, "limit": 50, "offset": 0, "total": true], cookies: cookies)
        guard let result = response.result, let songs = result.songs ?? (result.songCount == 0 ? [] : nil) else {
            throw MusicError.message("网易云搜索响应已变化，请稍后重试")
        }
        return songs.map(\.track)
    }

    func playlists(profile: MusicAccountProfile, cookies: [MusicSessionCookie]) async throws -> [RemoteMusicPlaylist] {
        try requireID(profile.id)
        var result: [RemoteMusicPlaylist] = [], seen = Set<String>(), offset = 0
        let pageSize = 100
        while offset < 10000 {
            try Task.checkCancellation()
            let response: NEPlaylistsResponse = try await request("user/playlist", payload: ["uid": profile.id, "limit": pageSize, "offset": offset, "includeVideo": false], cookies: cookies)
            guard let values = response.playlist else { throw MusicError.message("网易云未返回歌单列表，请重新登录后重试") }
            let before = result.count
            for playlist in values where seen.insert(playlist.id.value).inserted {
                result.append(RemoteMusicPlaylist(id: playlist.id.value, name: playlist.name?.nonempty ?? "未命名歌单", trackCount: max(0, playlist.trackCount ?? 0), artworkURL: Self.artworkURL(playlist.coverImgUrl), source: .netease))
            }
            if response.more == false || (response.more == nil && values.count < pageSize) { return result }
            guard !values.isEmpty, result.count > before else { throw MusicError.message("网易云歌单分页未继续，未将部分列表视为完整结果") }
            offset += values.count
        }
        throw MusicError.message("网易云歌单列表超过本次读取上限，未导入不完整结果")
    }

    func tracks(in playlist: RemoteMusicPlaylist, cookies: [MusicSessionCookie]) async throws -> [Track] {
        guard playlist.source == .netease else { throw MusicError.message("该歌单不是网易云歌单") }
        try requireID(playlist.id)
        let response: NEPlaylistResponse = try await request("v6/playlist/detail", payload: ["id": playlist.id, "n": 100000, "s": 0], cookies: cookies)
        guard let detail = response.playlist else { throw MusicError.message("无法读取网易云歌单，请检查登录状态或歌单权限") }
        let expected = max(0, detail.trackCount ?? playlist.trackCount)
        guard let items = detail.trackIds ?? (expected == 0 ? [] : nil), items.count >= expected else {
            throw MusicError.message("网易云未返回完整歌单曲目，请重新登录后重试")
        }
        guard items.count <= 10000 else { throw MusicError.message("歌单超过 10000 首，本次未导入；请拆分歌单后重试") }
        let orderedIDs = items.map { $0.id.value }
        var songsByID = Dictionary((detail.tracks ?? []).map { ($0.id.value, $0.track) }, uniquingKeysWith: { first, _ in first })
        for offset in stride(from: 0, to: orderedIDs.count, by: 200) {
            try Task.checkCancellation()
            let ids = Array(orderedIDs[offset..<min(offset + 200, orderedIDs.count)])
            let descriptors = ids.map { ["id": $0] }
            let c = try JSONSerialization.data(withJSONObject: descriptors, options: [.sortedKeys])
            let result: NESongsResponse = try await request("v3/song/detail", payload: ["c": String(decoding: c, as: UTF8.self)], cookies: cookies)
            guard let songs = result.songs else { throw MusicError.message("网易云曲目读取中断，未导入不完整歌单") }
            for song in songs { songsByID[song.id.value] = song.track }
        }
        return orderedIDs.map { id in
            songsByID[id] ?? Track(id: "netease:\(id)", title: "暂不可用的歌曲", artist: "未知艺术家", album: playlist.name, duration: 0, source: .netease, sourceID: id, unavailable: true)
        }
    }

    func resolve(_ track: Track, cookies: [MusicSessionCookie]) async throws -> URL {
        guard track.source == .netease, let id = track.sourceID else { throw MusicError.message("歌曲缺少网易云标识") }
        try requireID(id)
        let response: NEURLsResponse = try await request("song/enhance/player/url/v1", payload: ["ids": "[\(id)]", "level": "standard", "encodeType": "aac"], cookies: cookies)
        guard let items = response.data else {
            throw MusicError.message("网易云播放地址响应缺少歌曲列表（阶段：获取播放地址；接口码：200）")
        }
        guard let item = items.first(where: { $0.id.value == id }) else {
            throw MusicError.message("网易云未返回所选歌曲的播放结果（阶段：获取播放地址；接口码：200）")
        }
        // The website accepts a successful envelope and URL without requiring item.code.
        // An explicitly unsuccessful item code must still never become playable.
        if let code = item.code, code != 200 {
            throw try await playbackFailure("网易云拒绝提供这首歌的播放地址", item: item, id: id, cookies: cookies)
        }
        switch item.trial {
        case .preview:
            throw MusicError.message("网易云仅返回试听片段，未提供完整播放（\(item.diagnostic)）；本应用不播放试听替代完整歌曲")
        case .unknown:
            throw MusicError.message("网易云返回的试听标记格式已变化，无法确认完整播放，已停止播放（\(item.diagnostic)）")
        case .absent: break
        }
        guard let address = item.url?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else {
            throw try await playbackFailure("网易云返回的播放地址为空", item: item, id: id, cookies: cookies)
        }
        guard let url = Self.mediaURL(address) else {
            throw MusicError.message("网易云返回的播放地址格式无效或不属于已允许的官方音频域名，已停止播放（\(item.diagnostic)）")
        }
        return url
    }

    func lyrics(_ track: Track, cookies: [MusicSessionCookie]) async throws -> LyricsPayload? {
        guard track.source == .netease, let id = track.sourceID else { throw MusicError.message("歌曲缺少网易云标识，无法读取歌词。") }
        try requireID(id)
        let response: NELyricsResponse = try await request("song/lyric", payload: ["id": id, "lv": -1, "tv": -1, "rv": -1, "kv": -1], cookies: cookies, phase: "读取歌词")
        if response.nolyric == true { return .init(text: "", isInstrumental: true) }
        guard let text = response.lrc?.lyric, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard text.utf8.count <= LyricsParser.maximumBytes, (response.tlyric?.lyric?.utf8.count ?? 0) <= LyricsParser.maximumBytes else {
            throw MusicError.message("网易云返回的歌词过大，未加载。")
        }
        return .init(text: text, translation: response.tlyric?.lyric)
    }

    /// A failed URL response is not evidence of a subscription, removal, or region issue.
    /// Ask once for account-specific rights; never replace the URL with another source.
    private func playbackFailure(_ reason: String, item: NEURLsResponse.Item, id: String, cookies: [MusicSessionCookie]) async throws -> MusicError {
        let base = "\(reason)（\(item.diagnostic)）"
        do {
            let descriptors = try JSONSerialization.data(withJSONObject: [["id": id]], options: [.sortedKeys])
            let response: NESongsResponse = try await request("v3/song/detail", payload: ["c": String(decoding: descriptors, as: UTF8.self)], cookies: cookies, phase: "核对歌曲权限", timeout: 5)
            guard let privilege = response.privileges?.first(where: { $0.id.value == id }) else {
                return .message("\(base)。平台未提供可核对的权限详情，无法确定具体原因")
            }
            return .message("\(base)。\(privilege.explanation)（\(privilege.diagnostic)）")
        } catch is CancellationError { throw CancellationError() }
        catch {
            return .message("\(base)。补充权限查询未完成，无法确定具体原因")
        }
    }

    private var loginError: MusicError { .message("网易云尚未登录或登录已失效，请在应用内重新登录") }
    private func requireID(_ id: String) throws {
        guard !id.isEmpty, id.count <= 20, id.utf8.allSatisfy({ (48...57).contains($0) }), id.contains(where: { $0 != "0" }) else {
            throw MusicError.message("网易云资源标识无效")
        }
    }
    private func request<T: Decodable>(_ route: String, payload: [String: Any], cookies: [MusicSessionCookie], phase: String? = nil, timeout: TimeInterval = 15) async throws -> T {
        try Task.checkCancellation()
        let phase = phase ?? Self.phase(for: route)
        let url = URL(string: "https://music.163.com/weapi/\(route)")!
        let matching = DirectMusicAccess.requestCookies(cookies, for: .netease, url: url)
        guard matching.contains(where: { $0.name == "MUSIC_U" && !$0.value.isEmpty }) else {
            throw MusicError.message("\(loginError.localizedDescription)（阶段：\(phase)）")
        }
        let json = try Self.requestPayload(payload, matchingCookies: matching)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try NeteaseWebCrypto.encrypt(json).formData
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/26.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let data: Data
        do { data = try await http.data(for: request, source: .netease, cookies: cookies) }
        catch is CancellationError { throw CancellationError() }
        catch { throw MusicError.message("\(error.localizedDescription)（阶段：\(phase)）") }
        let decoder = JSONDecoder()
        guard let status = try? decoder.decode(NEStatus.self, from: data) else {
            throw MusicError.message("网易云返回了无法识别的响应（阶段：\(phase)），请在官网确认登录或验证提示")
        }
        guard status.code == 200 else {
            let diagnostic = "阶段：\(phase)；接口码：\(status.code)"
            if [301, 302, 401].contains(status.code) { throw MusicError.message("\(loginError.localizedDescription)（\(diagnostic)）") }
            if status.code == 429 { throw MusicError.message("网易云请求过于频繁，请稍后重试（\(diagnostic)）") }
            throw MusicError.message("网易云拒绝了请求（\(diagnostic)），平台未提供可确认的具体原因")
        }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw MusicError.message("网易云响应格式已变化（阶段：\(phase)；接口码：200），请稍后重试") }
    }
    static func requestPayload(_ payload: [String: Any], matchingCookies: [MusicSessionCookie]) throws -> Data {
        var payload = payload
        payload["csrf_token"] = matchingCookies.first(where: { $0.name == "__csrf" })?.value ?? ""
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func phase(for route: String) -> String {
        switch route {
        case "w/nuser/account/get": "确认登录身份"
        case "cloudsearch/pc": "搜索歌曲"
        case "user/playlist": "读取歌单列表"
        case "v6/playlist/detail": "读取歌单曲目"
        case "v3/song/detail": "读取歌曲资料"
        case "song/enhance/player/url/v1": "获取播放地址"
        default: "读取平台数据"
        }
    }
    private static func artworkURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return nil }
        return url
    }
    private static func mediaURL(_ value: String) -> URL? {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, let host = url.host?.lowercased(),
              ["music.126.net", "music.163.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if url.scheme?.lowercased() == "http" {
            components.scheme = "https"
            if components.port == 80 { components.port = nil }
        }
        guard components.port == nil || components.port == 443 else { return nil }
        return components.url
    }
}

private struct NEID: Decodable {
    let value: String
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self), !string.isEmpty,
           string.utf8.allSatisfy({ (48...57).contains($0) }) { value = string }
        else { value = String(try container.decode(UInt64.self)) }
    }
}
private struct NEStatus: Decodable { var code: Int }
private struct NELyricsResponse: Decodable {
    var nolyric: Bool?
    var lrc: Text?
    var tlyric: Text?
    struct Text: Decodable { var lyric: String? }
}
private struct NEProfileResponse: Decodable {
    var profile: Profile?
    struct Profile: Decodable { var userId: NEID?; var nickname: String? }
}
private struct NESearchResponse: Decodable {
    var result: Result?
    struct Result: Decodable { var songs: [NESong]?; var songCount: Int? }
}
private struct NEPlaylistsResponse: Decodable { var playlist: [NEPlaylist]?; var more: Bool? }
private struct NEPlaylistResponse: Decodable { var playlist: NEPlaylist? }
private struct NEPlaylist: Decodable {
    var id: NEID; var name: String?; var trackCount: Int?; var coverImgUrl: String?
    var trackIds: [TrackID]?; var tracks: [NESong]?
    struct TrackID: Decodable { var id: NEID }
}
private struct NESongsResponse: Decodable { var songs: [NESong]?; var privileges: [NEPrivilege]? }
private struct NEPrivilege: Decodable {
    var id: NEID; var st: Int?; var pl: Int?; var fee: Int?; var payed: Int?; var flag: Int?; var dl: Int?
    var explanation: String {
        if let pl, pl <= 0, (fee.map { $0 > 63 } ?? false) || (flag.map { $0 > 4095 } ?? false) {
            return "平台返回特殊播放限制，未说明具体原因"
        }
        if let st, st < 0 { return "平台将这首歌标记为当前不可用；此标记不能单独区分下架或地区限制" }
        if let fee, fee > 0, fee != 8, payed == 0, let pl, pl <= 0 {
            return "平台权限资料显示当前账户没有这首歌的付费播放权限"
        }
        if fee == 16 || (fee == 4 && ((flag ?? 0) & 2048) != 0) {
            return "平台标记这首歌需要下载后播放，请使用官方客户端；本应用未提供下载播放"
        }
        if let pl, pl > 0 { return "权限资料显示可播放，但地址接口未提供完整播放地址" }
        if pl == 0, dl == 0 { return "平台权限资料标记这首歌当前不可播放，未说明具体原因" }
        return "平台未提供足够信息，无法确定具体原因"
    }
    var diagnostic: String {
        [("st", st), ("pl", pl), ("fee", fee), ("payed", payed), ("flag", flag)]
            .compactMap { name, value in value.map { "\(name)=\($0)" } }.joined(separator: "，").nonempty ?? "权限字段缺失"
    }
}
private struct NESong: Decodable {
    var id: NEID; var name: String?; var ar: [Artist]?; var artists: [Artist]?; var al: Album?; var album: Album?; var dt: Double?; var duration: Double?
    struct Artist: Decodable { var name: String? }
    struct Album: Decodable { var name: String?; var picUrl: String? }
    var track: Track {
        let image = (al?.picUrl ?? album?.picUrl).flatMap(URL.init(string:)).flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        let seconds = (dt ?? duration ?? 0) / 1000
        return Track(id: "netease:\(id.value)", title: name?.nonempty ?? "未命名歌曲", artist: (ar ?? artists ?? []).compactMap(\.name).joined(separator: " / ").nonempty ?? "未知艺术家", album: al?.name ?? album?.name ?? "未知专辑", duration: seconds.isFinite ? max(0, seconds) : 0, source: .netease, sourceID: id.value, artworkURL: image)
    }
}
private struct NEURLsResponse: Decodable {
    var data: [Item]?
    struct Item: Decodable {
        enum Trial { case absent, preview, unknown }
        private struct Preview: Decodable { let start: Double; let end: Double }
        var id: NEID; var code: Int?; var url: String?; var trial: Trial; var fee: Int?
        var diagnostic: String {
            "阶段：获取播放地址；接口码：200；歌曲码：\(code.map(String.init) ?? "未提供")" + (fee.map { "；fee=\($0)" } ?? "")
        }
        enum CodingKeys: String, CodingKey { case id, code, url, freeTrialInfo, fee }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(NEID.self, forKey: .id)
            code = try container.decodeIfPresent(Int.self, forKey: .code)
            url = try container.decodeIfPresent(String.self, forKey: .url)
            fee = try container.decodeIfPresent(Int.self, forKey: .fee)
            if !container.contains(.freeTrialInfo) {
                trial = .absent
            } else if try container.decodeNil(forKey: .freeTrialInfo) {
                trial = .absent
            } else if let info = try? container.decode(Preview.self, forKey: .freeTrialInfo),
                      info.start.isFinite, info.end.isFinite, info.start >= 0, info.end > info.start {
                trial = .preview
            } else {
                trial = .unknown
            }
        }
    }
}
private extension String { var nonempty: String? { isEmpty ? nil : self } }
