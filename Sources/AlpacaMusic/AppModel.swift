import SwiftUI
import Observation

enum Destination: Hashable { case home, library, favorites, sources, playlist(String) }
enum AppSheet: String, Identifiable { case url, playlist, visual, addToPlaylist, appleMusicSetup, qqOfficialPlayback; var id: String { rawValue } }

/// Live state of one source during a search.
struct SearchSourceStatus: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case searching
        case done(Int)
        case failed(String)
    }
    var source: MusicSource
    var state: State
    var id: MusicSource { source }
}

/// Library tracks grouped by album and artist for search results.
struct SearchAlbumMatch: Identifiable, Equatable, Sendable {
    var id: String
    var album: String
    var artist: String
    var tracks: [Track]
}

@MainActor @Observable
final class AppModel {
    let library: MusicLibrary
    let player: PlayerController
    let sourceService: SourceService
    let appleMusic: AppleMusicService
    let spotify: SpotifyService
    let accounts: ConnectedMusicAccounts
    let lyrics: LyricsController
    var language: AppLanguage {
        didSet {
            preferences.set(language.rawValue, forKey: L10n.preferenceKey)
            L10n.setLanguage(language)
        }
    }
    var destination: Destination = .home
    var query = ""
    var searchTerm = ""
    var remoteResults: [Track] = [] { didSet { remoteRevision &+= 1 } }
    private var remoteRevision: UInt64 = 0
    var searchErrors: [String] = []
    var searching = false
    private(set) var searchStatuses: [SearchSourceStatus] = []
    var sodaPublicSearch: Bool {
        didSet { preferences.set(sodaPublicSearch, forKey: "soda-public-search") }
    }
    var sourceFilter: MusicSource? = nil
    var queueOpen = false
    var immersive = false
    var lyricsVisible = true
    var automaticLyricAudioAlignment: Bool {
        didSet {
            preferences.set(automaticLyricAudioAlignment, forKey: "lyrics-audio-alignment")
            lyrics.setAutomaticAudioAlignment(automaticLyricAudioAlignment)
        }
    }
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
    @ObservationIgnored private var searchGeneration: UInt64 = 0
    @ObservationIgnored private var addedFromSearch: Set<String> = []
    @ObservationIgnored private var searchSectionCache: (key: VisibleTrackKey, sections: SearchSections)?
    @ObservationIgnored private var libraryIndexCache: (revision: UInt64, ids: Set<String>, keys: Set<String>)?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(directory suppliedDirectory: URL? = nil, preferences suppliedDefaults: UserDefaults? = nil, ephemeralAccounts: Bool? = nil) {
        let directory = suppliedDirectory ?? ProcessInfo.processInfo.environment["ALPACA_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        preferences = suppliedDefaults ?? ProcessInfo.processInfo.environment["ALPACA_PREFERENCES_DOMAIN"].flatMap(UserDefaults.init(suiteName:)) ?? .standard
        language = L10n.preference(in: preferences)
        sodaPublicSearch = preferences.object(forKey: "soda-public-search") as? Bool ?? true
        library = MusicLibrary(directory: directory)
        let isolatedAccounts = ephemeralAccounts ?? (ProcessInfo.processInfo.environment["ALPACA_EPHEMERAL_ACCOUNTS"] == "1")
        let native = NativeMusicClient(credentials: isolatedAccounts ? MemoryMusicCredentialStore() : MusicCredentialStore())
        accounts = ConnectedMusicAccounts(client: native)
        let automaticLyrics = preferences.object(forKey: "apple-music-online-lyrics") as? Bool ?? true
        automaticAppleMusicLyrics = automaticLyrics
        let audioAlignment = preferences.object(forKey: "lyrics-audio-alignment") as? Bool ?? true
        automaticLyricAudioAlignment = audioAlignment
        lyrics = LyricsController(client: native, directory: directory, automaticAppleMusicLookup: automaticLyrics, automaticAudioAlignment: audioAlignment)
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
    private struct SearchSections {
        var library: [Track]
        var online: [Track]
        var albums: [SearchAlbumMatch]
        var onlineInLibrary: Set<String>
    }
    /// Library tracks matching the current search (source filter applied).
    var searchLibraryMatches: [Track] { searchSections.library }
    /// Remote results that are not library tracks. Songs added from this
    /// search stay here, marked as added, instead of jumping sections.
    var searchOnlineResults: [Track] { searchSections.online }
    /// Library albums whose title or artist matches the current search.
    var searchAlbumMatches: [SearchAlbumMatch] { searchSections.albums }
    /// The trimmed search term when it is a single HTTP(S) address.
    var searchLink: URL? { Self.linkAddress(in: searchTerm) }

    /// True for a library track, or a remote track whose title and artist
    /// match a library song.
    func isInLibrary(_ track: Track) -> Bool {
        let index = libraryIndex
        if index.ids.contains(track.id) { return true }
        if searchSections.onlineInLibrary.contains(track.id) { return true }
        return index.keys.contains(Self.matchKey(track))
    }
    /// True only when this exact track is saved in the library.
    func isLibraryTrack(_ track: Track) -> Bool { libraryIndex.ids.contains(track.id) }
    /// True for an online search result whose title and artist match a library song.
    func searchResultMatchesLibrary(_ track: Track) -> Bool { searchSections.onlineInLibrary.contains(track.id) }

    static func linkAddress(in text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty, let url = components.url else { return nil }
        return url
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func matchKey(_ track: Track) -> String {
        fold(track.title) + "\u{1F}" + fold(track.artist)
    }

    private var libraryIndex: (ids: Set<String>, keys: Set<String>) {
        let revision = library.listingRevision
        if let cached = libraryIndexCache, cached.revision == revision { return (cached.ids, cached.keys) }
        let tracks = library.tracks
        let ids = Set(tracks.map(\.id))
        let keys = Set(tracks.compactMap { track in Self.fold(track.title).isEmpty ? nil : Self.matchKey(track) })
        libraryIndexCache = (revision, ids, keys)
        return (ids, keys)
    }

    private var searchSections: SearchSections {
        let key = VisibleTrackKey(destination: .library, filter: sourceFilter, search: searchTerm,
                                  libraryRevision: library.listingRevision, remoteRevision: remoteRevision)
        if let cached = searchSectionCache, cached.key == key { return cached.sections }
        let sections = makeSearchSections()
        searchSectionCache = (key, sections)
        return sections
    }

    private func makeSearchSections() -> SearchSections {
        let term = searchTerm
        guard !term.isEmpty else { return SearchSections(library: [], online: [], albums: [], onlineInLibrary: []) }
        let filter = sourceFilter
        let added = addedFromSearch
        let index = libraryIndex
        let candidates = library.tracks.filter { track in
            !added.contains(track.id) && (filter == nil || track.source == filter)
        }
        let matches = candidates.filter { "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(term) }
        // Only tracks already shown in the library section are left out, so a
        // saved song a service matched by alias or translation stays visible.
        let matchIDs = Set(matches.map(\.id))
        var online: [Track] = []
        var seen = Set<String>()
        var onlineInLibrary = Set<String>()
        for track in remoteResults where filter == nil || track.source == filter {
            guard seen.insert(track.id).inserted, !matchIDs.contains(track.id) else { continue }
            online.append(track)
            if !index.ids.contains(track.id), index.keys.contains(Self.matchKey(track)) { onlineInLibrary.insert(track.id) }
        }
        let unknownAlbum = L10n.string("未知专辑"), linkAlbum = L10n.string("我的链接")
        var albumOrder: [String] = []
        var albumTracks: [String: [Track]] = [:]
        for track in matches {
            let album = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !album.isEmpty, album != unknownAlbum, album != linkAlbum,
                  album.localizedCaseInsensitiveContains(term) || track.artist.localizedCaseInsensitiveContains(term) else { continue }
            let id = Self.fold(album) + "\u{1F}" + Self.fold(track.artist)
            if albumTracks[id] == nil { albumOrder.append(id) }
            albumTracks[id, default: []].append(track)
        }
        let albums: [SearchAlbumMatch] = albumOrder.compactMap { id in
            guard let tracks = albumTracks[id], tracks.count > 1, let first = tracks.first else { return nil }
            return SearchAlbumMatch(id: id, album: first.album, artist: first.artist, tracks: tracks)
        }
        return SearchSections(library: matches, online: online, albums: Array(albums.prefix(12)), onlineInLibrary: onlineInLibrary)
    }

    var pageTitle: String {
        if !searchTerm.isEmpty { return L10n.string("搜索「\(searchTerm)」") }
        switch destination { case .home: return L10n.string("此刻"); case .library: return L10n.string("我的音乐库"); case .favorites: return L10n.string("喜欢的音乐"); case .sources: return L10n.string("音源"); case .playlist: return selectedPlaylist?.name ?? L10n.string("我的歌单") }
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
        stopSearch(); searchStatuses = []; addedFromSearch = []
        query = ""; searchTerm = ""; remoteResults = []; searchErrors = []; sourceFilter = nil
        destination = target; immersive = false
    }
    func beginLyricsImport() {
        guard let track = player.current else { notify(L10n.string("先选择一首歌曲，再为它导入歌词。")); return }
        lyricImportTarget = track; showLyricsImporter = true
    }
    func revealLyrics() { lyricsVisible = true; immersive = true }
    /// The single entry point for the local file importer; a running import
    /// keeps it closed instead of failing after the user picks files.
    func beginImport(folder: Bool) {
        guard !library.busy else { return }
        importFolder = folder; showImporter = true
    }
    func importURLs(_ urls: [URL]) async {
        let result = await library.importURLs(urls)
        notify(result.errors.isEmpty ? L10n.string("已导入 \(result.tracks.count) 首音乐") : L10n.string("已导入 \(result.tracks.count) 首。\(result.errors.first ?? "")"))
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
        stopSearch()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTerm = term; destination = .library; immersive = false; remoteResults = []; searchErrors = []
        searchStatuses = []; addedFromSearch = []
        // An address is offered as a link to add; it is never sent to search services.
        guard !term.isEmpty, Self.linkAddress(in: term) == nil else { return }
        searching = true
        let configs = library.sources
        let publicSoda = sodaPublicSearch
        let token = searchGeneration
        searchTask = Task { [weak self] in
            guard let self else { return }
            await self.performSearch(term, token: token, configurations: configs, includeSodaPublicly: publicSoda)
        }
    }
    /// Cancels the running search; late results of that search are ignored.
    private func stopSearch() {
        searchTask?.cancel(); searchTask = nil
        searchGeneration &+= 1
        searching = false
        searchStatuses.removeAll { $0.state == .searching }
    }
    private func isCurrentSearch(_ token: UInt64) -> Bool { !Task.isCancelled && token == searchGeneration }
    private func performSearch(_ term: String, token: UInt64, configurations: [SourceConfiguration], includeSodaPublicly: Bool) async {
        let service = sourceService
        let apple = appleMusic
        let spotifyService = spotify
        let includeApple = apple.isEnabled
        let includeSpotify = spotifyService.isEnabled
        var sources = await service.searchTargets(configurations: configurations, includeSodaPublicly: includeSodaPublicly)
        if includeApple { sources.append(.appleMusic) }
        if includeSpotify { sources.append(.spotify) }
        guard isCurrentSearch(token) else { return }
        searchStatuses = sources.map { SearchSourceStatus(source: $0, state: .searching) }
        let deliver: @MainActor @Sendable (SourceSearchResult) -> Void = { result in
            self.receiveSearchResult(result, token: token)
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = await service.search(term, configurations: configurations, includeSodaPublicly: includeSodaPublicly, onResult: deliver)
            }
            if includeApple {
                group.addTask {
                    let result = await AppModel.appleMusicSearchResult(apple, term: term)
                    await deliver(result)
                }
            }
            if includeSpotify {
                group.addTask {
                    let result = await AppModel.spotifySearchResult(spotifyService, term: term)
                    await deliver(result)
                }
            }
            await group.waitForAll()
        }
        guard isCurrentSearch(token) else { return }
        // Sources that returned nothing (for example an over-long query) settle as empty.
        for index in searchStatuses.indices where searchStatuses[index].state == .searching {
            searchStatuses[index].state = .done(0)
        }
        searching = false
    }
    private static func appleMusicSearchResult(_ service: AppleMusicService, term: String) async -> SourceSearchResult {
        do { return SourceSearchResult(source: .appleMusic, tracks: try await service.search(term)) }
        catch is CancellationError { return SourceSearchResult(source: .appleMusic, tracks: []) }
        catch { return SourceSearchResult(source: .appleMusic, tracks: [], error: AppleMusicErrorMessage.describe(error)) }
    }
    private static func spotifySearchResult(_ service: SpotifyService, term: String) async -> SourceSearchResult {
        do { return SourceSearchResult(source: .spotify, tracks: try await service.search(term)) }
        catch is CancellationError { return SourceSearchResult(source: .spotify, tracks: []) }
        catch { return SourceSearchResult(source: .spotify, tracks: [], error: SpotifyService.message(error)) }
    }
    /// Publishes one source's result, appending tracks not already shown.
    private func receiveSearchResult(_ result: SourceSearchResult, token: UInt64) {
        guard isCurrentSearch(token), isSearchSourceActive(result.source) else { return }
        let state: SearchSourceStatus.State
        if let error = result.error { state = .failed(error) } else { state = .done(result.tracks.count) }
        if let index = searchStatuses.firstIndex(where: { $0.source == result.source }) { searchStatuses[index].state = state }
        else { searchStatuses.append(SearchSourceStatus(source: result.source, state: state)) }
        if let error = result.error { searchErrors.append(L10n.string("\(result.source.title)：\(error)")) }
        var seen = Set(remoteResults.map(\.id))
        let additions = result.tracks.filter { seen.insert($0.id).inserted }
        if !additions.isEmpty { remoteResults.append(contentsOf: additions) }
    }
    /// Saves a search result to the library (C3).
    func addToLibrary(_ track: Track) {
        guard !isLibraryTrack(track) else { return }
        library.addTracks([track])
        // A full library skips the song and sets its own error; only a song
        // that was actually saved is marked added and reported as such.
        guard isLibraryTrack(track) else {
            notify(library.error ?? L10n.string("音乐库最多保存 10000 首歌曲"))
            return
        }
        addedFromSearch.insert(track.id)
        notify(L10n.string("已加入音乐库"))
    }
    func favorite(_ track: Track) { library.addTracks([track]); library.toggleFavorite(track.id) }
    /// Stops the running search and removes one source's status and results,
    /// for example after that source is disconnected.
    func clearSearchResults(for source: MusicSource) {
        stopSearch()
        searchStatuses.removeAll { $0.source == source }
        remoteResults.removeAll { $0.source == source }
    }
    /// Statuses to show; an official service that was turned off since the
    /// search started is hidden even if its owner did not clear it.
    var visibleSearchStatuses: [SearchSourceStatus] {
        searchStatuses.filter { isSearchSourceActive($0.source) }
    }
    private func isSearchSourceActive(_ source: MusicSource) -> Bool {
        switch source {
        case .spotify: spotify.isEnabled
        case .appleMusic: appleMusic.isEnabled
        default: true
        }
    }
    func disconnectAccount(_ source: MusicSource) async {
        if player.current?.source == source { player.pause() }
        clearSearchResults(for: source)
        await accounts.disconnect(source)
        notify(accounts.state(source).error ?? L10n.string("已退出\(source.title)，已导入的歌单保留"))
    }
    func disconnectAppleMusic() {
        if player.current?.source == .appleMusic { player.pause() }
        appleMusic.disconnect()
        clearSearchResults(for: .appleMusic)
        notify(L10n.string("Apple Music 已停用。系统授权可在系统设置中管理。"))
    }
    func remove(_ track: Track) { player.removeFromQueue(track.id); library.removeTrack(track.id); notify(L10n.string("已从音乐库移除，原文件保留")) }
    func addLink(title: String, address: String) throws {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw MusicError.message(L10n.string("请输入不含账号密码的 HTTP 或 HTTPS 音频链接")) }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let track = Track(id: "url-\(UUID().uuidString)", title: clean.isEmpty ? (url.host ?? L10n.string("网络音频")) : clean, artist: L10n.string("网络音频"), album: L10n.string("我的链接"), duration: 0, source: .url, url: url)
        library.addTracks([track]); navigate(.library); sheet = nil; notify(L10n.string("音频链接已加入音乐库"))
    }
    func saveSource(_ config: SourceConfiguration) throws {
        let next = library.sources.map { $0.id == config.id ? config : $0 }
        try library.saveSources(next); player.sourceConfigurations = next
    }
    func savePreset(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty else { return }
        presets.removeAll { $0.name == clean }; presets.append(.init(name: clean, settings: visual)); if presets.count > 12 { presets.removeFirst() }; notify(L10n.string("视觉预设已保存"))
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
