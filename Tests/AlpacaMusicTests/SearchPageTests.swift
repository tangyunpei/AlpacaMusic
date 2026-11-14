import Foundation
import Testing
@testable import AlpacaMusic

/// Services that answer when the test says so.
@MainActor final class FakeSearchLoader: SearchLoading {
    var targetList: [MusicSource] = []
    var first: [MusicSource: SearchPage] = [:]
    /// Sources whose first page waits for `answer(_:)`.
    var delayed: Set<MusicSource> = []
    var pages: [MusicSource: [Int: SearchPage]] = [:]
    var pageRequests: [String] = []
    private var waiting: [MusicSource: CheckedContinuation<Void, Never>] = [:]

    func targets(configurations: [SourceConfiguration], includeSodaPublicly: Bool) async -> [MusicSource] { targetList }
    func firstPages(_ term: String, configurations: [SourceConfiguration], includeSodaPublicly: Bool,
                    deliver: @escaping @MainActor (SearchPage) -> Void) async {
        for source in targetList where !delayed.contains(source) { if let page = first[source] { deliver(page) } }
        for source in targetList where delayed.contains(source) {
            await withCheckedContinuation { waiting[source] = $0 }
            if let page = first[source] { deliver(page) }
        }
    }
    func answer(_ source: MusicSource) { waiting.removeValue(forKey: source)?.resume() }
    var isWaiting: Bool { !waiting.isEmpty }
    func page(_ term: String, source: MusicSource, offset: Int, configurations: [SourceConfiguration],
              includeSodaPublicly: Bool) async -> SearchPage {
        pageRequests.append("\(source.rawValue)@\(offset)")
        return pages[source]?[offset] ?? SearchPage(source: source, tracks: [], paging: .end)
    }
    func isActive(_ source: MusicSource) -> Bool { true }
}

private func songs(_ source: MusicSource, _ count: Int, from start: Int = 0, artist: String = "谭米洛", title: String = "Song") -> [Track] {
    (start..<start + count).map { Track(id: "\(source.rawValue):\($0)", title: "\(title) \(source.rawValue) \($0)", artist: artist,
                                        album: "", duration: 200, source: source) }
}

/// Waits for the store's tasks; fails the test after two seconds.
@MainActor private func until(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<400 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out", sourceLocation: sourceLocation)
}

@MainActor private func makeStore(_ loader: FakeSearchLoader, wait: Duration = .seconds(10)) throws -> (SearchStore, UserDefaults, String) {
    let domain = "AlpacaSearchStore-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    let store = SearchStore(loader: loader, preferences: defaults)
    store.firstPaintWait = wait
    return (store, defaults, domain)
}

@Suite @MainActor
struct SearchStoreTests {
    @Test func theFirstPaintWaitsForEveryServiceThenTakesTurns() async throws {
        let loader = FakeSearchLoader()
        loader.targetList = [.appleMusic, .netease]
        loader.first = [.appleMusic: SearchPage(source: .appleMusic, tracks: songs(.appleMusic, 2), paging: .end),
                        .netease: SearchPage(source: .netease, tracks: songs(.netease, 2), paging: .end)]
        loader.delayed = [.netease]
        let (store, defaults, domain) = try makeStore(loader); defer { defaults.removePersistentDomain(forName: domain) }
        let saved = Track(id: "local:1", title: "Song local", artist: "Me", album: "", duration: 1, source: .local)
        store.start("Song", library: [saved], configurations: [], includeSodaPublicly: false, isSaved: { $0.id == saved.id })
        await until { loader.isWaiting }
        #expect(store.held)
        #expect(store.rows.isEmpty)
        loader.answer(.netease)
        await until { !store.held }
        #expect(store.rows.map(\.id) == ["local:1", "appleMusic:0", "netease:0", "appleMusic:1", "netease:1"])
        #expect(store.libraryCount == 1)
    }

    @Test func aServiceLaterThanTheWaitGoesBelowAndMovesNothing() async throws {
        let loader = FakeSearchLoader()
        loader.targetList = [.appleMusic, .qq]
        loader.first = [.appleMusic: SearchPage(source: .appleMusic, tracks: songs(.appleMusic, 3)),
                        .qq: SearchPage(source: .qq, tracks: songs(.qq, 2))]
        loader.delayed = [.qq]
        let (store, defaults, domain) = try makeStore(loader, wait: .milliseconds(30)); defer { defaults.removePersistentDomain(forName: domain) }
        store.start("Song", library: [], configurations: [], includeSodaPublicly: false, isSaved: { _ in false })
        await until { !store.held }
        let before = store.rows.map(\.id)
        #expect(before == ["appleMusic:0", "appleMusic:1", "appleMusic:2"])
        #expect(store.sources.map(\.status) == [.done, .searching])
        loader.answer(.qq)
        await until { store.rows.count == 5 }
        #expect(Array(store.rows.map(\.id).prefix(3)) == before)
        #expect(store.rows.map(\.id).suffix(2) == ["qq:0", "qq:1"])
    }

    @Test func moreSongsAsksOnlyAServiceThatCanPageAndSaysWhoCannot() async throws {
        let loader = FakeSearchLoader()
        loader.targetList = [.appleMusic, .netease]
        loader.first = [.appleMusic: SearchPage(source: .appleMusic, tracks: songs(.appleMusic, 25), paging: .more),
                        .netease: SearchPage(source: .netease, tracks: songs(.netease, 50), paging: .unsupported)]
        loader.pages = [.appleMusic: [25: SearchPage(source: .appleMusic, tracks: songs(.appleMusic, 10, from: 25), paging: .end)]]
        let (store, defaults, domain) = try makeStore(loader); defer { defaults.removePersistentDomain(forName: domain) }
        store.start("Song", library: [], configurations: [], includeSodaPublicly: false, isSaved: { _ in false })
        await until { !store.held }
        #expect(store.canLoadMore)
        let before = store.rows.map(\.id)
        store.loadMore()
        await until { !store.loadingMore && store.rows.count == 85 }
        #expect(loader.pageRequests == ["appleMusic@25"])
        #expect(Array(store.rows.map(\.id).prefix(before.count)) == before)
        #expect(store.rows.last?.id == "appleMusic:34")
        let apple = try #require(store.sources.first { $0.source == .appleMusic })
        #expect(apple.count == 35 && apple.paging == .end)
        #expect(store.sources.first { $0.source == .netease }?.paging == .unsupported)
        #expect(!store.canLoadMore)
        // Ranks run on from the first page, so one service keeps its own order.
        #expect(SearchList.filter(store.rows, by: .source(.appleMusic)).last?.id == "appleMusic:34")
    }

    @Test func moreSongsAsksEveryServiceAndKeepsTheirOrderAndAFailureCanBeTriedAgain() async throws {
        let loader = FakeSearchLoader()
        loader.targetList = [.netease, .qq]
        loader.first = [.netease: SearchPage(source: .netease, tracks: songs(.netease, 2), paging: .more),
                        .qq: SearchPage(source: .qq, tracks: songs(.qq, 2), paging: .more)]
        loader.pages = [.netease: [2: SearchPage(source: .netease, tracks: songs(.netease, 2, from: 2), paging: .end)],
                        .qq: [2: SearchPage(source: .qq, tracks: [], error: "timed out", paging: .more)]]
        let (store, defaults, domain) = try makeStore(loader); defer { defaults.removePersistentDomain(forName: domain) }
        store.start("Song", library: [], configurations: [], includeSodaPublicly: false, isSaved: { _ in false })
        await until { !store.held }
        store.loadMore()
        await until { !store.loadingMore && store.rows.count == 6 }
        #expect(Set(loader.pageRequests) == ["netease@2", "qq@2"])
        #expect(store.rows.suffix(2).map(\.id) == ["netease:2", "netease:3"])
        #expect(store.sources.first { $0.source == .qq }?.moreError == "timed out")
        // The failed service can still be asked; the one that ended is not.
        #expect(store.canLoadMore)
        loader.pages[.qq] = [2: SearchPage(source: .qq, tracks: songs(.qq, 1, from: 2), paging: .end)]
        store.loadMore()
        await until { !store.loadingMore && store.rows.count == 7 }
        #expect(loader.pageRequests.last == "qq@2")
        #expect(store.rows.last?.id == "qq:2")
        #expect(!store.canLoadMore)
    }

    @Test func aFailedServiceIsRetriedAndItsSongsGoBelow() async throws {
        let loader = FakeSearchLoader()
        loader.targetList = [.netease, .qq]
        loader.first = [.netease: SearchPage(source: .netease, tracks: songs(.netease, 2)),
                        .qq: SearchPage(source: .qq, tracks: [], error: "timed out")]
        loader.pages = [.qq: [0: SearchPage(source: .qq, tracks: songs(.qq, 1))]]
        let (store, defaults, domain) = try makeStore(loader); defer { defaults.removePersistentDomain(forName: domain) }
        store.start("Song", library: [], configurations: [], includeSodaPublicly: false, isSaved: { _ in false })
        await until { !store.held }
        #expect(store.sources.last?.status == .failed("timed out"))
        store.retry(.qq)
        await until { store.rows.count == 3 }
        #expect(store.rows.last?.id == "qq:0")
        #expect(store.sources.last?.status == .done)
    }

    @Test func noLinkedServiceShowsTheLibraryAtOnce() async throws {
        let loader = FakeSearchLoader()
        let (store, defaults, domain) = try makeStore(loader); defer { defaults.removePersistentDomain(forName: domain) }
        let saved = Track(id: "local:1", title: "Morning", artist: "Me", album: "", duration: 1, source: .local)
        store.start("morn", library: [saved], configurations: [], includeSodaPublicly: false, isSaved: { _ in true })
        await until { !store.held }
        #expect(store.noLinkedService)
        #expect(store.rows.map(\.id) == ["local:1"])
    }

    @Test func theSingerIsReadWhenTheFirstPaintIsMadeAndALateServiceAddsNoCard() async throws {
        let loader = FakeSearchLoader()
        loader.targetList = [.netease, .qq]
        loader.first = [.netease: SearchPage(source: .netease, tracks: songs(.netease, 20)),
                        .qq: SearchPage(source: .qq, tracks: songs(.qq, 20, artist: "Someone"))]
        let (store, defaults, domain) = try makeStore(loader); defer { defaults.removePersistentDomain(forName: domain) }
        store.start("Milo", library: [], configurations: [], includeSodaPublicly: false, isSaved: { _ in false })
        await until { !store.held }
        guard case .singer(let card) = store.shape else { Issue.record("expected a card"); return }
        #expect(card.names == ["谭米洛", "Someone"])

        let late = FakeSearchLoader()
        late.targetList = [.netease, .qq]
        late.first = [.netease: SearchPage(source: .netease, tracks: songs(.netease, 4, artist: "A") + songs(.netease, 4, from: 4, artist: "B")),
                      .qq: SearchPage(source: .qq, tracks: songs(.qq, 20))]
        late.delayed = [.qq]
        let (other, otherDefaults, otherDomain) = try makeStore(late, wait: .milliseconds(30))
        defer { otherDefaults.removePersistentDomain(forName: otherDomain) }
        other.start("x", library: [], configurations: [], includeSodaPublicly: false, isSaved: { _ in false })
        await until { !other.held }
        guard case .singers = other.shape else { Issue.record("expected the singers line"); return }
        late.answer(.qq)
        await until { other.rows.count == 28 }
        // A card now would push the rows down; the line stays.
        guard case .singers = other.shape else { Issue.record("a late service brought a card in"); return }
    }

    @Test func songsOnlyIsRemembered() throws {
        let loader = FakeSearchLoader()
        let (store, defaults, domain) = try makeStore(loader); defer { defaults.removePersistentDomain(forName: domain) }
        #expect(!store.songsOnly)
        store.songsOnly = true
        #expect(SearchStore(loader: loader, preferences: defaults).songsOnly)
    }

    @Test func aDisconnectedServiceLeavesWithItsSongs() async throws {
        let loader = FakeSearchLoader()
        loader.targetList = [.netease, .qq]
        loader.first = [.netease: SearchPage(source: .netease, tracks: songs(.netease, 1, title: "Same")),
                        .qq: SearchPage(source: .qq, tracks: songs(.qq, 1, title: "Other"))]
        let (store, defaults, domain) = try makeStore(loader); defer { defaults.removePersistentDomain(forName: domain) }
        store.start("x", library: [], configurations: [], includeSodaPublicly: false, isSaved: { _ in false })
        await until { !store.held }
        store.filter = .source(.qq)
        store.forget(.qq)
        #expect(store.sources.map(\.source) == [.netease])
        #expect(store.rows.map(\.id) == ["netease:0"])
        #expect(store.filter == .all)
    }
}

@MainActor private func pageModel(_ tracks: [Track], loader: FakeSearchLoader) throws -> (AppModel, () -> Void) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "AlpacaSearchPage-\(UUID().uuidString)")
    let domain = "AlpacaSearchPage-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    let model = AppModel(directory: directory, preferences: defaults, ephemeralAccounts: true, searchLoader: loader)
    model.library.addTracks(tracks)
    model.searchResults.firstPaintWait = .milliseconds(20)
    return (model, {
        model.player.shutdown()
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: directory)
    })
}

@Suite @MainActor
struct SearchBackPathTests {
    private let first = Track(id: "netease:1", title: "Morning Tide", artist: "Milo", album: "Dawn", duration: 5, source: .netease)
    private let second = Track(id: "netease:2", title: "Morning Rain", artist: "Milo", album: "Dawn", duration: 5, source: .netease)

    @Test func searchIsItsOwnPageAndBackReturnsToTheSameResultsAndPlace() async throws {
        let loader = FakeSearchLoader()
        loader.targetList = [.qq]
        loader.first = [.qq: SearchPage(source: .qq, tracks: songs(.qq, 3, title: "Morning"))]
        let (model, cleanup) = try pageModel([first, second], loader: loader); defer { cleanup() }
        model.navigate(.favorites)
        model.query = "  Morning "
        model.search()
        #expect(model.destination == .search)
        let term = "Morning"
        #expect(model.pageTitle == L10n.string("搜索「\(term)」"))
        #expect(model.trail == [.favorites])
        await until { !model.searchResults.held }
        let rows = model.searchResults.rows.map(\.id)
        model.searchResults.filter = .notSaved
        let album = try #require(model.libraryAlbumID(containing: first.id))
        model.open(.album(album))
        #expect(model.destination == .album(album))
        #expect(model.trail == [.favorites, .search])
        #expect(model.albumTracks.map(\.id) == [first.id, second.id])
        model.goBack()
        #expect(model.destination == .search)
        #expect(model.searchResults.rows.map(\.id) == rows)
        #expect(model.searchResults.filter == .notSaved)
        #expect(model.query == "Morning")
        #expect(loader.pageRequests.isEmpty)
        // Back from the results leaves the search for where it started.
        model.goBack()
        #expect(model.destination == .favorites)
        #expect(!model.searchResults.active)
        #expect(model.query.isEmpty)
    }

    @Test func clearingTheFieldOrEscapeOnAnAlbumGoesBackAndKeepsTheSearch() async throws {
        let loader = FakeSearchLoader()
        let (model, cleanup) = try pageModel([first, second], loader: loader); defer { cleanup() }
        model.navigate(.library); model.query = "Morning"; model.search()
        await until { !model.searchResults.held }
        let album = try #require(model.libraryAlbumID(containing: first.id))
        model.open(.album(album))
        model.clearSearchField()
        #expect(model.destination == .search)
        #expect(model.searchResults.term == "Morning")
        model.open(.album(album))
        model.escape()
        #expect(model.destination == .search)
        // On the results page Escape does nothing and the clear button empties the field only.
        model.escape()
        #expect(model.destination == .search)
        model.clearSearchField()
        #expect(model.query.isEmpty)
        #expect(model.searchResults.rows.count == 2)
    }

    @Test func theSidebarEndsTheSearchAndANewSearchKeepsTheFirstOrigin() async throws {
        let loader = FakeSearchLoader()
        let (model, cleanup) = try pageModel([first, second], loader: loader); defer { cleanup() }
        model.navigate(.albums); model.query = "Morning"; model.search()
        await until { !model.searchResults.held }
        let album = try #require(model.libraryAlbumID(containing: first.id))
        model.open(.album(album))
        model.query = "Rain"; model.search()
        #expect(model.trail == [.albums])
        await until { !model.searchResults.held }
        #expect(model.searchResults.rows.map(\.id) == [second.id])
        model.navigate(.library)
        #expect(model.trail.isEmpty)
        #expect(!model.searchResults.active)
        #expect(model.query.isEmpty)
        // An empty field does not search.
        model.search()
        #expect(model.destination == .library)
    }

    @Test func likingOrSavingASongNeverMovesItsRowAndActsOnTheLibraryCopy() async throws {
        let loader = FakeSearchLoader()
        let twin = Track(id: "qq:twin", title: "morning tide", artist: "MILO", album: "", duration: 5, source: .qq)
        let fresh = Track(id: "qq:fresh", title: "Morning Light", artist: "Other", album: "", duration: 5, source: .qq)
        loader.targetList = [.qq]
        loader.first = [.qq: SearchPage(source: .qq, tracks: [twin, fresh])]
        let (model, cleanup) = try pageModel([first], loader: loader); defer { cleanup() }
        model.query = "Morning"; model.search()
        await until { !model.searchResults.held }
        let store = model.searchResults
        #expect(store.rows.map(\.id) == [first.id, fresh.id])
        #expect(store.rows[0].sources == [.netease, .qq])
        // The QQ copy of a saved song acts on the saved one.
        #expect(model.actionTrack(for: store.rows[0]).id == first.id)
        store.filter = .notSaved
        model.favorite(model.actionTrack(for: store.rows[1]))
        model.addToLibrary(fresh)
        #expect(model.library.favorites.contains(fresh.id))
        #expect(model.isInLibrary(store.rows[1]))
        #expect(store.shownRows.map(\.id) == [fresh.id])
        #expect(store.rows.map(\.id) == [first.id, fresh.id])
    }

    @Test func aPastedLinkIsOfferedAndNeverSearched() async throws {
        let loader = FakeSearchLoader()
        loader.targetList = [.qq]
        let (model, cleanup) = try pageModel([], loader: loader); defer { cleanup() }
        model.query = "https://example.com/a.mp3"; model.search()
        #expect(model.searchResults.link?.host() == "example.com")
        #expect(model.searchResults.sources.isEmpty)
        #expect(!model.searchResults.held)
    }
}
