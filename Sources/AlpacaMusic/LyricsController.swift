import CryptoKit
import Foundation
import Observation

enum LyricsIdentity {
    static func key(for track: Track) -> String {
        var values = [track.source.rawValue, track.id, track.sourceID ?? "", track.appleMusicResourceKind?.rawValue ?? ""]
        if track.source == .soda {
            if let range = track.sodaPlayback {
                values += [String(range.start), String(range.duration), String(range.fullDuration), String(range.isPreview)]
            } else { values.append("unprepared") }
        }
        var data = Data()
        for value in values { data.append(contentsOf: "\(value.utf8.count):".utf8); data.append(contentsOf: value.utf8) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func onlineKey(for track: Track) -> String {
        let values = [key(for: track), track.title, track.artist, track.album, String(track.duration)]
        let data = values.reduce(into: Data()) { data, value in
            data.append(contentsOf: "\(value.utf8.count):".utf8); data.append(contentsOf: value.utf8)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// File access stays off the main actor. Imported lyrics and the bounded public
/// online cache are separate; authenticated platform results stay ephemeral.
actor LyricsStorage {
    private struct Record: Codable {
        var version = 1
        var key: String
        var text: String
        var format: LyricsFormat
    }
    private let directory: URL
    init(directory: URL) { self.directory = directory.appending(path: "lyrics", directoryHint: .isDirectory) }

    private struct OnlineRecord: Codable {
        var version = 1
        var key: String
        var savedAt: Date
        var document: LyricDocument
    }
    private var onlineDirectory: URL { directory.appending(path: "online", directoryHint: .isDirectory) }

    func cachedOnline(for track: Track, now: Date = Date()) -> LyricDocument? {
        let key = LyricsIdentity.onlineKey(for: track)
        let url = onlineDirectory.appending(path: key + ".json")
        guard !Task.isCancelled,
              let data = try? read(url, maximumBytes: 8 * 1024 * 1024),
              let record = try? JSONDecoder().decode(OnlineRecord.self, from: data),
              record.version == 1, record.key == key,
              (0...(30 * 24 * 3600)).contains(now.timeIntervalSince(record.savedAt)),
              Self.validOnlineDocument(record.document) else { return nil }
        return record.document
    }

    private static func validOnlineDocument(_ document: LyricDocument) -> Bool {
        guard document.sourceDescription == "LRCLIB", document.lines.count <= LyricsParser.maximumLines else { return false }
        if document.isInstrumental { return document.lines.isEmpty }
        guard !document.lines.isEmpty, Set(document.lines.map(\.id)).count == document.lines.count else { return false }
        var previous = -Double.infinity
        for line in document.lines {
            guard line.text.utf8.count <= 32_768, (line.translation?.utf8.count ?? 0) <= 32_768 else { return false }
            if document.timing != .plain {
                guard let start = line.start, start.isFinite, start >= previous else { return false }
                previous = start
                if let end = line.end, !end.isFinite || end < start { return false }
            } else if line.start != nil || line.end != nil || !line.words.isEmpty { return false }
            var wordStart = line.start ?? 0
            for word in line.words {
                guard word.start.isFinite, word.start >= wordStart, word.text.utf8.count <= 32_768 else { return false }
                if let end = word.end, !end.isFinite || end < word.start { return false }
                wordStart = word.start
            }
        }
        return true
    }

    func cacheOnline(_ document: LyricDocument, for track: Track) throws {
        try Task.checkCancellation()
        guard document.sourceDescription == "LRCLIB" else { return }
        let key = LyricsIdentity.onlineKey(for: track)
        let data = try JSONEncoder().encode(OnlineRecord(key: key, savedAt: Date(), document: document))
        guard data.count <= 8 * 1024 * 1024 else { return }
        try FileManager.default.createDirectory(at: onlineDirectory, withIntermediateDirectories: true)
        try Task.checkCancellation()
        try data.write(to: onlineDirectory.appending(path: key + ".json"), options: .atomic)
        // Cache at most 64 songs. Imported lyrics never participate in eviction.
        let files = try FileManager.default.contentsOfDirectory(at: onlineDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
            .compactMap { url -> (URL, Date)? in
                guard url.pathExtension == "json", url.deletingPathExtension().lastPathComponent.count == 64,
                      url.deletingPathExtension().lastPathComponent.allSatisfy({ $0.isHexDigit }),
                      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
                return (url, values.contentModificationDate ?? .distantPast)
            }.sorted { $0.1 > $1.1 }
        for (url, _) in files.dropFirst(64) { try? FileManager.default.removeItem(at: url) }
    }

    func imported(for track: Track) throws -> LyricDocument? {
        try Task.checkCancellation()
        let key = LyricsIdentity.key(for: track), location = location(for: key)
        guard FileManager.default.fileExists(atPath: location.path(percentEncoded: false)) else { return nil }
        do {
            let data = try read(location, maximumBytes: 8 * 1024 * 1024)
            let record = try JSONDecoder().decode(Record.self, from: data)
            guard record.version == 1, record.key == key else { throw MusicError.message(L10n.string("歌词关联资料无效。")) }
            return try LyricsParser.parse(record.text, format: record.format, sourceDescription: L10n.string("手动导入"))
        } catch is CancellationError { throw CancellationError() }
        catch { throw MusicError.message(L10n.string("已导入的歌词资料无法读取，请重新导入；原文件仍保留。")) }
    }

    func importFile(_ url: URL, for track: Track) throws -> LyricDocument {
        try Task.checkCancellation()
        guard url.isFileURL else { throw MusicError.message(L10n.string("请选择本机的 LRC、SRT 或 TXT 歌词文件。")) }
        let format: LyricsFormat
        switch url.pathExtension.lowercased() {
        case "lrc": format = .lrc
        case "srt": format = .srt
        case "txt": format = .plain
        default: throw MusicError.message(L10n.string("支持 LRC、SRT 和 TXT 歌词文件。"))
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let text: String
        do { text = try decodeText(read(url, maximumBytes: LyricsParser.maximumBytes)) }
        catch let error as MusicError { throw error }
        catch { throw MusicError.message(L10n.string("无法读取所选歌词文件，请重新选择。")) }
        let document = try LyricsParser.parse(text, format: format, sourceDescription: L10n.string("手动导入"))
        try Task.checkCancellation()
        let key = LyricsIdentity.key(for: track)
        let record = Record(key: key, text: text, format: format)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(record)
            try data.write(to: location(for: key), options: [.atomic])
        } catch { throw MusicError.message(L10n.string("歌词已读取，但无法保存到本机。请检查资料目录权限后重试。")) }
        return document
    }

    func sidecar(for track: Track) throws -> LyricDocument? {
        guard track.source == .local, let bookmark = track.bookmark else { return nil }
        try Task.checkCancellation()
        var stale = false
        let audioURL: URL
        do { audioURL = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) }
        catch { return nil }
        guard audioURL.isFileURL else { return nil }
        let scoped = audioURL.startAccessingSecurityScopedResource()
        defer { if scoped { audioURL.stopAccessingSecurityScopedResource() } }
        // A file-only sandbox grant may not cover a sibling. Never request a
        // wider grant implicitly; users can explicitly import that lyric file.
        for suffix in ["lrc", "srt", "txt", "LRC", "SRT", "TXT"] {
            try Task.checkCancellation()
            let url = audioURL.deletingPathExtension().appendingPathExtension(suffix)
            guard let data = try? read(url, maximumBytes: LyricsParser.maximumBytes) else { continue }
            let format: LyricsFormat = suffix.lowercased() == "srt" ? .srt : (suffix.lowercased() == "txt" ? .plain : .lrc)
            return try LyricsParser.parse(decodeText(data), format: format, sourceDescription: L10n.string("本地同名歌词"))
        }
        return nil
    }

    private func location(for key: String) -> URL { directory.appending(path: "\(key).json") }
    private func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw MusicError.message(L10n.string("请选择普通歌词文件。")) }
        guard (values.fileSize ?? 0) <= maximumBytes else { throw MusicError.message(L10n.string("歌词文件过大，无法读取。")) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw MusicError.message(L10n.string("歌词文件过大，无法读取。")) }
        return data
    }
    private func decodeText(_ data: Data) throws -> String {
        if let value = String(data: data, encoding: .utf8) { return value }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let value = String(data: data, encoding: .utf16) { return value }
        throw MusicError.message(L10n.string("歌词编码无法读取，请将文件保存为 UTF-8 或带字节序标记的 UTF-16。"))
    }
}

@MainActor @Observable final class LyricsController {
    private(set) var document: LyricDocument?
    private(set) var status: LyricsStatus = .idle
    private(set) var error: String?
    private(set) var automaticAppleMusicLookup: Bool
    private(set) var automaticAudioAlignment: Bool
    private(set) var audioAlignmentStatus: LyricAudioAlignmentStatus = .waitingAudio
    @ObservationIgnored private let alignmentCache: LyricAlignmentCache
    @ObservationIgnored private let alignmentOperation: LyricAlignmentRunner.Operation
    @ObservationIgnored private var alignmentRequest: Task<Void, Never>?
    @ObservationIgnored private var alignmentGeneration = UUID()
    @ObservationIgnored private var audioSource: LyricAudioSource?
    @ObservationIgnored private var originalDocument: LyricDocument?
    @ObservationIgnored private var alignedResult: LyricAlignmentResult?
    @ObservationIgnored private var alignmentPosition: Double = 0
    @ObservationIgnored private let client: NativeMusicClient
    @ObservationIgnored private let storage: LyricsStorage
    @ObservationIgnored private let online: LRCLIBClient
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var current: Track?
    @ObservationIgnored private var manualDocument = false
    @ObservationIgnored private var request: Task<LoadResult, Error>?
    @ObservationIgnored private var accountObserver: Task<Void, Never>?
    @ObservationIgnored private var cache: [CacheKey: LyricDocument] = [:]
    @ObservationIgnored private var publicSodaCache: [String: LyricDocument] = [:]
    private struct CacheKey: Hashable { let track: String; let scope: LyricsSessionScope }
    private struct LoadResult { var document: LyricDocument?; var manual = false; var explanation: String? = nil }

    init(client: NativeMusicClient, directory: URL? = nil, online: LRCLIBClient = LRCLIBClient(), automaticAppleMusicLookup: Bool = true, automaticAudioAlignment: Bool = true,
         alignmentOperation: @escaping LyricAlignmentRunner.Operation = { source, track, document, cache, position, progress, publish in
             await LyricAlignmentRunner.run(source: source, track: track, document: document, cache: cache, position: position, progress: progress, publish: publish)
         }) {
        self.client = client
        self.online = online
        self.automaticAppleMusicLookup = automaticAppleMusicLookup
        self.automaticAudioAlignment = automaticAudioAlignment
        self.alignmentOperation = alignmentOperation
        audioAlignmentStatus = automaticAudioAlignment ? .waitingAudio : .off
        let environmentDirectory = ProcessInfo.processInfo.environment["ALPACA_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        storage = LyricsStorage(directory: directory ?? environmentDirectory ?? URL.applicationSupportDirectory.appending(path: "AlpacaMusic", directoryHint: .isDirectory))
        alignmentCache = LyricAlignmentCache(directory: directory ?? environmentDirectory ?? URL.applicationSupportDirectory.appending(path: "AlpacaMusic", directoryHint: .isDirectory))
        accountObserver = Task { [weak self, client] in
            let changes = await client.lyricsSessionChanges()
            for await source in changes {
                guard !Task.isCancelled else { return }
                self?.accountChanged(source)
            }
        }
    }
    deinit { request?.cancel(); accountObserver?.cancel(); alignmentRequest?.cancel() }

    func shutdown() async {
        request?.cancel(); accountObserver?.cancel()
        let pending = alignmentRequest
        cancelAlignment(); audioSource = nil
        await pending?.value
    }

    func setAutomaticAudioAlignment(_ enabled: Bool) {
        automaticAudioAlignment = enabled
        cancelAlignment()
        if let originalDocument { document = originalDocument }
        if enabled { startAlignment() } else { audioAlignmentStatus = .off }
    }

    func setAudioSource(_ source: LyricAudioSource?, position: Double) {
        if position.isFinite { alignmentPosition = max(0, position) }
        guard audioSource != source else { return }
        audioSource = source; cancelAlignment()
        if let originalDocument { document = originalDocument }
        startAlignment()
    }

    func updateAlignmentPosition(_ position: Double, didSeek: Bool = false) {
        guard position.isFinite else { return }
        alignmentPosition = max(0, position)
        if didSeek, let originalDocument, let alignedResult {
            document = LyricAnalysisWindow.merge(alignedResult, into: originalDocument, position: nil, includeCurrent: true)
        }
    }

    private func cancelAlignment() {
        alignmentGeneration = UUID(); alignmentRequest?.cancel(); alignmentRequest = nil; alignedResult = nil
    }

    private func installedDocument(_ value: LyricDocument?) {
        cancelAlignment(); originalDocument = value; document = value
        startAlignment()
    }

    private func startAlignment() {
        guard automaticAudioAlignment else { audioAlignmentStatus = .off; return }
        guard let track = current, let originalDocument, !originalDocument.isInstrumental,
              originalDocument.timing != .plain else { audioAlignmentStatus = .waitingAudio; return }
        guard originalDocument.lines.contains(where: { $0.words.isEmpty }) else { audioAlignmentStatus = .provider; return }
        guard let audioSource, audioSource.trackKey == LyricsIdentity.key(for: track) else { audioAlignmentStatus = .waitingAudio; return }
        let token = alignmentGeneration
        audioAlignmentStatus = .preparing
        let cache = alignmentCache
        let operation = alignmentOperation
        alignmentRequest = Task.detached(priority: .utility) { [weak self] in
            await operation(audioSource, track, originalDocument, cache,
                { @MainActor [weak self] in self?.alignmentPosition ?? 0 },
                { @MainActor [weak self] status in
                    guard let self, self.alignmentGeneration == token else { return }
                    self.audioAlignmentStatus = status
                }, { @MainActor [weak self] result, cached in
                    guard let self, self.alignmentGeneration == token else { return }
                    self.alignedResult = result
                    // Fresh analysis never rewrites a phrase already on screen.
                    // Cached timing is available immediately on a later play/seek.
                    self.document = LyricAnalysisWindow.merge(result, into: originalDocument,
                                                             position: self.alignmentPosition, includeCurrent: cached)
                })
        }
    }

    func setAutomaticAppleMusicLookup(_ enabled: Bool) async {
        automaticAppleMusicLookup = enabled
        if let current, current.source == .appleMusic { await load(track: current) }
    }

    func load(track: Track?) async {
        generation = UUID(); let token = generation
        request?.cancel(); request = nil
        cancelAlignment(); originalDocument = nil
        audioAlignmentStatus = automaticAudioAlignment ? .waitingAudio : .off
        current = track; document = nil; manualDocument = false; error = nil
        guard let track else { status = .idle; return }
        status = .loading
        let pending = Task { try await self.read(track) }
        request = pending
        do {
            let result = try await withTaskCancellationHandler { try await pending.value } onCancel: { pending.cancel() }
            try Task.checkCancellation()
            guard generation == token else { return }
            installedDocument(result.document); manualDocument = result.manual
            status = result.document == nil ? .unavailable : .ready
            error = result.explanation
        } catch is CancellationError {
            if generation == token { status = .idle }
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            self.error = error.localizedDescription; status = .failed
        }
        if generation == token { request = nil }
    }
    /// Explicit retry for any source; Apple Music also uses this service during
    /// automatic load when enabled. No platform sessions leave the native client.
    func lookupOnline(for track: Track) async {
        guard current.map({ LyricsIdentity.key(for: $0) }) == LyricsIdentity.key(for: track) else { return }
        generation = UUID(); let token = generation
        request?.cancel(); request = nil
        document = nil; manualDocument = false; status = .loading; error = nil
        cancelAlignment(); originalDocument = nil
        let pending = Task { [online, storage] in
            let value = try await online.lookup(track)
            if let value { try? await storage.cacheOnline(value, for: track) }
            try Task.checkCancellation()
            return LoadResult(document: value, manual: true, explanation: value == nil ? L10n.string("LRCLIB 未匹配到这首歌曲的歌词，可手动导入歌词文件。") : nil)
        }
        request = pending
        do {
            let result = try await withTaskCancellationHandler { try await pending.value } onCancel: { pending.cancel() }
            try Task.checkCancellation()
            guard generation == token else { return }
            installedDocument(result.document); manualDocument = result.manual
            status = result.document == nil ? .unavailable : .ready; error = result.explanation
        } catch is CancellationError {
            if generation == token { status = .idle }
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            self.error = error.localizedDescription; status = .failed
        }
        if generation == token { request = nil }
    }
    func importFile(url: URL, for track: Track) async throws {
        let imported = try await storage.importFile(url, for: track)
        try Task.checkCancellation()
        guard current.map({ LyricsIdentity.key(for: $0) }) == LyricsIdentity.key(for: track) else { return }
        generation = UUID(); request?.cancel(); request = nil
        installedDocument(imported); status = .ready; error = nil; manualDocument = true
    }
    func activeIndex(at seconds: Double) -> Int? { document?.activeIndex(at: seconds) }

    private func read(_ track: Track) async throws -> LoadResult {
        if let value = try await storage.imported(for: track) { return .init(document: value, manual: true) }
        try Task.checkCancellation()
        if let value = try await storage.sidecar(for: track) { return .init(document: value, manual: true) }
        try Task.checkCancellation()
        if let value = await storage.cachedOnline(for: track) { return .init(document: value, manual: true) }
        if track.source == .appleMusic, automaticAppleMusicLookup {
            guard !track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .init(document: nil, explanation: L10n.string("歌曲名或歌手资料不足，无法匹配歌词；可手动导入。"))
            }
            let value = try await online.lookup(track)
            try Task.checkCancellation()
            if let value { try? await storage.cacheOnline(value, for: track) }
            try Task.checkCancellation()
            return .init(document: value, manual: true, explanation: value == nil
                ? L10n.string("LRCLIB 未找到与这首歌的歌名、歌手和时长匹配的歌词。可重新查找或导入歌词文件。") : nil)
        }
        if track.source == .soda {
            guard track.sodaPlayback != nil else {
                return .init(document: nil, explanation: L10n.string("播放时会读取汽水音乐当前可用片段及同步歌词。"))
            }
            if !(await client.connectedSources()).contains(.soda) {
                let key = LyricsIdentity.key(for: track)
                if let value = publicSodaCache[key] { return .init(document: value) }
                guard let payload = try await SodaDirectProvider().lyrics(track, cookies: []) else {
                    return .init(document: nil, explanation: L10n.string("汽水音乐未提供当前片段的歌词。"))
                }
                let value = try await Task.detached(priority: .utility) {
                    try LyricsParser.parse(payload, sourceDescription: MusicSource.soda.title)
                }.value
                try Task.checkCancellation()
                if publicSodaCache.count >= 16 { publicSodaCache.removeAll(keepingCapacity: true) }
                publicSodaCache[key] = value
                return .init(document: value)
            }
        }
        guard DirectMusicAccess.sources.contains(track.source) else {
            if track.source == .spotify { return .init(document: nil, explanation: L10n.string("Spotify 接口不提供歌词，可在 LRCLIB 查找或导入歌词文件。")) }
            let explanation = track.source == .appleMusic ? L10n.string("Apple Music 自动查词已关闭，可在线查找或导入歌词文件。") : L10n.string("没有找到同名歌词文件，可手动导入 LRC、SRT 或 TXT 歌词。")
            return .init(document: nil, explanation: explanation)
        }
        let scope = try await client.lyricsScope(for: track.source)
        let key = CacheKey(track: LyricsIdentity.key(for: track), scope: scope)
        if let value = cache[key] {
            try await client.validateLyricsScope(scope)
            return .init(document: value)
        }
        guard let payload = try await client.lyrics(track, scope: scope) else { return .init(document: nil, explanation: L10n.string("平台暂未提供这首歌曲的歌词，可手动导入。")) }
        let description = track.source.title
        let value = try await Task.detached(priority: .utility) { try LyricsParser.parse(payload, sourceDescription: description) }.value
        try Task.checkCancellation(); try await client.validateLyricsScope(scope)
        if cache.count >= 16 { cache.removeAll(keepingCapacity: true) }
        cache[key] = value
        return .init(document: value)
    }
    private func accountChanged(_ source: MusicSource) {
        cache = cache.filter { $0.key.scope.source != source }
        if source == .soda { publicSodaCache.removeAll(keepingCapacity: true) }
        if current?.source == source {
            audioSource = nil; cancelAlignment(); document = originalDocument
            audioAlignmentStatus = automaticAudioAlignment ? .waitingAudio : .off
        }
        guard let track = current, track.source == source, !manualDocument else { return }
        generation = UUID(); let token = generation
        request?.cancel(); request = nil
        document = nil; status = .loading; error = nil
        Task { [weak self] in
            guard let self, self.generation == token,
                  self.current.map({ LyricsIdentity.key(for: $0) }) == LyricsIdentity.key(for: track) else { return }
            await self.load(track: track)
        }
    }
}
