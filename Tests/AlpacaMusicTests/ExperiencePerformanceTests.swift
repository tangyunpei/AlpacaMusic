import Foundation
import Testing
@testable import AlpacaMusic

@Suite @MainActor
struct ExperiencePerformanceTests {
    @Test func indexedPlaylistRetainsOrderAndUpdatesAfterEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(directory: directory)
        let a = Track(id: "indexed-a", title: "One", artist: "Test", album: "", duration: 5, source: .url)
        var b = Track(id: "indexed-b", title: "Two", artist: "Test", album: "", duration: 5, source: .url)
        library.addTracks([a, b])
        #expect(library.tracks(withIDs: [b.id, "missing", a.id, b.id]).map(\.id) == [b.id, a.id, b.id])
        b.title = "Updated"
        library.addTracks([b])
        #expect(library.tracks(withIDs: [b.id]).first?.title == "Updated")
        library.removeTrack(a.id)
        #expect(library.tracks(withIDs: [a.id, b.id]).map(\.id) == [b.id])
    }

    @Test func visibleListsReflectLibraryFilterSearchAndPlaylistChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let domain = "AlpacaExperienceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(directory: directory, preferences: defaults, ephemeralAccounts: true)
        defer { model.player.shutdown() }
        let a = Track(id: "a", title: "Morning", artist: "Test", album: "", duration: 5, source: .url)
        let b = Track(id: "b", title: "Evening", artist: "Test", album: "", duration: 5, source: .netease)
        model.library.addTracks([a,b]); model.navigate(.library)
        #expect(model.visibleTracks.map(\.id) == ["a","b"])
        model.sourceFilter = .netease
        #expect(model.visibleTracks.map(\.id) == ["b"])
        model.navigate(.favorites)
        #expect(model.visibleTracks.isEmpty)
        model.library.toggleFavorite(a.id)
        #expect(model.visibleTracks.map(\.id) == ["a"])
        let playlist = model.library.createPlaylist("Test")
        model.library.addToPlaylist(playlist.id, track: b); model.navigate(.playlist(playlist.id))
        #expect(model.visibleTracks.map(\.id) == ["b"])
        model.library.addToPlaylist(playlist.id, track: a)
        #expect(model.visibleTracks.map(\.id) == ["b","a"])
        model.navigate(.library); model.searchTerm = "Morning"
        #expect(model.visibleTracks.map(\.id) == ["a"])
        model.remoteResults = [Track(id: "remote", title: "Morning", artist: "Test", album: "", duration: 5, source: .qq)]
        #expect(model.visibleTracks.map(\.id) == ["a","remote"])
        model.library.removeTrack(a.id)
        #expect(model.visibleTracks.map(\.id) == ["remote"])
    }

    @Test func thumbnailsUseBoundedRasterDimensions() {
        let pixels = Artwork.placeholder(for: nil, size: 128)
        #expect(pixels.width == 128 && pixels.height == 128)
        #expect(pixels.rgba.count == 128 * 128 * 4)
        #expect(Artwork.placeholder(for: nil).width == 512)
    }

    @Test func cancelledQueuedArtworkDoesNotStealNextPermit() async {
        let limiter = ArtworkWorkLimiter(limit: 1)
        #expect(await limiter.acquire())
        let queued = Task { await limiter.acquire() }
        queued.cancel()
        #expect(await queued.value == false)
        await limiter.release()
        #expect(await limiter.acquire())
        await limiter.release()
    }
}
