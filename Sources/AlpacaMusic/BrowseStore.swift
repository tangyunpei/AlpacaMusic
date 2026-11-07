import Foundation
import Observation

/// Whether a source can show charts and picks on the Now page.
enum BrowseAvailability: Equatable, Sendable {
    /// Not offered in this build, such as Apple Music without MusicKit signing.
    case hidden
    case signedOut
    /// A saved login is being restored or a connection is in progress.
    case connecting
    /// Signed in. `account` changes when the listener switches accounts, and
    /// nothing read for one account is shown for another.
    case ready(account: String)
}

/// Where the Now page's lists come from. Production reads the signed-in
/// platform clients; tests substitute it.
@MainActor protocol BrowseLoading: AnyObject {
    func availability(of source: MusicSource) -> BrowseAvailability
    func charts(_ source: MusicSource) async throws -> [BrowseCollection]
    func recommendations(_ source: MusicSource) async throws -> BrowseRecommendations
    func tracks(in collection: BrowseCollection, limit: Int) async throws -> [Track]
}

@MainActor final class PlatformBrowseLoader: BrowseLoading {
    private let accounts: ConnectedMusicAccounts
    private let appleMusic: AppleMusicService
    init(accounts: ConnectedMusicAccounts, appleMusic: AppleMusicService) {
        self.accounts = accounts; self.appleMusic = appleMusic
    }
    func availability(of source: MusicSource) -> BrowseAvailability {
        switch source {
        case .appleMusic:
            guard appleMusic.isConfigured else { return .hidden }
            guard appleMusic.isEnabled else { return .signedOut }
            return appleMusic.isBusy ? .connecting : .ready(account: appleMusic.librarySessionID.uuidString)
        case .netease, .qq:
            guard MusicSourceAvailability.isVisible(source) else { return .hidden }
            let state = accounts.state(source)
            if let profile = state.profile { return .ready(account: profile.id) }
            return state.busy ? .connecting : .signedOut
        default:
            return .hidden
        }
    }
    func charts(_ source: MusicSource) async throws -> [BrowseCollection] {
        source == .appleMusic ? try await appleMusic.charts() : try await accounts.client.charts(source)
    }
    func recommendations(_ source: MusicSource) async throws -> BrowseRecommendations {
        source == .appleMusic ? try await appleMusic.recommendations() : try await accounts.client.recommendations(source)
    }
    func tracks(in collection: BrowseCollection, limit: Int) async throws -> [Track] {
        collection.source == .appleMusic ? try await appleMusic.tracks(in: collection, limit: limit)
            : try await accounts.client.tracks(in: collection, limit: limit)
    }
}

/// Charts and picks for the Now page, kept for the app session so revisiting
/// the page never asks a platform again while its copy is fresh.
///
/// Requests start only when the page shows a signed-in source whose copy is
/// missing or stale (`BrowseSchedule`), when a list is opened or played, or
/// when the listener presses refresh, which has a cooldown. Nothing polls,
/// and only the source on screen loads.
@MainActor @Observable final class BrowseStore {
    struct Shelf<Value: Equatable>: Equatable {
        var value: Value?
        var loading = false
        var error: String?
        var fetchedAt: Date?
        var expiresAt: Date?
        var failedAt: Date?
        /// A missing or stale copy loads, except shortly after a failure.
        func needsLoad(at date: Date) -> Bool {
            if let failedAt, date < failedAt.addingTimeInterval(BrowseSchedule.retryDelay) { return false }
            guard let expiresAt else { return true }
            return date >= expiresAt
        }
    }
    struct Entry: Equatable {
        var account: String
        var charts = Shelf<[BrowseCollection]>()
        var picks = Shelf<BrowseRecommendations>()
        /// When the last request for this source started; refresh waits a cooldown after it.
        var lastRequest: Date?
    }
    /// Which shelf a list was opened from; one playlist can be in both.
    enum ShelfKind: Equatable, Sendable { case charts, picks }
    enum TracksState: Equatable {
        case loading
        case loaded([Track])
        case failed(String)
    }
    private struct CachedTracks {
        var account: String
        var tracks: [Track]
        var expiresAt: Date
    }

    static let order: [MusicSource] = [.appleMusic, .netease, .qq]
    private static let selectionKey = "now-browse-source"

    private(set) var entries: [MusicSource: Entry] = [:]
    /// The chart or playlist expanded on the page, and the shelf it opened in.
    private(set) var opened: BrowseCollection?
    private(set) var openedShelf: ShelfKind?
    private(set) var trackStates: [String: TracksState] = [:]
    /// The list whose play button is waiting for its songs.
    private(set) var pendingPlay: String?
    /// The source the listener picked; nil follows the first signed-in one.
    private(set) var selection: MusicSource?

    @ObservationIgnored private let loader: any BrowseLoading
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var generations: [MusicSource: UUID] = [:]
    @ObservationIgnored private var shelfTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var trackLoads: [String: Task<[Track]?, Never>] = [:]
    @ObservationIgnored private var cachedTracks: [String: CachedTracks] = [:]
    @ObservationIgnored private var cacheOrder: [String] = []

    init(loader: any BrowseLoading, defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
        self.loader = loader; self.defaults = defaults; self.now = now
        selection = defaults.string(forKey: Self.selectionKey).flatMap(MusicSource.init(rawValue:)).flatMap { Self.order.contains($0) ? $0 : nil }
    }

    // MARK: Sources

    /// Sources this build can show, in a fixed order.
    var sources: [MusicSource] { Self.order.filter { loader.availability(of: $0) != .hidden } }
    func availability(of source: MusicSource) -> BrowseAvailability { loader.availability(of: source) }
    /// The picked source, or else the first one signed in or still signing
    /// in, or else the first shown. Counting sources that are signing in keeps
    /// the default from jumping to another source, and loading it, at launch.
    var current: MusicSource? {
        let shown = sources
        if let selection, shown.contains(selection) { return selection }
        return shown.first {
            switch loader.availability(of: $0) { case .ready, .connecting: true; case .signedOut, .hidden: false }
        } ?? shown.first
    }
    func select(_ source: MusicSource) {
        guard Self.order.contains(source) else { return }
        selection = source
        defaults.set(source.rawValue, forKey: Self.selectionKey)
    }
    func entry(for source: MusicSource) -> Entry? {
        guard case .ready(let account) = loader.availability(of: source), let entry = entries[source], entry.account == account else { return nil }
        return entry
    }
    /// The lists last read for a source that is checking its sign-in again
    /// (Apple Music's status check), so the page keeps them on screen.
    /// Signing out or switching accounts clears them first.
    func entryWhileConnecting(_ source: MusicSource) -> Entry? {
        guard loader.availability(of: source) == .connecting else { return nil }
        return entries[source]
    }

    // MARK: Lists

    /// Loads what is missing or stale for a signed-in source. Fresh copies
    /// and requests already running are left alone.
    func ensureLoaded(_ source: MusicSource) {
        guard case .ready(let account) = loader.availability(of: source) else { return }
        if entries[source]?.account != account {
            // Another account: nothing read for the previous one may remain.
            reset(source)
            entries[source] = Entry(account: account)
        }
        load(source, force: false)
        // An open list whose songs were dropped (for example by an interrupted
        // read) loads again instead of showing placeholders.
        if let opened, opened.source == source, trackLoads[opened.id] == nil, trackStates[opened.id] == nil {
            loadTracks(opened, force: false)
        }
    }
    /// When the refresh button turns on again; nil while it is already on.
    func refreshAvailableAt(_ source: MusicSource) -> Date? {
        guard let last = entry(for: source)?.lastRequest else { return nil }
        let date = last.addingTimeInterval(BrowseSchedule.refreshCooldown)
        return date > now() ? date : nil
    }
    func canRefresh(_ source: MusicSource, at date: Date? = nil) -> Bool {
        guard let entry = entry(for: source), !entry.charts.loading, !entry.picks.loading else { return false }
        guard let last = entry.lastRequest else { return true }
        return (date ?? now()) >= last.addingTimeInterval(BrowseSchedule.refreshCooldown)
    }
    /// Reads both lists again, and the open list's songs when it belongs to
    /// this source. Ignored during the cooldown.
    func refresh(_ source: MusicSource) {
        guard canRefresh(source) else { return }
        // Songs read before are read again when opened; their keys stay in
        // the recent-list order so the cap still bounds what is kept.
        for key in cachedTracks.keys where key.hasPrefix(Self.prefix(source)) { cachedTracks.removeValue(forKey: key) }
        load(source, force: true)
        // Lists that carry their own songs are replaced when the new lists arrive.
        if let opened, opened.source == source, opened.tracks == nil { loadTracks(opened, force: true) }
    }
    /// Tries a list that failed again at once; lists that loaded are left alone.
    func retry(_ source: MusicSource) {
        guard let entry = entry(for: source) else { return }
        load(source, charts: entry.charts.error != nil, picks: entry.picks.error != nil)
    }
    /// Drops everything read for a source, for example after signing out.
    func forget(_ source: MusicSource) { reset(source) }

    private func load(_ source: MusicSource, force: Bool) { load(source, charts: force, picks: force) }
    private func load(_ source: MusicSource, charts forceCharts: Bool, picks forcePicks: Bool) {
        guard let entry = entries[source] else { return }
        let date = now()
        if !entry.charts.loading, forceCharts || entry.charts.needsLoad(at: date) {
            startShelf(source, account: entry.account, name: "charts") { [loader] in
                try await loader.charts(source)
            } apply: { store, result in
                store.entries[source]?.charts.apply(result, at: store.now(), hint: nil)
                if case .success(let fresh) = result { store.adopt(fresh, source: source) }
            } begin: { store in
                store.entries[source]?.charts.loading = true
            }
        }
        if !entry.picks.loading, forcePicks || entry.picks.needsLoad(at: date) {
            startShelf(source, account: entry.account, name: "picks") { [loader] in
                try await loader.recommendations(source)
            } apply: { store, result in
                let value = try? result.get(), date = store.now()
                store.entries[source]?.picks.apply(result, at: date, hint: value?.refreshesAt)
                if let value { store.adopt(value.collections, source: source) }
                if let partial = value?.partialError {
                    // Part of the picks is missing: say so, and treat the copy
                    // as stale so a visit after the retry delay asks again.
                    store.entries[source]?.picks.error = partial
                    store.entries[source]?.picks.failedAt = date
                    store.entries[source]?.picks.expiresAt = date
                }
            } begin: { store in
                store.entries[source]?.picks.loading = true
            }
        }
    }
    private func startShelf<Value: Sendable>(_ source: MusicSource, account: String, name: String,
                                             request: @escaping @MainActor () async throws -> Value,
                                             apply: @escaping @MainActor (BrowseStore, Result<Value, any Error>) -> Void,
                                             begin: @MainActor (BrowseStore) -> Void) {
        let token = generation(source), key = "\(source.rawValue)|\(name)"
        begin(self)
        entries[source]?.lastRequest = now()
        shelfTasks[key] = Task { [weak self] in
            let result: Result<Value, any Error>
            do { result = .success(try await request()) } catch { result = .failure(error) }
            guard let self, self.generations[source] == token else { return }
            self.shelfTasks[key] = nil
            // An unchanged generation means the same account's entry. It is
            // settled even while a status check briefly shows the source as
            // signing in, so a shelf can never stay loading; another account
            // never sees it, because `entry(for:)` checks the account.
            guard self.entries[source]?.account == account else { return }
            apply(self, result)
        }
    }
    /// The open list follows its newest copy, and lists that carry their own
    /// songs (Apple Music's song charts) replace any songs shown from before.
    private func adopt(_ collections: [BrowseCollection], source: MusicSource) {
        for collection in collections {
            if let tracks = collection.tracks, trackStates[collection.id] != nil {
                trackStates[collection.id] = .loaded(Array(tracks.prefix(BrowseSchedule.trackLimit)))
            }
        }
        if let opened, opened.source == source, let match = collections.first(where: { $0.id == opened.id }) { self.opened = match }
    }

    // MARK: Songs of a list

    func open(_ collection: BrowseCollection, from shelf: ShelfKind = .charts) {
        guard opened?.id != collection.id || openedShelf != shelf else { close(); return }
        opened = collection; openedShelf = shelf
        loadTracks(collection, force: false)
    }
    func close() { opened = nil; openedShelf = nil }
    func tracksState(for collection: BrowseCollection) -> TracksState? { trackStates[collection.id] }
    /// Retries a list whose songs failed to load.
    func reloadTracks(_ collection: BrowseCollection) { loadTracks(collection, force: true) }
    /// The songs for playing a list: the copy already read, or one request.
    func tracksForPlayback(_ collection: BrowseCollection) async -> [Track]? {
        loadTracks(collection, force: false)
        if case .loaded(let tracks) = trackStates[collection.id] { return tracks }
        guard let task = trackLoads[collection.id] else { return nil }
        pendingPlay = collection.id
        defer { if pendingPlay == collection.id { pendingPlay = nil } }
        return await task.value
    }

    private func loadTracks(_ collection: BrowseCollection, force: Bool) {
        let source = collection.source, key = collection.id
        guard case .ready(let account) = loader.availability(of: source), entries[source]?.account == account else { return }
        if let tracks = collection.tracks {
            trackStates[key] = .loaded(Array(tracks.prefix(BrowseSchedule.trackLimit))); touch(key); trim(); return
        }
        guard trackLoads[key] == nil else { return }
        if !force, let cached = cachedTracks[key], cached.account == account, now() < cached.expiresAt {
            touch(key); trackStates[key] = .loaded(cached.tracks); return
        }
        let token = generation(source)
        trackStates[key] = .loading
        trackLoads[key] = Task { [weak self, loader] in
            let result: Result<[Track], any Error>
            do { result = .success(try await loader.tracks(in: collection, limit: BrowseSchedule.trackLimit)) }
            catch { result = .failure(error) }
            guard let self, self.generations[source] == token else { return nil }
            self.trackLoads[key] = nil
            guard self.entries[source]?.account == account else { self.trackStates[key] = nil; return nil }
            switch result {
            case .success(let tracks):
                self.cache(tracks, key: key, account: account)
                self.trackStates[key] = .loaded(tracks)
                return tracks
            case .failure(let error):
                // An interrupted read is shown like a failure, with its retry.
                self.trackStates[key] = .failed(error is CancellationError ? BrowseStore.interrupted : error.localizedDescription)
                self.touch(key); self.trim()
                return nil
            }
        }
    }
    private func cache(_ tracks: [Track], key: String, account: String) {
        cachedTracks[key] = CachedTracks(account: account, tracks: tracks,
                                         expiresAt: BrowseSchedule.expiry(fetched: now(), lifetime: BrowseSchedule.tracksLifetime))
        touch(key); trim()
    }
    /// Keeps the songs of only the most recent lists; the open list and one
    /// waiting to play stay.
    private func trim() {
        var kept: [String] = []
        while cacheOrder.count > BrowseSchedule.cachedCollections {
            let oldest = cacheOrder.removeFirst()
            if opened?.id == oldest || pendingPlay == oldest { kept.append(oldest); continue }
            cachedTracks.removeValue(forKey: oldest)
            trackStates.removeValue(forKey: oldest)
        }
        cacheOrder.insert(contentsOf: kept, at: 0)
    }
    private func touch(_ key: String) {
        cacheOrder.removeAll { $0 == key }; cacheOrder.append(key)
    }

    // MARK: Sessions

    nonisolated static var interrupted: String { L10n.string("读取已中断，请重试。") }
    private func generation(_ source: MusicSource) -> UUID {
        if let value = generations[source] { return value }
        let value = UUID(); generations[source] = value; return value
    }
    private static func prefix(_ source: MusicSource) -> String { "\(source.rawValue):" }
    private func reset(_ source: MusicSource) {
        generations[source] = UUID()
        for (key, task) in shelfTasks where key.hasPrefix("\(source.rawValue)|") { task.cancel(); shelfTasks.removeValue(forKey: key) }
        let prefix = Self.prefix(source)
        for (key, task) in trackLoads where key.hasPrefix(prefix) { task.cancel(); trackLoads.removeValue(forKey: key) }
        for key in cachedTracks.keys where key.hasPrefix(prefix) { cachedTracks.removeValue(forKey: key) }
        cacheOrder.removeAll { $0.hasPrefix(prefix) }
        for key in trackStates.keys where key.hasPrefix(prefix) { trackStates.removeValue(forKey: key) }
        if opened?.source == source { close() }
        if pendingPlay?.hasPrefix(prefix) == true { pendingPlay = nil }
        entries.removeValue(forKey: source)
    }
}

private extension BrowseStore.Shelf {
    mutating func apply(_ result: Result<Value, any Error>, at date: Date, hint: Date?) {
        loading = false
        switch result {
        case .success(let fresh):
            value = fresh; error = nil; failedAt = nil; fetchedAt = date
            expiresAt = BrowseSchedule.expiry(fetched: date, lifetime: BrowseSchedule.listLifetime, hint: hint)
        case .failure(let failure):
            // An interrupted read (the platform session changed under it) is
            // shown like a failure, so the page offers a retry instead of
            // placeholders with nothing loading.
            error = failure is CancellationError ? BrowseStore.interrupted : failure.localizedDescription
            failedAt = date
        }
    }
}
