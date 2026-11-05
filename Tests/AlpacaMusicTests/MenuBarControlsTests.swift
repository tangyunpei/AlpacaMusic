import Foundation
import Testing
@testable import AlpacaMusic

/// The menu bar transport's pure state. No status items are created here.
@Suite @MainActor
struct MenuBarControlsTests {
    @Test func playButtonShowsPauseOnlyWhilePlaying() {
        let playing = transport(isPlaying: true)
        let paused = transport()
        let loading = transport(isLoading: true)
        #expect(playing.playSymbol == "pause.fill")
        #expect(playing.playLabel == L10n.string("暂停"))
        #expect(paused.playSymbol == "play.fill")
        #expect(paused.playLabel == L10n.string("播放"))
        #expect(loading.playSymbol == "play.fill")
        #expect(loading.playLabel == L10n.string("播放"))
        #expect(playing.playLabel != paused.playLabel)
    }

    @Test func statesAreEqualOnlyWhenEveryFieldMatches() {
        let base = transport()
        let variants: [MenuBarTransportState] = [
            transport(visible: false), transport(hasTrack: false), transport(canPlay: false),
            transport(isPlaying: true), transport(isLoading: true)
        ]
        #expect(base == transport())
        for variant in variants {
            #expect(variant != base)
        }
    }

    @Test func freshModelShowsTheControlsButNothingCanPlayBeforeLoading() throws {
        let domain = "AlpacaMenuBarControlsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = AppModel(directory: directory, preferences: defaults, ephemeralAccounts: true)
        defer { model.player.shutdown() }
        // The library stays empty until load(), so play has nothing to start.
        let fresh = MenuBarTransportState(model: model)
        #expect(fresh == transport(hasTrack: false, canPlay: false))
        model.showsMenuBarControls = false
        let hidden = MenuBarTransportState(model: model)
        #expect(!hidden.visible)
        #expect(hidden == transport(visible: false, hasTrack: false, canPlay: false))
        model.showsMenuBarControls = true
        #expect(MenuBarTransportState(model: model).visible)
    }

    @Test func playCanStartTheLibraryWhilePreviousAndNextWaitForATrack() async throws {
        let domain = "AlpacaMenuBarControlsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        let empty = Data(#"{"version":1,"tracks":[],"favorites":[],"playlists":[],"sources":[]}"#.utf8)
        try empty.write(to: directory.appending(path: "library-v1.json"))
        let model = AppModel(directory: directory, preferences: defaults, ephemeralAccounts: true)
        defer { model.player.shutdown() }
        // Load only the fixture library: no queue restore, accounts or network.
        await model.library.load()
        let song = Track(id: "netease:menu-bar-1", title: "Fixture song", artist: "Fixture artist",
                         album: "Fixture album", duration: 90, source: .netease, sourceID: "menu-bar-1")
        model.library.addTracks([song])
        let state = MenuBarTransportState(model: model)
        await model.library.flushPersistence()
        await model.lyrics.shutdown()
        #expect(state == transport(hasTrack: false, canPlay: true))
    }

    private func transport(visible: Bool = true, hasTrack: Bool = true, canPlay: Bool = true,
                           isPlaying: Bool = false, isLoading: Bool = false) -> MenuBarTransportState {
        MenuBarTransportState(visible: visible, hasTrack: hasTrack, canPlay: canPlay,
                              isPlaying: isPlaying, isLoading: isLoading)
    }
}
