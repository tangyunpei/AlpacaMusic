import Foundation
import Observation

/// How one service's part of a page is doing.
enum SourceLoad: Equatable, Sendable {
    case loading
    case loaded(more: Bool)
    case failed(String)
    /// The service has no such singer, or cannot be asked.
    case none
    var more: Bool { if case .loaded(let more) = self { more } else { false } }
}

/// One singer across the linked services: who they are on each, their albums
/// newest first and their songs. The search page's singer card and the
/// singer page share it, so opening the page asks nothing again.
@MainActor @Observable
final class SingerStore: Identifiable {
    /// The names as the card shows them, first one first.
    let names: [String]
    let id: String
    private(set) var profiles: [SingerProfile] = []
    private(set) var finding = true
    /// Every service's albums so far, in `AlbumOrder`.
    private(set) var albums: [SingerAlbum] = []
    private(set) var albumLoads: [MusicSource: SourceLoad] = [:]
    private(set) var songRows: [SearchRow] = []
    private(set) var songLoads: [MusicSource: SourceLoad] = [:]
    /// The singer page's source pill; nil shows every service.
    var filter: MusicSource?

    @ObservationIgnored private let loader: any SearchLoading
    @ObservationIgnored private let sources: [MusicSource]
    @ObservationIgnored private var query: [MusicSource: String]
    @ObservationIgnored private var albumCounts: [MusicSource: Int] = [:]
    @ObservationIgnored private var songCounts: [MusicSource: Int] = [:]
    @ObservationIgnored private var isSaved: (Track) -> Bool
    @ObservationIgnored private var started = false
    @ObservationIgnored private var asking: Set<String> = []

    static func key(_ names: [String]) -> String { "singer:" + names.map(SearchList.fold).sorted().joined(separator: "|") }

    /// `names` as the card shows them; `query` the name to look for on each
    /// service, where the songs said which spelling that service uses.
    init(names: [String], query: [MusicSource: String] = [:], sources: [MusicSource], loader: any SearchLoading,
         isSaved: @escaping (Track) -> Bool) {
        self.names = names
        self.id = Self.key(names)
        self.query = query
        self.sources = SearchSourceOrder.sorted(sources)
        self.loader = loader
        self.isSaved = isSaved
    }

    var primary: SingerProfile? { profiles.first }
    var pictureURL: URL? { profiles.lazy.compactMap(\.pictureURL).first }
    var latest: SingerAlbum? { AlbumOrder.latest(shownAlbums) }
    var shownAlbums: [SingerAlbum] { filter.map { source in albums.filter { $0.source == source } } ?? albums }
    var shownSongs: [SearchRow] { filter.map { SearchList.filter(songRows, by: .source($0)) } ?? songRows }
    var loadingAlbums: Bool { albumLoads.values.contains(.loading) }
    var loadingSongs: Bool { songLoads.values.contains(.loading) }
    func albumCount(_ source: MusicSource) -> Int { albums.filter { $0.source == source }.count }

    /// Finds the singer on every service, then each one's first albums and songs.
    func start() {
        guard !started else { return }
        started = true
        Task { [weak self] in await self?.find() }
    }

    private func find() async {
        let loader = loader, names = names, query = query
        let found = await withTaskGroup(of: (MusicSource, SingerProfile?).self) { group in
            for source in sources {
                group.addTask {
                    let name = query[source] ?? names.first ?? ""
                    let candidates = (try? await loader.singers(name, source: source)) ?? []
                    return (source, Self.match(candidates, names: [name] + names))
                }
            }
            var found: [MusicSource: SingerProfile] = [:]
            for await (source, profile) in group { found[source] = profile }
            return found
        }
        profiles = sources.compactMap { found[$0] }
        // Marked loading before the search counts as done, so the page never
        // shows a moment of "no albums" between the two.
        for source in sources {
            let load: SourceLoad = found[source] == nil ? .none : .loading
            albumLoads[source] = load; songLoads[source] = load
        }
        finding = false
        await withTaskGroup(of: Void.self) { group in
            for profile in profiles {
                group.addTask { await self.loadAlbums(profile) }
                group.addTask { await self.loadSongs(profile) }
            }
        }
    }

    /// The service's singer for these names: an exact name or alias, after
    /// folding, wins; otherwise the top result when its name contains the
    /// name looked for or the other way round; otherwise none.
    nonisolated static func match(_ candidates: [SingerProfile], names: [String]) -> SingerProfile? {
        let wanted = Set(names.map(SearchList.fold).filter { !$0.isEmpty })
        if let exact = candidates.first(where: { candidate in
            ([candidate.name] + candidate.aliases).contains { wanted.contains(SearchList.fold($0)) }
        }) { return exact }
        guard let top = candidates.first else { return nil }
        let name = SearchList.fold(top.name)
        return wanted.contains { !$0.isEmpty && (name.contains($0) || $0.contains(name)) } ? top : nil
    }

    /// The next albums from every service that has more.
    func loadMoreAlbums() {
        for profile in profiles where albumLoads[profile.source]?.more == true {
            Task { await loadAlbums(profile) }
        }
    }
    /// The next songs from every service that has more; they go below.
    func loadMoreSongs() {
        for profile in profiles where songLoads[profile.source]?.more == true {
            Task { await loadSongs(profile) }
        }
    }

    private func loadAlbums(_ profile: SingerProfile) async {
        guard asking.insert("albums:" + profile.id).inserted else { return }
        defer { asking.remove("albums:" + profile.id) }
        albumLoads[profile.source] = .loading
        do {
            let page = try await loader.albums(of: profile, offset: albumCounts[profile.source] ?? 0)
            albumCounts[profile.source, default: 0] += page.items.count
            var known = Set(albums.map(\.id))
            albums = AlbumOrder.sorted(albums + page.items.filter { known.insert($0.id).inserted })
            albumLoads[profile.source] = .loaded(more: page.more && !page.items.isEmpty)
        } catch {
            albumLoads[profile.source] = .failed(error.localizedDescription)
        }
    }

    private func loadSongs(_ profile: SingerProfile) async {
        guard asking.insert("songs:" + profile.id).inserted else { return }
        defer { asking.remove("songs:" + profile.id) }
        songLoads[profile.source] = .loading
        do {
            let start = songCounts[profile.source] ?? 0
            let page = try await loader.songs(of: profile, offset: start)
            songCounts[profile.source, default: 0] += page.items.count
            let copies = page.items.enumerated().map { SearchCopy(track: $1, origin: .service(profile.source), rank: start + $0) }
            SearchList.append(copies, to: &songRows, isSaved: isSaved)
            songLoads[profile.source] = .loaded(more: page.more && !page.items.isEmpty)
        } catch {
            songLoads[profile.source] = .failed(error.localizedDescription)
        }
    }
}

/// An album opened from search or a singer page, not imported.
@MainActor @Observable
final class AlbumStore: Identifiable {
    let album: SingerAlbum
    private(set) var tracks: [Track] = []
    private(set) var load: SourceLoad = .loading
    private(set) var saving = false
    let id: String
    @ObservationIgnored private let loader: any SearchLoading
    @ObservationIgnored private var started = false

    init(album: SingerAlbum, loader: any SearchLoading) {
        self.album = album
        self.id = "album:" + album.id
        self.loader = loader
    }

    func start() {
        guard !started else { return }
        started = true
        reload()
    }
    func reload() {
        load = .loading
        Task { [weak self] in
            guard let self else { return }
            do { tracks = try await loader.tracks(in: album); load = .loaded(more: false) }
            catch { load = .failed(error.localizedDescription) }
        }
    }
    func setSaving(_ value: Bool) { saving = value }
    var duration: Double { tracks.reduce(0) { $0 + max(0, $1.duration) } }
}
