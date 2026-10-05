import Foundation
import Testing
@testable import AlpacaMusic

private struct AppleLibrarySnapshot: Encodable {
    let version = 1
    var tracks: [Track]
    var favorites: Set<String> = []
    var playlists: [MusicPlaylist] = []
    var sources = SourceConfiguration.defaults
}

private func appleLibraryDirectory(tracks: [Track] = []) throws -> URL {
    let directory = URL.temporaryDirectory.appending(path: "Apple Music 曲库 \(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(AppleLibrarySnapshot(tracks: tracks)).write(to: directory.appending(path: "library-v1.json"))
    return directory
}

private func appleLibraryTrack(_ id: String, title: String = "Fixture", addedAt: Date = Date(timeIntervalSince1970: 100)) -> Track {
    Track(id: "appleMusic:\(id)", title: title, artist: "Artist", album: "Album", duration: 30,
          source: .appleMusic, sourceID: id, addedAt: addedAt)
}

@Suite("Apple Music library persistence") @MainActor struct AppleMusicLibraryPersistenceTests {
    @Test func opaqueLibraryIDAndExplicitResourceKindSurviveRestartAlongsideLegacyRecords() async throws {
        let directory = try appleLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appending(path: "library-v1.json")
        // This is an actual old-format fixture: the resource-kind key is absent,
        // independently of how the current Track encoder handles a nil value.
        let legacy = #"{"version":1,"tracks":[{"id":"appleMusic:123456","title":"Legacy catalog song","artist":"Artist","album":"Album","duration":30,"source":"appleMusic","sourceID":"123456","addedAt":0,"unavailable":false}],"favorites":["appleMusic:123456"],"playlists":[{"id":"local-legacy","name":"Legacy playlist","trackIDs":["appleMusic:123456"]}],"sources":[{"kind":"netease","endpoint":"","enabled":false},{"kind":"qq","endpoint":"","enabled":false}]}"#
        try Data(legacy.utf8).write(to: location)
        let opaqueID = "x.AbCd1234567"
        var incoming = appleLibraryTrack(opaqueID)
        incoming.id = "appleMusic:library:\(opaqueID)"
        incoming.appleMusicResourceKind = .librarySong
        let library = MusicLibrary(directory: directory)

        #expect(try await library.importAppleMusicSongsAndSave([incoming]) == 1)
        #expect(library.tracks.first?.appleMusicResourceKind == nil)
        let restored = MusicLibrary(directory: directory)
        await restored.load()
        #expect(restored.error == nil)
        #expect(restored.tracks.count == 2)
        let song = try #require(restored.tracks.first { $0.id == incoming.id })
        #expect(song == incoming)
        #expect(song.sourceID == opaqueID && song.appleMusicResourceKind == .librarySong)
        let prior = try #require(restored.tracks.first { $0.id == "appleMusic:123456" })
        #expect(prior.sourceID == "123456" && prior.appleMusicResourceKind == nil)
        #expect(restored.favorites == [prior.id])
        #expect(restored.playlists.first?.trackIDs == [prior.id])
        #expect(restored.playlists.first?.name == "Legacy playlist")
    }

    @Test func allSongsLoadExistingStateDeduplicateAndPreserveLibraryPlaybackIDsAfterRestart() async throws {
        let catalog = appleLibraryTrack("123456")
        let directory = try appleLibraryDirectory(tracks: [catalog])
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        let first = appleLibraryTrack("i.library-one")
        var upload = appleLibraryTrack("i.upload-without-catalog")
        upload.unavailable = true

        let count = try await library.importAppleMusicSongsAndSave([first, first, upload])
        #expect(count == 2)
        #expect(library.playlists.isEmpty)
        let restored = MusicLibrary(directory: directory)
        await restored.load()
        #expect(restored.tracks == [catalog, first, upload])
        #expect(restored.tracks.map(\.sourceID) == ["123456", "i.library-one", "i.upload-without-catalog"])
        #expect(restored.tracks.last?.unavailable == true)
        #expect(restored.tracks.allSatisfy { $0.url == nil })
        #expect(restored.playlists.isEmpty)
    }

    @Test func reimportUpdatesMetadataAndPreservesAddedAtFavoritesAndLocalPlaylists() async throws {
        let first = appleLibraryTrack("i.first")
        let omitted = appleLibraryTrack("i.omitted")
        let directory = try appleLibraryDirectory(tracks: [first, omitted])
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        await library.load()
        library.toggleFavorite(first.id)
        let playlist = library.createPlaylist("自己整理的歌单")
        library.addToPlaylist(playlist.id, track: first)
        library.addToPlaylist(playlist.id, track: omitted)
        await library.flushPersistence()
        var refreshed = first
        refreshed.title = "Updated title"
        refreshed.artworkURL = URL(string: "https://example.com/updated-artwork.jpg")
        refreshed.addedAt = Date(timeIntervalSince1970: 9_999)
        let next = appleLibraryTrack("i.next")

        #expect(try await library.importAppleMusicSongsAndSave([refreshed, next, next]) == 2)
        #expect(try await library.importAppleMusicSongsAndSave([refreshed, next]) == 2)
        let restored = MusicLibrary(directory: directory)
        await restored.load()
        var expected = refreshed
        expected.addedAt = first.addedAt
        #expect(restored.tracks == [expected, omitted, next])
        #expect(restored.favorites == [first.id])
        #expect(restored.playlists.first?.name == "自己整理的歌单")
        #expect(restored.playlists.first?.trackIDs == [first.id, omitted.id])
    }

    @Test(arguments: ["emptyID", "blankID", "nilSourceID", "blankSourceID", "negativeDuration", "nanDuration", "infiniteDuration", "mixedSource"])
    func invalidBatchLeavesAllExistingStateAndDiskUnchanged(kind: String) async throws {
        let original = appleLibraryTrack("i.existing")
        let directory = try appleLibraryDirectory(tracks: [original])
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        await library.load()
        library.toggleFavorite(original.id)
        let playlist = library.createPlaylist("Keep me")
        library.addToPlaylist(playlist.id, track: original)
        await library.flushPersistence()
        let location = directory.appending(path: "library-v1.json")
        let before = try Data(contentsOf: location)
        let priorPlaylists = library.playlists
        var invalid = appleLibraryTrack("i.invalid")
        switch kind {
        case "emptyID": invalid.id = ""
        case "blankID": invalid.id = " \n"
        case "nilSourceID": invalid.sourceID = nil
        case "blankSourceID": invalid.sourceID = " \n"
        case "negativeDuration": invalid.duration = -1
        case "nanDuration": invalid.duration = .nan
        case "infiniteDuration": invalid.duration = .infinity
        default: invalid.source = .qq
        }
        let valid = appleLibraryTrack("i.must-not-be-partially-added")

        await #expect(throws: MusicError.self) { try await library.importAppleMusicSongsAndSave([valid, invalid]) }
        #expect(library.tracks == [original])
        #expect(library.favorites == [original.id])
        #expect(library.playlists == priorPlaylists)
        #expect(try Data(contentsOf: location) == before)
    }

    @Test func matchingIDFromAnotherSourceCannotBeOverwritten() async throws {
        var otherSource = appleLibraryTrack("i.collision")
        otherSource.source = .url
        otherSource.url = URL(string: "https://example.com/original.mp3")
        let directory = try appleLibraryDirectory(tracks: [otherSource])
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        await library.load()
        let location = directory.appending(path: "library-v1.json")
        let before = try Data(contentsOf: location)
        let incoming = appleLibraryTrack("i.collision")
        await #expect(throws: MusicError.self) { try await library.importAppleMusicSongsAndSave([incoming]) }
        let remote = RemoteMusicPlaylist(id: "p.collision", name: "Collision", trackCount: 1, source: .appleMusic)
        await #expect(throws: MusicError.self) { try await library.importRemotePlaylistAndSave(remote, accountID: "musickit-library", tracks: [incoming]) }
        #expect(library.tracks == [otherSource])
        #expect(library.playlists.isEmpty)
        #expect(try Data(contentsOf: location) == before)
    }

    @Test func totalLibraryCapacityCountsUniqueIDsAndRejectsWholeOverLimitBatch() async throws {
        var existing = (0..<9_999).map { appleLibraryTrack("i.\($0)") }
        // The ceiling is shared with other platforms, not an Apple-only quota.
        existing[1] = Track(id: "netease:existing", title: "Other platform", artist: "Artist", album: "Album", duration: 15,
                            source: .netease, sourceID: "existing")
        let directory = try appleLibraryDirectory(tracks: existing)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        let last = appleLibraryTrack("i.9999")
        #expect(try await library.importAppleMusicSongsAndSave([existing[0], last, last]) == 2)
        #expect(library.tracks.count == 10_000)
        let location = directory.appending(path: "library-v1.json")
        let before = try Data(contentsOf: location)
        var changed = existing[0]
        changed.title = "Must not update during rejected import"
        await #expect(throws: MusicError.self) {
            try await library.importAppleMusicSongsAndSave([changed, appleLibraryTrack("i.10000")])
        }
        #expect(library.tracks.count == 10_000)
        #expect(library.tracks[0] == existing[0])
        #expect(try Data(contentsOf: location) == before)
        let restored = MusicLibrary(directory: directory)
        await restored.load()
        #expect(restored.tracks == existing + [last])
    }

    @Test func cancelledImportDoesNotLoadOrSubmitItsBatch() async throws {
        let original = appleLibraryTrack("i.original")
        let directory = try appleLibraryDirectory(tracks: [original])
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        let location = directory.appending(path: "library-v1.json")
        let before = try Data(contentsOf: location)
        // Both closures inherit MainActor; cancellation happens before the task
        // can enter the import, without timing sleeps or real account access.
        let task = Task { try await library.importAppleMusicSongsAndSave([appleLibraryTrack("i.cancelled")]) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!library.ready && library.tracks.isEmpty)
        #expect(try Data(contentsOf: location) == before)
        await library.load()
        #expect(library.tracks == [original])
    }

    @Test func unreadableOriginalLibraryIsNeverReplacedByImportedSongs() async throws {
        let directory = try appleLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = directory.appending(path: "library-v1.json")
        try FileManager.default.removeItem(at: location)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false)
        let sentinel = location.appending(path: "original-data")
        let bytes = Data("keep original contents".utf8)
        try bytes.write(to: sentinel)
        let library = MusicLibrary(directory: directory)

        await #expect(throws: MusicError.self) { try await library.importAppleMusicSongsAndSave([appleLibraryTrack("i.new")]) }
        #expect(library.tracks.isEmpty && library.playlists.isEmpty)
        #expect(library.error?.contains("无法读取") == true)
        #expect(try Data(contentsOf: sentinel) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == 1)
    }

    @Test func writeFailureDoesNotReportSuccessAndCanBeRetried() async throws {
        let directory = try appleLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        await library.load()
        let location = directory.appending(path: "library-v1.json")
        try FileManager.default.removeItem(at: location)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false)
        let incoming = appleLibraryTrack("i.unsaved")
        do {
            _ = try await library.importAppleMusicSongsAndSave([incoming])
            Issue.record("A failed disk write must not report a successful import")
        } catch {
            #expect(error.localizedDescription.contains("已加入当前会话"))
            #expect(error.localizedDescription.contains("未能保存到磁盘"))
        }
        #expect(library.tracks == [incoming] && library.persistenceError != nil)
        try FileManager.default.removeItem(at: location)
        await library.retryPersistence()
        #expect(library.persistenceError == nil)
        let restored = MusicLibrary(directory: directory)
        await restored.load()
        #expect(restored.tracks == [incoming] && restored.playlists.isEmpty)
    }

    @Test func appleMusicPlaylistReimportRetainsLocalEditsAndNeverUsesCookieSources() async throws {
        let directory = try appleLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        let first = appleLibraryTrack("i.first")
        let second = appleLibraryTrack("i.second")
        let playlist = RemoteMusicPlaylist(id: "p.library-playlist", name: "Library playlist", trackCount: 2, source: .appleMusic)
        let imported = try await library.importRemotePlaylistAndSave(playlist, accountID: "musickit-library", tracks: [first, first])
        let extra = Track(id: "url:manual", title: "Manual", artist: "Artist", album: "Album", duration: 10,
                          source: .url, url: URL(string: "https://example.com/manual.mp3"))
        library.addToPlaylist(imported.id, track: extra)
        var renamedRemote = playlist
        renamedRemote.name = "Remote rename should not replace local name"
        let reimported = try await library.importRemotePlaylistAndSave(renamedRemote, accountID: "musickit-library", tracks: [first, second])

        var missingPlaybackID = appleLibraryTrack("i.invalid-playlist-item")
        missingPlaybackID.sourceID = nil
        await #expect(throws: MusicError.self) {
            try await library.importRemotePlaylistAndSave(playlist, accountID: "musickit-library", tracks: [missingPlaybackID])
        }

        #expect(imported.id == reimported.id && reimported.name == imported.name)
        #expect(!DirectMusicAccess.sources.contains(.appleMusic))
        let restored = MusicLibrary(directory: directory)
        await restored.load()
        #expect(restored.playlists == [reimported])
        #expect(reimported.trackIDs == [first.id, extra.id, second.id])
        #expect(restored.tracks.count == 3 && Set(restored.tracks.map(\.id)).count == 3)
        #expect(restored.tracks.first?.sourceID == "i.first")
    }
}
