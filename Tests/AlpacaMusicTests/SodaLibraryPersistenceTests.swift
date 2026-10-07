import Foundation
import Testing
@testable import AlpacaMusic

private struct SodaLibraryDiskSnapshot: Codable {
    var version = 1
    var tracks: [Track]
    var favorites: Set<String> = []
    var playlists: [MusicPlaylist] = []
    var sources = SourceConfiguration.defaults
}

private func sodaLibraryDirectory(tracks: [Track] = []) throws -> URL {
    let directory = URL.temporaryDirectory.appending(path: "Soda Library Tests \(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(SodaLibraryDiskSnapshot(tracks: tracks)).write(to: directory.appending(path: "library-v1.json"))
    return directory
}

private func sodaLibraryTrack(_ id: String, title: String = "Fixture song", addedAt: Date = Date(timeIntervalSince1970: 100)) -> Track {
    Track(id: "soda:\(id)", title: title, artist: "Fixture artist", album: "Fixture album", duration: 30,
          source: .soda, sourceID: id, sodaPlayback: .init(fullDuration: 240, start: 60, duration: 30, isPreview: true),
          addedAt: addedAt)
}

@Suite("Soda library persistence")
@MainActor struct SodaLibraryPersistenceTests {
    @Test func reimportRefreshesMetadataWithoutReorderingOrReplacingFavoritesAndLocalEdits() async throws {
        let first = sodaLibraryTrack("7000000000000000001")
        let omitted = sodaLibraryTrack("7000000000000000002")
        let directory = try sodaLibraryDirectory(tracks: [first, omitted])
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        await library.load()
        library.toggleFavorite(first.id)
        let playlist = library.createPlaylist("本地排序")
        library.addToPlaylist(playlist.id, track: omitted)
        library.addToPlaylist(playlist.id, track: first)
        await library.flushPersistence()

        var refreshed = first
        refreshed.title = "Updated metadata"
        refreshed.addedAt = Date(timeIntervalSince1970: 9999)
        refreshed.sodaPlayback = .init(fullDuration: 240, start: 80, duration: 20, isPreview: true)
        refreshed.duration = 20
        refreshed.url = URL(string: "https://fixture.invalid/audio.mp3?temporary_key=refresh-secret")
        let next = sodaLibraryTrack("7000000000000000003", addedAt: Date(timeIntervalSince1970: 200))
        var duplicate = next; duplicate.title = "A duplicate must not replace the first occurrence"
        #expect(try await library.importSodaSongsAndSave([next, refreshed, duplicate]) == 2)
        #expect(try await library.importSodaSongsAndSave([next, refreshed]) == 2)

        let restored = MusicLibrary(directory: directory)
        await restored.load()
        var expected = refreshed; expected.addedAt = first.addedAt; expected.url = nil
        #expect(restored.tracks == [expected, omitted, next])
        #expect(restored.favorites == [first.id])
        #expect(restored.playlists.count == 1)
        #expect(restored.playlists.first?.name == "本地排序")
        #expect(restored.playlists.first?.trackIDs == [omitted.id, first.id])
        #expect(restored.tracks.first?.sodaPlayback?.start == 80)
        #expect(restored.tracks.allSatisfy { $0.source != .soda || $0.url == nil })
    }

    @Test(arguments: ["emptyID", "blankID", "nilSourceID", "emptySourceID", "blankSourceID", "negativeDuration", "nanDuration", "infiniteDuration", "mixedSource", "nanRangeDuration", "infiniteRangeStart", "negativeRangeStart", "negativeRangeDuration", "negativeFullDuration", "rangePastSongEnd"])
    func invalidBatchLeavesEveryExistingRecordAndTheDiskSnapshotUnchanged(kind: String) async throws {
        let original = sodaLibraryTrack("7000000000000000001")
        let directory = try sodaLibraryDirectory(tracks: [original])
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        await library.load()
        library.toggleFavorite(original.id)
        let playlist = library.createPlaylist("Preserve local edits")
        library.addToPlaylist(playlist.id, track: original)
        await library.flushPersistence()
        let location = directory.appending(path: "library-v1.json")
        let before = try Data(contentsOf: location)
        let priorPlaylists = library.playlists
        var invalid = sodaLibraryTrack("7000000000000000002")
        switch kind {
        case "emptyID": invalid.id = ""
        case "blankID": invalid.id = " \n"
        case "nilSourceID": invalid.sourceID = nil
        case "emptySourceID": invalid.sourceID = ""
        case "blankSourceID": invalid.sourceID = " \n"
        case "negativeDuration": invalid.duration = -1
        case "nanDuration": invalid.duration = .nan
        case "infiniteDuration": invalid.duration = .infinity
        case "mixedSource": invalid.source = .qq
        case "nanRangeDuration": invalid.sodaPlayback?.duration = .nan
        case "infiniteRangeStart": invalid.sodaPlayback?.start = .infinity
        case "negativeRangeStart": invalid.sodaPlayback?.start = -1
        case "negativeRangeDuration": invalid.sodaPlayback?.duration = -1
        case "negativeFullDuration": invalid.sodaPlayback?.fullDuration = -1
        default: invalid.sodaPlayback = .init(fullDuration: 240, start: 235, duration: 30, isPreview: true)
        }
        let valid = sodaLibraryTrack("7000000000000000003")
        await #expect(throws: MusicError.self) { try await library.importSodaSongsAndSave([valid, invalid]) }
        #expect(library.tracks == [original])
        #expect(library.favorites == [original.id])
        #expect(library.playlists == priorPlaylists)
        #expect(try Data(contentsOf: location) == before)
    }

    @Test func aMatchingIDOwnedByAnotherPlatformCannotBeOverwritten() async throws {
        var other = sodaLibraryTrack("7000000000000000001")
        other.source = .url
        other.sodaPlayback = nil
        other.url = URL(string: "https://fixture.invalid/original.mp3")
        let directory = try sodaLibraryDirectory(tracks: [other])
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        await library.load()
        let location = directory.appending(path: "library-v1.json")
        let before = try Data(contentsOf: location)
        await #expect(throws: MusicError.self) { try await library.importSodaSongsAndSave([sodaLibraryTrack("7000000000000000001")]) }
        #expect(library.tracks == [other])
        #expect(try Data(contentsOf: location) == before)
    }

    @Test func sharedCapacityCountsUniqueIDsAndRejectsAnEntireOverflowBatchBeforeRefreshingAnything() async throws {
        var existing = (1..<10000).map { sodaLibraryTrack(String($0)) }
        existing[1] = Track(id: "netease:fixture", title: "Other platform", artist: "Fixture", album: "Fixture", duration: 15,
                            source: .netease, sourceID: "fixture")
        let directory = try sodaLibraryDirectory(tracks: existing)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        let last = sodaLibraryTrack("10000")
        #expect(try await library.importSodaSongsAndSave([existing[0], last, last]) == 2)
        #expect(library.tracks.count == 10000)
        let location = directory.appending(path: "library-v1.json")
        let before = try Data(contentsOf: location)
        var changed = existing[0]; changed.title = "Must not change in a rejected batch"
        await #expect(throws: MusicError.self) { try await library.importSodaSongsAndSave([changed, sodaLibraryTrack("10001")]) }
        #expect(library.tracks == existing + [last])
        #expect(try Data(contentsOf: location) == before)
        let restored = MusicLibrary(directory: directory)
        await restored.load()
        #expect(restored.tracks == existing + [last])
    }

    @Test func realDiskWriteFailureCannotReportSuccessAndRetryPersistsTheSession() async throws {
        let directory = try sodaLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        await library.load()
        let location = directory.appending(path: "library-v1.json")
        try FileManager.default.removeItem(at: location)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false)
        let sentinel = location.appending(path: "original-data")
        let bytes = Data("Keep the blocked destination intact".utf8)
        try bytes.write(to: sentinel)
        var incoming = sodaLibraryTrack("7000000000000000001")
        incoming.url = URL(string: "https://fixture.invalid/audio.mp3?temporary_key=unsaved-secret")
        do {
            _ = try await library.importSodaSongsAndSave([incoming])
            Issue.record("A failed disk write reported import success")
        } catch {
            let persistenceError = try #require(library.persistenceError)
            #expect(error.localizedDescription == L10n.string("歌曲已加入当前会话，但未能保存到磁盘。\(persistenceError)"))
        }
        var expected = incoming; expected.url = nil
        #expect(library.tracks == [expected])
        #expect(library.persistenceError != nil)
        #expect(try Data(contentsOf: sentinel) == bytes)
        try FileManager.default.removeItem(at: location)
        await library.retryPersistence()
        #expect(library.persistenceError == nil)
        let restored = MusicLibrary(directory: directory)
        await restored.load()
        #expect(restored.error == nil)
        #expect(restored.tracks == [expected])
        #expect(restored.playlists.isEmpty)
        #expect(!String(decoding: try Data(contentsOf: location), as: UTF8.self).contains("unsaved-secret"))
    }

    @Test(arguments: ["songs", "playlist", "addTracks"])
    func everyLibraryWritePathStripsOnlySodaMediaURLsBeforeWritingJSON(kind: String) async throws {
        let directory = try sodaLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        await library.load()
        var incoming = sodaLibraryTrack("7000000000000000001")
        incoming.url = URL(string: "https://fixture.invalid/audio.mp3?temporary_key=must-never-reach-library-json")
        incoming.artworkURL = URL(string: "https://fixture.invalid/cover.jpg")
        let manual = Track(id: "url:manual", title: "Manual audio", artist: "Fixture", album: "Fixture", duration: 20,
                           source: .url, url: URL(string: "https://fixture.invalid/manual.mp3"))
        library.addTracks([manual])
        switch kind {
        case "songs": _ = try await library.importSodaSongsAndSave([incoming])
        case "playlist":
            let remote = RemoteMusicPlaylist(id: "7000000000000000002", name: "Public share", trackCount: 1, source: .soda)
            _ = try await library.importRemotePlaylistAndSave(remote, accountID: "public-share", tracks: [incoming])
        default: library.addTracks([incoming]); await library.flushPersistence()
        }
        let data = try Data(contentsOf: directory.appending(path: "library-v1.json"))
        let snapshot = try JSONDecoder().decode(SodaLibraryDiskSnapshot.self, from: data)
        let stored = try #require(snapshot.tracks.first { $0.id == incoming.id })
        #expect(stored.url == nil)
        #expect(stored.sodaPlayback == incoming.sodaPlayback)
        #expect(stored.artworkURL == incoming.artworkURL)
        #expect(snapshot.tracks.first { $0.id == manual.id }?.url == manual.url)
        #expect(!String(decoding: data, as: UTF8.self).contains("must-never-reach-library-json"))
        let restored = MusicLibrary(directory: directory)
        await restored.load()
        #expect(restored.tracks.first { $0.id == incoming.id }?.url == nil)
        #expect(restored.tracks.first { $0.id == incoming.id }?.sodaPlayback == incoming.sodaPlayback)
    }

    @Test func cancelledImportDoesNotLoadTheLibraryOrWriteItsBatch() async throws {
        let original = sodaLibraryTrack("7000000000000000001")
        let directory = try sodaLibraryDirectory(tracks: [original])
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        let location = directory.appending(path: "library-v1.json")
        let before = try Data(contentsOf: location)
        // MainActor inheritance keeps cancellation ahead of the first line of
        // the import, independent of scheduling sleeps or network behavior.
        let pending = Task { try await library.importSodaSongsAndSave([sodaLibraryTrack("7000000000000000002")]) }
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(!library.ready)
        #expect(library.tracks.isEmpty)
        #expect(try Data(contentsOf: location) == before)
        await library.load()
        #expect(library.tracks == [original])
    }

    @Test func cancelledImportAgainstAnAlreadyLoadedLibraryLeavesAllStateUnchanged() async throws {
        let original = sodaLibraryTrack("7000000000000000001")
        let directory = try sodaLibraryDirectory(tracks: [original])
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        await library.load()
        library.toggleFavorite(original.id)
        await library.flushPersistence()
        let location = directory.appending(path: "library-v1.json")
        let before = try Data(contentsOf: location)
        let pending = Task { try await library.importSodaSongsAndSave([sodaLibraryTrack("7000000000000000002")]) }
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(library.tracks == [original])
        #expect(library.favorites == [original.id])
        #expect(try Data(contentsOf: location) == before)
    }
}
