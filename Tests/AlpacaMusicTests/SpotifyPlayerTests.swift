import Foundation
import Testing
@testable import AlpacaMusic

@Suite(.serialized) @MainActor struct SpotifyPlayerTests {
    @Test func disconnectWaitsForRemoteStopAfterCurrentHasChangedToLocal() async throws {
        let fixture = try await spotifyPlayerFixture()
        defer { fixture.player.shutdown(); fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        await fixture.player.play(spotifyPlayerSong)
        try await spotifyPlayerEventually { fixture.player.status == .playing }
        let gate = SpotifyPlayerGate()
        await fixture.http.holdPause(gate)
        let transition = Task { await fixture.player.play(spotifyPlayerLocalSong) }
        try await spotifyPlayerEventually { await fixture.http.pauseCount == 1 }
        #expect(fixture.player.current?.source == .local)
        let disconnect = Task {
            await fixture.player.pauseAndWaitForSpotify()
            await fixture.service.disconnect()
        }
        // The disconnect caller has a turn to run while the remote pause is
        // deliberately suspended. It must not clear the account first.
        for _ in 0..<30 { await Task.yield() }
        #expect(fixture.service.isEnabled)
        await gate.open()
        await transition.value
        await disconnect.value
        #expect(!fixture.service.isEnabled)
        // This deliberate missing bookmark proves local preparation was reached
        // without opening a file, contacting a server, or producing audio.
        #expect(fixture.player.status == .failed)
        #expect(fixture.player.failure?.message == L10n.string("本地文件尚未授权，请重新导入"))
    }

    @Test func canceledRemoteStopFailsTheLiveLocalActivationAndAllowsRetry() async throws {
        let fixture = try await spotifyPlayerFixture()
        defer { fixture.player.shutdown(); fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        await fixture.player.play(spotifyPlayerSong)
        try await spotifyPlayerEventually { fixture.player.status == .playing }
        await fixture.http.cancelNextPause()
        await fixture.player.play(spotifyPlayerLocalSong)
        #expect(fixture.player.current?.source == .local)
        #expect(fixture.player.status == .failed)
        #expect(fixture.player.failure?.message == L10n.string("Spotify 连接已变更，无法确认上一首已暂停。请在官方播放器确认后重试。"))
        await fixture.player.retry()
        #expect(fixture.player.status == .failed)
        #expect(fixture.player.failure?.message == L10n.string("本地文件尚未授权，请重新导入"))
        #expect(await fixture.http.pauseCount == 1)
    }
}

private let spotifyPlayerSong = Track(id: "spotify:SongA", title: "Fixture", artist: "Fixture", album: "", duration: 120, source: .spotify, sourceID: "SongA")
private let spotifyPlayerLocalSong = Track(id: "local:missing-bookmark", title: "Local fixture", artist: "Fixture", album: "", duration: 120, source: .local)

@MainActor private struct SpotifyPlayerFixture {
    let player: PlayerController
    let service: SpotifyService
    let http: SpotifyPlayerHTTP
    let defaults: UserDefaults
    let suite: String
}

@MainActor private func spotifyPlayerFixture() async throws -> SpotifyPlayerFixture {
    let suite = "spotify-player-tests-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    let clientID = String(repeating: "a", count: 32)
    defaults.set(clientID, forKey: "spotify-client-id")
    defaults.set(true, forKey: "spotify-connected")
    let credentials = MemorySpotifyCredentialStore()
    try await credentials.save(.init(accessToken: "fixture-token", refreshToken: "fixture-refresh",
                                     expiresAt: Date().addingTimeInterval(3_600), scopes: []), clientID: clientID)
    let http = SpotifyPlayerHTTP()
    let service = SpotifyService(defaults: defaults, api: SpotifyAPIClient(transport: { try await http.respond($0) }),
                                 authorization: SpotifyPlayerAuthorization(), credentials: credentials)
    await service.restore()
    let player = PlayerController(sources: SourceService(), defaults: defaults, spotify: service)
    return .init(player: player, service: service, http: http, defaults: defaults, suite: suite)
}

private struct SpotifyPlayerAuthorization: SpotifyAuthorizing {
    func authorize(clientID: String) async throws -> SpotifyToken { throw MusicError.message("Unexpected fixture login") }
    func refresh(clientID: String, refreshToken: String) async throws -> SpotifyToken { throw MusicError.message("Unexpected fixture refresh") }
}

private actor SpotifyPlayerGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func open() { opened = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
}

private actor SpotifyPlayerHTTP {
    private var pauseGate: SpotifyPlayerGate?
    private var cancelPause = false
    private var playing = false
    private(set) var pauseCount = 0
    func holdPause(_ gate: SpotifyPlayerGate) { pauseGate = gate }
    func cancelNextPause() { cancelPause = true }
    func respond(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let json: String
        var status = 200
        switch url.path {
        case "/v1/me": json = #"{"account_id":"fixtureAccount","display_name":"Fixture"}"#
        case "/v1/me/player/devices": json = #"{"devices":[{"id":"DeviceA","name":"Fixture Mac","type":"Computer","is_active":true,"is_restricted":false}]}"#
        case "/v1/me/player/play": playing = true; status = 204; json = ""
        case "/v1/me/player":
            json = "{\"is_playing\":\(playing),\"progress_ms\":2000,\"device\":{\"id\":\"DeviceA\",\"name\":\"Fixture Mac\"},\"item\":{\"id\":\"SongA\",\"type\":\"track\",\"name\":\"Fixture\",\"duration_ms\":120000}}"
        case "/v1/me/player/pause":
            pauseCount += 1
            if let pauseGate { await pauseGate.wait() }
            if cancelPause { cancelPause = false; throw CancellationError() }
            playing = false; status = 204; json = ""
        default: throw SpotifyAPIError.invalidRequest
        }
        return (Data(json.utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }
}

@MainActor private func spotifyPlayerEventually(_ predicate: @MainActor () async -> Bool) async throws {
    for _ in 0..<2_000 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw MusicError.message("Timed out waiting for Spotify player fixture")
}
