import Foundation
import Testing
@testable import AlpacaMusic

@MainActor private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

private struct LoaderFailure: LocalizedError {
    var errorDescription: String? { "platform unavailable" }
}

/// Counts requests per source and list, and can hold any request open.
@MainActor private final class FakeBrowseLoader: BrowseLoading {
    var availabilities: [MusicSource: BrowseAvailability] = [.appleMusic: .hidden, .netease: .ready(account: "a"), .qq: .ready(account: "q")]
    var chartCalls: [MusicSource: Int] = [:]
    var pickCalls: [MusicSource: Int] = [:]
    var trackCalls: [String: Int] = [:]
    var chartError: (any Error)?
    var pickError: (any Error)?
    var partialPicks: String?
    var trackError: (any Error)?
    var holds = false
    var gates: [CheckedContinuation<Void, Never>] = []
    var chartTitle = "Hot"
    /// Songs bundled with chart "1", like Apple Music's song charts.
    var bundled: [Track]?

    func availability(of source: MusicSource) -> BrowseAvailability { availabilities[source] ?? .hidden }
    func charts(_ source: MusicSource) async throws -> [BrowseCollection] {
        chartCalls[source, default: 0] += 1
        let title = chartTitle
        try await hold()
        if let chartError { throw chartError }
        var first = chart(source, "1", title: title); first.tracks = bundled
        return [first, chart(source, "2", title: "New")]
    }
    func recommendations(_ source: MusicSource) async throws -> BrowseRecommendations {
        pickCalls[source, default: 0] += 1
        try await hold()
        if let pickError { throw pickError }
        return BrowseRecommendations(collections: [BrowseCollection(source: source, kind: .playlist, remoteID: "p1", title: "Pick")],
                                     songs: partialPicks == nil ? [song(source, "s1")] : [], partialError: partialPicks)
    }
    func tracks(in collection: BrowseCollection, limit: Int) async throws -> [Track] {
        trackCalls[collection.id, default: 0] += 1
        try await hold()
        if let trackError { throw trackError }
        return (1...3).map { song(collection.source, "\(collection.remoteID)-\($0)") }
    }
    func releaseAll() { let waiting = gates; gates = []; waiting.forEach { $0.resume() } }
    private func hold() async throws {
        if holds { await withCheckedContinuation { gates.append($0) } }
    }
}

private func chart(_ source: MusicSource, _ id: String, title: String = "Chart") -> BrowseCollection {
    BrowseCollection(source: source, kind: .chart, remoteID: id, title: title)
}
private func loadedIDs(_ state: BrowseStore.TracksState) -> [String]? {
    if case .loaded(let tracks) = state { tracks.map(\.id) } else { nil }
}
private func song(_ source: MusicSource, _ id: String) -> Track {
    Track(id: "\(source.rawValue):\(id)", title: "Song \(id)", artist: "Artist", album: "", duration: 100, source: source, sourceID: id)
}

@Suite(.serialized) @MainActor struct BrowseStoreTests {
    private func makeStore(_ loader: FakeBrowseLoader, clock: TestClock, defaults: UserDefaults? = nil) -> (BrowseStore, UserDefaults, String) {
        let suite = "AlpacaBrowseTests.\(UUID().uuidString)"
        let values = defaults ?? UserDefaults(suiteName: suite)!
        return (BrowseStore(loader: loader, defaults: values, now: { clock.now }), values, suite)
    }
    private func settle(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; await Task.yield(); try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    @Test func revisitingThePageReusesTheCopyItAlreadyRead() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        store.ensureLoaded(.netease); store.ensureLoaded(.netease)
        try await settle { store.entry(for: .netease)?.picks.value != nil && store.entry(for: .netease)?.charts.value != nil }
        for _ in 0..<5 { clock.advance(60 * 30); store.ensureLoaded(.netease) }
        #expect(loader.chartCalls[.netease] == 1)
        #expect(loader.pickCalls[.netease] == 1)
        #expect(loader.chartCalls[.qq] == nil)
        #expect(store.entry(for: .netease)?.charts.value?.map(\.remoteID) == ["1", "2"])
    }

    @Test func aStaleCopyLoadsAgainOnTheNextVisitOnly() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        store.ensureLoaded(.qq)
        try await settle { store.entry(for: .qq)?.charts.value != nil }
        let expiry = try #require(store.entry(for: .qq)?.charts.expiresAt)
        #expect(expiry <= clock.now.addingTimeInterval(BrowseSchedule.listLifetime))
        clock.now = expiry.addingTimeInterval(1)
        #expect(loader.chartCalls[.qq] == 1) // Time passing alone asks nothing.
        loader.chartTitle = "Hot, later"
        store.ensureLoaded(.qq)
        try await settle { store.entry(for: .qq)?.charts.value?.first?.title == "Hot, later" }
        #expect(loader.chartCalls[.qq] == 2)
        #expect(store.entry(for: .qq)?.charts.fetchedAt == clock.now)
    }

    @Test func listsExpireAtTheEarliestOfLifetimeDailyResetAndHint() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        let lifetime = BrowseSchedule.listLifetime
        #expect(BrowseSchedule.expiry(fetched: date(7, 5, 30), lifetime: lifetime, calendar: calendar) == date(7, 6))
        #expect(BrowseSchedule.expiry(fetched: date(7, 10), lifetime: lifetime, calendar: calendar) == date(7, 16))
        #expect(BrowseSchedule.expiry(fetched: date(7, 23), lifetime: lifetime, calendar: calendar) == date(8, 5))
        #expect(BrowseSchedule.expiry(fetched: date(7, 10), lifetime: lifetime, hint: date(7, 12), calendar: calendar) == date(7, 12))
        // A hint already in the past is ignored rather than making the copy stale at once.
        #expect(BrowseSchedule.expiry(fetched: date(7, 10), lifetime: lifetime, hint: date(7, 9), calendar: calendar) == date(7, 16))
    }

    @Test func aFailureWaitsBeforeTryingOnItsOwnButRetryIsImmediate() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        loader.chartError = LoaderFailure()
        store.ensureLoaded(.netease)
        try await settle { store.entry(for: .netease)?.charts.error != nil && store.entry(for: .netease)?.picks.value != nil }
        #expect(store.entry(for: .netease)?.charts.error == "platform unavailable")
        clock.advance(BrowseSchedule.retryDelay - 1); store.ensureLoaded(.netease)
        #expect(loader.chartCalls[.netease] == 1)
        clock.advance(2); store.ensureLoaded(.netease)
        try await settle { loader.chartCalls[.netease] == 2 && store.entry(for: .netease)?.charts.loading == false }
        loader.chartError = nil
        store.retry(.netease)
        try await settle { store.entry(for: .netease)?.charts.value != nil }
        #expect(loader.chartCalls[.netease] == 3)
        #expect(store.entry(for: .netease)?.charts.error == nil)
        #expect(loader.pickCalls[.netease] == 1) // Retry leaves the list that loaded alone.
    }

    @Test func partOfThePicksMissingIsShownAndAskedForAgainLater() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        loader.partialPicks = "daily songs timed out"
        store.ensureLoaded(.netease)
        try await settle { store.entry(for: .netease)?.picks.value != nil }
        let picks = try #require(store.entry(for: .netease)?.picks)
        #expect(picks.value?.collections.count == 1)
        #expect(picks.error == "daily songs timed out")
        clock.advance(BrowseSchedule.retryDelay - 1); store.ensureLoaded(.netease)
        #expect(loader.pickCalls[.netease] == 1)
        loader.partialPicks = nil
        clock.advance(2); store.ensureLoaded(.netease)
        try await settle { store.entry(for: .netease)?.picks.value?.songs.isEmpty == false }
        #expect(store.entry(for: .netease)?.picks.error == nil)
        #expect(loader.pickCalls[.netease] == 2)
        #expect(loader.chartCalls[.netease] == 1) // The charts that loaded are left alone.
    }

    @Test func refreshWaitsForItsCooldownAndForRunningRequests() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        loader.holds = true
        store.ensureLoaded(.netease)
        try await settle { loader.gates.count == 2 }
        #expect(!store.canRefresh(.netease))
        store.refresh(.netease); store.ensureLoaded(.netease)
        #expect(loader.chartCalls[.netease] == 1)
        loader.releaseAll()
        try await settle { store.entry(for: .netease)?.charts.loading == false && store.entry(for: .netease)?.picks.loading == false }
        loader.holds = false
        #expect(!store.canRefresh(.netease))
        #expect(store.refreshAvailableAt(.netease) == clock.now.addingTimeInterval(BrowseSchedule.refreshCooldown))
        store.refresh(.netease)
        #expect(loader.chartCalls[.netease] == 1)
        clock.advance(BrowseSchedule.refreshCooldown)
        #expect(store.canRefresh(.netease))
        #expect(store.refreshAvailableAt(.netease) == nil)
        store.refresh(.netease)
        try await settle { loader.chartCalls[.netease] == 2 && loader.pickCalls[.netease] == 2 }
    }

    @Test func signedOutAndConnectingSourcesNeverLoad() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        loader.availabilities[.netease] = .signedOut; loader.availabilities[.qq] = .connecting
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        store.ensureLoaded(.netease); store.ensureLoaded(.qq); store.ensureLoaded(.appleMusic); store.ensureLoaded(.spotify)
        try await Task.sleep(for: .milliseconds(30))
        #expect(loader.chartCalls.isEmpty && loader.pickCalls.isEmpty)
        #expect(store.entry(for: .netease) == nil)
        #expect(!store.canRefresh(.netease))
    }

    @Test func anotherAccountNeverSeesTheFirstAccountsLists() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        store.ensureLoaded(.qq)
        try await settle { store.entry(for: .qq)?.charts.value != nil }
        store.open(chart(.qq, "1"))
        try await settle { store.tracksState(for: chart(.qq, "1")) != .loading }
        loader.availabilities[.qq] = .ready(account: "other")
        #expect(store.entry(for: .qq) == nil)
        loader.holds = true
        store.ensureLoaded(.qq)
        #expect(store.opened == nil)
        #expect(store.tracksState(for: chart(.qq, "1")) == nil)
        #expect(store.entry(for: .qq)?.charts.value == nil)
        try await settle { loader.gates.count == 2 }
        loader.holds = false; loader.releaseAll()
        try await settle { store.entry(for: .qq)?.charts.value != nil }
        #expect(store.entry(for: .qq)?.account == "other")
        #expect(loader.chartCalls[.qq] == 2)
    }

    @Test func aLateResultFromThePreviousAccountIsDropped() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        loader.holds = true; loader.chartTitle = "First account"
        store.ensureLoaded(.netease)
        try await settle { loader.gates.count == 2 }
        let firstAccount = loader.gates; loader.gates = []
        loader.availabilities[.netease] = .ready(account: "b"); loader.chartTitle = "Second account"
        store.ensureLoaded(.netease)
        try await settle { loader.gates.count == 2 }
        firstAccount.forEach { $0.resume() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.entry(for: .netease)?.charts.value == nil)
        loader.releaseAll()
        try await settle { store.entry(for: .netease)?.charts.value != nil }
        #expect(store.entry(for: .netease)?.charts.value?.first?.title == "Second account")
    }

    @Test func signingOutForgetsListsAndOpenSongs() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        store.ensureLoaded(.netease)
        try await settle { store.entry(for: .netease)?.charts.value != nil }
        let list = chart(.netease, "1")
        store.open(list)
        try await settle { store.tracksState(for: list).flatMap(loadedIDs) == ["netease:1-1", "netease:1-2", "netease:1-3"] }
        store.forget(.netease)
        #expect(store.entries[.netease] == nil)
        #expect(store.opened == nil)
        #expect(store.tracksState(for: list) == nil)
        store.ensureLoaded(.netease)
        try await settle { store.entry(for: .netease)?.charts.value != nil }
        store.open(list)
        try await settle { loader.trackCalls[list.id] == 2 }
    }

    @Test func anOpenedListLoadsItsSongsOnceAndReusesThem() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        store.ensureLoaded(.qq)
        try await settle { store.entry(for: .qq)?.charts.value != nil }
        let list = chart(.qq, "26")
        store.open(list)
        #expect(store.opened == list)
        #expect(store.tracksState(for: list) == .loading)
        try await settle { if case .loaded = store.tracksState(for: list) { true } else { false } }
        store.open(list) // Toggles closed.
        #expect(store.opened == nil)
        store.open(list)
        let songs = await store.tracksForPlayback(list)
        #expect(songs?.count == 3)
        #expect(loader.trackCalls[list.id] == 1)
        clock.advance(BrowseSchedule.tracksLifetime + 1)
        store.close(); store.open(list)
        try await settle { loader.trackCalls[list.id] == 2 }

        let bundledSong = song(.qq, "x")
        let bundled = BrowseCollection(source: .qq, kind: .chart, remoteID: "bundled", title: "Bundled", tracks: [bundledSong])
        store.open(bundled)
        #expect(store.tracksState(for: bundled) == .loaded([bundledSong]))
        #expect(loader.trackCalls[bundled.id] == nil)
    }

    @Test func playingAListThatIsStillLoadingSharesTheSameRequest() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        store.ensureLoaded(.netease)
        try await settle { store.entry(for: .netease)?.charts.value != nil }
        loader.holds = true
        let list = chart(.netease, "2")
        async let first = store.tracksForPlayback(list)
        async let second = store.tracksForPlayback(list)
        try await settle { loader.gates.count == 1 }
        #expect(store.pendingPlay == list.id)
        loader.releaseAll()
        let (a, b) = await (first, second)
        #expect(a?.count == 3 && b?.count == 3)
        #expect(loader.trackCalls[list.id] == 1)
        #expect(store.pendingPlay == nil)
    }

    @Test func failedSongsAreReportedAndRetriedOnRequest() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        store.ensureLoaded(.qq)
        try await settle { store.entry(for: .qq)?.charts.value != nil }
        loader.trackError = LoaderFailure()
        let list = chart(.qq, "5")
        #expect(await store.tracksForPlayback(list) == nil)
        #expect(store.tracksState(for: list) == .failed("platform unavailable"))
        loader.trackError = nil
        store.reloadTracks(list)
        try await settle { if case .loaded = store.tracksState(for: list) { true } else { false } }
        #expect(loader.trackCalls[list.id] == 2)
    }

    @Test func onlyRecentListsStayCached() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        store.ensureLoaded(.netease)
        try await settle { store.entry(for: .netease)?.charts.value != nil }
        for index in 0...BrowseSchedule.cachedCollections {
            _ = await store.tracksForPlayback(chart(.netease, "c\(index)"))
        }
        _ = await store.tracksForPlayback(chart(.netease, "c\(BrowseSchedule.cachedCollections)"))
        #expect(loader.trackCalls[chart(.netease, "c\(BrowseSchedule.cachedCollections)").id] == 1)
        _ = await store.tracksForPlayback(chart(.netease, "c0"))
        #expect(loader.trackCalls[chart(.netease, "c0").id] == 2)
    }

    @Test func refreshAlsoReloadsTheOpenList() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        store.ensureLoaded(.netease)
        try await settle { store.entry(for: .netease)?.charts.value != nil && store.entry(for: .netease)?.picks.value != nil }
        let list = chart(.netease, "1")
        store.open(list)
        try await settle { if case .loaded = store.tracksState(for: list) { true } else { false } }
        clock.advance(BrowseSchedule.refreshCooldown)
        store.refresh(.netease)
        try await settle { loader.trackCalls[list.id] == 2 && loader.chartCalls[.netease] == 2 }
    }

    @Test func aResultArrivingDuringAStatusCheckStillSettlesTheShelf() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        loader.holds = true
        store.ensureLoaded(.netease)
        try await settle { loader.gates.count == 2 }
        // Apple Music's silent status check shows the same account as signing in.
        loader.availabilities[.netease] = .connecting
        loader.releaseAll()
        try await Task.sleep(for: .milliseconds(20))
        loader.availabilities[.netease] = .ready(account: "a")
        let entry = try #require(store.entry(for: .netease))
        #expect(!entry.charts.loading && !entry.picks.loading)
        #expect(entry.charts.value?.count == 2)
        #expect(store.canRefresh(.netease, at: clock.now.addingTimeInterval(BrowseSchedule.refreshCooldown)))
    }

    @Test func anInterruptedReadIsShownWithARetryInsteadOfPlaceholders() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        loader.chartError = CancellationError()
        store.ensureLoaded(.qq)
        try await settle { store.entry(for: .qq)?.charts.loading == false && store.entry(for: .qq)?.picks.value != nil }
        #expect(store.entry(for: .qq)?.charts.error == BrowseStore.interrupted)
        loader.chartError = nil
        store.retry(.qq)
        try await settle { store.entry(for: .qq)?.charts.value != nil }
        #expect(loader.chartCalls[.qq] == 2)
    }

    @Test func anInterruptedSongReadOffersARetry() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        store.ensureLoaded(.qq)
        try await settle { store.entry(for: .qq)?.charts.value != nil }
        loader.trackError = CancellationError()
        let list = chart(.qq, "2")
        store.open(list)
        try await settle { store.tracksState(for: list) == .failed(BrowseStore.interrupted) }
        loader.trackError = nil
        store.reloadTracks(list)
        try await settle { if case .loaded = store.tracksState(for: list) { true } else { false } }
        #expect(loader.trackCalls[list.id] == 2)
    }

    @Test func refreshedListsReplaceTheOpenListAndItsBundledSongs() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        loader.bundled = [song(.qq, "old")]
        store.ensureLoaded(.qq)
        try await settle { store.entry(for: .qq)?.charts.value != nil && store.entry(for: .qq)?.picks.value != nil }
        let opened = try #require(store.entry(for: .qq)?.charts.value?.first)
        store.open(opened)
        #expect(store.tracksState(for: opened).flatMap(loadedIDs) == ["qq:old"])
        loader.bundled = [song(.qq, "new")]; loader.chartTitle = "Hot, refreshed"
        clock.advance(BrowseSchedule.refreshCooldown)
        store.refresh(.qq)
        try await settle { store.opened?.title == "Hot, refreshed" }
        #expect(store.tracksState(for: opened).flatMap(loadedIDs) == ["qq:new"])
        #expect(loader.trackCalls[opened.id] == nil) // Bundled songs need no request.
    }

    @Test func theDefaultWaitsForASourceThatIsStillSigningIn() {
        let loader = FakeBrowseLoader(), clock = TestClock()
        loader.availabilities[.appleMusic] = .connecting
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.current == .appleMusic)
        loader.availabilities[.appleMusic] = .signedOut
        #expect(store.current == .netease)
    }

    @Test func aPlatformHintTooSoonIsIgnored() {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let plain = BrowseSchedule.expiry(fetched: fetched, lifetime: BrowseSchedule.listLifetime, calendar: calendar)
        #expect(BrowseSchedule.expiry(fetched: fetched, lifetime: BrowseSchedule.listLifetime, hint: fetched.addingTimeInterval(600), calendar: calendar) == plain)
    }

    @Test func aListInBothShelvesOpensOnlyWhereItWasChosen() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        store.ensureLoaded(.qq)
        try await settle { store.entry(for: .qq)?.charts.value != nil }
        let list = chart(.qq, "1")
        store.open(list, from: .charts)
        #expect(store.openedShelf == .charts)
        store.open(list, from: .picks) // Moves to the other shelf rather than closing.
        #expect(store.opened == list && store.openedShelf == .picks)
        store.open(list, from: .picks)
        #expect(store.opened == nil && store.openedShelf == nil)
    }

    @Test func listsStayOnScreenWhileASourceRechecksItsSignIn() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.entryWhileConnecting(.netease) == nil)
        store.ensureLoaded(.netease)
        try await settle { store.entry(for: .netease)?.charts.value != nil }
        loader.availabilities[.netease] = .connecting
        #expect(store.entry(for: .netease) == nil)
        #expect(store.entryWhileConnecting(.netease)?.charts.value?.count == 2)
        store.forget(.netease)
        #expect(store.entryWhileConnecting(.netease) == nil)
    }

    @Test func openingAListLeavesTheRefreshCooldownAlone() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        store.ensureLoaded(.netease)
        try await settle { store.entry(for: .netease)?.charts.loading == false && store.entry(for: .netease)?.picks.loading == false }
        clock.advance(BrowseSchedule.refreshCooldown)
        store.open(chart(.netease, "1"))
        #expect(store.canRefresh(.netease))
    }

    @Test func aListStillLoadingDoesNotOvertakeWhatTheListenerStartedSince() async throws {
        let loader = FakeBrowseLoader()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("browse-play-\(UUID().uuidString)")
        let suite = "AlpacaBrowsePlay.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, preferences: UserDefaults(suiteName: suite)!, ephemeralAccounts: true, browseLoader: loader)
        defer { model.player.shutdown() }
        await model.library.load()
        model.browse.ensureLoaded(.netease)
        try await settle { model.browse.entry(for: .netease)?.charts.value != nil }
        loader.holds = true
        model.play(chart(.netease, "1"))
        try await settle { loader.gates.count == 1 }
        await model.player.previous() // The listener does something else meanwhile.
        loader.releaseAll()
        try await settle { model.browse.pendingPlay == nil }
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.player.current?.source != .netease)
    }

    @Test func theChosenSourceIsRememberedAndHiddenSourcesAreSkipped() async throws {
        let loader = FakeBrowseLoader(), clock = TestClock()
        loader.availabilities[.netease] = .signedOut
        let (store, defaults, suite) = makeStore(loader, clock: clock); defer { defaults.removePersistentDomain(forName: suite) }
        #expect(store.sources == [.netease, .qq])
        #expect(store.current == .qq) // The first signed-in source until one is picked.
        store.select(.netease)
        #expect(store.current == .netease)
        let (again, _, _) = makeStore(loader, clock: clock, defaults: defaults)
        #expect(again.current == .netease)
        loader.availabilities[.appleMusic] = .ready(account: "apple")
        #expect(again.sources == [.appleMusic, .netease, .qq])
        loader.availabilities[.netease] = .hidden
        #expect(again.current == .appleMusic)
    }
}
