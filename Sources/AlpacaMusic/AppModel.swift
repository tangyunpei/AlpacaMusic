import SwiftUI
import Observation

enum Destination: Hashable { case home, library, favorites, sources, playlist(String) }
enum AppSheet: String, Identifiable { case url, playlist, visual, addToPlaylist, appleMusicSetup, qqOfficialPlayback; var id: String { rawValue } }

@MainActor @Observable
final class AppModel {
    let library: MusicLibrary
    let player: PlayerController
    let sourceService: SourceService
    let appleMusic: AppleMusicService
    let spotify: SpotifyService
    let accounts: ConnectedMusicAccounts
    let lyrics: LyricsController
    var destination: Destination = .home
    var query = ""
    var searchTerm = ""
    var remoteResults: [Track] = [] { didSet { remoteRevision &+= 1 } }
    private var remoteRevision: UInt64 = 0
    var searchErrors: [String] = []
    var searching = false
    var sodaPublicSearch: Bool {
        didSet { preferences.set(sodaPublicSearch, forKey: "soda-public-search") }
    }
    var sourceFilter: MusicSource? = nil
    var queueOpen = false
    var immersive = false
    var lyricsVisible = true
    var automaticAppleMusicLyrics: Bool {
        didSet {
            preferences.set(automaticAppleMusicLyrics, forKey: "apple-music-online-lyrics")
            let enabled = automaticAppleMusicLyrics
            Task { [weak self] in
                guard let self, self.automaticAppleMusicLyrics == enabled else { return }
                await self.lyrics.setAutomaticAppleMusicLookup(enabled)
            }
        }
    }
    var showLyricsImporter = false
    var lyricImportTarget: Track?
    var visualMode: VisualizationMode { didSet { preferences.set(visualMode.rawValue, forKey: "visualization-mode") } }
    var lyricPresentation: LyricPresentationMode { didSet { preferences.set(lyricPresentation.rawValue, forKey: "lyrics-presentation") } }
    var showImporter = false
    var importFolder = false
    var sheet: AppSheet?
    var selectedTrack: Track?
    var officialPlaybackTrack: Track?
    var notice: String?
    var visual: VisualSettings { didSet { persistVisual() } }
    var presets: [VisualPreset] { didSet { if let data = try? JSONEncoder().encode(presets) { preferences.set(data, forKey: "visual-presets") } } }
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var visibleCache: (key: VisibleTrackKey, tracks: [Track])?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(directory suppliedDirectory: URL? = nil, preferences suppliedDefaults: UserDefaults? = nil, ephemeralAccounts: Bool? = nil) {
        let directory = suppliedDirectory ?? ProcessInfo.processInfo.environment["ALPACA_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        preferences = suppliedDefaults ?? ProcessInfo.processInfo.environment["ALPACA_PREFERENCES_DOMAIN"].flatMap(UserDefaults.init(suiteName:)) ?? .standard
        sodaPublicSearch = preferences.object(forKey: "soda-public-search") as? Bool ?? true
        library = MusicLibrary(directory: directory)
        let isolatedAccounts = ephemeralAccounts ?? (ProcessInfo.processInfo.environment["ALPACA_EPHEMERAL_ACCOUNTS"] == "1")
        let native = NativeMusicClient(credentials: isolatedAccounts ? MemoryMusicCredentialStore() : MusicCredentialStore())
        accounts = ConnectedMusicAccounts(client: native)
        let automaticLyrics = preferences.object(forKey: "apple-music-online-lyrics") as? Bool ?? true
        automaticAppleMusicLyrics = automaticLyrics
        lyrics = LyricsController(client: native, directory: directory, automaticAppleMusicLookup: automaticLyrics)
        visualMode = preferences.string(forKey: "visualization-mode").flatMap(VisualizationMode.init(rawValue:)) ?? .pointCloud
        lyricPresentation = preferences.string(forKey: "lyrics-presentation").flatMap(LyricPresentationMode.init(rawValue:)) ?? .scroll
        sourceService = SourceService(native: native)
        appleMusic = AppleMusicService(defaults: preferences)
        spotify = SpotifyService(defaults: preferences, credentials: isolatedAccounts ? MemorySpotifyCredentialStore() : SpotifyCredentialStore())
        player = PlayerController(sources: sourceService, defaults: preferences, appleMusic: appleMusic, spotify: spotify)
        visual = (preferences.data(forKey: "visual-settings").flatMap { try? JSONDecoder().decode(VisualSettings.self, from: $0) } ?? .standard).validated()
        presets = preferences.data(forKey: "visual-presets").flatMap { try? JSONDecoder().decode([VisualPreset].self, from: $0) }?.map { VisualPreset(id: $0.id, name: $0.name, settings: $0.settings.validated()) } ?? []
    }

    var activeTrack: Track? { player.current ?? library.tracks.first }
    var canVisualizeActiveTrack: Bool { activeTrack?.source.supportsAudioAnalysis ?? true }
    var selectedPlaylist: MusicPlaylist? {
        if case let .playlist(id) = destination { return library.playlists.first { $0.id == id } }
        return nil
    }
    private struct VisibleTrackKey: Equatable {
        let destination: Destination
        let filter: MusicSource?
        let search: String
        let libraryRevision: UInt64
        let remoteRevision: UInt64
    }
    var visibleTracks: [Track] {
        let key = VisibleTrackKey(destination: destination, filter: sourceFilter, search: searchTerm,
                                  libraryRevision: library.listingRevision, remoteRevision: remoteRevision)
        if let cached = visibleCache, cached.key == key { return cached.tracks }
        let base: [Track]
        if !searchTerm.isEmpty {
            let local = library.tracks.filter { "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(searchTerm) }
            let ids = Set(local.map(\.id)); base = local + remoteResults.filter { !ids.contains($0.id) }
        } else {
            switch destination {
            case .favorites: base = library.tracks.filter { library.favorites.contains($0.id) }
            case .playlist: base = selectedPlaylist.map { library.tracks(withIDs: $0.trackIDs) } ?? []
            default: base = library.tracks
            }
        }
        let result = sourceFilter.map { source in base.filter { $0.source == source } } ?? base
        visibleCache = (key, result)
        return result
    }
    var pageTitle: String {
        if !searchTerm.isEmpty { return "搜索「\(searchTerm)」" }
        switch destination { case .home: return "此刻"; case .library: return "我的音乐库"; case .favorites: return "喜欢的音乐"; case .sources: return "音源"; case .playlist: return selectedPlaylist?.name ?? "我的歌单" }
    }

    func load() async {
        guard !loaded else { return }; loaded = true
        await library.load()
        player.sourceConfigurations = library.sources
        player.restoreQueue(library.tracks)
        if let error = library.error { notify(error) }
        async let accountRestore: Void = accounts.restore()
        async let spotifyRestore: Void = spotify.restore()
        await appleMusic.refresh()
        await accountRestore
        await spotifyRestore
    }
    func navigate(_ target: Destination) {
        searchTask?.cancel(); searching = false; query = ""; searchTerm = ""; remoteResults = []; searchErrors = []; sourceFilter = nil
        destination = target; immersive = false
    }
    func beginLyricsImport() {
        guard let track = player.current else { notify("先选择一首歌曲，再为它导入歌词。"); return }
        lyricImportTarget = track; showLyricsImporter = true
    }
    func revealLyrics() { lyricsVisible = true; immersive = true }
    func beginImport(folder: Bool) { importFolder = folder; showImporter = true }
    func importURLs(_ urls: [URL]) async {
        let result = await library.importURLs(urls)
        notify(result.errors.isEmpty ? "已导入 \(result.tracks.count) 首音乐" : "已导入 \(result.tracks.count) 首。\(result.errors.first ?? "")")
    }
    func play(_ track: Track, context: [Track]? = nil) {
        Task { await player.play(track, context: context ?? visibleTracks) }
    }
    func showOfficialQQPlayback(_ track: Track) {
        guard QQOfficialPlaybackPolicy.detailURL(for: track) != nil else { return }
        player.pause()
        officialPlaybackTrack = track
        sheet = .qqOfficialPlayback
    }
    func toggle() async {
        if player.current == nil, let first = library.tracks.first { await player.play(first, context: library.tracks) }
        else { await player.toggle() }
    }
    func search() {
        searchTask?.cancel()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTerm = term; destination = .library; immersive = false; remoteResults = []; searchErrors = []
        guard !term.isEmpty else { searching = false; return }
        searching = true
        let configs = library.sources
        let publicSoda = sodaPublicSearch
        searchTask = Task { [weak self] in
            guard let self else { return }
            async let configuredResults = sourceService.search(term, configurations: configs, includeSodaPublicly: publicSoda)
            var officialResults: [SourceSearchResult] = []
            if appleMusic.isEnabled {
                do { officialResults = [.init(source: .appleMusic, tracks: try await appleMusic.search(term))] }
                catch is CancellationError { if !Task.isCancelled { searching = false }; return }
                catch { officialResults = [.init(source: .appleMusic, tracks: [], error: error.localizedDescription)] }
            }
            if spotify.isEnabled {
                do { officialResults.append(.init(source: .spotify, tracks: try await spotify.search(term))) }
                catch is CancellationError { if !Task.isCancelled { searching = false }; return }
                catch { officialResults.append(.init(source: .spotify, tracks: [], error: SpotifyService.message(error))) }
            }
            let results = await configuredResults + officialResults
            guard !Task.isCancelled else { return }
            remoteResults = results.flatMap(\.tracks)
            searchErrors = results.compactMap { result in result.error.map { "\(result.source.title)：\($0)" } }
            searching = false
        }
    }
    func favorite(_ track: Track) { library.addTracks([track]); library.toggleFavorite(track.id) }
    func disconnectAccount(_ source: MusicSource) async {
        if player.current?.source == source { player.pause() }
        searchTask?.cancel(); searching = false; remoteResults.removeAll { $0.source == source }
        await accounts.disconnect(source)
        notify(accounts.state(source).error ?? "已退出\(source.title)，已导入的歌单保留")
    }
    func disconnectAppleMusic() {
        if player.current?.source == .appleMusic { player.pause() }
        appleMusic.disconnect()
        searchTask?.cancel(); searching = false
        remoteResults.removeAll { $0.source == .appleMusic }
        notify("Apple Music 已停用。系统授权可在系统设置中管理。")
    }
    func remove(_ track: Track) { player.removeFromQueue(track.id); library.removeTrack(track.id); notify("已从音乐库移除，原文件保留") }
    func addLink(title: String, address: String) throws {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw MusicError.message("请输入不含账号密码的 HTTP 或 HTTPS 音频链接") }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let track = Track(id: "url-\(UUID().uuidString)", title: clean.isEmpty ? (url.host ?? "网络音频") : clean, artist: "网络音频", album: "我的链接", duration: 0, source: .url, url: url)
        library.addTracks([track]); navigate(.library); sheet = nil; notify("音频链接已加入音乐库")
    }
    func saveSource(_ config: SourceConfiguration) throws {
        let next = library.sources.map { $0.id == config.id ? config : $0 }
        try library.saveSources(next); player.sourceConfigurations = next
    }
    func savePreset(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty else { return }
        presets.removeAll { $0.name == clean }; presets.append(.init(name: clean, settings: visual)); if presets.count > 12 { presets.removeFirst() }; notify("视觉预设已保存")
    }
    func notify(_ message: String) {
        noticeTask?.cancel(); notice = message
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            self?.notice = nil
        }
    }
    private func persistVisual() { if let data = try? JSONEncoder().encode(visual) { preferences.set(data, forKey: "visual-settings") } }
}

extension VisualSettings {
    func validated() -> Self {
        var v = self
        func clamp(_ value: Float, _ low: Float, _ high: Float, _ fallback: Float) -> Float { value.isFinite ? min(high, max(low, value)) : fallback }
        v.density = [96, 160, 224].contains(v.density) ? v.density : 160
        v.pointSize = clamp(v.pointSize, 0.5, 4, 1.8); v.depth = clamp(v.depth, 0, 1, 0.35)
        v.bounce = clamp(v.bounce, 0, 0.4, 0.16); v.speed = clamp(v.speed, 0.5, 8, 3.5)
        v.frequency = clamp(v.frequency, 1, 10, 4); v.idle = clamp(v.idle, 0, 0.05, 0.012)
        v.scheme = v.scheme == 1 ? 1 : 0
        return v
    }
}
