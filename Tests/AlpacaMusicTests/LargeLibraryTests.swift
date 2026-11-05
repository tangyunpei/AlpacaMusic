import Foundation
import Testing
@testable import AlpacaMusic

private struct LargeLibrarySnapshot: Encodable {
    let version = 1
    var tracks: [Track] = []
    var favorites: Set<String> = []
    var playlists: [MusicPlaylist] = []
    var sources = SourceConfiguration.defaults
}

private func largeLibraryDirectory(tracks: [Track] = []) throws -> URL {
    let directory = URL.temporaryDirectory.appending(path: "Large Album Library \(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(LargeLibrarySnapshot(tracks: tracks)).write(to: directory.appending(path: "library-v1.json"))
    return directory
}

private func albumTrack(_ id: String, source: MusicSource) -> Track {
    Track(id: "\(source.rawValue):\(id)", title: "Song \(id)", artist: "Album artist", album: "Saved album", duration: 150,
          source: source, sourceID: id, addedAt: Date(timeIntervalSince1970: 100))
}

@Suite("Large libraries and saved album imports")
@MainActor struct LargeLibraryTests {
    @Test func largeAddsPlaylistImportsAndPlaylistEditsPersistWithoutTruncatingOrDroppingDuplicates() async throws {
        let directory = try largeLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        await library.load()
        let initial = (0..<10_001).map { albumTrack(String($0), source: .netease) }
        library.addTracks(initial + [initial[0]])
        #expect(library.tracks.count == initial.count)
        var refreshed = initial[0]
        refreshed.title = "Updated song"
        refreshed.addedAt = Date(timeIntervalSince1970: 500)
        let importedSong = albumTrack("new", source: .netease)
        let remote = RemoteMusicPlaylist(id: "large-library-playlist", name: "Saved playlist", trackCount: 2, source: .netease)
        let playlist = try await library.importRemotePlaylistAndSave(remote, accountID: "fixture", tracks: [refreshed, importedSong, importedSong])
        let manuallyAdded = albumTrack("manual", source: .netease)
        library.addToPlaylist(playlist.id, track: manuallyAdded)
        library.toggleFavorite(initial[0].id)
        await library.flushPersistence()

        let restored = MusicLibrary(directory: directory)
        await restored.load()
        #expect(restored.error == nil)
        #expect(restored.tracks.count == 10_003)
        #expect(Set(restored.tracks.map(\.id)).count == 10_003)
        #expect(restored.tracks.first?.title == refreshed.title)
        #expect(restored.tracks.first?.addedAt == initial[0].addedAt)
        #expect(restored.tracks.suffix(2).map(\.id) == [importedSong.id, manuallyAdded.id])
        #expect(restored.favorites == [initial[0].id])
        #expect(restored.playlists.first?.trackIDs == [initial[0].id, importedSong.id, manuallyAdded.id])
    }

    @Test(arguments: [MusicSource.appleMusic, .netease])
    func savedAlbumReimportRefreshesMetadataAndRetainsFavoritesDatesAndLocalPlaylists(source: MusicSource) async throws {
        let first = albumTrack("first", source: source)
        let omitted = albumTrack("omitted", source: source)
        let directory = try largeLibraryDirectory(tracks: [first, omitted])
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        await library.load()
        library.toggleFavorite(first.id)
        let local = library.createPlaylist("Local collection")
        library.addToPlaylist(local.id, track: omitted)
        library.addToPlaylist(local.id, track: first)
        await library.flushPersistence()
        var refreshed = first
        refreshed.album = "Correct album metadata"
        refreshed.title = "Correct song title"
        refreshed.artworkURL = URL(string: "https://fixture.invalid/cover.jpg")
        refreshed.addedAt = Date(timeIntervalSince1970: 9999)
        let next = albumTrack("next", source: source)
        let album = RemoteMusicAlbum(id: "saved-album", name: "Saved album", artist: "Album artist", trackCount: 2, source: source)
        #expect(try await library.importRemoteAlbumAndSave(album, tracks: [refreshed, next, next]) == 2)
        #expect(try await library.importRemoteAlbumAndSave(album, tracks: [refreshed, next]) == 2)

        let restored = MusicLibrary(directory: directory)
        await restored.load()
        var expected = refreshed
        expected.addedAt = first.addedAt
        #expect(restored.error == nil)
        #expect(restored.tracks == [expected, omitted, next])
        #expect(restored.favorites == [first.id])
        #expect(restored.playlists.count == 1)
        #expect(restored.playlists.first?.id == local.id)
        #expect(restored.playlists.first?.name == "Local collection")
        #expect(restored.playlists.first?.trackIDs == [omitted.id, first.id])
    }

    @Test(arguments: ["unsupportedSource", "blankAlbumID", "mixedSource", "blankTrackID", "nilSourceID", "invalidDuration", "collision"])
    func invalidAlbumBatchDoesNotPartiallyImportOrOverwriteExistingData(kind: String) async throws {
        let original = albumTrack("existing", source: .netease)
        let directory = try largeLibraryDirectory(tracks: [original])
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        await library.load()
        library.toggleFavorite(original.id)
        await library.flushPersistence()
        let location = directory.appending(path: "library-v1.json")
        let before = try Data(contentsOf: location)
        var album = RemoteMusicAlbum(id: "saved-album", name: "Saved album", source: .appleMusic)
        var incoming = albumTrack("incoming", source: .appleMusic)
        switch kind {
        case "unsupportedSource": album.source = .spotify; incoming.source = .spotify
        case "blankAlbumID": album.id = " \n"
        case "mixedSource": incoming.source = .qq
        case "blankTrackID": incoming.id = " \n"
        case "nilSourceID": incoming.sourceID = nil
        case "invalidDuration": incoming.duration = .nan
        default: incoming.id = original.id
        }
        let valid = albumTrack("must-not-partially-add", source: album.source)
        await #expect(throws: MusicError.self) { try await library.importRemoteAlbumAndSave(album, tracks: [valid, incoming]) }
        #expect(library.tracks == [original])
        #expect(library.favorites == [original.id])
        #expect(library.playlists.isEmpty)
        #expect(try Data(contentsOf: location) == before)
    }

    @Test(arguments: [MusicSource.appleMusic, .netease])
    func albumImportReportsDiskFailuresAndRetrySavesTheSessionWithoutSyntheticPlaylists(source: MusicSource) async throws {
        let directory = try largeLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        await library.load()
        let location = directory.appending(path: "library-v1.json")
        try FileManager.default.removeItem(at: location)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false)
        let incoming = albumTrack("new", source: source)
        let album = RemoteMusicAlbum(id: "saved-album", name: "Saved album", source: source)
        do {
            _ = try await library.importRemoteAlbumAndSave(album, tracks: [incoming])
            Issue.record("A failed album write reported import success")
        } catch {
            let reason = try #require(library.persistenceError)
            #expect(error.localizedDescription == L10n.string("专辑歌曲已加入当前会话，但未能保存到磁盘。\(reason)"))
        }
        #expect(library.tracks == [incoming])
        #expect(library.playlists.isEmpty)
        try FileManager.default.removeItem(at: location)
        await library.retryPersistence()
        let restored = MusicLibrary(directory: directory)
        await restored.load()
        #expect(restored.error == nil && restored.tracks == [incoming])
        #expect(restored.playlists.isEmpty)
    }

    @Test func cancelledAlbumImportDoesNotLoadOrWriteTheLibrary() async throws {
        let original = albumTrack("original", source: .netease)
        let directory = try largeLibraryDirectory(tracks: [original])
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        let location = directory.appending(path: "library-v1.json")
        let before = try Data(contentsOf: location)
        let album = RemoteMusicAlbum(id: "saved-album", name: "Saved album", source: .netease)
        let task = Task { try await library.importRemoteAlbumAndSave(album, tracks: [albumTrack("new", source: .netease)]) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!library.ready && library.tracks.isEmpty)
        #expect(try Data(contentsOf: location) == before)
    }

    @Test func duplicateTrackIDsOnDiskStillKeepCorruptSnapshotAsBackup() async throws {
        let original = albumTrack("duplicate", source: .netease)
        let directory = try largeLibraryDirectory(tracks: [original, original])
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appending(path: "library-v1.json")
        let before = try Data(contentsOf: location)
        let library = MusicLibrary(directory: directory)
        await library.load()
        #expect(library.error == L10n.string("音乐资料库格式损坏，已保留原始备份并创建空资料库。原始音频文件没有改动。"))
        #expect(library.tracks.isEmpty)
        let backup = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains(".corrupt-") })
        #expect(try Data(contentsOf: backup) == before)
    }
}
