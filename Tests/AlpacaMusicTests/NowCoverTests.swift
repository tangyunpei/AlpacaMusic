import Foundation
import Testing
@testable import AlpacaMusic

/// When the Now stage shows the song's cover in place of the chosen visual.
@Suite @MainActor struct NowCoverTests {
    private struct SavedQueue: Codable { var tracks: [Track]; var currentID: String?; var position: Double }

    /// A model that opens on `track` restored and paused, or on nothing playing.
    private func model(restoring track: Track?, library: [Track] = []) async throws -> (model: AppModel, cleanUp: () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "now-cover-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "AlpacaNowCoverTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        if let track {
            defaults.set(try JSONEncoder().encode(SavedQueue(tracks: [track], currentID: track.id, position: 12)),
                         forKey: "AlpacaMusic.NativePlayer.queue.v1")
        }
        let model = AppModel(directory: directory, preferences: defaults, ephemeralAccounts: true)
        await model.library.load()
        model.library.addTracks(library)
        model.player.restoreQueue(model.library.tracks)
        return (model, {
            model.player.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    private func song(_ source: MusicSource) -> Track {
        Track(id: "song-\(source.rawValue)", title: "Low Tide Radio", artist: "Mono Coast", album: "", duration: 281, source: source, sourceID: "1")
    }

    @Test(arguments: [MusicSource.appleMusic, .spotify])
    func theCoverStandsInWhileASongWithoutLiveAudioPlaysUnderAVisualThatNeedsIt(_ source: MusicSource) async throws {
        let (model, cleanUp) = try await model(restoring: song(source)); defer { cleanUp() }
        #expect(model.player.current?.source == source)
        for mode in VisualizationMode.allCases {
            model.visualMode = mode
            #expect(NowCover.standsIn(model) == mode.isSignalDisplay)
            #expect(NowCover.shows(model) == (mode.isSignalDisplay || mode == .artwork))
            // Standing in is decided when the stage is drawn; the listener's choice stays as it is.
            #expect(model.visualMode == mode)
        }
    }

    @Test func aSongWithLiveAudioKeepsItsVisual() async throws {
        let (model, cleanUp) = try await model(restoring: song(.netease)); defer { cleanUp() }
        #expect(model.player.current?.source == .netease)
        for mode in VisualizationMode.allCases {
            model.visualMode = mode
            #expect(!NowCover.standsIn(model))
            #expect(NowCover.shows(model) == (mode == .artwork))
        }
    }

    /// The visual draws for the library's first song while nothing plays; a
    /// song that is not playing does not bring the cover in.
    @Test func nothingPlayingKeepsTheVisualWhateverTheLibraryHolds() async throws {
        let (model, cleanUp) = try await model(restoring: nil, library: [song(.appleMusic)]); defer { cleanUp() }
        #expect(model.player.current == nil)
        model.visualMode = .spectrumBars
        #expect(!NowCover.standsIn(model) && !NowCover.shows(model))
        model.visualMode = .artwork
        #expect(!NowCover.standsIn(model) && NowCover.shows(model))
    }
}
