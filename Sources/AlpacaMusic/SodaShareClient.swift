import Foundation

struct SodaShareImport: Sendable {
    var tracks: [Track]
    var playlistName: String? = nil
    var playlistID: String? = nil
}

/// Reads the same public share metadata as the official browser page. It never
/// uses account cookies, application signatures, or encrypted media keys.
struct SodaShareClient: Sendable {
    private let http: NativeMusicHTTP
    private let publicHTTP: SodaPublicHTTP
    init(http: NativeMusicHTTP = NativeMusicHTTP(), transport: NativeMusicHTTP.Transport? = nil) {
        self.http = http; self.publicHTTP = SodaPublicHTTP(transport: transport)
    }

    func importShare(_ input: String) async throws -> SodaShareImport {
        try Task.checkCancellation()
        let reference = try Self.reference(input)
        switch reference {
        case .track(let id):
            let song = try await song(id)
            return .init(tracks: [song.libraryTrack])
        case .playlist(let id):
            let page = try await playlist(id)
            return .init(tracks: page.tracks, playlistName: page.name, playlistID: id)
        case .url(let url):
            let (data, finalURL) = try await publicHTTP.fetch(url)
            if case .url = try Self.reference(finalURL.absoluteString) {
                let router = try Self.routerData(data)
                if let loader = Self.loader(router, name: "playlist_page"), let info = loader["playlistInfo"] as? [String: Any], let id = SodaJSON.identifier(info["id"]) {
                    let page = try await playlist(id)
                    return .init(tracks: page.tracks, playlistName: page.name, playlistID: id)
                }
                let song = try Self.song(router: router, expectedID: nil)
                return .init(tracks: [song.libraryTrack])
            }
            return try await importShare(finalURL.absoluteString)
        }
    }

    func preparePlayback(_ track: Track, cookies: [MusicSessionCookie] = []) async throws -> Track {
        guard track.source == .soda, let id = track.sourceID, SodaJSON.validID(id) else { throw MusicError.message("歌曲缺少有效的汽水音乐标识") }
        let song = try await song(id)
        guard !song.encrypted else { throw MusicError.message("汽水音乐官方页面返回了受保护的加密音频，本应用无法直接播放；请在汽水音乐中播放") }
        guard let url = song.mediaURL else { throw MusicError.message("汽水音乐官方页面未提供可直接播放的音频，请在汽水音乐中确认歌曲权限") }
        guard let range = song.range else { throw MusicError.message("汽水音乐未提供可确认的播放片段范围，已停止播放以避免歌词和音频错位") }
        var result = track
        result.title = song.libraryTrack.title; result.artist = song.libraryTrack.artist; result.album = song.libraryTrack.album
        result.artworkURL = song.libraryTrack.artworkURL ?? track.artworkURL
        result.duration = range.duration; result.sodaPlayback = range; result.url = url; result.unavailable = false
        return result
    }

    func song(_ id: String) async throws -> SodaShareSong {
        guard SodaJSON.validID(id) else { throw MusicError.message("汽水音乐歌曲标识无效") }
        let url = URL(string: "https://music.douyin.com/qishui/share/track?track_id=\(id)")!
        let (data, _) = try await publicHTTP.fetch(url)
        return try Self.song(router: Self.routerData(data), expectedID: id)
    }

    func playlist(_ id: String, cookies: [MusicSessionCookie] = []) async throws -> SodaSharePlaylist {
        guard SodaJSON.validID(id) else { throw MusicError.message("汽水音乐歌单标识无效") }
        var result: [Track] = [], seen = Set<String>(), cursor = "0", visited = Set<String>()
        var name = "汽水音乐歌单", expected: Int?
        for _ in 0..<500 {
            try Task.checkCancellation()
            guard visited.insert(cursor).inserted else { throw MusicError.message("汽水音乐歌单分页重复，未导入不完整结果") }
            let data = try await api("/luna/pc/playlist/detail", query: ["playlist_id": id, "cursor": cursor, "cnt": "50"], cookies: cookies)
            let object = try SodaJSON.object(data, phase: "读取公开歌单")
            guard let info = object["playlist"] as? [String: Any], SodaJSON.identifier(info["id"]) == id,
                  let count = SodaJSON.number(info["count_tracks"]), count >= 0, count <= 10_000, count.rounded() == count else {
                throw MusicError.message("汽水音乐未返回可核对的歌单身份和总曲数，未导入不完整结果")
            }
            let total = Int(count)
            if let expected, expected != total { throw MusicError.message("汽水音乐歌单在读取时发生变化，请重新导入") }
            expected = total; name = SodaJSON.string(info["title"]) ?? name
            let items = object["media_resources"] as? [[String: Any]] ?? []
            let before = result.count
            for item in items {
                guard SodaJSON.string(item["type"]) == "track",
                      let entity = item["entity"] as? [String: Any], let wrapper = entity["track_wrapper"] as? [String: Any],
                      let raw = wrapper["track"] as? [String: Any] else { continue }
                let track = try SodaJSON.track(raw)
                if seen.insert(track.id).inserted { result.append(track) }
            }
            guard result.count <= 10_000 else { throw MusicError.message("汽水音乐歌单超过 10000 首，本次未导入") }
            if result.count == total { return .init(name: name, tracks: result) }
            guard result.count < total, result.count > before, let next = SodaJSON.string(object["next_cursor"]), next != cursor else {
                throw MusicError.message("汽水音乐歌单仅返回 \(result.count) / \(total) 首，未导入不完整结果")
            }
            cursor = next
        }
        throw MusicError.message("汽水音乐歌单分页超过读取上限，未导入不完整结果")
    }

    func api(_ path: String, query: [String: String], cookies: [MusicSessionCookie]) async throws -> Data {
        var components = URLComponents(string: "https://api.qishui.com\(path)")!
        var query = query; query["aid"] = "386088"; query["device_platform"] = "web"; query["channel"] = "pc_web"
        components.queryItems = query.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue(SodaPublicHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        return try await http.data(for: request, source: .soda, cookies: cookies)
    }

    enum Reference: Equatable { case track(String), playlist(String), url(URL) }
    static func reference(_ input: String) throws -> Reference {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.utf8.count <= 16384 else { throw MusicError.message("汽水音乐分享内容过长") }
        if SodaJSON.validID(input) { return .track(input) }
        let pattern = #"https://[^\s<>\"，。]+"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let range = Range(match.range, in: input), let url = URL(string: String(input[range]).trimmingCharacters(in: CharacterSet(charactersIn: ")）]】"))), SodaPublicHTTP.allowed(url) else {
            throw MusicError.message("请输入汽水音乐官方的歌曲或歌单分享链接")
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queries = components?.queryItems ?? []
        let playlist = queries.first { ["playlist_id", "playlistId"].contains($0.name) }?.value
        let track = queries.first { $0.name == "track_id" }?.value
        guard !(playlist != nil && track != nil) else { throw MusicError.message("汽水音乐分享链接同时包含歌曲和歌单标识，无法确定导入对象") }
        if let playlist { guard SodaJSON.validID(playlist) else { throw MusicError.message("汽水音乐歌单标识无效") }; return .playlist(playlist) }
        if let track { guard SodaJSON.validID(track) else { throw MusicError.message("汽水音乐歌曲标识无效") }; return .track(track) }
        let path = url.path.split(separator: "/").map(String.init)
        if let i = path.firstIndex(where: { ["track", "song", "playlist", "list"].contains($0) }), i + 1 < path.count, SodaJSON.validID(path[i + 1]) {
            return ["playlist", "list"].contains(path[i]) ? .playlist(path[i + 1]) : .track(path[i + 1])
        }
        guard url.path.hasPrefix("/s/") || url.path.hasPrefix("/qishui/share/") else { throw MusicError.message("该链接不是汽水音乐歌曲或歌单分享地址") }
        return .url(url)
    }

    static func routerData(_ data: Data) throws -> [String: Any] {
        guard data.count <= SodaPublicHTTP.maximumBytes, let text = String(data: data, encoding: .utf8), let marker = text.range(of: "_ROUTER_DATA"),
              let start = text[marker.upperBound...].firstIndex(of: "{") else { throw MusicError.message("汽水音乐分享页面未返回歌曲或歌单数据") }
        var depth = 0, quoted = false, escaped = false
        for index in text.indices where index >= start {
            let char = text[index]
            if quoted {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { quoted = false }
            } else if char == "\"" { quoted = true }
            else if char == "{" { depth += 1 }
            else if char == "}" {
                depth -= 1
                if depth == 0 {
                    let raw = Data(text[start...index].utf8)
                    guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { break }
                    return object
                }
            }
        }
        throw MusicError.message("汽水音乐分享页面数据格式已变化，无法读取")
    }
    static func loader(_ router: [String: Any], name: String) -> [String: Any]? {
        let data = router["loaderData"] as? [String: Any] ?? [:]
        if let named = data[name] as? [String: Any] { return named }
        return data.values.compactMap { $0 as? [String: Any] }.first { $0["audioWithLyricsOption"] != nil }
    }
    static func song(router: [String: Any], expectedID: String?) throws -> SodaShareSong {
        guard let loader = loader(router, name: "track_page"), let option = loader["audioWithLyricsOption"] as? [String: Any],
              let rawTrack = option["trackInfo"] as? [String: Any] else { throw MusicError.message("汽水音乐分享页面没有返回所选歌曲") }
        var track = try SodaJSON.track(rawTrack)
        guard let id = track.sourceID, expectedID.map({ $0 == id }) ?? true,
              SodaJSON.identifier(option["track_id"]).map({ $0 == id }) ?? true else { throw MusicError.message("汽水音乐返回的歌曲身份与所选歌曲不一致，已停止播放") }
        if let status = SodaJSON.number(option["status_code"]), status != 0 { throw MusicError.message("汽水音乐官方分享页面拒绝歌曲访问（接口码 \(SodaJSON.statusCode(status))）") }
        guard let encryptedFlag = option["encrypt"] as? Bool else { throw MusicError.message("汽水音乐分享页面未提供可确认的音频保护状态，已停止读取播放地址") }
        let encrypted = encryptedFlag || !(SodaJSON.string(option["kid"]) ?? "").isEmpty
        let mediaURL = SodaJSON.mediaURL(SodaJSON.string(option["url"]))
        let full = SodaJSON.number(option["duration"]) ?? track.duration
        var range: SodaPlaybackRange?
        if let start = SodaJSON.number(option["offsetStart"]), let duration = SodaJSON.number(option["offsetDuration"]),
           full.isFinite, full > 0, full <= 86400, start.isFinite, start >= 0, duration.isFinite, duration > 0, start + duration <= full + 1 {
            range = .init(fullDuration: full, start: start, duration: duration, isPreview: start > 0.05 || duration + 1 < full)
        }
        let lyricObject = option["lyrics"] as? [String: Any] ?? [:]
        let rawSentences = lyricObject["sentences"] as? [[String: Any]] ?? []
        guard rawSentences.count <= LyricsParser.maximumLines else { throw MusicError.message("汽水音乐返回的歌词行数过多") }
        var sentences: [SodaLyricSentence] = [], bytes = 0, wordCount = 0
        for sentence in rawSentences {
            guard let start = SodaJSON.number(sentence["startMs"]), let end = SodaJSON.number(sentence["endMs"]), start >= 0, end > start, end <= 86_400_000 else { continue }
            let rawWords = sentence["words"] as? [[String: Any]] ?? []
            var words: [SodaLyricWord] = []
            for word in rawWords {
                guard let text = SodaJSON.string(word["text"]), let ws = SodaJSON.number(word["startMs"]), let we = SodaJSON.number(word["endMs"]), ws >= start, we > ws, we <= end + 1 else { continue }
                words.append(.init(text: text, start: ws / 1000, end: we / 1000)); bytes += text.utf8.count; wordCount += 1
            }
            let text = SodaJSON.string(sentence["text"]) ?? words.map(\.text).joined()
            bytes += text.utf8.count
            guard bytes <= LyricsParser.maximumBytes, text.utf8.count <= 32768, wordCount <= 100_000 else { throw MusicError.message("汽水音乐返回的歌词过大") }
            if !text.isEmpty { sentences.append(.init(text: text, start: start / 1000, end: end / 1000, words: words)) }
        }
        if let range, !encrypted, mediaURL != nil {
            track.sodaPlayback = range; track.duration = range.duration
        }
        return .init(libraryTrack: track, range: range, mediaURL: mediaURL, encrypted: encrypted, sentences: sentences)
    }
}

struct SodaSharePlaylist: Sendable { var name: String; var tracks: [Track] }
struct SodaLyricWord: Sendable { var text: String; var start: Double; var end: Double }
struct SodaLyricSentence: Sendable { var text: String; var start: Double; var end: Double; var words: [SodaLyricWord] }
struct SodaShareSong: Sendable {
    var libraryTrack: Track
    var range: SodaPlaybackRange?
    var mediaURL: URL?
    var encrypted: Bool
    var sentences: [SodaLyricSentence]
}

enum SodaJSON {
    static func validID(_ id: String) -> Bool { (10...20).contains(id.utf8.count) && id.utf8.allSatisfy { (48...57).contains($0) } && id.contains { $0 != "0" } }
    static func identifier(_ value: Any?) -> String? {
        guard let text = string(value), validID(text) else { return nil }; return text
    }
    static func string(_ value: Any?) -> String? {
        let result = (value as? String) ?? (value as? NSNumber)?.stringValue
        return result.flatMap { $0.isEmpty ? nil : $0 }
    }
    static func number(_ value: Any?) -> Double? {
        let result = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return result.flatMap { $0.isFinite ? $0 : nil }
    }
    static func statusCode(_ value: Double) -> String {
        value.isFinite && abs(value) <= 1_000_000 ? String(Int(value)) : "未知"
    }
    static func object(_ data: Data, phase: String) throws -> [String: Any] {
        guard !data.isEmpty else { throw MusicError.message("汽水音乐网页接口返回空响应（阶段：\(phase)；HTTP 200）；当前接口可能要求平台应用签名或访问验证，无法完成此操作") }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MusicError.message("汽水音乐返回了无法识别的响应（阶段：\(phase)）") }
        let statusInfo = object["status_info"] as? [String: Any] ?? [:]
        let code = number(object["status_code"]) ?? number(statusInfo["status_code"]) ?? 0
        guard code == 0 else { throw MusicError.message("汽水音乐拒绝请求（阶段：\(phase)；接口码 \(statusCode(code))）；请在官方页面确认登录或访问权限") }
        return object
    }
    static func track(_ raw: [String: Any]) throws -> Track {
        guard let id = identifier(raw["id"]), let title = string(raw["name"]), title.utf8.count <= 8192, let ms = number(raw["duration"]), ms >= 0, ms <= 86_400_000 else { throw MusicError.message("汽水音乐曲目资料缺少有效的标识、歌名或时长") }
        let artists = raw["artists"] as? [[String: Any]] ?? []
        let names = artists.compactMap { string($0["name"]) ?? string(($0["user_info"] as? [String: Any])?["nickname"]) }
        let album = raw["album"] as? [String: Any] ?? [:]
        return .init(id: "soda:\(id)", title: title, artist: names.isEmpty ? "未知艺术家" : names.joined(separator: " / "), album: string(album["name"]) ?? "", duration: ms / 1000, source: .soda, sourceID: id, artworkURL: artwork(album["url_cover"]), format: "AAC")
    }
    static func artwork(_ value: Any?) -> URL? {
        guard let raw = value as? [String: Any], let urls = raw["urls"] as? [String], let first = urls.first,
              var url = URL(string: first), url.scheme == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), host == "douyinpic.com" || host.hasSuffix(".douyinpic.com") else { return nil }
        if url.hasDirectoryPath, let uri = string(raw["uri"]) {
            let suffix = string(raw["template_prefix"]).map { "~\($0)-resize:960:960.png" } ?? "~c5_300x300.jpg"
            guard !uri.contains(".."), let joined = URL(string: first + uri + suffix) else { return nil }; url = joined
        }
        return url
    }
    static func mediaURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), host == "douyinvod.com" || host.hasSuffix(".douyinvod.com"), url.fragment == nil else { return nil }
        return url
    }
}

private struct SodaPublicHTTP: Sendable {
    static let maximumBytes = 8 * 1024 * 1024
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/26.0 Safari/605.1.15"
    private let transport: NativeMusicHTTP.Transport
    init(transport: NativeMusicHTTP.Transport? = nil) {
        self.transport = transport ?? { request in
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 25
            let session = URLSession(configuration: config, delegate: SodaNoRedirect(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.expectedContentLength <= Self.maximumBytes else { throw MusicError.message("汽水音乐分享页面响应无效或过大") }
            var data = Data()
            for try await byte in bytes { guard data.count < Self.maximumBytes else { throw MusicError.message("汽水音乐分享页面超过 8 MB") }; data.append(byte) }
            return (data, response)
        }
    }
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["music.douyin.com", "qishui.douyin.com", "qishui.com", "www.qishui.com"].contains(host)
    }
    func fetch(_ initialURL: URL) async throws -> (Data, URL) {
        var url = initialURL
        for _ in 0..<6 {
            try Task.checkCancellation()
            guard Self.allowed(url) else { throw MusicError.message("已阻止非汽水音乐官方分享地址") }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpShouldHandleCookies = false; request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            let data: Data, response: HTTPURLResponse
            do { (data, response) = try await transport(request) }
            catch is CancellationError { throw CancellationError() }
            catch let error as URLError { if error.code == .cancelled { throw CancellationError() }; throw MusicError.message("汽水音乐分享页面连接失败（网络错误 \(error.code.rawValue)）") }
            catch let error as MusicError { throw error }
            catch { throw MusicError.message("汽水音乐分享页面连接失败，请重试") }
            try Task.checkCancellation()
            guard data.count <= Self.maximumBytes, response.url?.host?.lowercased() == url.host?.lowercased() else { throw MusicError.message("汽水音乐分享页面响应过大或偏离原请求地址") }
            if (300..<400).contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location"), let next = URL(string: location, relativeTo: url)?.absoluteURL {
                guard Self.allowed(next) else { throw MusicError.message("汽水音乐分享链接跳转到了未允许的地址，已停止连接") }; url = next; continue
            }
            guard (200..<300).contains(response.statusCode) else { throw MusicError.message("汽水音乐分享页面无法访问（HTTP \(response.statusCode)）") }
            return (data, url)
        }
        throw MusicError.message("汽水音乐分享链接跳转次数过多")
    }
}
private final class SodaNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
}
