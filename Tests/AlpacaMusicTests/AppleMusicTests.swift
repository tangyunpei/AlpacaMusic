import Foundation
import struct MusicKit.MusicAuthorization
import Testing
@testable import AlpacaMusic

@MainActor private final class StubAppleMusic: AppleMusicAdapter {
    var authorization: MusicAuthorization.Status = .authorized
    var authorizationRequests = 0
    var subscriptionRequests = 0
    var searchRequests = 0
    var prepares = 0
    var plays = 0
    var stops = 0
    var pauses = 0
    var session: UUID?
    var subscriptionValue = AppleMusicCapabilities(canPlayCatalog: true, hasCloudLibrary: true)
    var snapshotValue = AppleMusicPlaybackSnapshot(state: .stopped, position: 0, hasCurrentEntry: false)
    var authorizationGate: CheckedContinuation<Void, Never>?
    var preparationGate: CheckedContinuation<Void, Never>?
    var searchGate: CheckedContinuation<Void, Never>?
    var playGate: CheckedContinuation<Void, Never>?
    var delaysAuthorization = false
    var delaysPreparation = false
    var delaysSearch = false
    var delaysPlay = false
    var libraryGate: CheckedContinuation<Void, Never>?
    var delaysLibrary = false
    var libraryRequests = 0
    var playError: (any Error)?
    func requestAuthorization() async -> MusicAuthorization.Status {
        authorizationRequests += 1
        if delaysAuthorization { await withCheckedContinuation { authorizationGate = $0 } }
        return authorization
    }
    func subscription() async throws -> AppleMusicCapabilities { subscriptionRequests += 1; return subscriptionValue }
    func search(_ query: String) async throws -> [Track] {
        searchRequests += 1
        if delaysSearch { await withCheckedContinuation { searchGate = $0 } }
        return [appleTrack("search")]
    }
    func librarySongs(validate: @MainActor () throws -> Void) async throws -> [Track] {
        libraryRequests += 1
        if delaysLibrary { await withCheckedContinuation { libraryGate = $0 } }
        try validate()
        return [appleTrack("i.librarySong")]
    }
    func libraryPlaylists(validate: @MainActor () throws -> Void) async throws -> [AppleMusicLibraryPlaylist] {
        try validate(); return [.init(id: "p.library", name: "Library")]
    }
    func libraryTracks(in playlist: AppleMusicLibraryPlaylist, validate: @MainActor () throws -> Void) async throws -> [Track] {
        try await librarySongs(validate: validate)
    }
    func setSession(_ id: UUID?) {
        session = id
        if id == nil { stops += 1; snapshotValue = .init(state: .stopped, position: 0, hasCurrentEntry: false) }
    }
    func prepare(_ track: Track, session: UUID) async throws -> Double {
        prepares += 1
        if delaysPreparation { await withCheckedContinuation { preparationGate = $0 } }
        // Deliberately ignores task cancellation; the service/player must reject it.
        return track.duration
    }
    func play(session: UUID) async throws {
        if let playError { throw playError }
        plays += 1
        if delaysPlay { await withCheckedContinuation { playGate = $0 } }
        snapshotValue = .init(state: .playing, position: 0.2, hasCurrentEntry: true)
    }
    func pause() { pauses += 1; snapshotValue.state = .paused }
    func seek(to seconds: Double) { snapshotValue.position = seconds }
    func snapshot() -> AppleMusicPlaybackSnapshot { snapshotValue }
}
private func appleTrack(_ id: String) -> Track {
    Track(id: "appleMusic:\(id)", title: "Song \(id)", artist: "Artist", album: "Album", duration: 10, source: .appleMusic, sourceID: id)
}
private let configuredMusic = AppleMusicConfiguration(enabledInBuild: true, expectedTeam: "TESTTEAM", signedTeam: "TESTTEAM", isAdHoc: false, hasUsageDescription: true)

@Suite(.serialized) @MainActor struct AppleMusicTests {
    private func environment() -> (UserDefaults, String) {
        let suite = "AlpacaAppleMusicTests.\(UUID().uuidString)"; return (UserDefaults(suiteName: suite)!, suite)
    }
    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        #expect(condition())
    }
    @Test func signingConfigurationRequiresMatchingRealTeamAndPurpose() {
        #expect(configuredMusic.isConfigured)
        var value = configuredMusic; value.signedTeam = "OTHER"; #expect(!value.isConfigured)
        value = configuredMusic; value.isAdHoc = true; #expect(!value.isConfigured)
        value = configuredMusic; value.hasUsageDescription = false; #expect(!value.isConfigured)
        value = configuredMusic; value.enabledInBuild = false; #expect(!value.isConfigured)
        value = configuredMusic; value.signedTeam = nil; #expect(!value.isConfigured)
    }
    @Test func unconfiguredBuildNeverPromptsOrContactsMusicKit() async {
        let (defaults, suite) = environment(); defer { defaults.removePersistentDomain(forName: suite) }
        let adapter = StubAppleMusic(); var config = configuredMusic; config.isAdHoc = true
        let service = AppleMusicService(defaults: defaults, configuration: config, adapter: adapter)
        await service.connect(); await service.refresh()
        do { _ = try await service.search("test"); Issue.record("Unconfigured search succeeded") } catch { }
        #expect(!service.isEnabled); #expect(service.error != nil)
        #expect(adapter.authorizationRequests == 0); #expect(adapter.subscriptionRequests == 0); #expect(adapter.searchRequests == 0)
    }
    @Test func deniedAccessRemainsRetryableAndDisabledRefreshIsSilent() async {
        let (defaults, suite) = environment(); defer { defaults.removePersistentDomain(forName: suite) }
        let adapter = StubAppleMusic(); adapter.authorization = .denied
        let service = AppleMusicService(defaults: defaults, configuration: configuredMusic, adapter: adapter)
        await service.refresh(); #expect(adapter.subscriptionRequests == 0)
        await service.connect(); #expect(!service.isEnabled); #expect(service.authorizationDescription == L10n.string("授权被拒绝"))
        #expect(adapter.subscriptionRequests == 0)
        adapter.authorization = .authorized; await service.connect()
        #expect(service.isEnabled); #expect(service.error == nil); #expect(adapter.authorizationRequests == 2)
    }
    @Test func disconnectRejectsLateAuthorizationAndSearchResults() async throws {
        let (defaults, suite) = environment(); defer { defaults.removePersistentDomain(forName: suite) }
        let adapter = StubAppleMusic(); adapter.delaysAuthorization = true
        let service = AppleMusicService(defaults: defaults, configuration: configuredMusic, adapter: adapter)
        let connection = Task { await service.connect() }
        try await waitFor { adapter.authorizationGate != nil }; service.disconnect(); adapter.authorizationGate?.resume(); await connection.value
        #expect(!service.isEnabled); #expect(!service.isBusy); #expect(adapter.subscriptionRequests == 0)
        adapter.delaysAuthorization = false; await service.connect(); adapter.delaysSearch = true
        let search = Task { try await service.search("test") }
        try await waitFor { adapter.searchGate != nil }; service.disconnect(); adapter.searchGate?.resume()
        do { _ = try await search.value; Issue.record("Late search survived disconnect") } catch { }
        #expect(!service.isEnabled)
    }
    @Test func restoredPreferenceCannotBypassBuildConfiguration() async {
        let (defaults, suite) = environment(); defer { defaults.removePersistentDomain(forName: suite) }
        let adapter = StubAppleMusic(), service = AppleMusicService(defaults: defaults, configuration: configuredMusic, adapter: StubAppleMusic())
        await service.connect(); #expect(service.isEnabled)
        var config = configuredMusic; config.enabledInBuild = false
        let unsigned = AppleMusicService(defaults: defaults, configuration: config, adapter: adapter)
        #expect(!unsigned.isEnabled); await unsigned.refresh(); #expect(adapter.subscriptionRequests == 0)
    }
    @Test func libraryReadsRequireAccessAndRejectReconnectOrCancelledResults() async throws {
        let (defaults, suite) = environment(); defer { defaults.removePersistentDomain(forName: suite) }
        let adapter = StubAppleMusic(), service = AppleMusicService(defaults: defaults, configuration: configuredMusic, adapter: adapter)
        await #expect(throws: MusicError.self) { try await service.librarySongs() }
        #expect(adapter.libraryRequests == 0)
        await service.connect(); let token = service.librarySessionID
        let playlists = try await service.libraryPlaylists(); #expect(playlists.first?.id == "p.library")
        adapter.delaysLibrary = true
        let pending = Task { try await service.libraryTracks(in: playlists[0]) }
        try await waitFor { adapter.libraryGate != nil }
        service.disconnect(); await service.connect(); adapter.libraryGate?.resume()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(service.librarySessionID != token)
        #expect(throws: CancellationError.self) { try service.validateLibrarySession(token) }
        adapter.libraryGate = nil
        let cancelled = Task { try await service.librarySongs() }
        try await waitFor { adapter.libraryGate != nil }; cancelled.cancel(); adapter.libraryGate?.resume()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }
    @Test func musicKitUsesRealStateAndNeverFabricatesSpectrumOrVolume() async throws {
        let (defaults, suite) = environment(); defer { defaults.removePersistentDomain(forName: suite) }
        let adapter = StubAppleMusic(), service = AppleMusicService(defaults: defaults, configuration: configuredMusic, adapter: adapter)
        await service.connect()
        let player = PlayerController(sources: SourceService(), defaults: defaults, appleMusic: service); defer { player.shutdown() }
        await player.play(appleTrack("1")); #expect(player.status == .playing); #expect(!player.supportsVolumeControl)
        #expect(!player.readLevels().available); #expect(player.readLevels().spectrum.isEmpty)
        let volume = player.volume; player.setVolume(0.1); player.toggleMute(); #expect(player.volume == volume); #expect(!player.muted)
        player.seek(to: 4); #expect(adapter.snapshotValue.position == 4)
        player.pause(); #expect(player.status == .paused); #expect(adapter.pauses > 0)
        await player.toggle(); #expect(player.status == .playing)
        service.disconnect(); try await waitFor { player.status == .failed }; #expect(adapter.session == nil)
    }
    @Test func clearAndEngineSwitchRejectLateMusicPreparation() async throws {
        let (defaults, suite) = environment(); defer { defaults.removePersistentDomain(forName: suite) }
        let adapter = StubAppleMusic(), service = AppleMusicService(defaults: defaults, configuration: configuredMusic, adapter: adapter)
        await service.connect(); adapter.delaysPreparation = true
        let player = PlayerController(sources: SourceService(), defaults: defaults, appleMusic: service); defer { player.shutdown() }
        let pending = Task { await player.play(appleTrack("late")) }
        try await waitFor { adapter.preparationGate != nil }; player.clearQueue(); adapter.preparationGate?.resume(); await pending.value
        #expect(player.status == .idle); #expect(player.current == nil); #expect(adapter.plays == 0)
        adapter.preparationGate = nil
        let pending2 = Task { await player.play(appleTrack("late2")) }
        try await waitFor { adapter.preparationGate != nil }
        let native = Track(id: "native", title: "Native", artist: "", album: "", duration: 0, source: .netease, sourceID: "1")
        await player.play(native); adapter.preparationGate?.resume(); await pending2.value
        #expect(player.current?.id == "native"); #expect(player.supportsVolumeControl); #expect(adapter.plays == 0); #expect(adapter.session == nil)
    }
    @Test func pauseDuringPreparationDoesNotStartMusic() async throws {
        let (defaults, suite) = environment(); defer { defaults.removePersistentDomain(forName: suite) }
        let adapter = StubAppleMusic(), service = AppleMusicService(defaults: defaults, configuration: configuredMusic, adapter: adapter)
        await service.connect(); adapter.delaysPreparation = true
        let player = PlayerController(sources: SourceService(), defaults: defaults, appleMusic: service); defer { player.shutdown() }
        let pending = Task { await player.play(appleTrack("1")) }
        try await waitFor { adapter.preparationGate != nil }; player.pause(); adapter.preparationGate?.resume(); await pending.value
        #expect(player.status == .paused); #expect(adapter.plays == 0)
    }
    @Test func delayedResumeDoesNotMistakePreviousPauseForNewInterruption() async throws {
        let (defaults, suite) = environment(); defer { defaults.removePersistentDomain(forName: suite) }
        let adapter = StubAppleMusic(), service = AppleMusicService(defaults: defaults, configuration: configuredMusic, adapter: adapter)
        await service.connect()
        let player = PlayerController(sources: SourceService(), defaults: defaults, appleMusic: service); defer { player.shutdown() }
        await player.play(appleTrack("resume")); player.pause(); adapter.delaysPlay = true
        let pending = Task { await player.toggle() }
        try await waitFor { adapter.playGate != nil }
        try await Task.sleep(for: .milliseconds(150)); #expect(player.status == .loading)
        adapter.playGate?.resume(); await pending.value; #expect(player.status == .playing)
    }
    @Test func latePlayCompletionAfterDisconnectCannotRevivePlayback() async throws {
        let (defaults, suite) = environment(); defer { defaults.removePersistentDomain(forName: suite) }
        let adapter = StubAppleMusic(), service = AppleMusicService(defaults: defaults, configuration: configuredMusic, adapter: adapter)
        await service.connect(); adapter.delaysPlay = true
        let player = PlayerController(sources: SourceService(), defaults: defaults, appleMusic: service); defer { player.shutdown() }
        let pending = Task { await player.play(appleTrack("late-play")) }
        try await waitFor { adapter.playGate != nil }
        player.clearQueue(); service.disconnect(); adapter.playGate?.resume(); await pending.value
        #expect(player.status == .idle); #expect(player.current == nil)
        #expect(adapter.snapshotValue.state == .stopped); #expect(adapter.session == nil)
    }
    @Test func subscriptionAndPlaybackFailuresNeverClaimPlaying() async {
        let (defaults, suite) = environment(); defer { defaults.removePersistentDomain(forName: suite) }
        let adapter = StubAppleMusic(), service = AppleMusicService(defaults: defaults, configuration: configuredMusic, adapter: adapter)
        await service.connect(); adapter.subscriptionValue.canPlayCatalog = false
        let player = PlayerController(sources: SourceService(), defaults: defaults, appleMusic: service); defer { player.shutdown() }
        await player.play(appleTrack("1")); #expect(player.status == .failed); #expect(adapter.plays == 0)
        adapter.subscriptionValue.canPlayCatalog = true; adapter.playError = MusicError.message("Account playback failure")
        await player.retry(); #expect(player.status == .failed); #expect(player.error == "Account playback failure")
    }
    @Test func genuineCompletionAdvancesAndRepeatOneReplaysButPauseDoesNot() async throws {
        let (defaults, suite) = environment(); defer { defaults.removePersistentDomain(forName: suite) }
        let adapter = StubAppleMusic(), service = AppleMusicService(defaults: defaults, configuration: configuredMusic, adapter: adapter)
        await service.connect()
        let player = PlayerController(sources: SourceService(), defaults: defaults, appleMusic: service); defer { player.shutdown() }
        await player.play(appleTrack("1"), context: [appleTrack("1"), appleTrack("2")])
        adapter.snapshotValue = .init(state: .paused, position: 9.7, hasCurrentEntry: true)
        try await Task.sleep(for: .milliseconds(150)); #expect(player.current?.sourceID == "1"); #expect(player.status == .paused)
        await player.toggle(); adapter.snapshotValue = .init(state: .stopped, position: 10, hasCurrentEntry: false)
        try await waitFor { player.current?.sourceID == "2" && player.status == .playing }
        player.cycleRepeat(); player.cycleRepeat(); #expect(player.repeatMode == .one)
        let oldPlays = adapter.plays; adapter.snapshotValue = .init(state: .stopped, position: 10, hasCurrentEntry: false)
        try await waitFor { adapter.plays > oldPlays }; #expect(player.current?.sourceID == "2")
    }
}
