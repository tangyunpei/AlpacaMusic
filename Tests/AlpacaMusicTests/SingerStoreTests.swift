import Foundation
import Testing
@testable import AlpacaMusic

@MainActor private func waitFor(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<400 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out", sourceLocation: sourceLocation)
}
private func profile(_ source: MusicSource, _ id: String, _ name: String, aliases: [String] = []) -> SingerProfile {
    SingerProfile(source: source, remoteID: id, name: name, aliases: aliases)
}
private func album(_ source: MusicSource, _ name: String, _ date: ReleaseDate?) -> SingerAlbum {
    SingerAlbum(source: source, remoteID: "\(name)", name: name, artist: "周杰伦", date: date)
}
private func song(_ source: MusicSource, _ id: String, _ title: String) -> Track {
    Track(id: "\(source.rawValue):\(id)", title: title, artist: "周杰伦", album: "", duration: 200, source: source)
}

@Suite @MainActor
struct SingerStoreTests {
    @Test func theServicesSingerIsAnExactNameOrAliasElseAClearTopResult() {
        let candidates = [profile(.netease, "1", "周杰伦.", aliases: ["周杰伦头号粉"]), profile(.netease, "6452", "周杰伦", aliases: ["Jay Chou"])]
        #expect(SingerStore.match(candidates, names: ["jay chou"])?.remoteID == "6452")
        #expect(SingerStore.match(candidates, names: ["周杰伦"])?.remoteID == "6452")
        #expect(SingerStore.match([profile(.qq, "m", "周杰伦 (Jay Chou)")], names: ["周杰伦"])?.remoteID == "m")
        #expect(SingerStore.match([profile(.qq, "m", "Lara梁心颐")], names: ["周杰伦"]) == nil)
        #expect(SingerStore.match([], names: ["周杰伦"]) == nil)
    }

    @Test func findsTheSingerOnEachServiceThenAlbumsNewestFirstAndSongsTakingTurns() async throws {
        let loader = FakeSearchLoader()
        let netease = profile(.netease, "6452", "周杰伦", aliases: ["Jay Chou"]), qq = profile(.qq, "0025", "周杰伦")
        loader.singerResults = [.netease: [netease], .qq: [qq], .appleMusic: [profile(.appleMusic, "x", "Somebody Else")]]
        loader.albumPages = [
            netease.id: [0: SingerPage(items: [album(.netease, "太阳之子", ReleaseDate(year: 2026, month: 3, day: 24)),
                                              album(.netease, "即兴曲", ReleaseDate(year: 2025, month: 6, day: 5))], more: true),
                         2: SingerPage(items: [album(.netease, "Jay", ReleaseDate(year: 2000, month: 11, day: 7))], more: false)],
            qq.id: [0: SingerPage(items: [album(.qq, "太阳之子", ReleaseDate(year: 2026, month: 3, day: 25))], more: false)],
        ]
        loader.songPages = [netease.id: [0: SingerPage(items: [song(.netease, "1", "晴天"), song(.netease, "2", "稻香")], more: true)],
                            qq.id: [0: SingerPage(items: [song(.qq, "a", "晴天"), song(.qq, "b", "七里香")], more: false)]]
        let store = SingerStore(names: ["周杰伦", "Jay Chou"], query: [.netease: "周杰伦", .qq: "周杰伦", .appleMusic: "Jay Chou"],
                                sources: [.qq, .netease, .appleMusic], loader: loader, isSaved: { _ in false })
        store.start()
        await waitFor { !store.finding && !store.loadingAlbums && !store.loadingSongs }
        #expect(store.profiles.map(\.source) == [.netease, .qq])
        #expect(store.albumLoads[.appleMusic] == SourceLoad.none)
        // Copies of 太阳之子 stand together, newest first.
        #expect(store.albums.map { "\($0.name)/\($0.source.rawValue)" } == ["太阳之子/netease", "太阳之子/qq", "即兴曲/netease"])
        #expect(store.latest?.name == "太阳之子")
        // 晴天 from both services is one row; the services take turns.
        #expect(store.songRows.map(\.track.title) == ["晴天", "稻香", "七里香"])
        #expect(store.songRows.first?.sources == [.netease, .qq])
        store.loadMoreAlbums()
        await waitFor { store.albums.count == 4 }
        #expect(store.albums.last?.name == "Jay")
        #expect(store.albumLoads[.netease] == .loaded(more: false))
        store.filter = .qq
        #expect(store.shownAlbums.map(\.source) == [.qq])
    }

    @Test func aSingerPageOpensFromTheResultsAndBackReturnsThroughItsAlbum() async throws {
        let loader = FakeSearchLoader()
        loader.targetList = [.netease]
        loader.first = [.netease: SearchPage(source: .netease, tracks: (0..<10).map { song(.netease, "s\($0)", "Song \($0)") })]
        let netease = profile(.netease, "6452", "周杰伦")
        loader.singerResults = [.netease: [netease]]
        let sun = album(.netease, "太阳之子", ReleaseDate(year: 2026, month: 3, day: 24))
        loader.albumPages = [netease.id: [0: SingerPage(items: [sun], more: false)]]
        loader.albumSongs = [sun.id: [song(.netease, "t1", "太阳之子")]]
        let directory = FileManager.default.temporaryDirectory.appending(path: "AlpacaSinger-\(UUID().uuidString)")
        let domain = "AlpacaSinger-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let model = AppModel(directory: directory, preferences: defaults, ephemeralAccounts: true, searchLoader: loader)
        defer { model.player.shutdown(); defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        model.searchResults.firstPaintWait = .milliseconds(20)
        model.navigate(.library); model.query = "周杰伦"; model.search()
        await waitFor { !model.searchResults.held }
        guard case .singer(let card) = model.searchResults.shape else { Issue.record("expected a card"); return }
        let store = model.singerStore(for: card)
        #expect(model.singerStore(for: card) === store)
        model.openSinger(store)
        #expect(model.destination == .singer(store.id))
        #expect(model.trail == [.library, .search])
        #expect(model.pageTitle == "周杰伦")
        await waitFor { store.albums.count == 1 }
        model.openAlbum(sun)
        let albumStore = try #require(model.albumStores["album:" + sun.id])
        await waitFor { albumStore.load == .loaded(more: false) }
        #expect(albumStore.tracks.map(\.title) == ["太阳之子"])
        #expect(model.trail == [.library, .search, .singer(store.id)])
        model.goBack()
        #expect(model.destination == .singer(store.id))
        model.goBack(to: .search)
        #expect(model.destination == .search)
        #expect(model.searchResults.term == "周杰伦")
        // Leaving by the sidebar forgets the pages.
        model.navigate(.library)
        #expect(model.singerStores.isEmpty && model.albumStores.isEmpty)
    }
}
