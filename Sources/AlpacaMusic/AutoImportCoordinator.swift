import Foundation
import Observation
import SwiftUI

/// Live state of a background import started by a fresh account connection.
struct AutoImportStatus: Equatable, Sendable {
    var source: MusicSource
    /// The collection being read or saved; empty while collections are listed.
    var currentName: String
    /// Collections finished so far, successful or not.
    var finished: Int
    /// Collections planned; zero while still listing.
    var total: Int
    /// Page progress of the current collection, when the platform reports it.
    var currentFraction: Double?
    /// Sources waiting after this one.
    var queued: [MusicSource]

    /// Overall fraction once the plan is known; nil keeps the bar indeterminate.
    var fraction: Double? {
        guard total > 0 else { return nil }
        return ImportProgress.batchFraction(finished: finished, count: total, current: currentFraction)
    }
}

/// Imports everything a newly connected account offers, one source at a time,
/// in the background. Launch-time restores never start it. Every read is
/// validated against the session or account captured when the run began, and
/// a collection counts as imported only after the library reached disk.
@MainActor @Observable final class AutoImportCoordinator {
    @ObservationIgnored var onNotice: (@MainActor (String) -> Void)?
    /// Non-nil while a run is active. Changes on every progress tick.
    private(set) var status: AutoImportStatus?
    /// The source being imported. Changes only when runs start or end, so the
    /// app shell can gate on `isActive` without re-rendering on ticks.
    private var running: MusicSource?
    private var waiting: [MusicSource] = []
    private let library: MusicLibrary
    private let accounts: ConnectedMusicAccounts
    private let appleMusic: AppleMusicService
    private let spotify: SpotifyService
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private var imported = 0
    @ObservationIgnored private var failed = 0

    init(library: MusicLibrary, accounts: ConnectedMusicAccounts, appleMusic: AppleMusicService, spotify: SpotifyService) {
        self.library = library
        self.accounts = accounts
        self.appleMusic = appleMusic
        self.spotify = spotify
    }

    /// True while any run is active; cheap to observe from the app shell.
    var isActive: Bool { running != nil }

    /// Running now or queued.
    func isRunning(_ source: MusicSource) -> Bool {
        running == source || waiting.contains(source)
    }

    /// Call only for a fresh connection. A source already running or queued is
    /// ignored; another source waits until the current run ends.
    func start(_ source: MusicSource) {
        guard Self.supports(source), !isRunning(source) else { return }
        if running == nil {
            begin(source)
        } else {
            waiting.append(source)
            status?.queued = waiting
        }
    }

    /// Stops the current run and clears the queue. No failure notice is shown.
    func cancel() {
        operation = UUID(); task?.cancel(); task = nil
        waiting = []; running = nil; status = nil
    }

    /// Stops or dequeues one source; the next queued source then starts.
    func cancel(_ source: MusicSource) {
        if let index = waiting.firstIndex(of: source) {
            waiting.remove(at: index)
            status?.queued = waiting
        }
        guard running == source else { return }
        operation = UUID(); task?.cancel(); task = nil
        advance()
    }

    private static func supports(_ source: MusicSource) -> Bool {
        source == .appleMusic || source == .spotify || DirectMusicAccess.sources.contains(source)
    }

    // MARK: Run lifecycle

    private func begin(_ source: MusicSource) {
        let token = UUID(); operation = token
        imported = 0; failed = 0
        running = source
        status = AutoImportStatus(source: source, currentName: "", finished: 0, total: 0,
                                  currentFraction: nil, queued: waiting)
        task = Task { @MainActor in
            await self.run(source, token: token)
        }
    }

    private func advance() {
        guard !waiting.isEmpty else {
            running = nil; status = nil
            return
        }
        begin(waiting.removeFirst())
    }

    private func run(_ source: MusicSource, token: UUID) async {
        do {
            switch source {
            case .appleMusic: try await importAppleMusic(token: token)
            case .spotify: try await importSpotify(token: token)
            default: try await importAccount(source, token: token)
            }
            guard operation == token else { return }
            let message = failed == 0
                ? L10n.string("\(source.title) · 已自动导入 \(imported) 项")
                : L10n.string("\(source.title) · 已自动导入 \(imported) 项，\(failed) 项失败")
            onNotice?(message)
        } catch {
            // A manual cancel or a replaced run stays silent. Anything else that
            // ends the whole run means the connection changed underneath it.
            guard operation == token, !Task.isCancelled else { return }
            onNotice?(L10n.string("\(source.title) · 连接已变化，自动导入已停止"))
        }
        guard operation == token else { return }
        task = nil
        advance()
    }

    // MARK: Progress

    private func checkActive(_ token: UUID) throws {
        try Task.checkCancellation()
        guard operation == token else { throw CancellationError() }
    }

    private func plan(_ total: Int, token: UUID) {
        guard operation == token else { return }
        status?.total = total
    }

    /// Page progress; ignored once the run is replaced or cancelled.
    private func report(_ value: ImportProgress, expected: Int?, token: UUID) {
        guard operation == token else { return }
        let progress = value.total == nil ? ImportProgress(completed: value.completed, total: expected) : value
        status?.currentFraction = progress.fraction
    }

    /// Lists collections. A failed listing is counted and the run continues;
    /// cancellation and changed connections stop it.
    private func list<T>(token: UUID, _ body: @MainActor () async throws -> [T]) async throws -> [T] {
        do {
            return try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try checkActive(token)
            failed += 1
            return []
        }
    }

    /// Reads and saves one collection. A failure is counted and the run
    /// continues; cancellation and changed connections stop the whole run.
    private func collect(_ name: String, token: UUID, _ body: @MainActor () async throws -> Void) async throws {
        try checkActive(token)
        status?.currentName = name
        status?.currentFraction = nil
        do {
            try await body()
            try checkActive(token)
            imported += 1
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try checkActive(token)
            failed += 1
        }
        status?.finished += 1
        status?.currentFraction = nil
    }

    // MARK: Apple Music

    private func importAppleMusic(token: UUID) async throws {
        let music = appleMusic
        guard music.isEnabled else { throw CancellationError() }
        let session = music.librarySessionID
        // Load first so each save's final validation and mutation have no
        // intervening disk-load suspension that can change accounts.
        await library.load()
        try checkActive(token)
        try music.validateLibrarySession(session)
        let playlists = try await list(token: token) { try await music.libraryPlaylists() }
        try music.validateLibrarySession(session)
        let albums = try await list(token: token) { try await music.libraryAlbums() }
        try music.validateLibrarySession(session)
        plan(1 + playlists.count + albums.count, token: token)

        try await collect(L10n.string("全部歌曲"), token: token) {
            let tracks = try await music.librarySongs(progress: { value in
                self.report(value, expected: nil, token: token)
            })
            try music.validateLibrarySession(session)
            try self.checkActive(token)
            _ = try await self.library.importAppleMusicSongsAndSave(tracks)
        }
        for playlist in playlists {
            try await collect(playlist.name, token: token) {
                let tracks = try await music.libraryTracks(in: playlist, progress: { value in
                    self.report(value, expected: playlist.trackCount, token: token)
                })
                try music.validateLibrarySession(session)
                try self.checkActive(token)
                let remote = RemoteMusicPlaylist(id: playlist.id, name: playlist.name, trackCount: tracks.count,
                                                 artworkURL: playlist.artworkURL, source: .appleMusic)
                // A provider namespace, not an Apple Account ID.
                _ = try await self.library.importRemotePlaylistAndSave(remote, accountID: "musickit-library", tracks: tracks)
            }
        }
        for album in albums {
            try await collect(album.name, token: token) {
                let tracks = try await music.libraryTracks(in: album, progress: { value in
                    self.report(value, expected: album.trackCount, token: token)
                })
                try music.validateLibrarySession(session)
                try self.checkActive(token)
                let remote = RemoteMusicAlbum(id: album.id, name: album.name, artist: album.artistName,
                                              trackCount: album.trackCount, artworkURL: album.artworkURL, source: .appleMusic)
                _ = try await self.library.importRemoteAlbumAndSave(remote, tracks: tracks)
            }
        }
    }

    // MARK: Spotify

    private func importSpotify(token: UUID) async throws {
        let service = spotify
        guard service.isEnabled, let accountID = service.profile?.id else { throw CancellationError() }
        let session = service.sessionID
        await library.load()
        try checkActive(token)
        try service.validateSession(session)
        let playlists = try await list(token: token) { try await service.playlists() }
        try service.validateSession(session)
        plan(1 + playlists.count, token: token)

        let likedName = L10n.string("喜欢的歌曲")
        try await collect(likedName, token: token) {
            let progress: @MainActor @Sendable (ImportProgress) -> Void = { value in
                self.report(value, expected: nil, token: token)
            }
            let tracks = try await service.savedTracks(progress: progress)
            try service.validateSession(session)
            try self.checkActive(token)
            let remote = RemoteMusicPlaylist(id: "saved-tracks", name: likedName, trackCount: tracks.count, source: .spotify)
            _ = try await self.library.importRemotePlaylistAndSave(remote, accountID: accountID, tracks: tracks)
        }
        for playlist in playlists {
            try await collect(playlist.name, token: token) {
                let expected: Int? = playlist.trackCount > 0 ? playlist.trackCount : nil
                let progress: @MainActor @Sendable (ImportProgress) -> Void = { value in
                    self.report(value, expected: expected, token: token)
                }
                let tracks = try await service.tracks(in: playlist, progress: progress)
                try service.validateSession(session)
                try self.checkActive(token)
                _ = try await self.library.importRemotePlaylistAndSave(playlist, accountID: accountID, tracks: tracks)
            }
        }
    }

    // MARK: NetEase, QQ Music, Soda

    private func importAccount(_ source: MusicSource, token: UUID) async throws {
        guard let accountID = accounts.state(source).profile?.id else { throw CancellationError() }
        let client = accounts.client
        await library.load()
        try await validateAccount(source, accountID: accountID, token: token)
        await accounts.loadPlaylists(source)
        try await validateAccount(source, accountID: accountID, token: token)
        let state = accounts.state(source)
        let listed = state.error == nil && state.playlistsLoaded
        let playlists: [RemoteMusicPlaylist] = listed ? state.playlists : []
        if !listed { failed += 1 }
        var albums: [RemoteMusicAlbum] = []
        if source == .netease {
            albums = try await list(token: token) { try await client.albums(source) }
            try await validateAccount(source, accountID: accountID, token: token)
        }
        plan(playlists.count + albums.count, token: token)

        for playlist in playlists {
            try await collect(playlist.name, token: token) {
                let tracks = try await self.readPlaylist(playlist, accountID: accountID, token: token)
                try await self.validateAccount(source, accountID: accountID, token: token)
                _ = try await self.library.importRemotePlaylistAndSave(playlist, accountID: accountID, tracks: tracks)
            }
        }
        for album in albums {
            try await collect(album.name, token: token) {
                let scope = try await client.libraryScope(for: source)
                let tracks = try await client.tracks(in: album)
                try self.checkActive(token)
                try await client.validateLibraryScope(scope)
                try await self.validateAccount(source, accountID: accountID, token: token)
                _ = try await self.library.importRemoteAlbumAndSave(album, tracks: tracks)
            }
        }
    }

    /// An incomplete playlist keeps its readable tracks, after the same
    /// account validation as a complete one.
    private func readPlaylist(_ playlist: RemoteMusicPlaylist, accountID: String, token: UUID) async throws -> [Track] {
        let expected: Int? = playlist.trackCount > 0 ? playlist.trackCount : nil
        do {
            return try await accounts.client.tracks(in: playlist, progress: { value in
                self.report(value, expected: expected, token: token)
            })
        } catch MusicError.incompletePlaylist(let partial) {
            try await validateAccount(playlist.source, accountID: accountID, token: token)
            guard !partial.tracks.isEmpty else { throw MusicError.incompletePlaylist(partial) }
            return partial.tracks
        }
    }

    /// The same account checks as the playlist sheet. A list refresh started
    /// elsewhere is waited out rather than treated as a changed account.
    private func validateAccount(_ source: MusicSource, accountID: String, token: UUID) async throws {
        try await waitUntilIdle(source, token: token)
        guard accounts.state(source).profile?.id == accountID else { throw CancellationError() }
        guard await accounts.client.isConnected(source, accountID: accountID) else { throw CancellationError() }
        try checkActive(token)
        let state = accounts.state(source)
        guard !state.busy, state.profile?.id == accountID else { throw CancellationError() }
    }

    private func waitUntilIdle(_ source: MusicSource, token: UUID) async throws {
        try checkActive(token)
        var attempts = 0
        while accounts.state(source).busy && attempts < 300 {
            attempts += 1
            try await Task.sleep(for: .milliseconds(100))
            try checkActive(token)
        }
    }
}

/// A compact, cancellable card for a running auto-import. With a `source`, it
/// shows only that source's run, or a quiet waiting line while it is queued;
/// otherwise any run, with the queue as a small count. Renders nothing when idle.
struct AutoImportStatusPanel: View {
    var coordinator: AutoImportCoordinator
    var source: MusicSource? = nil

    var body: some View {
        if let status = coordinator.status, source == nil || status.source == source {
            ImportProgressPanel(title: title(status),
                                progress: status.total > 0 ? ImportProgress(completed: status.finished, total: status.total) : nil,
                                fraction: status.fraction,
                                symbol: status.total > 0 ? "square.stack" : "arrow.down.circle",
                                onCancel: { coordinator.cancel(status.source) })
        } else if let source, coordinator.isRunning(source) {
            AutoImportQueuedLine(source: source, onCancel: { coordinator.cancel(source) })
        }
    }

    private func title(_ status: AutoImportStatus) -> String {
        let name = status.currentName.isEmpty
            ? L10n.string("\(status.source.title) · 正在读取资料库…")
            : L10n.string("\(status.source.title) ·「\(status.currentName)」")
        // The app-wide card also counts sources waiting behind this one.
        guard source == nil, !status.queued.isEmpty else { return name }
        return "\(name)  +\(status.queued.count)"
    }
}

/// A source waiting behind another source's run: glyph, name, cancel.
private struct AutoImportQueuedLine: View {
    @Environment(\.appPalette) private var palette
    var source: MusicSource
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ImportStatusGlyph(state: .queued, size: 12)
            Text(source.title).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.text)
                .lineLimit(1)
            Text(L10n.string("等待导入")).font(.system(size: 10)).foregroundStyle(palette.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onCancel) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .frame(width: 20, height: 20).contentShape(.rect)
            }.buttonStyle(.plain).foregroundStyle(palette.secondary)
                .help(L10n.string("取消")).accessibilityLabel(L10n.string("取消导入"))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(palette.accent.opacity(0.05), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}
