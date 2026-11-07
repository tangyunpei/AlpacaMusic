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
        return MusicAccountProfile(id: id.value, displayName: profile.nickname?.nonempty ?? L10n.string("网易云用户"))
    }

    func search(_ query: String, cookies: [MusicSessionCookie]) async throws -> [Track] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        let response: NESearchResponse = try await request("cloudsearch/pc", payload: ["s": term, "type": 1, "limit": 50, "offset": 0, "total": true], cookies: cookies)
        guard let result = response.result, let songs = result.songs ?? (result.songCount == 0 ? [] : nil) else {
            throw MusicError.message(L10n.string("网易云搜索响应已变化，请稍后重试"))
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
            guard let values = response.playlist else { throw MusicError.message(L10n.string("网易云未返回歌单列表，请重新登录后重试")) }
            let before = result.count
            for playlist in values where seen.insert(playlist.id.value).inserted {
                result.append(RemoteMusicPlaylist(id: playlist.id.value, name: playlist.name?.nonempty ?? L10n.string("未命名歌单"), trackCount: max(0, playlist.trackCount ?? 0), artworkURL: Self.artworkURL(playlist.coverImgUrl), source: .netease))
            }
            if response.more == false || (response.more == nil && values.count < pageSize) { return result }
            guard !values.isEmpty, result.count > before else { throw MusicError.message(L10n.string("网易云歌单分页未继续，未将部分列表视为完整结果")) }
            offset += values.count
        }
        throw MusicError.message(L10n.string("网易云歌单列表超过本次读取上限，未导入不完整结果"))
    }

    func tracks(in playlist: RemoteMusicPlaylist, cookies: [MusicSessionCookie]) async throws -> [Track] {
        try await tracks(in: playlist, cookies: cookies, progress: { _ in })
    }

    func tracks(in playlist: RemoteMusicPlaylist, cookies: [MusicSessionCookie],
                progress: @MainActor @Sendable (ImportProgress) -> Void) async throws -> [Track] {
        guard playlist.source == .netease else { throw MusicError.message(L10n.string("该歌单不是网易云歌单")) }
        try requireID(playlist.id)
        let response: NEPlaylistResponse = try await request("v6/playlist/detail", payload: ["id": playlist.id, "n": 100000, "s": 0], cookies: cookies)
        guard let detail = response.playlist else { throw MusicError.message(L10n.string("无法读取网易云歌单，请检查登录状态或歌单权限")) }
        let expected = max(0, detail.trackCount ?? playlist.trackCount)
        guard let items = detail.trackIds ?? (expected == 0 ? [] : nil), items.count >= expected else {
            throw MusicError.message(L10n.string("网易云未返回完整歌单曲目，请重新登录后重试"))
        }
        guard items.count <= 10000 else { throw MusicError.message(L10n.string("歌单超过 10000 首，本次未导入；请拆分歌单后重试")) }
        let orderedIDs = items.map { $0.id.value }
        var songsByID = Dictionary((detail.tracks ?? []).map { ($0.id.value, $0.track) }, uniquingKeysWith: { first, _ in first })
        await progress(ImportProgress(completed: 0, total: orderedIDs.count))
        for offset in stride(from: 0, to: orderedIDs.count, by: 200) {
            try Task.checkCancellation()
            let ids = Array(orderedIDs[offset..<min(offset + 200, orderedIDs.count)])
            let descriptors = ids.map { ["id": $0] }
            let c = try JSONSerialization.data(withJSONObject: descriptors, options: [.sortedKeys])
            let result: NESongsResponse = try await request("v3/song/detail", payload: ["c": String(decoding: c, as: UTF8.self)], cookies: cookies)
            guard let songs = result.songs else { throw MusicError.message(L10n.string("网易云曲目读取中断，未导入不完整歌单")) }
            for song in songs { songsByID[song.id.value] = song.track }
            await progress(ImportProgress(completed: offset + ids.count, total: orderedIDs.count))
        }
        return orderedIDs.map { id in
            songsByID[id] ?? Track(id: "netease:\(id)", title: L10n.string("暂不可用的歌曲"), artist: L10n.string("未知艺术家"), album: playlist.name, duration: 0, source: .netease, sourceID: id, unavailable: true)
        }
    }

    func albums(profile: MusicAccountProfile, cookies: [MusicSessionCookie]) async throws -> [RemoteMusicAlbum] {
        try requireID(profile.id)
        var result: [RemoteMusicAlbum] = [], seen = Set<String>(), offset = 0
        var expectedCount: Int?
        let pageSize = 100
        while true {
            try Task.checkCancellation()
            // The collection belongs to the logged-in account, not a supplied UID.
            let response: NEAlbumsResponse = try await request("album/sublist", payload: ["limit": pageSize, "offset": offset, "total": true], cookies: cookies)
            try Task.checkCancellation()
            guard let albums = response.data else {
                throw MusicError.message(L10n.string("网易云未返回收藏专辑列表，请重新登录后重试"))
            }
            if let count = response.count {
                guard count >= 0, expectedCount == nil || expectedCount == count else {
                    throw MusicError.message(L10n.string("网易云收藏专辑数量在读取时发生变化，请刷新后重试"))
                }
                expectedCount = count
            }
            for album in albums {
                try requireID(album.id.value)
                guard seen.insert(album.id.value).inserted else {
                    throw MusicError.message(L10n.string("网易云收藏专辑分页重复，未将部分列表视为完整结果"))
                }
                result.append(RemoteMusicAlbum(id: album.id.value,
                    name: album.name?.nonempty ?? L10n.string("未知专辑"),
                    artist: album.artistName,
                    trackCount: (album.songCount ?? album.size).flatMap { $0 >= 0 ? $0 : nil },
                    artworkURL: Self.artworkURL(album.picUrl), source: .netease))
            }
            let hasMore = response.hasMore ?? response.more
            if let expectedCount {
                guard result.count <= expectedCount,
                      hasMore != false || result.count == expectedCount,
                      hasMore != true || result.count < expectedCount else {
                    throw MusicError.message(L10n.string("网易云收藏专辑数量与分页结果不一致，请刷新后重试"))
                }
                if result.count == expectedCount { return result }
            } else if hasMore == false || (hasMore == nil && albums.count < pageSize) {
                return result
            }
            guard !albums.isEmpty else {
                throw MusicError.message(L10n.string("网易云收藏专辑分页未继续，未将部分列表视为完整结果"))
            }
            offset += albums.count
        }
    }

    func tracks(in album: RemoteMusicAlbum, cookies: [MusicSessionCookie]) async throws -> [Track] {
        guard album.source == .netease else { throw MusicError.message(L10n.string("该专辑不是网易云专辑")) }
        try requireID(album.id)
        let response: NEAlbumResponse = try await request("v1/album/\(album.id)", payload: [:], cookies: cookies, phase: L10n.string("读取专辑曲目"))
        try Task.checkCancellation()
        guard let detail = response.album, detail.id.value == album.id, let songs = response.songs else {
            throw MusicError.message(L10n.string("网易云未返回完整专辑资料，请刷新后重试"))
        }
        // Fresh album metadata wins over the collection's potentially stale count.
        // A missing song cannot be classified as deleted without an explicit item.
        if let expected = detail.size ?? detail.songCount ?? album.trackCount,
           expected < 0 || expected != songs.count {
            throw MusicError.message(L10n.string("网易云专辑标记有 \(String(expected)) 首，但返回 \(String(songs.count)) 首，无法确认完整曲目，本次未导入"))
        }
        let albumName = detail.name?.nonempty ?? album.name
        let albumArtist = detail.artistName.nonempty ?? album.artist
        let artwork = Self.artworkURL(detail.picUrl) ?? album.artworkURL
        var seen = Set<String>()
        return try songs.map { song in
            try Task.checkCancellation()
            try requireID(song.id.value)
            guard seen.insert(song.id.value).inserted else {
                throw MusicError.message(L10n.string("网易云专辑返回重复曲目，无法确认完整顺序，本次未导入"))
            }
            var track = song.track
            if (song.al?.name ?? song.album?.name)?.nonempty == nil { track.album = albumName }
            if (song.ar ?? song.artists ?? []).compactMap(\.name).joined().isEmpty, !albumArtist.isEmpty { track.artist = albumArtist }
            if track.artworkURL == nil { track.artworkURL = artwork }
            // Explicitly unavailable entries remain in their original album position.
            if (song.st ?? song.privilege?.st ?? 0) < 0 { track.unavailable = true }
            return track
        }
    }

    /// One request. Charts are playlists; links to web pages (`H5`, id 0) and
    /// charts repeated across groups are left out, in the platform's order.
    func charts(cookies: [MusicSessionCookie]) async throws -> [BrowseCollection] {
        let route = "toplist/detail/v2"
        let response: NEChartsResponse = try await request(route, payload: [:], cookies: cookies)
        var result: [BrowseCollection] = [], seen = Set<String>()
        for chart in response.data.compactMap(\.value).flatMap({ $0.list?.compactMap(\.value) ?? [] }) where result.count < 30 {
            guard chart.targetType == "PLAYLIST", let id = chart.id, isValidID(id), seen.insert(id).inserted else { continue }
            result.append(BrowseCollection(source: .netease, kind: .chart, remoteID: id,
                title: chart.name?.nonempty ?? L10n.string("未命名歌单"), caption: chart.updateFrequency ?? "",
                artworkURL: Self.coverURL(chart.coverUrl), preview: chart.preview))
        }
        // NetEase always lists charts; none readable means the format moved.
        guard !result.isEmpty else {
            throw MusicError.message(L10n.string("网易云响应格式已变化（阶段：\(Self.phase(for: route))；接口码：200），请稍后重试"))
        }
        return result
    }

    /// Recommended playlists and the daily songs load together. Either half
    /// may fail alone; only both failing is an error, and it is the playlists'.
    func recommendations(cookies: [MusicSessionCookie]) async throws -> BrowseRecommendations {
        async let playlists = Self.outcome { try await recommendedPlaylists(cookies: cookies) }
        async let songs = Self.outcome { try await dailySongs(cookies: cookies) }
        let (lists, picks) = await (playlists, songs)
        // A cancelled half never turns into a partial result.
        if case .failure(let error) = lists, error is CancellationError { throw CancellationError() }
        if case .failure(let error) = picks, error is CancellationError { throw CancellationError() }
        try Task.checkCancellation()
        if case .failure(let error) = lists, case .failure = picks { throw error }
        // A half that failed is reported, so the page says so and asks again
        // after the usual retry delay instead of keeping the gap for hours.
        var partial: String?
        if case .failure(let error) = lists { partial = error.localizedDescription }
        if case .failure(let error) = picks { partial = error.localizedDescription }
        return BrowseRecommendations(collections: (try? lists.get()) ?? [], songs: (try? picks.get()) ?? [], partialError: partial)
    }

    private func recommendedPlaylists(cookies: [MusicSessionCookie]) async throws -> [BrowseCollection] {
        let response: NEPersonalizedResponse = try await request("personalized/playlist", payload: Self.recommendedPlaylistsPayload(), cookies: cookies)
        var seen = Set<String>()
        return response.result.compactMap(\.value).compactMap { item in
            guard isValidID(item.id), seen.insert(item.id).inserted else { return nil }
            return BrowseCollection(source: .netease, kind: .playlist, remoteID: item.id,
                title: item.name?.nonempty ?? L10n.string("未命名歌单"), caption: item.copywriter ?? "",
                artworkURL: Self.coverURL(item.picUrl), trackCount: item.trackCount.flatMap { $0 >= 0 ? $0 : nil })
        }
    }

    private func dailySongs(cookies: [MusicSessionCookie]) async throws -> [Track] {
        let response: NEDailySongsResponse = try await request("v3/discovery/recommend/songs", payload: [:], cookies: cookies)
        return browseTracks(response.data.songs, privileges: response.data.privileges, limit: .max)
    }

    /// One `v6/playlist/detail` request asks for only the first `limit` songs.
    /// The import path above stays separate: it must read every song.
    func tracks(in collection: BrowseCollection, limit: Int, cookies: [MusicSessionCookie]) async throws -> [Track] {
        guard collection.source == .netease, [.chart, .playlist].contains(collection.kind) else {
            throw MusicError.message(L10n.string("该歌单不是网易云歌单"))
        }
        try requireID(collection.remoteID)
        // Each song row is about 2.5 KB; this keeps a reply far below 8 MB.
        let limit = min(limit, 1000)
        guard limit > 0 else { return [] }
        let response: NEPlaylistTracksResponse = try await request("v6/playlist/detail", payload: Self.collectionTracksPayload(id: collection.remoteID, limit: limit), cookies: cookies)
        guard let detail = response.playlist else { throw MusicError.message(L10n.string("无法读取网易云歌单，请检查登录状态或歌单权限")) }
        var seen = Set<String>()
        let wanted = Array(detail.trackIds.filter { isValidID($0) && seen.insert($0).inserted }.prefix(limit))
        let present = Set(detail.tracks.map(\.id.value))
        let missing = wanted.filter { !present.contains($0) }
        // The id list is complete, but NetEase can send fewer song rows (it
        // does for signed-out reads): one batch fills only the missing ones.
        guard !missing.isEmpty else { return browseTracks(detail.tracks, privileges: response.privileges, limit: limit) }
        let extra: NESongRows = try await request("v3/song/detail", payload: try Self.songDetailPayload(missing), cookies: cookies)
        let byID = Dictionary((detail.tracks + extra.songs).map { ($0.id.value, $0) }, uniquingKeysWith: { first, _ in first })
        return browseTracks(wanted.compactMap { byID[$0] }, privileges: response.privileges + extra.privileges, limit: limit)
    }

    /// Request bodies of the Now page's lists, before `requestPayload` adds the CSRF token.
    static func recommendedPlaylistsPayload() -> [String: Any] { ["limit": 12, "total": true, "n": 1000] }
    static func collectionTracksPayload(id: String, limit: Int) -> [String: Any] { ["id": id, "n": limit, "s": 0] }
    static func songDetailPayload(_ ids: [String]) throws -> [String: Any] {
        let c = try JSONSerialization.data(withJSONObject: ids.map { ["id": $0] }, options: [.sortedKeys])
        return ["c": String(decoding: c, as: UTF8.self)]
    }

    /// A song is unavailable when its row says so, or when its privilege marks
    /// it grey (negative `st`) and grants no play level. Real rows always carry
    /// `st: 0`, so the privilege is what usually decides.
    private func browseTracks(_ songs: [NESong], privileges: [NEPrivilege], limit: Int) -> [Track] {
        let rights = Dictionary(privileges.map { ($0.id.value, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Track] = [], seen = Set<String>()
        for song in songs where result.count < limit {
            guard isValidID(song.id.value), seen.insert(song.id.value).inserted else { continue }
            var track = song.track
            let right = song.privilege ?? rights[song.id.value]
            if (song.st ?? 0) < 0 || ((right?.st ?? 0) < 0 && (right?.pl ?? 0) <= 0) { track.unavailable = true }
            result.append(track)
        }
        return result
    }

    private static func outcome<T: Sendable>(_ operation: () async throws -> T) async -> Result<T, any Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }

    func resolve(_ track: Track, cookies: [MusicSessionCookie]) async throws -> URL {
        guard track.source == .netease, let id = track.sourceID else { throw MusicError.message(L10n.string("歌曲缺少网易云标识")) }
        try requireID(id)
        let response: NEURLsResponse = try await request("song/enhance/player/url/v1", payload: ["ids": "[\(id)]", "level": "standard", "encodeType": "aac"], cookies: cookies)
        guard let items = response.data else {
            throw MusicError.message(L10n.string("网易云播放地址响应缺少歌曲列表（阶段：获取播放地址；接口码：200）"))
        }
        guard let item = items.first(where: { $0.id.value == id }) else {
            throw MusicError.message(L10n.string("网易云未返回所选歌曲的播放结果（阶段：获取播放地址；接口码：200）"))
        }
        // The website accepts a successful envelope and URL without requiring item.code.
        // An explicitly unsuccessful item code must still never become playable.
        if let code = item.code, code != 200 {
            throw try await playbackFailure(L10n.string("网易云拒绝提供这首歌的播放地址"), item: item, id: id, cookies: cookies)
        }
        switch item.trial {
        case .preview:
            throw MusicError.message(L10n.string("网易云仅返回试听片段，未提供完整播放（\(item.diagnostic)）；本应用不播放试听替代完整歌曲"))
        case .unknown:
            throw MusicError.message(L10n.string("网易云返回的试听标记格式已变化，无法确认完整播放，已停止播放（\(item.diagnostic)）"))
        case .absent: break
        }
        guard let address = item.url?.trimmingCharacters(in: .whitespacesAndNewlines), !address.isEmpty else {
            throw try await playbackFailure(L10n.string("网易云返回的播放地址为空"), item: item, id: id, cookies: cookies)
        }
        guard let url = Self.mediaURL(address) else {
            throw MusicError.message(L10n.string("网易云返回的播放地址格式无效或不属于已允许的官方音频域名，已停止播放（\(item.diagnostic)）"))
        }
        return url
    }

    func lyrics(_ track: Track, cookies: [MusicSessionCookie]) async throws -> LyricsPayload? {
        guard track.source == .netease, let id = track.sourceID else { throw MusicError.message(L10n.string("歌曲缺少网易云标识，无法读取歌词。")) }
        try requireID(id)
        // New official lyric route may provide measured YRC word timestamps.
        // A failed or malformed optional field must not take away readable LRC.
        do {
            let response: NELyricsResponse = try await request("song/lyric/v1", payload: ["id": id, "cp": false, "lv": 0, "tv": 0, "rv": 0, "kv": 0, "yv": 0, "ytv": 0, "yrv": 0], cookies: cookies, phase: L10n.string("读取歌词"), timeout: 8)
            try Task.checkCancellation()
            // `ytlrc` shares the YRC sentence clock; `tlyric` follows the LRC one.
            let wordTranslation = response.ytlrc?.lyric.flatMap { $0.isEmpty ? nil : $0 } ?? response.tlyric?.lyric
            if let text = response.yrc?.lyric,
               let document = PlatformWordLyrics.parse(text, format: .yrc, translation: wordTranslation) {
                return .init(text: response.lrc?.lyric ?? "", translation: response.tlyric?.lyric, document: document)
            }
            if let payload = try lyricPayload(response) { return payload }
        } catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation() }
        let response: NELyricsResponse = try await request("song/lyric", payload: ["id": id, "lv": -1, "tv": -1, "rv": -1, "kv": -1], cookies: cookies, phase: L10n.string("读取歌词"))
        return try lyricPayload(response)
    }

    private func lyricPayload(_ response: NELyricsResponse) throws -> LyricsPayload? {
        if response.nolyric == true { return .init(text: "", isInstrumental: true) }
        guard let text = response.lrc?.lyric, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard text.utf8.count <= LyricsParser.maximumBytes, (response.tlyric?.lyric?.utf8.count ?? 0) <= LyricsParser.maximumBytes else {
            throw MusicError.message(L10n.string("网易云返回的歌词过大，未加载。"))
        }
        return .init(text: text, translation: response.tlyric?.lyric)
    }

    /// A failed URL response is not evidence of a subscription, removal, or region issue.
    /// Ask once for account-specific rights; never replace the URL with another source.
    private func playbackFailure(_ reason: String, item: NEURLsResponse.Item, id: String, cookies: [MusicSessionCookie]) async throws -> MusicError {
        let base = L10n.string("\(reason)（\(item.diagnostic)）")
        do {
            let descriptors = try JSONSerialization.data(withJSONObject: [["id": id]], options: [.sortedKeys])
            let response: NESongsResponse = try await request("v3/song/detail", payload: ["c": String(decoding: descriptors, as: UTF8.self)], cookies: cookies, phase: L10n.string("核对歌曲权限"), timeout: 5)
            guard let privilege = response.privileges?.first(where: { $0.id.value == id }) else {
                return .message(L10n.string("\(base)。平台未提供可核对的权限详情，无法确定具体原因"))
            }
            return .message(L10n.string("\(base)。\(privilege.explanation)（\(privilege.diagnostic)）"))
        } catch is CancellationError { throw CancellationError() }
        catch {
            return .message(L10n.string("\(base)。补充权限查询未完成，无法确定具体原因"))
        }
    }

    private var loginError: MusicError { .message(L10n.string("网易云尚未登录或登录已失效，请在应用内重新登录")) }
    private func requireID(_ id: String) throws {
        guard !id.isEmpty, id.count <= 20, id.utf8.allSatisfy({ (48...57).contains($0) }), id.contains(where: { $0 != "0" }) else {
            throw MusicError.message(L10n.string("网易云资源标识无效"))
        }
    }
    private func isValidID(_ id: String) -> Bool { (try? requireID(id)) != nil }
    private func request<T: Decodable>(_ route: String, payload: [String: Any], cookies: [MusicSessionCookie], phase: String? = nil, timeout: TimeInterval = 15) async throws -> T {
        try Task.checkCancellation()
        let phase = phase ?? Self.phase(for: route)
        let wordLyrics = route == "song/lyric/v1"
        let url = URL(string: wordLyrics ? "https://interface3.music.163.com/eapi/\(route)" : "https://music.163.com/weapi/\(route)")!
        let matching = DirectMusicAccess.requestCookies(cookies, for: .netease, url: url)
        guard matching.contains(where: { $0.name == "MUSIC_U" && !$0.value.isEmpty }) else {
            throw MusicError.message(L10n.string("\(loginError.localizedDescription)（阶段：\(phase)）"))
        }
        var wirePayload = payload
        if wordLyrics {
            wirePayload["e_r"] = false
            // Body and HTTP cookies use identical filtering and precedence.
            var header: [String: String] = [:]
            for cookie in matching where header[cookie.name] == nil { header[cookie.name] = cookie.value }
            wirePayload["header"] = header
        }
        let json = try Self.requestPayload(wirePayload, matchingCookies: matching)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = wordLyrics ? try NeteaseLyricCrypto.encrypt(json) : try NeteaseWebCrypto.encrypt(json).formData
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue("https://music.163.com", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/26.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let data: Data
        do { data = try await http.data(for: request, source: .netease, cookies: cookies) }
        catch is CancellationError { throw CancellationError() }
        catch { throw MusicError.message(L10n.string("\(error.localizedDescription)（阶段：\(phase)）")) }
        let decoder = JSONDecoder()
        guard let status = try? decoder.decode(NEStatus.self, from: data) else {
            throw MusicError.message(L10n.string("网易云返回了无法识别的响应（阶段：\(phase)），请在官网确认登录或验证提示"))
        }
        guard status.code == 200 else {
            let diagnostic = L10n.string("阶段：\(phase)；接口码：\(String(status.code))")
            if [301, 302, 401].contains(status.code) { throw MusicError.message(L10n.string("\(loginError.localizedDescription)（\(diagnostic)）")) }
            if status.code == 429 { throw MusicError.message(L10n.string("网易云请求过于频繁，请稍后重试（\(diagnostic)）")) }
            throw MusicError.message(L10n.string("网易云拒绝了请求（\(diagnostic)），平台未提供可确认的具体原因"))
        }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw MusicError.message(L10n.string("网易云响应格式已变化（阶段：\(phase)；接口码：200），请稍后重试")) }
    }
    static func requestPayload(_ payload: [String: Any], matchingCookies: [MusicSessionCookie]) throws -> Data {
        var payload = payload
        payload["csrf_token"] = matchingCookies.first(where: { $0.name == "__csrf" })?.value ?? ""
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func phase(for route: String) -> String {
        switch route {
        case "w/nuser/account/get": L10n.string("确认登录身份")
        case "cloudsearch/pc": L10n.string("搜索歌曲")
        case "user/playlist": L10n.string("读取歌单列表")
        case "album/sublist": L10n.string("读取收藏专辑")
        case "v6/playlist/detail": L10n.string("读取歌单曲目")
        case "v3/song/detail": L10n.string("读取歌曲资料")
        case "song/enhance/player/url/v1": L10n.string("获取播放地址")
        case "toplist/detail/v2": L10n.string("读取榜单")
        case "personalized/playlist": L10n.string("读取推荐歌单")
        case "v3/discovery/recommend/songs": L10n.string("读取每日推荐")
        default: L10n.string("读取平台数据")
        }
    }
    private static func artworkURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return nil }
        return url
    }
    /// Covers on NetEase's image hosts load over HTTPS as 300-pixel thumbnails.
    /// Any other address, or one already carrying a query, stays as sent.
    private static func coverURL(_ value: String?) -> URL? {
        guard let url = artworkURL(value?.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        guard let host = url.host?.lowercased(), host == "music.126.net" || host.hasSuffix(".music.126.net"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              [nil, 80, 443].contains(components.port) else { return url }
        components.scheme = "https"
        components.port = nil
        if (components.percentEncodedQuery ?? "").isEmpty, components.fragment == nil { components.percentEncodedQuery = "param=300y300" }
        return components.url ?? url
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
    var yrc: Text?
    var ytlrc: Text?
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
private struct NEAlbumsResponse: Decodable {
    var data: [NEAlbum]?; var hasMore: Bool?; var more: Bool?; var count: Int?
}
private struct NEAlbumResponse: Decodable { var album: NEAlbum?; var songs: [NESong]? }
private struct NEAlbum: Decodable {
    var id: NEID; var name: String?; var artists: [NESong.Artist]?; var artist: NESong.Artist?
    var songCount: Int?; var size: Int?; var picUrl: String?
    var artistName: String {
        let names = (artists ?? []).compactMap(\.name).filter { !$0.isEmpty }.joined(separator: " / ")
        return names.nonempty ?? artist?.name?.nonempty ?? ""
    }
}
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
            return L10n.string("平台返回特殊播放限制，未说明具体原因")
        }
        if let st, st < 0 { return L10n.string("平台将这首歌标记为当前不可用；此标记不能单独区分下架或地区限制") }
        if let fee, fee > 0, fee != 8, payed == 0, let pl, pl <= 0 {
            return L10n.string("平台权限资料显示当前账户没有这首歌的付费播放权限")
        }
        if fee == 16 || (fee == 4 && ((flag ?? 0) & 2048) != 0) {
            return L10n.string("平台标记这首歌需要下载后播放，请使用官方客户端；本应用未提供下载播放")
        }
        if let pl, pl > 0 { return L10n.string("权限资料显示可播放，但地址接口未提供完整播放地址") }
        if pl == 0, dl == 0 { return L10n.string("平台权限资料标记这首歌当前不可播放，未说明具体原因") }
        return L10n.string("平台未提供足够信息，无法确定具体原因")
    }
    var diagnostic: String {
        [("st", st), ("pl", pl), ("fee", fee), ("payed", payed), ("flag", flag)]
            .compactMap { name, value in value.map { "\(name)=\($0)" } }.joined(separator: L10n.string("，")).nonempty ?? L10n.string("权限字段缺失")
    }
}
private struct NESong: Decodable {
    var id: NEID; var name: String?; var ar: [Artist]?; var artists: [Artist]?; var al: Album?; var album: Album?; var dt: Double?; var duration: Double?
    var st: Int?; var privilege: NEPrivilege?
    struct Artist: Decodable { var name: String? }
    struct Album: Decodable { var name: String?; var picUrl: String? }
    var track: Track {
        let image = (al?.picUrl ?? album?.picUrl).flatMap(URL.init(string:)).flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        let seconds = (dt ?? duration ?? 0) / 1000
        return Track(id: "netease:\(id.value)", title: name?.nonempty ?? L10n.string("未命名歌曲"), artist: (ar ?? artists ?? []).compactMap(\.name).joined(separator: " / ").nonempty ?? L10n.string("未知艺术家"), album: al?.name ?? album?.name ?? L10n.string("未知专辑"), duration: seconds.isFinite ? max(0, seconds) : 0, source: .netease, sourceID: id.value, artworkURL: image)
    }
}
private struct NEURLsResponse: Decodable {
    var data: [Item]?
    struct Item: Decodable {
        enum Trial { case absent, preview, unknown }
        private struct Preview: Decodable { let start: Double; let end: Double }
        var id: NEID; var code: Int?; var url: String?; var trial: Trial; var fee: Int?
        var diagnostic: String {
            L10n.string("阶段：获取播放地址；接口码：200；歌曲码：\(code.map(String.init) ?? L10n.string("未提供"))") + (fee.map { L10n.string("；fee=\(String($0))") } ?? "")
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
/// One list element that may be unreadable; the rest of the list still decodes.
private struct NELossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
}
private extension KeyedDecodingContainer {
    /// The readable elements of an optional list. A missing or odd list is nil.
    func readable<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T]? {
        (try? decodeIfPresent([NELossy<T>].self, forKey: key))?.compactMap(\.value)
    }
    func text(_ key: Key) -> String? {
        (try? decodeIfPresent(String.self, forKey: key))?.trimmingCharacters(in: .whitespacesAndNewlines).nonempty
    }
}
/// `toplist/detail/v2`. The v1 routes repeat `updateFrequency` and `tracks`
/// in every item, and Foundation keeps the first copy, which is null.
private struct NEChartsResponse: Decodable {
    var data: [NELossy<Group>]
    struct Group: Decodable { var list: [NELossy<NEChart>]? }
}
private struct NEChart: Decodable {
    var id: String?; var targetType: String?; var name: String?; var updateFrequency: String?; var coverUrl: String?
    var preview: [BrowsePreviewLine]
    private enum CodingKeys: String, CodingKey { case id, targetType, name, updateFrequency, coverUrl, tracks, trackRankList }
    private struct Line: Decodable { var first: String?; var second: String? }
    private struct Rank: Decodable { var songName: String?; var artistName: String? }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(NEID.self, forKey: .id))?.value
        targetType = container.text(.targetType); name = container.text(.name)
        updateFrequency = container.text(.updateFrequency); coverUrl = container.text(.coverUrl)
        let lines = Self.preview((container.readable(Line.self, forKey: .tracks) ?? []).map { ($0.first, $0.second) })
        preview = lines.isEmpty ? Self.preview((container.readable(Rank.self, forKey: .trackRankList) ?? []).map { ($0.songName, $0.artistName) }) : lines
    }
    private static func preview(_ rows: [(String?, String?)]) -> [BrowsePreviewLine] {
        Array(rows.compactMap { title, artist in
            (title?.trimmingCharacters(in: .whitespacesAndNewlines).nonempty).map {
                BrowsePreviewLine(title: $0, artist: artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            }
        }.prefix(3))
    }
}
private struct NEPersonalizedResponse: Decodable {
    var result: [NELossy<Item>]
    struct Item: Decodable {
        var id: String; var name: String?; var copywriter: String?; var picUrl: String?; var trackCount: Int?
        private enum CodingKeys: String, CodingKey { case id, name, copywriter, picUrl, trackCount }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(NEID.self, forKey: .id).value
            name = container.text(.name); copywriter = container.text(.copywriter); picUrl = container.text(.picUrl)
            trackCount = try? container.decodeIfPresent(Int.self, forKey: .trackCount)
        }
    }
}
/// Song rows with the account's rights for them: `v3/song/detail` calls the
/// list `songs`, the daily recommendation `dailySongs`. Odd rows are skipped.
private struct NESongRows: Decodable {
    var songs: [NESong]; var privileges: [NEPrivilege]
    private enum CodingKeys: String, CodingKey { case songs, dailySongs, privileges }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        songs = try container.decode([NELossy<NESong>].self, forKey: container.contains(.dailySongs) ? .dailySongs : .songs).compactMap(\.value)
        privileges = container.readable(NEPrivilege.self, forKey: .privileges) ?? []
    }
}
private struct NEDailySongsResponse: Decodable { var data: NESongRows }
/// `v6/playlist/detail` read for browsing: rights sit beside the playlist.
private struct NEPlaylistTracksResponse: Decodable {
    var playlist: Playlist?; var privileges: [NEPrivilege]
    private enum CodingKeys: String, CodingKey { case playlist, privileges }
    struct Playlist: Decodable {
        var tracks: [NESong]; var trackIds: [String]
        private enum CodingKeys: String, CodingKey { case tracks, trackIds }
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tracks = container.readable(NESong.self, forKey: .tracks) ?? []
            trackIds = (container.readable(NEPlaylist.TrackID.self, forKey: .trackIds) ?? []).map(\.id.value)
        }
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playlist = try container.decodeIfPresent(Playlist.self, forKey: .playlist)
        privileges = container.readable(NEPrivilege.self, forKey: .privileges) ?? []
    }
}
private extension String { var nonempty: String? { isEmpty ? nil : self } }
