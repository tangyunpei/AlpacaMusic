import Foundation
import Security
import Testing
@testable import AlpacaMusic

private let sodaSessionFixture = MusicSessionCookie(name: "sessionid", value: "soda-fixture", domain: ".qishui.com")
private let qqSessionFixture = MusicSessionCookie(name: "qqmusic_key", value: "qq-fixture", domain: ".qq.com")

private func sodaIntegrationTrack() -> Track {
    Track(id: "soda:7380000000000000001", title: "Fixture song", artist: "Fixture artist", album: "Fixture album",
          duration: 30, source: .soda, sourceID: "7380000000000000001",
          sodaPlayback: .init(fullDuration: 240, start: 60, duration: 30, isPreview: true))
}

private actor SodaIntegrationFixtureProvider: DirectMusicProvider {
    nonisolated let source: MusicSource
    private var suspendPreparation = false
    private let failsResolution: Bool
    private(set) var preparationStarted = false
    private(set) var searchCalls = 0
    private var preparationContinuation: CheckedContinuation<Void, Never>?
    init(source: MusicSource = .soda, failsResolution: Bool = false) { self.source = source; self.failsResolution = failsResolution }
    func delayPreparation() { suspendPreparation = true }
    func releasePreparation() { preparationContinuation?.resume(); preparationContinuation = nil }
    func profile(cookies: [MusicSessionCookie]) async throws -> MusicAccountProfile {
        let name = source == .soda ? "sessionid" : "qqmusic_key"
        guard cookies.contains(where: { $0.name == name }) else { throw MusicError.message("Fixture session missing") }
        return .init(id: "fixture-\(source.rawValue)", displayName: "Fixture")
    }
    func search(_ query: String, cookies: [MusicSessionCookie]) async throws -> [Track] { searchCalls += 1; return [sodaIntegrationTrack()] }
    func playlists(profile: MusicAccountProfile, cookies: [MusicSessionCookie]) async throws -> [RemoteMusicPlaylist] {
        [.init(id: "7380000000000000002", name: "Fixture playlist", trackCount: 1, source: source)]
    }
    func tracks(in playlist: RemoteMusicPlaylist, cookies: [MusicSessionCookie]) async throws -> [Track] { [sodaIntegrationTrack()] }
    func preparePlayback(_ track: Track, cookies: [MusicSessionCookie]) async throws -> Track {
        preparationStarted = true
        if suspendPreparation { await withCheckedContinuation { preparationContinuation = $0 } }
        var result = track
        result.duration = 10
        result.sodaPlayback = .init(fullDuration: 240, start: 80, duration: 10, isPreview: true)
        return result
    }
    func resolve(_ track: Track, cookies: [MusicSessionCookie]) async throws -> URL {
        if failsResolution { throw MusicError.message("Fixture resolve rejection") }
        return URL(string: "https://fixture.invalid/fresh-audio.m4a")!
    }
}

private actor SodaHTTPFixtureRecorder {
    private(set) var requests: [URLRequest] = []
    func receive(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite(.serialized)
@MainActor struct SodaIntegrationTests {
    @Test func oldTrackDecodesAndNewPreviewRangeRoundTripsWithoutChangingProxyConfigurations() throws {
        let oldJSON = Data(#"{"id":"qq:fixture","title":"Existing song","artist":"Existing artist","album":"Existing album","duration":200,"source":"qq","addedAt":0,"unavailable":false}"#.utf8)
        let old = try JSONDecoder().decode(Track.self, from: oldJSON)
        #expect(old.sodaPlayback == nil)
        #expect(old.source == .qq)
        let track = sodaIntegrationTrack()
        #expect(try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(track)) == track)
        #expect(MusicSource.soda.title == "汽水音乐")
        #expect(MusicSource.soda.symbol == "drop")
        #expect(DirectMusicAccess.sources.contains(.soda))
        #expect(SourceConfiguration.defaults.map(\.kind) == [.netease, .qq])
        #expect(throws: SourceFailure.self) { try SourceService.validatedConfigurations([.init(kind: .soda)]) }
    }

    @Test func sodaCookieScopeExcludesOtherDouyinServicesAndInvalidValues() throws {
        let beta = MusicSessionCookie(name: "sid_tt", value: "beta-fixture", domain: "beta-luna.douyin.com")
        let api = MusicSessionCookie(name: "sessionid_ss", value: "api-fixture", domain: "api.qishui.com", path: "/luna")
        let cookies = [sodaSessionFixture, beta, api, qqSessionFixture,
                       .init(name: "sessionid", value: "main-site", domain: ".douyin.com"),
                       .init(name: "sessionid", value: "other-service", domain: "www.douyin.com"),
                       .init(name: "sessionid", value: "other-subdomain", domain: "unrelated.qishui.com"),
                       .init(name: "sessionid", value: "expired", domain: ".qishui.com", expires: .distantPast),
                       .init(name: "password", value: "never-retain", domain: ".qishui.com")]
        #expect(DirectMusicAccess.sessionCookies(cookies, for: .soda) == [sodaSessionFixture, beta, api])
        #expect(DirectMusicAccess.sessionCookies(cookies, for: .qq) == [qqSessionFixture])
        let apiURL = try #require(URL(string: "https://api.qishui.com/luna/track"))
        #expect(DirectMusicAccess.requestCookies(cookies, for: .soda, url: apiURL) == [api, sodaSessionFixture])
        let betaURL = try #require(URL(string: "https://beta-luna.douyin.com/luna/track"))
        #expect(DirectMusicAccess.requestCookies(cookies, for: .soda, url: betaURL) == [beta])
    }

    @Test func thirdCredentialEntryKeepsTheExistingKeychainServiceAndAccountIsolation() async throws {
        #expect(try MusicCredentialAccount(source: .soda) == .soda)
        #expect(MusicCredentialAccount.soda.title == "汽水音乐")
        let query = KeychainMusicCredentialAccess.query(for: .soda)
        #expect(query[kSecAttrService as String] as? String == "dev.byalpaca.music.direct-session.v1")
        #expect(query[kSecAttrAccount as String] as? String == "soda")
        #expect(query[kSecAttrAccessGroup as String] == nil)
        let store = MemoryMusicCredentialStore()
        try await store.save([sodaSessionFixture, qqSessionFixture], for: .soda)
        try await store.save([qqSessionFixture, sodaSessionFixture], for: .qq)
        #expect(try await store.load(for: .soda) == [sodaSessionFixture])
        #expect(try await store.load(for: .qq) == [qqSessionFixture])
        try await store.delete(for: .soda)
        #expect(try await store.load(for: .soda).isEmpty)
        #expect(try await store.load(for: .qq) == [qqSessionFixture])
    }

    @Test func hiddenSodaSkipsSearchButExistingTracksStillPrepareAndResolveWithoutAProxy() async throws {
        let provider = SodaIntegrationFixtureProvider()
        let client = NativeMusicClient(providers: [provider], credentials: MemoryMusicCredentialStore())
        let source = SourceService(transport: { _ in Issue.record("Soda reached a custom proxy"); throw MusicError.message("Unexpected proxy") }, native: client)
        _ = try await client.connect(.soda, cookies: [sodaSessionFixture])
        let configs = [SourceConfiguration(kind: .qq, endpoint: "https://proxy.invalid", enabled: false)]
        let results = await source.search("Fixture", configurations: configs, includeSodaPublicly: true)
        #expect(results.isEmpty)
        #expect(await provider.searchCalls == 0)
        let prepared = try await source.preparePlayback(sodaIntegrationTrack())
        #expect(prepared.duration == 10)
        #expect(prepared.sodaPlayback?.start == 80)
        #expect(try await source.resolve(prepared, configurations: configs).host == "fixture.invalid")
        var ordinary = sodaIntegrationTrack(); ordinary.source = .url; ordinary.sodaPlayback = nil
        #expect(try await source.preparePlayback(ordinary) == ordinary)
    }

    @Test func hiddenPublicSodaSearchMakesNoRequestEvenWithAPreviouslySavedOptIn() async {
        let source = SourceService(transport: { _ in Issue.record("Disabled search contacted a proxy"); throw MusicError.message("Unexpected proxy") })
        let results = await source.search("Fixture", configurations: SourceConfiguration.defaults, includeSodaPublicly: true)
        #expect(results.isEmpty)
    }

    @Test func disconnectCancelsAnInFlightSodaMetadataRefresh() async throws {
        let provider = SodaIntegrationFixtureProvider()
        await provider.delayPreparation()
        let client = NativeMusicClient(providers: [provider], credentials: MemoryMusicCredentialStore())
        _ = try await client.connect(.soda, cookies: [sodaSessionFixture])
        let pending = Task { try await client.preparePlayback(sodaIntegrationTrack()) }
        for _ in 0..<100 {
            if await provider.preparationStarted { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await provider.preparationStarted)
        try await client.disconnect(.soda)
        await provider.releasePreparation()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await client.connectedSources().isEmpty)
    }

    @Test func otherPlatformLogoutCannotInvalidateSodaLyricsOrCredentials() async throws {
        let store = MemoryMusicCredentialStore()
        let client = NativeMusicClient(providers: [SodaIntegrationFixtureProvider(), SodaIntegrationFixtureProvider(source: .qq)], credentials: store)
        _ = try await client.connect(.soda, cookies: [sodaSessionFixture])
        _ = try await client.connect(.qq, cookies: [qqSessionFixture])
        let scope = try await client.lyricsScope(for: .soda)
        try await client.disconnect(.qq)
        try await client.validateLyricsScope(scope)
        #expect(try await store.load(for: .soda) == [sodaSessionFixture])
        #expect(await client.connectedSources() == [.soda])
        try await client.disconnect(.soda)
        await #expect(throws: CancellationError.self) { try await client.validateLyricsScope(scope) }
    }

    @Test func queuedSodaPreviewRetainsRangeWithoutPersistingTheSignedMediaURL() throws {
        struct QueueSnapshot: Decodable { var tracks: [Track] }
        let suite = "AlpacaMusic.SodaQueueTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlayerController(sources: SourceService(), defaults: defaults)
        defer { player.shutdown() }
        var track = sodaIntegrationTrack()
        track.url = URL(string: "https://fixture.invalid/audio.m4a?temporary_key=do-not-persist")
        player.enqueue(track)
        let data = try #require(defaults.data(forKey: "AlpacaMusic.NativePlayer.queue.v1"))
        let stored = try JSONDecoder().decode(QueueSnapshot.self, from: data)
        #expect(stored.tracks.count == 1)
        #expect(stored.tracks.first?.url == nil)
        #expect(stored.tracks.first?.sodaPlayback == track.sodaPlayback)
        #expect(!String(decoding: data, as: UTF8.self).contains("do-not-persist"))
        let restored = PlayerController(sources: SourceService(), defaults: defaults)
        defer { restored.shutdown() }
        restored.restoreQueue([])
        #expect(restored.queue.first?.url == nil)
        #expect(restored.queue.first?.source == .soda)
        #expect(restored.queue.first?.sodaPlayback == track.sodaPlayback)
    }

    @Test func restoredPlaybackRefreshesPreviewMetadataAndClampsSecondsBeforeResolution() async throws {
        struct QueueSnapshot: Codable { var tracks: [Track]; var currentID: String?; var position: Double }
        let suite = "AlpacaMusic.SodaPrepareTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let track = sodaIntegrationTrack()
        defaults.set(try JSONEncoder().encode(QueueSnapshot(tracks: [track], currentID: track.id, position: 25)), forKey: "AlpacaMusic.NativePlayer.queue.v1")
        let provider = SodaIntegrationFixtureProvider(failsResolution: true)
        let client = NativeMusicClient(providers: [provider], credentials: MemoryMusicCredentialStore())
        _ = try await client.connect(.soda, cookies: [sodaSessionFixture])
        let player = PlayerController(sources: SourceService(native: client), defaults: defaults)
        defer { player.shutdown() }
        player.restoreQueue([])
        #expect(player.position == 25)
        await player.toggle()
        // The fixture deliberately stops before any media is opened. This
        // verifies production preparation without networking or audible playback.
        #expect(player.failure?.stage == .resolving)
        #expect(player.position == 10)
        #expect(player.duration == 10)
        #expect(player.current?.sodaPlayback?.start == 80)
        #expect(player.current?.sodaPlayback?.duration == 10)
        #expect(player.queue.first?.sodaPlayback == player.current?.sodaPlayback)
        let persisted = try JSONDecoder().decode(QueueSnapshot.self, from: #require(defaults.data(forKey: "AlpacaMusic.NativePlayer.queue.v1")))
        #expect(persisted.position == 10)
        #expect(persisted.tracks.first?.sodaPlayback?.start == 80)
    }

    @Test func nativeHTTPAllowsOnlyMusicAPIHostsAndScopesEveryCookieToItsRequest() async throws {
        let recorder = SodaHTTPFixtureRecorder()
        let http = NativeMusicHTTP(transport: { await recorder.receive($0) })
        let cookies = [sodaSessionFixture, .init(name: "sessionid", value: "douyin-main", domain: ".douyin.com"),
                       .init(name: "sid_tt", value: "beta-only", domain: "beta-luna.douyin.com"), qqSessionFixture]
        let url = try #require(URL(string: "https://api.qishui.com/luna/user"))
        _ = try await http.data(for: URLRequest(url: url), source: .soda, cookies: cookies)
        let requests = await recorder.requests
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "Cookie") == "sessionid=soda-fixture")
        for address in ["https://www.douyin.com/", "https://qishui.com/", "https://api.qishui.com.attacker.invalid/", "https://bff-pc.qishui.com/"] {
            let blocked = try #require(URL(string: address))
            await #expect(throws: MusicError.self) { try await http.data(for: URLRequest(url: blocked), source: .soda, cookies: cookies) }
        }
        #expect(await recorder.requests.count == 1)
    }
}
