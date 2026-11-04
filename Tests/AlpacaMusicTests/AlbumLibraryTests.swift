import Foundation
import Testing
@testable import AlpacaMusic

private struct AlbumDiskFixture: Codable {
    var version = 1
    var tracks: [Track]
    var favorites: Set<String> = []
    var playlists: [MusicPlaylist] = []
    var albums: [MusicAlbum]? = nil
    var sources = SourceConfiguration.defaults
}

private func albumDirectory(_ snapshot: AlbumDiskFixture) throws -> URL {
    let directory = URL.temporaryDirectory.appending(path: "Album Library \(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(snapshot).write(to: directory.appending(path: "library-v1.json"))
    return directory
}

private func savedAlbumTrack(_ id: String, source: MusicSource = .appleMusic, album: String = "One album", artist: String = "One artist") -> Track {
    Track(id: "\(source.rawValue):\(id)", title: "Song \(id)", artist: artist, album: album, duration: 30,
          source: source, sourceID: id, addedAt: Date(timeIntervalSince1970: 100))
}

private func savedRemoteAlbum(_ id: String = "remote-album", source: MusicSource = .appleMusic) -> RemoteMusicAlbum {
    RemoteMusicAlbum(id: id, name: "One album", artist: "One artist", source: source)
}

@Suite("Persisted and inferred library albums")
@MainActor struct AlbumLibraryTests {
    @Test func versionOneWithoutAlbumsMigratesAndInfersExistingSongsWithoutReimport() async throws {
        let first = savedAlbumTrack("first", album: "  One   album \n", artist: "One artist")
        let second = savedAlbumTrack("second", album: "one album", artist: "ONE ARTIST")
        let otherArtist = savedAlbumTrack("other-artist", album: "One album", artist: "Another artist")
        let otherSource = savedAlbumTrack("other-source", source: .netease)
        let blankAlbum = savedAlbumTrack("no-album", album: "  \n")
        let local = MusicPlaylist(id: "local", name: "Keep playlist", trackIDs: [second.id, first.id])
        let directory = try albumDirectory(AlbumDiskFixture(tracks: [first, second, otherArtist, otherSource, blankAlbum], favorites: [first.id], playlists: [local]))
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appending(path: "library-v1.json")
        let oldJSON = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: location)) as? [String: Any])
        #expect(oldJSON["albums"] == nil)
        let library = MusicLibrary(directory: directory)
        await library.load()
        #expect(library.error == nil && library.tracks.count == 5)
        #expect(library.albums.count == 3)
        #expect(library.albums[0].name == "One album")
        #expect(library.albums[0].trackIDs == [first.id, second.id])
        #expect(library.albums[1].trackIDs == [otherArtist.id])
        #expect(library.albums[2].source == .netease)
        #expect(library.albums.allSatisfy { !$0.trackIDs.contains(blankAlbum.id) })
        #expect(library.favorites == [first.id] && library.playlists == [local])
        let saved = try JSONDecoder().decode(AlbumDiskFixture.self, from: Data(contentsOf: location))
        #expect(saved.albums == []) // Inferred groups are not saved as explicit albums.
        let reopened = MusicLibrary(directory: directory)
        await reopened.load()
        #expect(reopened.error == nil && reopened.albums == library.albums)
        #expect(reopened.tracks == library.tracks && reopened.playlists == [local])
    }

    @Test(arguments: [MusicSource.appleMusic, .netease])
    func explicitAlbumPersistsProviderMetadataAndExactOrderWithoutCreatingPlaylist(source: MusicSource) async throws {
        let directory = try albumDirectory(AlbumDiskFixture(tracks: []))
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        let first = savedAlbumTrack("first", source: source, artist: "First track artist")
        let second = savedAlbumTrack("second", source: source, artist: "Second track artist")
        var remote = savedRemoteAlbum(source: source)
        remote.name = "Provider album title"
        remote.artist = "Various artists"
        remote.artworkURL = URL(string: "https://fixture.invalid/album-cover.jpg")
        #expect(try await library.importRemoteAlbumAndSave(remote, tracks: [second, first, second]) == 2)
        let album = try #require(library.albums.first)
        #expect(library.albums.count == 1 && library.playlists.isEmpty)
        #expect(album.id == AlbumGrouping.importedID(source: source, remoteID: remote.id))
        #expect(album.name == remote.name && album.artist == remote.artist && album.source == source)
        #expect(album.artworkURL == remote.artworkURL && album.trackIDs == [second.id, first.id])
        #expect(library.tracks(withIDs: album.trackIDs) == [second, first])
        let reopened = MusicLibrary(directory: directory)
        await reopened.load()
        #expect(reopened.error == nil && reopened.albums == [album])
        #expect(reopened.album(id: album.id) == album)
        #expect(reopened.album(id: "missing") == nil)
        #expect(reopened.playlists.isEmpty)
    }

    @Test func reimportReplacesOrderAndUpdatesMetadataWithoutDuplicateCardsOrRemovingOmittedSongs() async throws {
        let first = savedAlbumTrack("first")
        let omitted = savedAlbumTrack("omitted")
        let third = savedAlbumTrack("third")
        let directory = try albumDirectory(AlbumDiskFixture(tracks: []))
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        let remote = savedRemoteAlbum()
        _ = try await library.importRemoteAlbumAndSave(remote, tracks: [first, omitted])
        let originalID = try #require(library.albums.first?.id)
        library.toggleFavorite(first.id)
        let playlist = library.createPlaylist("Local order")
        library.addToPlaylist(playlist.id, track: omitted)
        library.addToPlaylist(playlist.id, track: first)
        var refreshed = first
        refreshed.title = "Updated track title"
        refreshed.addedAt = Date(timeIntervalSince1970: 9999)
        var updatedAlbum = remote
        updatedAlbum.name = "ONE ALBUM"
        updatedAlbum.artworkURL = URL(string: "https://fixture.invalid/new-cover.jpg")
        #expect(try await library.importRemoteAlbumAndSave(updatedAlbum, tracks: [third, refreshed, third]) == 2)
        #expect(try await library.importRemoteAlbumAndSave(updatedAlbum, tracks: [third, refreshed]) == 2)
        let reopened = MusicLibrary(directory: directory)
        await reopened.load()
        #expect(reopened.albums.count == 1)
        let album = try #require(reopened.album(id: originalID))
        #expect(album.name == "ONE ALBUM" && album.artworkURL == updatedAlbum.artworkURL)
        #expect(album.trackIDs == [third.id, first.id])
        #expect(reopened.tracks.map(\.id) == [first.id, omitted.id, third.id])
        #expect(reopened.tracks.first?.title == refreshed.title)
        #expect(reopened.tracks.first?.addedAt == first.addedAt)
        #expect(reopened.favorites == [first.id])
        #expect(reopened.playlists.first?.trackIDs == [omitted.id, first.id])
    }

    @Test func remoteIdentitySeparatesSourcesAndDistinctAlbumsWithTheSameDisplayMetadata() async throws {
        let directory = try albumDirectory(AlbumDiskFixture(tracks: []))
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        _ = try await library.importRemoteAlbumAndSave(savedRemoteAlbum("same-id"), tracks: [savedAlbumTrack("first")])
        _ = try await library.importRemoteAlbumAndSave(savedRemoteAlbum("another-id"), tracks: [savedAlbumTrack("second")])
        _ = try await library.importRemoteAlbumAndSave(savedRemoteAlbum("same-id", source: .netease), tracks: [savedAlbumTrack("first", source: .netease)])
        #expect(library.albums.count == 3 && Set(library.albums.map(\.id)).count == 3)
        let reopened = MusicLibrary(directory: directory)
        await reopened.load()
        #expect(reopened.albums == library.albums)
    }

    @Test func artworkFallsBackToSongAndIsRetainedWhenLaterResponseHasNoCover() async throws {
        let directory = try albumDirectory(AlbumDiskFixture(tracks: []))
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        let first = savedAlbumTrack("first")
        var second = savedAlbumTrack("second")
        second.artworkURL = URL(string: "https://fixture.invalid/song-cover.jpg")
        _ = try await library.importRemoteAlbumAndSave(savedRemoteAlbum(), tracks: [first, second])
        let id = try #require(library.albums.first?.id)
        #expect(library.album(id: id)?.artworkURL == second.artworkURL)
        let cover = second.artworkURL
        second.artworkURL = nil
        _ = try await library.importRemoteAlbumAndSave(savedRemoteAlbum(), tracks: [first, second])
        #expect(library.album(id: id)?.artworkURL == cover)
        let reopened = MusicLibrary(directory: directory)
        await reopened.load()
        #expect(reopened.album(id: id)?.artworkURL == cover)
    }

    @Test func removingSongsCleansExactMembershipAndRemovesEmptyAlbumsAcrossRestart() async throws {
        let directory = try albumDirectory(AlbumDiskFixture(tracks: []))
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        let first = savedAlbumTrack("first"), second = savedAlbumTrack("second")
        _ = try await library.importRemoteAlbumAndSave(savedRemoteAlbum(), tracks: [second, first])
        let id = try #require(library.albums.first?.id)
        library.toggleFavorite(second.id)
        library.removeTrack(second.id)
        await library.flushPersistence()
        #expect(library.album(id: id)?.trackIDs == [first.id])
        #expect(library.favorites.isEmpty)
        let reopened = MusicLibrary(directory: directory)
        await reopened.load()
        #expect(reopened.album(id: id)?.trackIDs == [first.id])
        reopened.removeTrack(first.id)
        await reopened.flushPersistence()
        #expect(reopened.albums.isEmpty && reopened.album(id: id) == nil)
        let empty = MusicLibrary(directory: directory)
        await empty.load()
        #expect(empty.error == nil && empty.albums.isEmpty && empty.tracks.isEmpty)
    }

    @Test func inferredIdentityIsDeterministicAndCacheRefreshesAfterTrackMetadataChanges() async throws {
        var first = savedAlbumTrack("first", album: "Cafe\u{301}  Album", artist: "Ａｒｔｉｓｔ")
        let second = savedAlbumTrack("second", album: "CAFÉ ALBUM", artist: "artist")
        let separate = savedAlbumTrack("separate", album: "Café Album", artist: "Another artist")
        first.artworkURL = URL(string: "https://fixture.invalid/inferred.jpg")
        let directory = try albumDirectory(AlbumDiskFixture(tracks: [first, second, separate]))
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        await library.load()
        let albums = library.albums
        #expect(albums.count == 2 && albums[0].trackIDs == [first.id, second.id])
        #expect(albums[0].artworkURL == first.artworkURL)
        let reordered = AlbumGrouping.collections(stored: [], tracks: [second, first, separate])
        #expect(reordered[0].id == albums[0].id)
        first.album = "Another album"
        library.addTracks([first])
        #expect(library.albums.count == 3)
        #expect(library.album(id: albums[0].id)?.trackIDs == [second.id])
        library.removeTrack(second.id)
        #expect(library.album(id: albums[0].id) == nil)
        await library.flushPersistence()
        let reopened = MusicLibrary(directory: directory)
        await reopened.load()
        #expect(reopened.albums == library.albums)
    }

    @Test func loadingDropsMissingAlbumReferencesWithoutDiscardingExistingSongs() async throws {
        let song = savedAlbumTrack("exists")
        let album = MusicAlbum(id: "saved-album", name: "One album", artist: "One artist", source: .appleMusic, trackIDs: ["missing", song.id])
        let empty = MusicAlbum(id: "empty-album", name: "Removed album", artist: "Artist", source: .appleMusic, trackIDs: ["gone"])
        let directory = try albumDirectory(AlbumDiskFixture(tracks: [song], albums: [album, empty]))
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        await library.load()
        #expect(library.error == nil && library.tracks == [song])
        #expect(library.albums.count == 1 && library.albums.first?.trackIDs == [song.id])
        let saved = try JSONDecoder().decode(AlbumDiskFixture.self, from: Data(contentsOf: directory.appending(path: "library-v1.json")))
        #expect(saved.albums?.count == 1 && saved.albums?.first?.trackIDs == [song.id])
    }

    @Test(arguments: ["duplicateAlbumIDs", "duplicateTrackIDs", "wrongSource", "blankName", "blankID"])
    func malformedAlbumSnapshotPreservesOriginalBackup(kind: String) async throws {
        let song = savedAlbumTrack("exists")
        var album = MusicAlbum(id: "saved-album", name: "One album", artist: "One artist", source: .appleMusic, trackIDs: [song.id])
        switch kind {
        case "duplicateTrackIDs": album.trackIDs.append(song.id)
        case "wrongSource": album.source = .netease
        case "blankName": album.name = " \n"
        case "blankID": album.id = " \n"
        default: break
        }
        let directory = try albumDirectory(AlbumDiskFixture(tracks: [song], albums: kind == "duplicateAlbumIDs" ? [album, album] : [album]))
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appending(path: "library-v1.json")
        let original = try Data(contentsOf: location)
        let library = MusicLibrary(directory: directory)
        await library.load()
        #expect(library.error == L10n.string("音乐资料库格式损坏，已保留原始备份并创建空资料库。原始音频文件没有改动。"))
        #expect(library.tracks.isEmpty && library.albums.isEmpty)
        let backup = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains(".corrupt-") })
        #expect(try Data(contentsOf: backup) == original)
    }

    @Test func invalidAlbumNameAndCancellationDoNotMutateExistingAlbumCollection() async throws {
        let directory = try albumDirectory(AlbumDiskFixture(tracks: []))
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        let song = savedAlbumTrack("first")
        _ = try await library.importRemoteAlbumAndSave(savedRemoteAlbum(), tracks: [song])
        let originalAlbums = library.albums
        let location = directory.appending(path: "library-v1.json")
        let original = try Data(contentsOf: location)
        var invalid = savedRemoteAlbum()
        invalid.name = " \n"
        await #expect(throws: MusicError.self) { try await library.importRemoteAlbumAndSave(invalid, tracks: [savedAlbumTrack("must-not-add")]) }
        let pending = Task { try await library.importRemoteAlbumAndSave(savedRemoteAlbum(), tracks: [savedAlbumTrack("cancelled")]) }
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(library.albums == originalAlbums && library.tracks == [song])
        #expect(try Data(contentsOf: location) == original)
    }

    @Test func failedSaveRetainsSessionAlbumAndRetryPersistsItsMembership() async throws {
        let directory = try albumDirectory(AlbumDiskFixture(tracks: []))
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        await library.load()
        let location = directory.appending(path: "library-v1.json")
        try FileManager.default.removeItem(at: location)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false)
        let song = savedAlbumTrack("first")
        await #expect(throws: MusicError.self) { try await library.importRemoteAlbumAndSave(savedRemoteAlbum(), tracks: [song]) }
        let album = try #require(library.albums.first)
        #expect(library.persistenceError != nil && album.trackIDs == [song.id])
        try FileManager.default.removeItem(at: location)
        await library.retryPersistence()
        let reopened = MusicLibrary(directory: directory)
        await reopened.load()
        #expect(reopened.error == nil && reopened.albums == [album])
        #expect(reopened.tracks == [song] && reopened.playlists.isEmpty)
    }
}
