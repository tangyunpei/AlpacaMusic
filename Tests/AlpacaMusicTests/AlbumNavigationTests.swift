import Foundation
import Testing
@testable import AlpacaMusic

@Suite(.serialized) @MainActor struct AlbumNavigationTests {
    private func track(_ id: String, album: String = "First album", source: MusicSource = .netease, unavailable: Bool = false) -> Track {
        Track(id: "\(source.rawValue):\(id)", title: "Song \(id)", artist: "Fixture artist", album: album,
              duration: 90, source: source, sourceID: id, unavailable: unavailable)
    }

    private func withModel(initialJSON: Data? = nil, _ body: @MainActor (AppModel, UserDefaults) async throws -> Void) async throws {
        let directory = URL.temporaryDirectory.appending(path: "AlbumNavigationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let domain = "AlpacaMusic.AlbumNavigationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        let empty = Data(#"{"version":1,"tracks":[],"favorites":[],"playlists":[],"sources":[]}"#.utf8)
        try (initialJSON ?? empty).write(to: directory.appending(path: "library-v1.json"))
        let model = AppModel(directory: directory, preferences: defaults, ephemeralAccounts: true)
        defer { model.player.shutdown() }
        // Load only the fixture library. No account restoration or MusicKit calls.
        await model.library.load()
        do { try await body(model, defaults) }
        catch {
            await model.library.flushPersistence()
            await model.lyrics.shutdown()
            throw error
        }
        await model.library.flushPersistence()
        await model.lyrics.shutdown()
    }

    @Test func albumNavigationKeepsSourceGroupsAndFiltersSeparate() async throws {
        try await withModel { model, _ in
            let first = track("1"), second = track("2"), otherSource = track("3", source: .qq)
            model.library.addTracks([first, second, otherSource, track("4", album: "Other album")])
            model.navigate(.albums)
            #expect(model.pageTitle == L10n.string("专辑库"))
            #expect(model.selectedAlbum == nil)
            #expect(model.visibleAlbums.count == 3)
            model.sourceFilter = .netease
            #expect(model.visibleAlbums.count == 2)
            #expect(model.visibleAlbums.allSatisfy { $0.source == .netease })
            let album = try #require(model.visibleAlbums.first { $0.name == "First album" })
            model.navigate(.album(album.id))
            #expect(model.sourceFilter == nil)
            #expect(model.selectedAlbum?.id == album.id)
            #expect(model.pageTitle == "First album")
            #expect(model.albumTracks.map(\.id) == [first.id, second.id])
            #expect(model.visibleTracks.map(\.id) == [first.id, second.id])
            model.sourceFilter = .qq
            #expect(model.visibleTracks.isEmpty)
            #expect(model.albumTracks.map(\.id) == [first.id, second.id])
            model.navigate(.albums)
            #expect(model.selectedAlbum == nil)
            #expect(model.albumTracks.isEmpty)
            #expect(model.sourceFilter == nil)
        }
    }

    @Test func oldLibraryWithoutExplicitAlbumRecordsOpensAnInferredAlbum() async throws {
        let json = Data(#"{"version":1,"tracks":[{"id":"netease:9","title":"Older song","artist":"Older artist","album":"Older album","duration":90,"source":"netease","sourceID":"9","addedAt":0,"unavailable":false}],"favorites":[],"playlists":[],"sources":[]}"#.utf8)
        try await withModel(initialJSON: json) { model, _ in
            #expect(model.library.error == nil)
            let album = try #require(model.library.albums.first)
            #expect(album.name == "Older album")
            model.navigate(.album(album.id))
            #expect(model.pageTitle == "Older album")
            #expect(model.albumTracks.map(\.id) == ["netease:9"])
            #expect(model.visibleTracks.first?.title == "Older song")
        }
    }

    @Test func removingAlbumTracksRefreshesDetailAndMissingAlbumIsSafe() async throws {
        try await withModel { model, _ in
            let first = track("1"), second = track("2")
            model.library.addTracks([first, second])
            let album = try #require(model.library.albums.first)
            model.navigate(.album(album.id))
            #expect(model.visibleTracks.count == 2)
            model.library.removeTrack(first.id)
            #expect(model.selectedAlbum?.id == album.id)
            #expect(model.albumTracks.map(\.id) == [second.id])
            #expect(model.visibleTracks.map(\.id) == [second.id])
            model.library.removeTrack(second.id)
            #expect(model.selectedAlbum == nil)
            #expect(model.albumTracks.isEmpty)
            #expect(model.visibleTracks.isEmpty)
            #expect(model.pageTitle == L10n.string("专辑"))
            await model.playAlbum()
            #expect(model.player.current == nil)
            #expect(model.player.queue.isEmpty)
        }
    }

    @Test func playAlbumStartsFirstAvailableAndPersistsOrderedQueueAndModes() async throws {
        try await withModel { model, defaults in
            let missing = track("1", unavailable: true), first = track("2"), last = track("3")
            let previous = track("4", album: "Other album")
            model.library.addTracks([missing, first, last, previous])
            await model.player.play(previous, context: [previous])
            model.player.toggleShuffle()
            model.player.cycleRepeat()
            model.player.cycleRepeat()
            #expect(model.player.shuffle && model.player.repeatMode == .one)
            let album = try #require(model.library.albums.first { $0.name == "First album" })
            model.navigate(.album(album.id))
            // A display filter must not turn Play Album into Play Visible Songs.
            model.sourceFilter = .qq
            await model.playAlbum()
            #expect(model.player.current?.id == first.id)
            #expect(model.player.queue.map(\.id) == [missing.id, first.id, last.id])
            #expect(!model.player.shuffle)
            #expect(model.player.repeatMode == .off)
            // NetEase is intentionally disconnected: resolution fails locally,
            // after queue selection, without issuing a network request.
            #expect(model.player.status == .failed)
            await model.player.next()
            #expect(model.player.current?.id == last.id)
            await model.player.next()
            #expect(model.player.current?.id == last.id)

            let restored = PlayerController(sources: model.sourceService, defaults: defaults)
            defer { restored.shutdown() }
            restored.restoreQueue(model.library.tracks)
            #expect(restored.queue.map(\.id) == [missing.id, first.id, last.id])
            #expect(restored.current?.id == last.id)
            #expect(restored.status == .paused)
            #expect(!restored.shuffle && restored.repeatMode == .off)
        }
    }

    @Test func playAlbumPreservesAlbumRepeatAndWrapsInOrder() async throws {
        try await withModel { model, _ in
            let first = track("1"), missing = track("2", unavailable: true), last = track("3")
            model.library.addTracks([first, missing, last])
            model.player.cycleRepeat()
            let album = try #require(model.library.albums.first)
            model.navigate(.album(album.id))
            await model.playAlbum()
            #expect(model.player.repeatMode == .all)
            #expect(model.player.current?.id == first.id)
            await model.player.next()
            #expect(model.player.current?.id == last.id)
            await model.player.next()
            #expect(model.player.current?.id == first.id)
        }
    }

    @Test func unavailableAlbumDoesNotReplaceQueueOrChangeUserModes() async throws {
        try await withModel { model, _ in
            let current = track("1", album: "Other album"), missing = track("2", unavailable: true)
            model.library.addTracks([current, missing])
            await model.player.play(current, context: [current])
            model.player.toggleShuffle()
            model.player.cycleRepeat()
            model.player.cycleRepeat()
            let album = try #require(model.library.albums.first { $0.name == "First album" })
            model.navigate(.album(album.id))
            await model.playAlbum()
            #expect(model.player.current?.id == current.id)
            #expect(model.player.queue.map(\.id) == [current.id])
            #expect(model.player.shuffle && model.player.repeatMode == .one)
            model.navigate(.album("missing-album-id"))
            await model.playAlbum()
            #expect(model.player.current?.id == current.id)
            #expect(model.player.shuffle && model.player.repeatMode == .one)
        }
    }
}
