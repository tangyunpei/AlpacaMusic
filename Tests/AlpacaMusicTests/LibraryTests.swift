import Foundation
import Testing
@testable import AlpacaMusic

private func makeLibraryDirectory(seedEmpty: Bool = true, name: String = "AlpacaLibraryTest") throws -> URL {
    let url = URL.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    if seedEmpty {
        let empty = #"{"version":1,"tracks":[],"favorites":[],"playlists":[],"sources":[{"kind":"netease","endpoint":"","enabled":false},{"kind":"qq","endpoint":"","enabled":false}]}"#
        try Data(empty.utf8).write(to: url.appending(path: "library-v1.json"))
    }
    return url
}
private func writeWAV(in directory: URL, name: String = "actual.wav") throws -> URL {
    let sampleCount = 8000
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    data.append(Data("RIFF".utf8)); append(UInt32(36 + sampleCount * 2)); data.append(Data("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(8000)); append(UInt32(16000)); append(UInt16(2)); append(UInt16(16)); data.append(Data("data".utf8)); append(UInt32(sampleCount * 2)); data.append(Data(repeating: 0, count: sampleCount * 2))
    let url = directory.appending(path: name); try data.write(to: url); return url
}

@Suite("Native library persistence and imports") @MainActor struct LibraryTests {
    private func remote(_ id: String) -> Track { Track(id: id, title: id, artist: "Fixture", album: "Fixture", duration: 12, source: .url, url: URL(string: "https://audio.example/\(id).mp3")) }

    @Test func partialPlaylistThenFullReimportPreservesLocalEditsAcrossRestarts() async throws {
        let directory = try makeLibraryDirectory(name: "Partial Import 音乐")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Track(id: "qq:first", title: "First", artist: "Fixture", album: "Fixture", duration: 30,
                          source: .qq, sourceID: "first", addedAt: Date(timeIntervalSince1970: 1_000))
        let second = Track(id: "qq:second", title: "Second", artist: "Fixture", album: "Fixture", duration: 40,
                           source: .qq, sourceID: "second", addedAt: Date(timeIntervalSince1970: 2_000))
        let missing = Track(id: "qq:missing", title: "Recovered", artist: "Fixture", album: "Fixture", duration: 50,
                            source: .qq, sourceID: "missing")
        let partial = PartialPlaylistImport(tracks: [first, second], totalCount: 3, failedCount: 1,
                                            issues: ["第三首暂时读取失败"], message: "只能读取 2 / 3 首歌曲")
        let remotePlaylist = RemoteMusicPlaylist(id: "partial-fixture", name: "平台歌单", trackCount: 3, source: .qq)
        let library = MusicLibrary(directory: directory)
        let imported = try await library.importRemotePlaylistAndSave(remotePlaylist, accountID: "fixture-account", tracks: partial.tracks)
        let partialRestored = MusicLibrary(directory: directory)
        await partialRestored.load()
        #expect(Set(partialRestored.tracks.map(\.id)) == Set(partial.tracks.map(\.id)))
        #expect(partialRestored.playlists == [imported])
        #expect(!partialRestored.tracks.contains { $0.id == missing.id })

        let localResult = await partialRestored.importURLs([try writeWAV(in: directory, name: "本地追加.wav")])
        #expect(localResult.errors.isEmpty)
        let localTrack = try #require(localResult.tracks.first)
        partialRestored.addToPlaylist(imported.id, track: localTrack)
        await partialRestored.flushPersistence()

        // The model has no rename method. Seed an existing local name on disk;
        // all import and merge operations still use the real persistence API.
        let location = directory.appending(path: "library-v1.json")
        var snapshot = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: location)) as? [String: Any])
        var playlists = try #require(snapshot["playlists"] as? [[String: Any]])
        let playlistIndex = try #require(playlists.firstIndex { $0["id"] as? String == imported.id })
        playlists[playlistIndex]["name"] = "我的本地名称"
        snapshot["playlists"] = playlists
        try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]).write(to: location, options: .atomic)

        let merging = MusicLibrary(directory: directory)
        await merging.load()
        var refreshedFirst = first
        refreshedFirst.title = "First refreshed"
        refreshedFirst.addedAt = Date(timeIntervalSince1970: 9_000)
        let completeTracks = [refreshedFirst, second, missing, refreshedFirst, missing]
        let completed = try await merging.importRemotePlaylistAndSave(remotePlaylist, accountID: "fixture-account", tracks: completeTracks)
        _ = try await merging.importRemotePlaylistAndSave(remotePlaylist, accountID: "fixture-account", tracks: completeTracks)
        #expect(completed.id == imported.id)

        let final = MusicLibrary(directory: directory)
        await final.load()
        let result = try #require(final.playlists.first)
        #expect(final.playlists.count == 1)
        #expect(result.id == imported.id && result.name == "我的本地名称")
        #expect(result.trackIDs == [first.id, second.id, localTrack.id, missing.id])
        #expect(Set(result.trackIDs).count == result.trackIDs.count)
        #expect(final.tracks.count == 4 && Set(final.tracks.map(\.id)).count == 4)
        #expect(final.tracks.first { $0.id == first.id }?.addedAt == first.addedAt)
        #expect(final.tracks.first { $0.id == first.id }?.title == refreshedFirst.title)
        #expect(final.tracks.first { $0.id == localTrack.id }?.addedAt == localTrack.addedAt)
        #expect(final.persistenceError == nil && final.error == nil)
    }

    @Test func remotePlaylistSurvivesRestartInDirectoryWithSpacesAndUnicode() async throws {
        let directory = try makeLibraryDirectory(name: "Alpaca Music 音乐 # 100%")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        await library.load()
        let incoming = ["first", "second"].map {
            Track(id: "netease:\($0)", title: $0, artist: "Fixture", album: "Fixture", duration: 30, source: .netease, sourceID: $0)
        }
        let remote = RemoteMusicPlaylist(id: "fixture", name: "保留歌单", trackCount: incoming.count, source: .netease)
        let playlist = try await library.importRemotePlaylistAndSave(remote, accountID: "fixture-account", tracks: incoming)
        library.toggleFavorite(incoming[0].id)
        await library.flushPersistence()
        let savedIDs = Set(library.tracks.map(\.id))
        let restored = MusicLibrary(directory: directory)
        await restored.load()
        await restored.flushPersistence()

        #expect(Set(restored.tracks.map(\.id)) == savedIDs)
        #expect(restored.tracks.filter { $0.source == .netease }.count == incoming.count)
        #expect(restored.playlists == [playlist])
        #expect(restored.favorites == [incoming[0].id])
        #expect(restored.error == nil)
        let persisted = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "library-v1.json"))) as? [String: Any])
        #expect((persisted["playlists"] as? [[String: Any]])?.count == 1)
    }

    @Test func localBookmarkWithSpacesAndUnicodeStaysAvailableAfterRestart() async throws {
        let directory = try makeLibraryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try writeWAV(in: directory, name: "我的 音乐 # 100%.wav")
        let library = MusicLibrary(directory: directory)
        let imported = await library.importURLs([file])
        #expect(imported.errors.isEmpty)
        let original = try #require(imported.tracks.first)
        await library.flushPersistence()
        let restored = MusicLibrary(directory: directory)
        await restored.load()

        let track = try #require(restored.tracks.first { $0.id == original.id })
        #expect(!track.unavailable)
        #expect(track.url?.resolvingSymlinksInPath() == file.resolvingSymlinksInPath())
        #expect(FileManager.default.isReadableFile(atPath: file.path(percentEncoded: false)))
    }

    @Test func cloudImportDoesNotReportSuccessUntilDiskSaveSucceeds() async throws {
        let directory = try makeLibraryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory); await library.load(); await library.flushPersistence()
        let location = directory.appending(path: "library-v1.json")
        // A directory in place of the file makes real atomic writes fail reliably.
        try FileManager.default.removeItem(at: location)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: false)
        let playlist = RemoteMusicPlaylist(id: "fixture", name: "Cloud", trackCount: 1, source: .netease)
        let track = Track(id: "netease:fixture", title: "Fixture", artist: "Fixture", album: "Fixture", duration: 10, source: .netease, sourceID: "12345")
        await #expect(throws: MusicError.self) { try await library.importRemotePlaylistAndSave(playlist, accountID: "12345", tracks: [track]) }
        #expect(library.tracks.count == 1 && library.persistenceError != nil)
        try FileManager.default.removeItem(at: location)
        await library.retryPersistence()
        #expect(library.persistenceError == nil)
        let restored = MusicLibrary(directory: directory); await restored.load()
        #expect(restored.tracks.map(\.id) == [track.id] && restored.playlists.count == 1)
    }

    @Test func favoritesPlaylistsAndSourcesPersistWithoutResurrectingDeletes() async throws {
        let directory = try makeLibraryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        library.addTracks([remote("one"), remote("two")]); library.toggleFavorite("one")
        let playlist = library.createPlaylist("  我的音乐  "); library.addToPlaylist(playlist.id, track: remote("one")); library.addToPlaylist(playlist.id, track: remote("one"))
        try library.saveSources([SourceConfiguration(kind: .qq, endpoint: "http://127.0.0.1:3300/", enabled: true)])
        await library.flushPersistence()
        let restored = MusicLibrary(directory: directory); await restored.load()
        #expect(restored.tracks.count == 2 && restored.favorites == ["one"])
        #expect(restored.playlists.first?.name == "我的音乐" && restored.playlists.first?.trackIDs == ["one"])
        #expect(restored.sources.last?.endpoint == "http://127.0.0.1:3300")
        restored.removeTrack("one"); restored.removeTrack("two"); await restored.flushPersistence()
        let empty = MusicLibrary(directory: directory); await empty.load()
        #expect(empty.tracks.isEmpty && empty.favorites.isEmpty && empty.playlists.first?.trackIDs.isEmpty == true)
    }
    @Test func rapidMutationsPersistTheLatestSnapshot() async throws {
        let directory = try makeLibraryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        for number in 0..<40 { library.addTracks([remote("song-\(number)")]) }
        for number in 0..<20 { library.removeTrack("song-\(number)") }
        await library.flushPersistence()
        let restored = MusicLibrary(directory: directory); await restored.load()
        #expect(Set(restored.tracks.map(\.id)) == Set((20..<40).map { "song-\($0)" }))
    }
    @Test func damagedStatePreservesOriginalBytes() async throws {
        let directory = try makeLibraryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data("{broken-json".utf8)
        try original.write(to: directory.appending(path: "library-v1.json"))
        let library = MusicLibrary(directory: directory); await library.load()
        #expect(library.error == L10n.string("音乐资料库格式损坏，已保留原始备份并创建空资料库。原始音频文件没有改动。") && library.tracks.isEmpty)
        let backup = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains(".corrupt-") })
        #expect(try Data(contentsOf: backup) == original)
        #expect(library.ready)
    }
    @Test func realWAVImportsMetadataAndBookmarkThenSurvivesRestart() async throws {
        let directory = try makeLibraryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = try writeWAV(in: directory)
        let library = MusicLibrary(directory: directory)
        let result = await library.importURLs([file, file])
        #expect(result.errors.isEmpty)
        let track = try #require(result.tracks.first)
        #expect(result.tracks.count == 1 && track.title == "actual" && track.format == "WAV")
        #expect(abs(track.duration - 1) < 0.01 && track.bookmark != nil)
        await library.flushPersistence()
        let restored = MusicLibrary(directory: directory); await restored.load()
        #expect(restored.tracks.count == 1 && restored.tracks.first?.unavailable == false)
        restored.removeTrack(track.id); await restored.flushPersistence()
        #expect(FileManager.default.fileExists(atPath: file.path()))
    }
    @Test func recursiveImportSkipsHiddenFilesAndSymlinkLoops() async throws {
        let directory = try makeLibraryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let music = directory.appending(path: "Music", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        _ = try writeWAV(in: music, name: "visible.wav"); _ = try writeWAV(in: music, name: ".hidden.wav")
        try FileManager.default.createSymbolicLink(at: music.appending(path: "loop"), withDestinationURL: music)
        let importer = MetadataImporter(); let result = await importer.importURLs([music])
        #expect(result.tracks.count == 1 && result.tracks.first?.title == "visible")
        let unsupported = music.appending(path: "notes.txt"); try Data("hello".utf8).write(to: unsupported)
        let rejected = await importer.importURLs([unsupported])
        #expect(rejected.tracks.isEmpty && rejected.errors.first == L10n.string("\(unsupported.lastPathComponent)：不支持此文件格式"))
    }
    @Test func startupMutationsReplayAfterDemoSeedingWithoutLosingImports() async throws {
        let directory = try makeLibraryDirectory(seedEmpty: false); defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        let loading = Task { await library.load() }
        library.addTracks([remote("early")]); library.toggleFavorite("early")
        let playlist = library.createPlaylist("启动期间"); library.addToPlaylist(playlist.id, track: remote("early"))
        library.addTracks([remote("removed")]); library.removeTrack("removed")
        let result = await library.importURLs([try writeWAV(in: directory)])
        await loading.value; await library.flushPersistence()
        #expect(result.errors.isEmpty && result.tracks.count == 1)
        #expect(library.tracks.contains { $0.id == "early" } && !library.tracks.contains { $0.id == "removed" })
        #expect(library.tracks.filter { $0.source == .demo }.count == 3)
        #expect(library.tracks.filter { $0.source == .local }.count == 1)
        #expect(library.favorites.contains("early") && library.playlists.first?.trackIDs == ["early"])
        let restored = MusicLibrary(directory: directory); await restored.load()
        #expect(Set(restored.tracks.map(\.id)) == Set(library.tracks.map(\.id)))
        #expect(restored.favorites == library.favorites && restored.playlists == library.playlists)
    }
    @Test func earlyMutationsPreserveExistingDiskLibraryAndSourceSettings() async throws {
        let directory = try makeLibraryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let original = MusicLibrary(directory: directory); original.addTracks([remote("existing")]); await original.flushPersistence()
        let reopening = MusicLibrary(directory: directory)
        reopening.addTracks([remote("new")]); reopening.toggleFavorite("new")
        try reopening.saveSources([SourceConfiguration(kind: .qq, endpoint: "https://service.example", enabled: true)])
        async let first: Void = reopening.load()
        async let second: Void = reopening.load()
        _ = await (first, second)
        await reopening.flushPersistence()
        #expect(Set(reopening.tracks.map(\.id)) == ["existing", "new"])
        #expect(reopening.favorites == ["new"] && reopening.sources.last?.enabled == true)
        let restored = MusicLibrary(directory: directory); await restored.load()
        #expect(Set(restored.tracks.map(\.id)) == ["existing", "new"] && restored.favorites == ["new"])
    }
    @Test func corruptAudioProducesAnErrorWithoutAddingARecord() async throws {
        let directory = try makeLibraryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "corrupt.mp3"); try Data("not an audio file".utf8).write(to: file)
        let library = MusicLibrary(directory: directory); let result = await library.importURLs([file])
        #expect(result.tracks.isEmpty && !result.errors.isEmpty && library.tracks.isEmpty && !library.busy)
        await library.flushPersistence()
    }
}
