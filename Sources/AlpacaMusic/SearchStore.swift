import Foundation
import Observation

/// One linked source during a search.
struct SearchSourceState: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case searching
        case done
        case failed(String)
    }
    var source: MusicSource
    var status: Status = .searching
    /// Songs this source has returned so far, over every page.
    var count = 0
    var paging: SearchPaging = .end
    var loadingMore = false
    /// Why the last "More songs" for this source failed.
    var moreError: String?
    var id: MusicSource { source }
    var failed: Bool { if case .failed = status { true } else { false } }
}

/// The results of the current search. They stay while the listener opens an
/// album and comes back, and end with a new search or when the listener
/// leaves by the sidebar.
@MainActor @Observable
final class SearchStore {
    static let songsOnlyKey = "search-songs-only"

    private(set) var term = ""
    /// A pasted HTTP(S) address: offered to add, never searched.
    private(set) var link: URL?
    private(set) var sources: [SearchSourceState] = []
    private(set) var rows: [SearchRow] = []
    /// True until every source answered or the first-paint wait ran out.
    private(set) var held = false
    private(set) var shape: SearchShape = .songs
    /// "Not one singer?" was pressed: one card per spelling.
    var split = false
    var filter: SearchFilter = .all
    /// The first row in view, so coming back lands at the same place.
    var scrollAnchor: String?
    /// Fold everything but the songs away. Remembered.
    var songsOnly: Bool { didSet { preferences.set(songsOnly, forKey: Self.songsOnlyKey) } }

    var active: Bool { !term.isEmpty }
    /// No linked service was asked; the page says so.
    var noLinkedService: Bool { active && link == nil && sources.isEmpty && !preparing }
    var searching: Bool { preparing || sources.contains { $0.status == .searching } }
    var loadingMore: Bool { sources.contains { $0.loadingMore } }
    /// Some source can still be asked for another page.
    var canLoadMore: Bool { sources.contains { $0.paging == .more && !$0.failed } }
    /// Rows saved in the library when they appeared.
    var libraryCount: Int { rows.filter(\.savedAtArrival).count }
    var shownRows: [SearchRow] { SearchList.filter(rows, by: filter) }

    /// How long the first paint waits for slow sources.
    @ObservationIgnored var firstPaintWait: Duration = .seconds(1)
    @ObservationIgnored private let loader: any SearchLoading
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var isSaved: (Track) -> Bool = { _ in false }
    @ObservationIgnored private var configurations: [SourceConfiguration] = []
    @ObservationIgnored private var includeSoda = false
    @ObservationIgnored private var library: [Track] = []
    @ObservationIgnored private var firstPages: [MusicSource: [Track]] = [:]
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var generation: UInt64 = 0
    private var preparing = false

    init(loader: any SearchLoading, preferences: UserDefaults) {
        self.loader = loader
        self.preferences = preferences
        songsOnly = preferences.bool(forKey: Self.songsOnlyKey)
    }

    /// Starts a search for `term` over the library and every linked source.
    func start(_ term: String, library: [Track], configurations: [SourceConfiguration], includeSodaPublicly: Bool,
               isSaved: @escaping (Track) -> Bool) {
        clear()
        self.term = term
        self.isSaved = isSaved
        self.configurations = configurations
        self.includeSoda = includeSodaPublicly
        if let url = AppModel.linkAddress(in: term) { link = url; return }
        self.library = SearchList.libraryMatches(library, term: term)
        held = true; preparing = true
        let token = generation
        tasks.append(Task { [weak self] in
            guard let self else { return }
            let targets = await loader.targets(configurations: configurations, includeSodaPublicly: includeSodaPublicly)
            guard current(token) else { return }
            preparing = false
            sources = targets.map { SearchSourceState(source: $0) }
            if targets.isEmpty { release(token); return }
            tasks.append(Task { [weak self] in
                guard let wait = self?.firstPaintWait else { return }
                try? await Task.sleep(for: wait)
                self?.release(token)
            })
            await loader.firstPages(term, configurations: configurations, includeSodaPublicly: includeSodaPublicly) { [weak self] page in
                self?.receiveFirst(page, token: token)
            }
            guard current(token) else { return }
            // A source that never answered (an over-long query) settles as empty.
            for index in sources.indices where sources[index].status == .searching { sources[index].status = .done }
            release(token)
        })
    }

    /// Ends the search and forgets its results.
    func clear() {
        generation &+= 1
        tasks.forEach { $0.cancel() }; tasks = []
        term = ""; link = nil; sources = []; rows = []; held = false; preparing = false
        shape = .songs; split = false; filter = .all; scrollAnchor = nil
        library = []; firstPages = [:]
    }

    /// Asks every source that has more for its next page. The new songs take
    /// turns among themselves and go below the last row.
    func loadMore() {
        guard !held, !loadingMore else { return }
        let asked = sources.filter { $0.paging == .more && !$0.failed }.map(\.source)
        guard !asked.isEmpty else { return }
        let token = generation, term = term
        for index in sources.indices where asked.contains(sources[index].source) {
            sources[index].loadingMore = true; sources[index].moreError = nil
        }
        let offsets = Dictionary(uniqueKeysWithValues: sources.map { ($0.source, $0.count) })
        tasks.append(Task { [weak self] in
            guard let self else { return }
            var pages: [SearchPage] = []
            for source in asked {
                pages.append(await loader.page(term, source: source, offset: offsets[source] ?? 0, configurations: configurations,
                                               includeSodaPublicly: includeSoda))
                guard current(token) else { return }
            }
            var lists: [[SearchCopy]] = []
            for page in pages {
                guard let index = sources.firstIndex(where: { $0.source == page.source }) else { continue }
                sources[index].loadingMore = false
                if let error = page.error { sources[index].moreError = error; continue }
                let start = sources[index].count
                sources[index].count += page.tracks.count
                sources[index].paging = page.paging
                lists.append(page.tracks.enumerated().map { SearchCopy(track: $1, origin: .service(page.source), rank: start + $0) })
            }
            SearchList.append(SearchList.takeTurns(lists), to: &rows, isSaved: isSaved)
        })
    }

    /// Asks a failed source again; its songs go below the last row.
    func retry(_ source: MusicSource) {
        guard let index = sources.firstIndex(where: { $0.source == source }), sources[index].failed else { return }
        sources[index].status = .searching
        let token = generation, term = term
        tasks.append(Task { [weak self] in
            guard let self else { return }
            let page = await loader.page(term, source: source, offset: 0, configurations: configurations, includeSodaPublicly: includeSoda)
            guard current(token) else { return }
            receiveFirst(page, token: token)
        })
    }

    /// Drops a source that was disconnected, with its songs.
    func forget(_ source: MusicSource) {
        sources.removeAll { $0.source == source }
        firstPages[source] = nil
        rows = rows.compactMap { row in
            var row = row
            row.copies.removeAll { $0.origin == .service(source) }
            return row.copies.isEmpty ? nil : row
        }
        if filter == .source(source) { filter = .all }
    }

    private func current(_ token: UInt64) -> Bool { !Task.isCancelled && token == generation }

    private func receiveFirst(_ page: SearchPage, token: UInt64) {
        guard token == generation, loader.isActive(page.source),
              let index = sources.firstIndex(where: { $0.source == page.source }) else { return }
        if let error = page.error {
            sources[index].status = .failed(error)
        } else {
            sources[index].status = .done
            sources[index].count = page.tracks.count
            sources[index].paging = page.paging
            firstPages[page.source] = page.tracks
        }
        if held {
            if !sources.contains(where: { $0.status == .searching }) { release(token) }
        } else if page.error == nil {
            // A late source: its songs go below as their own run.
            SearchList.append(copies(page.tracks, page.source), to: &rows, isSaved: isSaved)
            reshape(lateOnly: true)
        }
    }

    /// The first paint: library matches and every source in so far, taking turns.
    private func release(_ token: UInt64) {
        guard token == generation, held else { return }
        held = false
        var lists = [library.enumerated().map { SearchCopy(track: $1, origin: .library, rank: $0) }]
        for state in sources { if let tracks = firstPages[state.source] { lists.append(copies(tracks, state.source)) } }
        SearchList.append(SearchList.takeTurns(lists), to: &rows, isSaved: isSaved)
        reshape(lateOnly: false)
    }

    /// Reads the singer from the first pages. A late source may add its
    /// support to a card already shown, but never brings a card in or takes
    /// one away, since that would move the rows below.
    private func reshape(lateOnly: Bool) {
        let pages = sources.compactMap { state in firstPages[state.source].map { (source: state.source, tracks: $0) } }
        let next = SingerRule.shape(term: term, pages: pages)
        guard lateOnly else { shape = next; return }
        switch (shape, next) {
        case (.singer, .singer), (.singers, .singers): shape = next
        default: break
        }
    }

    private func copies(_ tracks: [Track], _ source: MusicSource) -> [SearchCopy] {
        tracks.enumerated().map { SearchCopy(track: $1, origin: .service(source), rank: $0) }
    }
}
