import SwiftUI
import Observation

enum Destination: Hashable { case home, library, albums, favorites, sources, playlist(String), album(String), search }
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
    /// Imports a newly connected account's collections in the background (C4).
    let autoImport: AutoImportCoordinator
    /// Charts and recommendations shown on the Now page.
    let browse: BrowseStore
    /// Fades the immersive room's controls while the listener is idle.
    let immersiveChrome = ImmersiveChromeController()
    var language: AppLanguage {
        didSet {
            preferences.set(language.rawValue, forKey: L10n.preferenceKey)
            L10n.setLanguage(language)
        }
    }
    var destination: Destination = .home
    /// The pages behind the current one that Back returns to: the page a
    /// search started from, then the results when an album was opened from them.
    private(set) var trail: [Destination] = []
    var query = ""
    /// The current search's results; they outlive opening an album from them.
    let searchResults: SearchStore
    var sodaPublicSearch: Bool {
        didSet { preferences.set(sodaPublicSearch, forKey: "soda-public-search") }
    }
    /// Shows the status bar player; while it is shown, closing the last
    /// window keeps the app (and playback) running from the menu bar.
    var showsMenuBarPlayer: Bool {
        didSet { preferences.set(showsMenuBarPlayer, forKey: "menu-bar-player") }
    }
    /// Shows the current lyric just below the menu bar while music plays.
    var showsMenuBarLyrics: Bool {
        didSet { preferences.set(showsMenuBarLyrics, forKey: "menu-bar-lyrics") }
    }
    /// The mini player's layout: artwork, lyric strip or card.
    var miniPlayerStyle: MiniPlayerStyle {
        didSet { preferences.set(miniPlayerStyle.rawValue, forKey: "mini-player-style") }
    }
    /// True while any menu bar item is shown; closing the last window then
    /// keeps the app (and playback) running.
    var hasMenuBarPresence: Bool { showsMenuBarPlayer || showsMenuBarLyrics }
    var sourceFilter: MusicSource? = nil
    var queueOpen = false
    var immersive = false {
        didSet {
            if !immersive { immersiveOpenedForLyrics = false }
            // The room's view starts the controller when it appears.
            if !immersive { immersiveChrome.deactivate() }
        }
    }
    var lyricsVisible = true
    /// True while the immersive view is open only because the lyrics button
    /// opened it, so closing the lyrics returns to the library.
    @ObservationIgnored private var immersiveOpenedForLyrics = false
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
    /// Use word timing from a signed-in NetEase or QQ account for Apple Music.
    var appleMusicPlatformWordLyrics: Bool {
        didSet {
            preferences.set(appleMusicPlatformWordLyrics, forKey: "apple-music-platform-word-lyrics")
            let enabled = appleMusicPlatformWordLyrics
            Task { [weak self] in
                guard let self, self.appleMusicPlatformWordLyrics == enabled else { return }
                await self.lyrics.setPlatformWordLyrics(enabled)
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
    static let abstractionDefaultMoved = "visual-abstraction-default-moved-to-0"
    var presets: [VisualPreset] { didSet { if let data = try? JSONEncoder().encode(presets) { preferences.set(data, forKey: "visual-presets") } } }
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var visibleCache: (key: VisibleTrackKey, tracks: [Track])?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var albumIndexCache: (revision: UInt64, ids: [String: String])?
    @ObservationIgnored private var libraryIndexCache: (revision: UInt64, ids: Set<String>, keys: Set<String>)?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// The listener's latest play request. A list still loading its songs
    /// plays only if nothing was chosen after it.
    @ObservationIgnored private var playIntent = UUID()
    @ObservationIgnored private var lyricsSync: LyricsSync?

    /// `browseLoader` replaces the platforms behind the Now page's charts in
    /// tests, and `searchLoader` the services a search asks.
    init(directory suppliedDirectory: URL? = nil, preferences suppliedDefaults: UserDefaults? = nil, ephemeralAccounts: Bool? = nil,
         browseLoader: (any BrowseLoading)? = nil, searchLoader: (any SearchLoading)? = nil) {
        let directory = suppliedDirectory ?? ProcessInfo.processInfo.environment["ALPACA_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        preferences = suppliedDefaults ?? ProcessInfo.processInfo.environment["ALPACA_PREFERENCES_DOMAIN"].flatMap(UserDefaults.init(suiteName:)) ?? .standard
        language = L10n.preference(in: preferences)
        sodaPublicSearch = preferences.object(forKey: "soda-public-search") as? Bool ?? true
        showsMenuBarPlayer = preferences.object(forKey: "menu-bar-player") as? Bool ?? true
        showsMenuBarLyrics = preferences.object(forKey: "menu-bar-lyrics") as? Bool ?? true
        miniPlayerStyle = preferences.string(forKey: "mini-player-style").flatMap(MiniPlayerStyle.init(rawValue:)) ?? .lyrics
        library = MusicLibrary(directory: directory)
        let isolatedAccounts = ephemeralAccounts ?? (ProcessInfo.processInfo.environment["ALPACA_EPHEMERAL_ACCOUNTS"] == "1")
        let native = NativeMusicClient(credentials: isolatedAccounts ? MemoryMusicCredentialStore() : MusicCredentialStore())
        accounts = ConnectedMusicAccounts(client: native)
        let automaticLyrics = preferences.object(forKey: "apple-music-online-lyrics") as? Bool ?? true
        automaticAppleMusicLyrics = automaticLyrics
        let platformWords = preferences.object(forKey: "apple-music-platform-word-lyrics") as? Bool ?? true
        appleMusicPlatformWordLyrics = platformWords
        let audioAlignment = preferences.object(forKey: "lyrics-audio-alignment") as? Bool ?? true
        automaticLyricAudioAlignment = audioAlignment
        lyrics = LyricsController(client: native, directory: directory, automaticAppleMusicLookup: automaticLyrics,
                                  platformWordLyrics: platformWords, automaticAudioAlignment: audioAlignment)
        visualMode = preferences.string(forKey: "visualization-mode").flatMap(VisualizationMode.init(rawValue:)) ?? .standard
        lyricPresentation = preferences.string(forKey: "lyrics-presentation").flatMap(LyricPresentationMode.init(rawValue:)) ?? .scroll
        sourceService = SourceService(native: native)
        appleMusic = AppleMusicService(defaults: preferences)
        spotify = SpotifyService(defaults: preferences, credentials: isolatedAccounts ? MemorySpotifyCredentialStore() : SpotifyCredentialStore())
        player = PlayerController(sources: sourceService, defaults: preferences, appleMusic: appleMusic, spotify: spotify)
        autoImport = AutoImportCoordinator(library: library, accounts: accounts, appleMusic: appleMusic, spotify: spotify)
        browse = BrowseStore(loader: browseLoader ?? PlatformBrowseLoader(accounts: accounts, appleMusic: appleMusic), defaults: preferences)
        searchResults = SearchStore(loader: searchLoader ?? PlatformSearchLoader(sources: sourceService, appleMusic: appleMusic, spotify: spotify),
                                    preferences: preferences)
        var savedVisual = (preferences.data(forKey: "visual-settings").flatMap { try? JSONDecoder().decode(VisualSettings.self, from: $0) } ?? .standard).validated()
        // Abstraction's default moved from 0.2 to 0 (true colours, every point).
        // Settings saved at the old default move with it, once; a value the
        // listener chose themselves stays.
        if !preferences.bool(forKey: Self.abstractionDefaultMoved) {
            if savedVisual.abstraction == 0.2, preferences.data(forKey: "visual-settings") != nil {
                savedVisual.abstraction = 0
                if let data = try? JSONEncoder().encode(savedVisual) { preferences.set(data, forKey: "visual-settings") }
            }
            preferences.set(true, forKey: Self.abstractionDefaultMoved)
        }
        visual = savedVisual
        presets = preferences.data(forKey: "visual-presets").flatMap { try? JSONDecoder().decode([VisualPreset].self, from: $0) }?.map { VisualPreset(id: $0.id, name: $0.name, settings: $0.settings.validated()) } ?? []
        autoImport.onNotice = { [weak self] message in self?.notify(message) }
    }

    var activeTrack: Track? { player.current ?? library.tracks.first }
    /// A "Needs live audio" effect has nothing to draw for a source that
    /// gives no audio (Apple Music, Spotify), so the cover stands in while
    /// such a song is the current one, on the Now stage and in the room.
    /// Decided when drawn: `visualMode` keeps the listener's choice, which is
    /// back with the next song that has live audio. Whether the source can
    /// give audio decides this, not whether samples have arrived yet.
    var coverStandsIn: Bool { player.current?.source.supportsAudioAnalysis == false && visualMode.isSignalDisplay }
    /// The effect actually drawn: the chosen one, or Album artwork standing in.
    var shownVisualMode: VisualizationMode { coverStandsIn ? .artwork : visualMode }
    var selectedPlaylist: MusicPlaylist? {
        if case let .playlist(id) = destination { return library.playlists.first { $0.id == id } }
        return nil
    }
    var selectedAlbum: MusicAlbum? {
        if case let .album(id) = destination { return library.album(id: id) }
        return nil
    }
    var albumTracks: [Track] {
        selectedAlbum.map { library.tracks(withIDs: $0.trackIDs) } ?? []
    }
    var visibleAlbums: [MusicAlbum] {
        let albums = library.albums
        return sourceFilter.map { source in albums.filter { $0.source == source } } ?? albums
    }
    private struct VisibleTrackKey: Equatable {
        let destination: Destination
        let filter: MusicSource?
        let libraryRevision: UInt64
    }
    var visibleTracks: [Track] {
        // The results change without the library changing; they are not cached here.
        if destination == .search { return searchResults.shownRows.map(\.track) }
        let key = VisibleTrackKey(destination: destination, filter: sourceFilter, libraryRevision: library.listingRevision)
        if let cached = visibleCache, cached.key == key { return cached.tracks }
        let base: [Track]
        switch destination {
        case .favorites: base = library.tracks.filter { library.favorites.contains($0.id) }
        case .playlist: base = selectedPlaylist.map { library.tracks(withIDs: $0.trackIDs) } ?? []
        case .album: base = albumTracks
        default: base = library.tracks
        }
        let result = sourceFilter.map { source in base.filter { $0.source == source } } ?? base
        visibleCache = (key, result)
        return result
    }
    /// True for a library track, or a track whose title and singer match a library song.
    func isInLibrary(_ track: Track) -> Bool {
        let index = libraryIndex
        return index.ids.contains(track.id) || index.keys.contains(Self.matchKey(track))
    }
    /// True only when this exact track is saved in the library.
    func isLibraryTrack(_ track: Track) -> Bool { libraryIndex.ids.contains(track.id) }
    /// The library album that holds this song, for the results' album links.
    func libraryAlbumID(containing trackID: String) -> String? {
        let revision = library.listingRevision
        if albumIndexCache?.revision != revision {
            var index: [String: String] = [:]
            for album in library.albums { for id in album.trackIDs where index[id] == nil { index[id] = album.id } }
            albumIndexCache = (revision, index)
        }
        return albumIndexCache?.ids[trackID]
    }
    /// A result row is in the library when any of its copies is.
    func isInLibrary(_ row: SearchRow) -> Bool { row.copies.contains { isInLibrary($0.track) } }
    /// The song a row's like, playlist and menu act on: the library's own copy
    /// when there is one, so an action never saves a second copy.
    func actionTrack(for row: SearchRow) -> Track {
        let index = libraryIndex
        if let saved = row.copies.first(where: { index.ids.contains($0.track.id) }) { return saved.track }
        let key = Self.matchKey(row.track)
        if index.keys.contains(key), let twin = library.tracks.first(where: { Self.matchKey($0) == key }) { return twin }
        return row.track
    }

    static func linkAddress(in text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty, let url = components.url else { return nil }
        return url
    }

    private static func matchKey(_ track: Track) -> String { SearchList.key(track) }

    private var libraryIndex: (ids: Set<String>, keys: Set<String>) {
        let revision = library.listingRevision
        if let cached = libraryIndexCache, cached.revision == revision { return (cached.ids, cached.keys) }
        let tracks = library.tracks
        let ids = Set(tracks.map(\.id))
        let keys = Set(tracks.compactMap { track in SearchList.fold(track.title).isEmpty ? nil : Self.matchKey(track) })
        libraryIndexCache = (revision, ids, keys)
        return (ids, keys)
    }

    var pageTitle: String {
        switch destination {
        case .search: return L10n.string("搜索「\(searchResults.term)」") case .home: return L10n.string("此刻"); case .library: return L10n.string("我的音乐库"); case .albums: return L10n.string("专辑库"); case .favorites: return L10n.string("喜欢的音乐"); case .sources: return L10n.string("音源"); case .playlist: return selectedPlaylist?.name ?? L10n.string("我的歌单"); case .album: return selectedAlbum?.name ?? L10n.string("专辑") }
    }

    func load() async {
        guard !loaded else { return }; loaded = true
        await library.load()
        player.sourceConfigurations = library.sources
        player.restoreQueue(library.tracks)
        startLyricsSync()
        if let error = library.error { notify(error) }
        async let accountRestore: Void = accounts.restore()
        async let spotifyRestore: Void = spotify.restore()
        await appleMusic.refresh()
        await accountRestore
        await spotifyRestore
    }
    /// Keeps lyrics loaded and aligned with playback whichever windows are
    /// open; calling it again while it runs does nothing.
    func startLyricsSync() {
        if lyricsSync == nil { lyricsSync = LyricsSync(player: player, lyrics: lyrics) }
        lyricsSync?.start()
    }
    /// Stops lyric loading and alignment, for example while quitting.
    func stopLyricsSync() { lyricsSync?.stop() }
    /// Goes to a page from the sidebar or a page's own link. It ends a search
    /// and its trail.
    func navigate(_ target: Destination) {
        searchResults.clear(); trail = []
        query = ""; sourceFilter = nil
        destination = target; immersive = false
    }
    /// Opens a page from the search results, keeping them to come back to.
    func open(_ target: Destination) {
        guard destination == .search || !trail.isEmpty else { navigate(target); return }
        trail.append(destination); sourceFilter = nil
        destination = target; immersive = false
    }
    /// True when Back has a page to return to.
    var canGoBack: Bool { !trail.isEmpty }
    /// Back: from an album opened from the results, to the same results; from
    /// the results, out of the search to the page it started from.
    func goBack() {
        guard let previous = trail.popLast() else { return }
        if destination == .search { searchResults.clear(); query = "" }
        else if previous == .search { query = searchResults.term }
        sourceFilter = nil
        destination = previous; immersive = false
    }
    /// Escape: back one page from a page opened from the results. On the
    /// results page it does nothing; elsewhere it clears the field as before.
    func escape() {
        if destination == .search { return }
        if canGoBack { goBack() } else { navigate(destination) }
    }
    /// The field's clear button: on the results page it clears the field only;
    /// on a page opened from them it goes back; elsewhere it clears as before.
    func clearSearchField() {
        if destination == .search { query = ""; return }
        if canGoBack { goBack() } else { navigate(destination) }
    }
    func beginLyricsImport() {
        guard let track = player.current else { notify(L10n.string("先选择一首歌曲，再为它导入歌词。")); return }
        lyricImportTarget = track; showLyricsImporter = true
    }
    func revealLyrics() {
        if !immersive { immersiveOpenedForLyrics = true }
        lyricsVisible = true; immersive = true
    }
    /// The player bar's lyrics button. It opens the lyrics, and closes them
    /// to where the listener was: the library when the button opened the
    /// immersive view, otherwise the immersive visuals.
    func toggleLyrics() {
        guard immersive, lyricsVisible else { revealLyrics(); return }
        if immersiveOpenedForLyrics { immersive = false } else { lyricsVisible = false }
        immersiveOpenedForLyrics = false
    }
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
        playIntent = UUID()
        Task { await player.play(track, context: context ?? visibleTracks) }
    }
    /// Plays a chart or recommended list from its first playable song, with
    /// the whole list as the queue. Its songs load once if not read yet.
    func play(_ collection: BrowseCollection) {
        let intent = UUID(); playIntent = intent
        let revision = player.listenerRevision
        Task {
            let tracks = await browse.tracksForPlayback(collection)
            // Anything the listener started meanwhile (a row, a key, next or
            // previous, play or pause) wins over this list.
            guard playIntent == intent, player.listenerRevision == revision else { return }
            guard let tracks else {
                if case .failed(let message) = browse.tracksState(for: collection) { notify(message) }
                return
            }
            guard let first = tracks.first(where: { !$0.unavailable }) else {
                notify(L10n.string("这个列表暂时没有可播放的歌曲。")); return
            }
            await player.play(first, context: tracks)
        }
    }
    func playAlbum() async {
        playIntent = UUID()
        let tracks = albumTracks
        guard let first = tracks.first(where: { !$0.unavailable }) else { return }
        if player.shuffle { player.toggleShuffle() }
        if player.repeatMode == .one { player.cycleRepeat() }
        await player.play(first, context: tracks)
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
    /// Searches for the field's text. The results are their own page; Back
    /// returns to where the search started, even when it started on a page
    /// opened from earlier results.
    func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        if destination != .search { trail = [trail.first ?? destination] } else if trail.isEmpty { trail = [.library] }
        destination = .search; immersive = false; sourceFilter = nil
        searchResults.start(term, library: library.tracks, configurations: library.sources, includeSodaPublicly: sodaPublicSearch,
                            isSaved: { [weak self] track in self?.isInLibrary(track) ?? false })
    }
    /// Saves an online song to the library (C3).
    func addToLibrary(_ track: Track) {
        guard !isLibraryTrack(track) else { return }
        library.addTracks([track])
        guard isLibraryTrack(track) else { return }
        notify(L10n.string("已加入音乐库"))
    }
    func favorite(_ track: Track) { library.addTracks([track]); library.toggleFavorite(track.id) }
    /// Removes one source's results, for example after it is disconnected.
    func clearSearchResults(for source: MusicSource) { searchResults.forget(source) }
    func disconnectAccount(_ source: MusicSource) async {
        autoImport.cancel(source)
        if player.current?.source == source { player.pause() }
        clearSearchResults(for: source)
        browse.forget(source)
        await accounts.disconnect(source)
        notify(accounts.state(source).error ?? L10n.string("已退出\(source.title)，已导入的歌单保留"))
    }
    func disconnectAppleMusic() {
        autoImport.cancel(.appleMusic)
        if player.current?.source == .appleMusic { player.pause() }
        appleMusic.disconnect()
        clearSearchResults(for: .appleMusic)
        browse.forget(.appleMusic)
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
        v.density = VisualSettings.densities.contains(v.density) ? v.density : 160
        v.abstraction = clamp(v.abstraction, 0, 1, 0)
        v.pointSize = clamp(v.pointSize, 0.5, 4, 1.8); v.depth = clamp(v.depth, 0, 1, 0.35)
        v.bounce = clamp(v.bounce, 0, 0.4, 0.16); v.speed = clamp(v.speed, 0.5, 8, 3.5)
        v.frequency = clamp(v.frequency, 1, 10, 4); v.idle = clamp(v.idle, 0, 0.05, 0.012)
        v.scheme = v.scheme == 1 ? 1 : 0
        return v
    }
}
