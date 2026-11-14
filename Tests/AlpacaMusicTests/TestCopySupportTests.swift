import Foundation
import Testing
@testable import AlpacaMusic

/// Counts every call; stands in for the installed app's saved sign-ins.
private actor SpyCredentialStore: MusicCredentialStoring {
    var loads = 0, saves = 0, deletes = 0
    let cookies: [MusicSessionCookie]
    init(_ cookies: [MusicSessionCookie]) { self.cookies = cookies }
    func load(for source: MusicSource) async throws -> [MusicSessionCookie] { loads += 1; return source == .netease ? cookies : [] }
    func save(_ cookies: [MusicSessionCookie], for source: MusicSource) async throws { saves += 1 }
    func delete(for source: MusicSource) async throws { deletes += 1 }
}

@Suite struct TestCopySupportTests {
    @Test func aTestCopyReadsTheInstalledSignInsOnceAndNeverWritesThem() async throws {
        let saved = [MusicSessionCookie(name: "MUSIC_U", value: "installed-session", domain: ".music.163.com")]
        let spy = SpyCredentialStore(saved)
        let store = SeededMemoryMusicCredentialStore(seed: spy)
        #expect(try await store.load(for: .netease).map(\.value) == ["installed-session"])
        #expect(try await store.load(for: .netease).map(\.value) == ["installed-session"])
        #expect(try await store.load(for: .qq).isEmpty)
        #expect(await spy.loads == 2)
        // A refreshed or signed-out session stays in the test copy.
        try await store.save([MusicSessionCookie(name: "MUSIC_U", value: "refreshed", domain: ".music.163.com")], for: .netease)
        #expect(try await store.load(for: .netease).map(\.value) == ["refreshed"])
        try await store.delete(for: .netease)
        #expect(try await store.load(for: .netease).isEmpty)
        #expect(await spy.saves == 0)
        #expect(await spy.deletes == 0)
        #expect(await spy.loads == 2)
    }

    @Test @MainActor func aWholeAlbumGoesIntoAPlaylistInOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AlpacaAddAll-\(UUID().uuidString)")
        let domain = "AlpacaAddAll-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let model = AppModel(directory: directory, preferences: defaults, ephemeralAccounts: true)
        defer { model.player.shutdown(); defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: directory) }
        let tracks = (0..<3).map { Track(id: "netease:\($0)", title: "Song \($0)", artist: "周杰伦", album: "太阳之子", duration: 200, source: .netease) }
        model.choosePlaylist(for: tracks)
        #expect(model.sheet == .addToPlaylist)
        #expect(model.playlistSheetTracks.map(\.id) == tracks.map(\.id))
        let playlist = model.library.createPlaylist("Mine")
        model.add(model.playlistSheetTracks, toPlaylist: playlist.id)
        #expect(model.library.playlists.first { $0.id == playlist.id }?.trackIDs == tracks.map(\.id))
        // Choosing one song later sends that song alone.
        model.selectedTrack = tracks[2]
        #expect(model.playlistSheetTracks.map(\.id) == ["netease:2"])
    }
}
