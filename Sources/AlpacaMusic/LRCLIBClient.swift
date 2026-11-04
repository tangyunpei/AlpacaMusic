import Foundation

/// Bounded metadata-only lookups. This client never receives platform sessions.
actor LRCLIBClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private let clock = ContinuousClock()
    private var inFlight = false
    private var nextRequestAt: ContinuousClock.Instant?
    private var blockedUntil: ContinuousClock.Instant?
    private var blockedIndefinitely = false
    private var cache: [Signature: LyricDocument] = [:]
    private struct Signature: Hashable {
        let title: String
        let artist: String
        let album: String
        let duration: Double
    }
    private struct Response: Decodable {
        let trackName: String
        let artistName: String
        let albumName: String
        let duration: Double
        let instrumental: Bool
        let plainLyrics: String?
        let syncedLyrics: String?
    }
    private struct SearchQuery: Hashable { let title: String; let artist: String }
    private enum Match { case missing, ambiguous, found(Response) }
    private static let maximumBytes = 4 * 1024 * 1024

    init(transport: Transport? = nil) { self.transport = transport ?? Self.fetch }

    func lookup(_ track: Track) async throws -> LyricDocument? {
        try Task.checkCancellation()
        guard track.duration.isFinite, (1...3600).contains(track.duration),
              [track.title, track.artist, track.album].allSatisfy({ $0.utf8.count <= 2048 }) else {
            throw MusicError.message(L10n.string("歌曲名、歌手或时长资料不足，无法精确查找歌词。可手动导入歌词文件。"))
        }
        let signature = Signature(title: Self.normalized(track.title), artist: Self.normalized(track.artist), album: Self.normalized(track.album), duration: track.duration)
        guard !signature.title.isEmpty, !signature.artist.isEmpty else {
            throw MusicError.message(L10n.string("歌曲名、歌手或时长资料不足，无法精确查找歌词。可手动导入歌词文件。"))
        }
        if let value = cache[signature] { return value }
        // A cancelled previous song may still be unwinding its URLSession.
        // Serialize cooperatively instead of turning the new song into a busy
        // error; a cancelled waiter never owns the slot or sends a request.
        while inFlight { try await clock.sleep(for: .milliseconds(30)); try Task.checkCancellation() }
        try Task.checkCancellation()
        if let value = cache[signature] { return value }
        inFlight = true
        defer { inFlight = false }

        let exactQuery: [URLQueryItem] = [
            .init(name: "track_name", value: track.title.trimmingCharacters(in: .whitespacesAndNewlines)),
            .init(name: "artist_name", value: track.artist.trimmingCharacters(in: .whitespacesAndNewlines)),
            .init(name: "album_name", value: track.album.trimmingCharacters(in: .whitespacesAndNewlines)),
            .init(name: "duration", value: String(track.duration))
        ]
        if let data = try await request(path: "/api/get", query: exactQuery) {
            let value: Response = try Self.decode(data)
            if Self.matches(value, signature: signature), Self.normalized(value.albumName) == signature.album,
               let document = try document(value, signature: signature) { return document }
        }

        // Structured title/artist searches only: no free-text q, title-only
        // lookup, artist aliases, removed version labels, or unbounded paging.
        // Original + simplified + traditional forms produce at most 3 searches
        // (4 HTTP requests including get), usually only one fallback search.
        for query in Self.searchQueries(title: track.title, artist: track.artist) {
            guard let data = try await request(path: "/api/search", query: [
                .init(name: "track_name", value: query.title), .init(name: "artist_name", value: query.artist)
            ]) else { continue }
            let values: [Response] = try Self.decode(data)
            guard values.count <= 100 else { return nil }
            switch Self.select(values, signature: signature) {
            case .missing: continue
            case .ambiguous: return nil
            case .found(let value): return try document(value, signature: signature)
            }
        }
        return nil
    }

    private func request(path: String, query: [URLQueryItem]) async throws -> Data? {
        try Task.checkCancellation()
        if blockedIndefinitely || blockedUntil.map({ clock.now < $0 }) == true {
            throw MusicError.message(L10n.string("LRCLIB 暂时限制查询，请等待服务要求的冷却时间结束后重试。"))
        }
        if let nextRequestAt, clock.now < nextRequestAt { try await clock.sleep(until: nextRequestAt) }
        try Task.checkCancellation()
        var components = URLComponents(string: "https://lrclib.net" + path)!
        components.queryItems = query
        guard let url = components.url else { throw MusicError.message(L10n.string("歌曲资料无法用于歌词查询。")) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AlpacaMusic/1.0 (https://byalpaca.dev)", forHTTPHeaderField: "User-Agent")
        // Throttle every HTTP completion, including fallbacks and cancellation.
        defer { nextRequestAt = clock.now.advanced(by: .milliseconds(300)) }
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw MusicError.message(error.code == .timedOut ? L10n.string("LRCLIB 查询超时，请稍后重试。") : L10n.string("无法连接 LRCLIB，请检查网络后重试。"))
        } catch let error as MusicError { throw error }
        catch { throw MusicError.message(L10n.string("无法连接 LRCLIB，请稍后重试。")) }
        try Task.checkCancellation()
        guard response.url?.scheme == "https", response.url?.host == "lrclib.net", response.url?.path() == path,
              response.url?.port == nil || response.url?.port == 443 else {
            throw MusicError.message(L10n.string("已阻止歌词查询跳转到其他地址。"))
        }
        if response.statusCode == 429 || response.statusCode == 503 {
            let delay = Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After"))
            if delay > 31_536_000 {
                blockedIndefinitely = true
                throw MusicError.message(L10n.string("LRCLIB 要求较长冷却时间，本次会话不再发出歌词查询。"))
            }
            blockedUntil = clock.now.advanced(by: .seconds(delay))
            throw MusicError.message(L10n.string("LRCLIB 暂时繁忙或限制查询，请至少等待 \(Int(delay.rounded(.up))) 秒后重试。"))
        }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw MusicError.message(L10n.string("LRCLIB 未完成歌词查询（HTTP \(String(response.statusCode))）。")) }
        guard data.count <= Self.maximumBytes else { throw MusicError.message(L10n.string("LRCLIB 返回的歌词资料过大，无法读取。")) }
        return data
    }

    private func document(_ value: Response, signature: Signature) throws -> LyricDocument? {
        let payload: LyricsPayload
        if value.instrumental { payload = .init(text: "", isInstrumental: true) }
        else if let text = value.syncedLyrics, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload = .init(text: text, format: .lrc)
        } else if let text = value.plainLyrics, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload = .init(text: text, format: .plain)
        } else { return nil }
        let document = try LyricsParser.parse(payload, sourceDescription: "LRCLIB")
        try Task.checkCancellation()
        if cache.count >= 8 { cache.removeAll(keepingCapacity: true) }
        cache[signature] = document
        return document
    }

    private static func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw MusicError.message(L10n.string("LRCLIB 返回的歌词资料无法读取。")) }
    }
    private static func matches(_ value: Response, signature: Signature) -> Bool {
        normalized(value.trackName) == signature.title && normalized(value.artistName) == signature.artist &&
        value.duration.isFinite && abs(value.duration - signature.duration) <= 2
    }
    private static func hasLyrics(_ value: Response) -> Bool {
        value.instrumental || [value.syncedLyrics, value.plainLyrics].contains { $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
    }
    private static func select(_ values: [Response], signature: Signature) -> Match {
        let candidates = values.filter { matches($0, signature: signature) && hasLyrics($0) }
        let exactAlbum = candidates.filter { !signature.album.isEmpty && normalized($0.albumName) == signature.album }
        if exactAlbum.count == 1 { return .found(exactAlbum[0]) }
        if exactAlbum.count > 1 { return .ambiguous }
        // Album aliases are allowed only when they do not erase a recording
        // edition. Even identical title/duration cannot turn a live/remix album
        // into a studio recording. Ambiguous candidates are never ranked by
        // a convenient duration difference or by lyric availability/order.
        let compatible = candidates.filter { !hasEditionMarker(signature.album) && !hasEditionMarker(normalized($0.albumName)) }
        if compatible.isEmpty { return .missing }
        // Search has no pagination and currently caps results at 20. A unique
        // alias in a full page cannot establish that the match is unambiguous.
        if compatible.count != 1 || values.count >= 20 { return .ambiguous }
        return .found(compatible[0])
    }
    private static func hasEditionMarker(_ value: String) -> Bool {
        let pattern = #"\b(live|remix|acoustic|instrumental|karaoke|remaster(?:ed)?|demo|radio\s+edit|extended|sped\s+up|slowed|re-?recorded|mono|stereo)\b|现场|演唱会|混音|伴奏|纯音乐|不插电|重制|重录|加速|慢速"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
    private static func searchQueries(title: String, artist: String) -> [SearchQuery] {
        func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        let original = SearchQuery(title: clean(title), artist: clean(artist))
        var values = [original]
        for transform in ["Hant-Hans", "Hans-Hant"] {
            let converted = SearchQuery(title: original.title.applyingTransform(.init(transform), reverse: false) ?? original.title,
                                        artist: original.artist.applyingTransform(.init(transform), reverse: false) ?? original.artist)
            if !values.contains(converted) { values.append(converted) }
        }
        return values
    }
    private static func normalized(_ value: String) -> String {
        let folded = value.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let simplified = folded.applyingTransform(.init("Hant-Hans"), reverse: false) ?? folded
        return simplified.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func retryDelay(_ header: String?) -> Double {
        guard let header else { return 60 }
        let text = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(text), seconds.isFinite, seconds >= 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        if let date = formatter.date(from: text) { return max(0, date.timeIntervalSinceNow) }
        return 60
    }
    private static func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: LRCLIBRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, raw) = try await session.bytes(for: request)
        guard let response = raw as? HTTPURLResponse else { throw MusicError.message(L10n.string("LRCLIB 返回的响应无法读取。")) }
        guard response.expectedContentLength <= maximumBytes else { throw MusicError.message(L10n.string("LRCLIB 返回的歌词资料过大，无法读取。")) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw MusicError.message(L10n.string("LRCLIB 返回的歌词资料过大，无法读取。")) }
            data.append(byte)
        }
        return (data, response)
    }
}

private final class LRCLIBRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
}
