import Foundation
import struct MusicKit.MusicAuthorization
import Testing
@testable import AlpacaMusic

/// A library with one song, one playlist and one album. `delaysSongs` holds
/// the songs read open until the test resumes `songsGate`.
@MainActor private final class AutoImportAppleStub: AppleMusicAdapter {
    var authorization: MusicAuthorization.Status = .authorized
    var delaysSongs = false
    var songsGate: CheckedContinuation<Void, Never>?
    var songRequests = 0
    var songsResumed = false
    var playlistTrackRequests = 0
    var albumTrackRequests = 0

    func requestAuthorization() async -> MusicAuthorization.Status { authorization }
    func subscription() async throws -> AppleMusicCapabilities {
        AppleMusicCapabilities(canPlayCatalog: true, hasCloudLibrary: true)
    }
    func search(_ query: String) async throws -> [Track] { [] }
    func librarySongs(validate: @MainActor () throws -> Void, progress: @MainActor (ImportProgress) -> Void) async throws -> [Track] {
        songRequests += 1
        progress(ImportProgress(completed: 0, total: 1))
        if delaysSongs { await withCheckedContinuation { songsGate = $0 } }
        songsResumed = true
        try validate()
        progress(ImportProgress(completed: 1, total: 1))
        return [autoImportTrack("i.song", album: "Single")]
    }
    func libraryPlaylists(validate: @MainActor () throws -> Void) async throws -> [AppleMusicLibraryPlaylist] {
        try validate()
        return [AppleMusicLibraryPlaylist(id: "p.mix", name: "Mix", trackCount: 1)]
    }
    func libraryTracks(in playlist: AppleMusicLibraryPlaylist, validate: @MainActor () throws -> Void,
                       progress: @MainActor (ImportProgress) -> Void) async throws -> [Track] {
        playlistTrackRequests += 1
        try validate()
        progress(ImportProgress(completed: 1, total: 1))
        return [autoImportTrack("i.playlistSong", album: "Mix Album")]
    }
    func libraryAlbums(validate: @MainActor () throws -> Void) async throws -> [AppleMusicLibraryAlbum] {
        try validate()
        return [AppleMusicLibraryAlbum(id: "l.album", name: "Saved Album", artistName: "Album Artist", trackCount: 1)]
    }
    func libraryTracks(in album: AppleMusicLibraryAlbum, validate: @MainActor () throws -> Void,
                       progress: @MainActor (ImportProgress) -> Void) async throws -> [Track] {
        albumTrackRequests += 1
        try validate()
        progress(ImportProgress(completed: 1, total: album.trackCount))
        return [autoImportTrack("i.albumSong", album: album.name)]
    }
    func setSession(_ id: UUID?) { }
    func prepare(_ track: Track, session: UUID) async throws -> Double { track.duration }
    func play(session: UUID) async throws { }
    func pause() { }
    func seek(to seconds: Double) { }
    func snapshot() -> AppleMusicPlaybackSnapshot {
        AppleMusicPlaybackSnapshot(state: .stopped, position: 0, hasCurrentEntry: false)
    }
}

private func autoImportTrack(_ id: String, album: String) -> Track {
    Track(id: "appleMusic:library:\(id)", title: "Song \(id)", artist: "Artist", album: album, duration: 10,
          source: .appleMusic, sourceID: id, appleMusicResourceKind: .librarySong)
}

private struct AutoImportLibrarySnapshot: Encodable {
    let version = 1
    var tracks: [Track] = []
    var favorites: Set<String> = []
    var playlists: [MusicPlaylist] = []
    var sources = SourceConfiguration.defaults
}

private let autoImportMusicConfiguration = AppleMusicConfiguration(enabledInBuild: true, expectedTeam: "TESTTEAM",
                                                                   signedTeam: "TESTTEAM", isAdHoc: false,
                                                                   hasUsageDescription: true)

@MainActor private struct AutoImportFixture {
    let directory: URL
    let suite: String
    let defaults: UserDefaults
    let stub: AutoImportAppleStub
    let library: MusicLibrary
    let appleMusic: AppleMusicService
    let coordinator: AutoImportCoordinator
    let notices: AutoImportNotices

    init() throws {
        let folder = URL.temporaryDirectory.appending(path: "AutoImport \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(AutoImportLibrarySnapshot()).write(to: folder.appending(path: "library-v1.json"))
        let name = "AlpacaAutoImportTests.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        let adapter = AutoImportAppleStub()
        let musicLibrary = MusicLibrary(directory: folder)
        let music = AppleMusicService(defaults: store, configuration: autoImportMusicConfiguration, adapter: adapter)
        let accounts = ConnectedMusicAccounts(client: NativeMusicClient(credentials: MemoryMusicCredentialStore()))
        let spotify = SpotifyService(defaults: store, credentials: MemorySpotifyCredentialStore())
        let importer = AutoImportCoordinator(library: musicLibrary, accounts: accounts, appleMusic: music, spotify: spotify)
        let received = AutoImportNotices()
        importer.onNotice = { message in received.values.append(message) }
        directory = folder; suite = name; defaults = store; stub = adapter
        library = musicLibrary; appleMusic = music; coordinator = importer; notices = received
    }

    func tearDown() {
        coordinator.cancel()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor private final class AutoImportNotices {
    var values: [String] = []
}

@Suite(.serialized) @MainActor struct AutoImportTests {
    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<150 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }

    @Test func connectedAppleMusicImportsSongsPlaylistsAndAlbumsThenReportsOnce() async throws {
        let fixture = try AutoImportFixture(); defer { fixture.tearDown() }
        await fixture.appleMusic.connect()
        #expect(fixture.appleMusic.isEnabled)

        fixture.coordinator.start(.appleMusic)
        #expect(fixture.coordinator.status?.source == .appleMusic)
        #expect(fixture.coordinator.isActive)
        #expect(fixture.coordinator.isRunning(.appleMusic))
        try await waitFor { fixture.coordinator.status == nil }

        let ids = Set(fixture.library.tracks.map(\.id))
        #expect(ids.isSuperset(of: ["appleMusic:library:i.song", "appleMusic:library:i.playlistSong", "appleMusic:library:i.albumSong"]))
        #expect(fixture.library.playlists.count == 1)
        let playlist = try #require(fixture.library.playlists.first)
        #expect(playlist.trackIDs == ["appleMusic:library:i.playlistSong"])
        let albumID = AlbumGrouping.importedID(source: .appleMusic, remoteID: "l.album")
        let album = try #require(fixture.library.album(id: albumID))
        #expect(album.trackIDs == ["appleMusic:library:i.albumSong"])
        #expect(fixture.stub.songRequests == 1)
        #expect(fixture.stub.playlistTrackRequests == 1)
        #expect(fixture.stub.albumTrackRequests == 1)
        #expect(fixture.notices.values.count == 1)
        #expect(!fixture.coordinator.isActive)
        #expect(!fixture.coordinator.isRunning(.appleMusic))
    }

    @Test func cancelDuringAGatedReadStopsWithoutSavingOrNotifying() async throws {
        let fixture = try AutoImportFixture(); defer { fixture.tearDown() }
        await fixture.appleMusic.connect()
        fixture.stub.delaysSongs = true

        fixture.coordinator.start(.appleMusic)
        try await waitFor { fixture.stub.songsGate != nil }
        #expect(fixture.coordinator.status?.total == 3)
        fixture.coordinator.cancel()
        #expect(fixture.coordinator.status == nil)
        #expect(!fixture.coordinator.isActive)

        fixture.stub.songsGate?.resume()
        fixture.stub.songsGate = nil
        try await waitFor { fixture.stub.songsResumed }
        // Give the cancelled task every chance to (wrongly) continue.
        for _ in 0..<10 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))

        #expect(fixture.coordinator.status == nil)
        #expect(fixture.library.tracks.allSatisfy { $0.source != .appleMusic })
        #expect(fixture.library.playlists.isEmpty)
        #expect(fixture.stub.playlistTrackRequests == 0)
        #expect(fixture.stub.albumTrackRequests == 0)
        #expect(fixture.notices.values.isEmpty)
    }

    @Test func startIgnoresDuplicatesAndQueuesOtherSources() async throws {
        let fixture = try AutoImportFixture(); defer { fixture.tearDown() }
        await fixture.appleMusic.connect()
        fixture.stub.delaysSongs = true

        fixture.coordinator.start(.appleMusic)
        try await waitFor { fixture.stub.songsGate != nil }
        fixture.coordinator.start(.appleMusic)
        #expect(fixture.coordinator.status?.queued.isEmpty == true)
        fixture.coordinator.start(.netease)
        fixture.coordinator.start(.netease)
        let queued: [MusicSource] = fixture.coordinator.status?.queued ?? []
        #expect(queued == [MusicSource.netease])
        #expect(fixture.coordinator.isRunning(.netease))
        fixture.coordinator.cancel(.netease)
        #expect(fixture.coordinator.status?.queued.isEmpty == true)
        #expect(!fixture.coordinator.isRunning(.netease))
        #expect(fixture.coordinator.isRunning(.appleMusic))

        fixture.stub.songsGate?.resume()
        fixture.stub.songsGate = nil
        try await waitFor { fixture.coordinator.status == nil }
        #expect(fixture.stub.songRequests == 1)
        #expect(fixture.stub.playlistTrackRequests == 1)
        #expect(fixture.notices.values.count == 1)
    }
}
