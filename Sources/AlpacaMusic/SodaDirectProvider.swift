import Foundation

/// Native public website requests; unavailable private operations report the
/// actual response boundary instead of guessing an account or a full stream.
struct SodaDirectProvider: DirectMusicProvider {
    let source: MusicSource = .soda
    private let http: NativeMusicHTTP
    private let share: SodaShareClient
    init(http: NativeMusicHTTP = NativeMusicHTTP(), share: SodaShareClient? = nil) {
        self.http = http; self.share = share ?? SodaShareClient(http: http)
    }

    func profile(cookies: [MusicSessionCookie]) async throws -> MusicAccountProfile {
        let url = URL(string: "https://api.qishui.com/luna/pc/me")!
        guard DirectMusicAccess.requestCookies(cookies, for: .soda, url: url).contains(where: { ["sessionid", "sessionid_ss"].contains($0.name) && !$0.value.isEmpty }) else {
            throw MusicError.message(L10n.string("汽水音乐尚未登录或登录已失效，请在官方页面完成登录"))
        }
        let data = try await share.api("/luna/pc/me", query: [:], cookies: cookies)
        let object = try SodaJSON.object(data, phase: L10n.string("确认登录身份"))
        guard let info = object["my_info"] as? [String: Any], let id = SodaJSON.identifier(info["id"]), let name = SodaJSON.string(info["nickname"]) else {
            throw MusicError.message(L10n.string("汽水音乐未返回已登录账号身份，尚不能确认连接成功；请在官方页面完成登录或验证"))
        }
        return .init(id: id, displayName: name)
    }

    func search(_ query: String, cookies: [MusicSessionCookie]) async throws -> [Track] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        guard term.utf8.count <= 1024 else { throw MusicError.message(L10n.string("汽水音乐搜索内容过长")) }
        var components = URLComponents(string: "https://api.qishui.com/luna/search/track")!
        components.queryItems = [.init(name: "q", value: term), .init(name: "cursor", value: "0"), .init(name: "count", value: "50"), .init(name: "aid", value: "386088")]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let data = try await http.data(for: request, source: .soda, cookies: cookies)
        let object = try SodaJSON.object(data, phase: L10n.string("搜索歌曲"))
        guard let groups = object["result_groups"] as? [[String: Any]] else { throw MusicError.message(L10n.string("汽水音乐搜索响应缺少结果分组，无法确认搜索结果")) }
        if groups.isEmpty { return [] }
        guard groups.contains(where: { SodaJSON.string($0["id"]) == "tracks" }) else { throw MusicError.message(L10n.string("汽水音乐搜索响应未返回歌曲分组，无法确认搜索结果")) }
        var tracks: [Track] = [], seen = Set<String>()
        for group in groups {
            // The public search endpoint puts metadata under data[].entity.track. Never
            // recursively choose unrelated recommendations as the requested hits.
            guard SodaJSON.string(group["id"]) == "tracks" else { continue }
            guard let results = group["data"] as? [[String: Any]] else { throw MusicError.message(L10n.string("汽水音乐搜索响应未返回歌曲列表，无法确认搜索结果")) }
            for result in results {
                let raw = (result["entity"] as? [String: Any])?["track"] as? [String: Any]
                guard let raw else { throw MusicError.message(L10n.string("汽水音乐搜索结果缺少歌曲资料，无法读取")) }
                let track = try SodaJSON.track(raw)
                if seen.insert(track.id).inserted { tracks.append(track) }
            }
        }
        return tracks
    }

    func playlists(profile expected: MusicAccountProfile, cookies: [MusicSessionCookie]) async throws -> [RemoteMusicPlaylist] {
        let current = try await profile(cookies: cookies)
        guard current.id == expected.id else { throw MusicError.message(L10n.string("汽水音乐当前登录账号已变化，请重新连接后导入")) }
        var result: [RemoteMusicPlaylist] = [], seen = Set<String>(), cursor = "0", visited = Set<String>()
        for _ in 0..<200 {
            try Task.checkCancellation()
            guard visited.insert(cursor).inserted else { throw MusicError.message(L10n.string("汽水音乐账号歌单分页重复，未将部分结果视为完整列表")) }
            let data = try await share.api("/luna/pc/me/playlist", query: ["cursor": cursor, "count": "50"], cookies: cookies)
            let object = try SodaJSON.object(data, phase: L10n.string("读取账号歌单"))
            guard let values = object["playlists"] as? [[String: Any]] else { throw MusicError.message(L10n.string("汽水音乐账号接口未返回歌单列表，无法确认曲库；请在官方页面确认账号权限")) }
            let before = result.count
            for value in values {
                guard let id = SodaJSON.identifier(value["id"]), let title = SodaJSON.string(value["title"]), let count = SodaJSON.number(value["count_tracks"]), count >= 0, count <= 100_000 else { throw MusicError.message(L10n.string("汽水音乐账号歌单资料不完整，未导入部分结果")) }
                if seen.insert(id).inserted { result.append(.init(id: id, name: title, trackCount: Int(count), artworkURL: SodaJSON.artwork(value["url_cover"]), source: .soda)) }
            }
            if object["has_more"] as? Bool == false || (object["has_more"] == nil && values.count < 50) { return result }
            guard result.count > before, let next = SodaJSON.string(object["next_cursor"]), next != cursor else { throw MusicError.message(L10n.string("汽水音乐账号歌单分页未继续，未导入不完整结果")) }
            cursor = next
        }
        throw MusicError.message(L10n.string("汽水音乐账号歌单超过读取上限，未导入不完整结果"))
    }

    func tracks(in playlist: RemoteMusicPlaylist, cookies: [MusicSessionCookie]) async throws -> [Track] {
        guard playlist.source == .soda else { throw MusicError.message(L10n.string("该歌单不是汽水音乐歌单")) }
        return try await share.playlist(playlist.id, cookies: cookies).tracks
    }

    func importShare(_ input: String) async throws -> SodaShareImport { try await share.importShare(input) }

    func preparePlayback(_ track: Track, cookies: [MusicSessionCookie]) async throws -> Track {
        try await share.preparePlayback(track, cookies: cookies)
    }

    func resolve(_ track: Track, cookies: [MusicSessionCookie]) async throws -> URL {
        guard let expected = track.sodaPlayback else { throw MusicError.message(L10n.string("汽水音乐播放范围尚未准备，请重新选择歌曲")) }
        let refreshed = try await preparePlayback(track, cookies: cookies)
        guard let actual = refreshed.sodaPlayback, Self.sameRange(expected, actual), let url = refreshed.url else {
            throw MusicError.message(L10n.string("汽水音乐官方播放片段范围已变化，请重新选择歌曲以同步音频和歌词"))
        }
        return url
    }

    func lyrics(_ track: Track, cookies: [MusicSessionCookie]) async throws -> LyricsPayload? {
        guard track.source == .soda, let id = track.sourceID, SodaJSON.validID(id) else { throw MusicError.message(L10n.string("歌曲缺少有效的汽水音乐标识，无法读取歌词")) }
        let song = try await share.song(id)
        if let expected = track.sodaPlayback, let actual = song.range, !Self.sameRange(expected, actual) {
            throw MusicError.message(L10n.string("汽水音乐官方播放片段范围已变化，暂不能同步歌词；请重新选择歌曲"))
        }
        let document = Self.lyricDocument(song.sentences, range: track.sodaPlayback, title: track.title, artist: track.artist)
        guard !document.lines.isEmpty else { return nil }
        return LyricsPayload(text: "", document: document)
    }

    static func sameRange(_ a: SodaPlaybackRange, _ b: SodaPlaybackRange) -> Bool {
        a.fullDuration.isFinite && a.start.isFinite && a.duration.isFinite && abs(a.fullDuration - b.fullDuration) < 0.01 && abs(a.start - b.start) < 0.01 && abs(a.duration - b.duration) < 0.01 && a.isPreview == b.isPreview
    }
    static func lyricDocument(_ sentences: [SodaLyricSentence], range: SodaPlaybackRange?, title: String, artist: String) -> LyricDocument {
        let offset = range?.start ?? 0, duration = range?.duration ?? 86400, limit = offset + duration
        var lines: [LyricLine] = []
        for sentence in sentences.sorted(by: { $0.start < $1.start }) where sentence.end > offset && sentence.start < limit {
            let start = max(0, sentence.start - offset), end = min(duration, sentence.end - offset)
            guard end > start else { continue }
            var words: [LyricWord] = []
            for word in sentence.words.sorted(by: { $0.start < $1.start }) where word.end > offset && word.start < limit {
                let ws = max(start, word.start - offset), we = min(end, word.end - offset)
                guard we > ws else { continue }
                words.append(.init(id: words.count, text: word.text, start: ws, end: we))
            }
            let text = words.isEmpty ? sentence.text : words.map(\.text).joined()
            lines.append(.init(id: lines.count, text: text, start: start, end: end, words: words))
        }
        return .init(lines: lines, timing: lines.contains { !$0.words.isEmpty } ? .word : .line, sourceDescription: L10n.string("汽水音乐"), title: title, artist: artist)
    }
}
