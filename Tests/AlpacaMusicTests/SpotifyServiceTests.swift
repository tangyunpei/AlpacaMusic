import Foundation
import Testing
@testable import AlpacaMusic

@Suite @MainActor struct SpotifyServiceTests {
    @Test func unconfiguredRestoreDoesNotReadCredentialsOrContactSpotify() async throws {
        let fixture = serviceFixture(configured: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        await fixture.service.restore()
        #expect(await fixture.credentials.loadCount == 0)
        #expect(await fixture.http.requests.isEmpty)
        #expect(!fixture.service.isConfigured && !fixture.service.isEnabled)
    }

    @Test func expiredRestoreRefreshesPersistsAndValidatesTheAccount() async throws {
        let fixture = serviceFixture(expired: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        await fixture.service.restore()
        #expect(fixture.service.profile?.id == "stableAccount")
        #expect(fixture.service.isEnabled && fixture.service.error == nil)
        #expect(await fixture.authorization.refreshCount == 1)
        #expect(await fixture.credentials.savedTokens.map(\.accessToken) == ["fresh-token"])
        let requests = await fixture.http.requests
        #expect(requests.count == 1 && requests[0].url?.path == "/v1/me")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
    }

    @Test func concurrentUnauthorizedRequestsRefreshOnceAndRetryOnlyOnce() async throws {
        let fixture = serviceFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        await fixture.service.restore()
        await fixture.http.rejectOldSearchToken()
        let gate = SpotifyServiceGate()
        await fixture.authorization.setRefreshGate(gate)
        let first = Task { try await fixture.service.search("first") }
        let second = Task { try await fixture.service.search("second") }
        try await serviceEventually {
            let calls = await fixture.http.searchCount
            let refreshes = await fixture.authorization.refreshCount
            return calls == 2 && refreshes == 1
        }
        await gate.open()
        let result = try await (first.value, second.value)
        #expect(result.0.count == 1 && result.1.count == 1)
        #expect(await fixture.authorization.refreshCount == 1)
        #expect(await fixture.http.searchCount == 4)
        #expect(await fixture.credentials.savedTokens.count == 1)
    }

    @Test func refreshWaitersCannotUseTheTokenUntilPersistenceCompletes() async throws {
        let fixture = serviceFixture(expired: true, freshScopes: [])
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let gate = SpotifyServiceGate()
        await fixture.credentials.setSaveGate(gate)
        let restore = Task { await fixture.service.restore() }
        try await serviceEventually { await fixture.credentials.saveCount == 1 }
        let first = Task { try await fixture.service.search("first") }
        let second = Task { try await fixture.service.search("second") }
        // Give both MainActor callers an opportunity to join the in-flight
        // refresh. The shared task must include persistence, not only OAuth.
        for _ in 0..<20 { await Task.yield() }
        #expect(await fixture.http.requests.isEmpty)
        #expect(await fixture.authorization.refreshCount == 1)
        await gate.open()
        await restore.value
        _ = try await (first.value, second.value)
        #expect(await fixture.credentials.savedTokens.first?.scopes == ["user-library-read"])
        #expect(fixture.service.isEnabled)
    }

    @Test func persistenceFailureIsSharedWithRefreshWaiters() async throws {
        let fixture = serviceFixture(expired: true)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let gate = SpotifyServiceGate()
        await fixture.credentials.setSaveGate(gate, failing: true)
        let restore = Task { await fixture.service.restore() }
        try await serviceEventually { await fixture.credentials.saveCount == 1 }
        let lookup = Task { try await fixture.service.search("waiting") }
        for _ in 0..<20 { await Task.yield() }
        await gate.open()
        await restore.value
        await #expect(throws: SpotifyAuthorizationError.credentialStorage(-50)) { try await lookup.value }
        #expect(await fixture.http.requests.isEmpty)
        #expect(!fixture.service.isEnabled)
    }

    @Test func resultsArrivingAfterDisconnectAreDiscarded() async throws {
        let fixture = serviceFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        await fixture.service.restore()
        let gate = SpotifyServiceGate()
        await fixture.http.setSearchGate(gate)
        let lookup = Task { try await fixture.service.search("late") }
        try await serviceEventually { await fixture.http.searchCount == 1 }
        await fixture.service.disconnect()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await lookup.value }
        #expect(!fixture.service.isEnabled && fixture.service.profile == nil)
        #expect(await fixture.credentials.deleteCount == 1)
        #expect(!fixture.defaults.bool(forKey: "spotify-connected"))
    }

    @Test func invalidConfigurationDoesNotSaveOrReadCredentials() async throws {
        let fixture = serviceFixture(configured: false)
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        #expect(throws: MusicError.self) { try fixture.service.configure("https://developer.spotify.com/app") }
        #expect(fixture.defaults.string(forKey: "spotify-client-id") == nil)
        #expect(await fixture.credentials.loadCount == 0)
        #expect(await fixture.credentials.saveCount == 0)
        #expect(await fixture.authorization.authorizeCount == 0)
    }

    @Test(arguments: [false, true])
    func pauseNeverControlsADeviceOrTrackSwitchedOutsideAlpacaMusic(_ changedDevice: Bool) async throws {
        let fixture = serviceFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        await fixture.service.restore()
        let session = UUID()
        let track = Track(id: "spotify:SongA", title: "A", artist: "Artist", album: "", duration: 120, source: .spotify, sourceID: "SongA")
        try await fixture.service.startPlayback(track, at: 0, session: session)
        await fixture.http.setSnapshot(track: changedDevice ? "SongA" : "SongB", device: changedDevice ? "DeviceB" : "DeviceA")
        try await fixture.service.pausePlayback(session: session)
        await #expect(throws: MusicError.self) { try await fixture.service.seekPlayback(to: 10, session: session) }
        let requests = await fixture.http.requests
        #expect(requests.contains { $0.url?.path == "/v1/me/player/play" })
        #expect(!requests.contains { $0.url?.path == "/v1/me/player/pause" || $0.url?.path == "/v1/me/player/seek" })
    }

    @Test func expiredPlaybackSessionCannotSendCommands() async throws {
        let fixture = serviceFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        await fixture.service.restore()
        let session = UUID()
        let track = Track(id: "spotify:SongA", title: "A", artist: "Artist", album: "", duration: 120, source: .spotify, sourceID: "SongA")
        try await fixture.service.startPlayback(track, at: 0, session: session)
        fixture.service.releasePlayback()
        let count = await fixture.http.requests.count
        await #expect(throws: CancellationError.self) { try await fixture.service.pausePlayback(session: session) }
        #expect(await fixture.http.requests.count == count)
    }
}

@MainActor private struct SpotifyServiceFixture {
    let service: SpotifyService
    let defaults: UserDefaults
    let suite: String
    let credentials: SpotifyServiceCredentials
    let authorization: SpotifyServiceAuthorization
    let http: SpotifyServiceHTTP
}
@MainActor private func serviceFixture(configured: Bool = true, expired: Bool = false, freshScopes: Set<String> = ["user-library-read"]) -> SpotifyServiceFixture {
    let suite = "spotify-service-tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    if configured {
        defaults.set(String(repeating: "a", count: 32), forKey: "spotify-client-id")
        defaults.set(true, forKey: "spotify-connected")
    }
    let old = SpotifyToken(accessToken: "old-token", refreshToken: "old-refresh", expiresAt: Date().addingTimeInterval(expired ? -60 : 3_600), scopes: ["user-library-read"])
    let fresh = SpotifyToken(accessToken: "fresh-token", refreshToken: "fresh-refresh", expiresAt: Date().addingTimeInterval(3_600), scopes: freshScopes)
    let credentials = SpotifyServiceCredentials(old)
    let authorization = SpotifyServiceAuthorization(fresh)
    let http = SpotifyServiceHTTP()
    let service = SpotifyService(defaults: defaults, api: SpotifyAPIClient(transport: { try await http.respond($0) }), authorization: authorization, credentials: credentials)
    return SpotifyServiceFixture(service: service, defaults: defaults, suite: suite, credentials: credentials, authorization: authorization, http: http)
}
private actor SpotifyServiceGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func open() { opened = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
}
private actor SpotifyServiceCredentials: SpotifyCredentialStoring {
    private var value: SpotifyToken?
    private var saveGate: SpotifyServiceGate?
    private var failingSave = false
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    private(set) var deleteCount = 0
    private(set) var savedTokens: [SpotifyToken] = []
    init(_ value: SpotifyToken) { self.value = value }
    func setSaveGate(_ gate: SpotifyServiceGate, failing: Bool = false) { saveGate = gate; failingSave = failing }
    func load(clientID: String) async throws -> SpotifyToken? { loadCount += 1; return value }
    func save(_ token: SpotifyToken, clientID: String) async throws {
        saveCount += 1
        if let saveGate { await saveGate.wait() }
        if failingSave { throw SpotifyAuthorizationError.credentialStorage(-50) }
        savedTokens.append(token); value = token
    }
    func delete(clientID: String) async throws { deleteCount += 1; value = nil }
}
private actor SpotifyServiceAuthorization: SpotifyAuthorizing {
    let token: SpotifyToken
    private var refreshGate: SpotifyServiceGate?
    private(set) var authorizeCount = 0
    private(set) var refreshCount = 0
    init(_ token: SpotifyToken) { self.token = token }
    func setRefreshGate(_ gate: SpotifyServiceGate) { refreshGate = gate }
    func authorize(clientID: String) async throws -> SpotifyToken { authorizeCount += 1; return token }
    func refresh(clientID: String, refreshToken: String) async throws -> SpotifyToken {
        refreshCount += 1
        if let refreshGate { await refreshGate.wait() }
        return token
    }
}
private actor SpotifyServiceHTTP {
    private(set) var requests: [URLRequest] = []
    private(set) var searchCount = 0
    private var rejectsOldToken = false
    private var searchGate: SpotifyServiceGate?
    private var snapshotTrack = "SongA"
    private var snapshotDevice = "DeviceA"
    func rejectOldSearchToken() { rejectsOldToken = true }
    func setSearchGate(_ gate: SpotifyServiceGate) { searchGate = gate }
    func setSnapshot(track: String, device: String) { snapshotTrack = track; snapshotDevice = device }
    func respond(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url!.path
        let json: String
        var status = 200
        switch path {
        case "/v1/me": json = #"{"account_id":"stableAccount","id":"legacyID","display_name":"Listener"}"#
        case "/v1/search":
            searchCount += 1
            if let searchGate { await searchGate.wait() }
            if rejectsOldToken && request.value(forHTTPHeaderField: "Authorization") == "Bearer old-token" { status = 401; json = "{}" }
            else { json = #"{"tracks":{"items":[{"id":"SongA","name":"Song","type":"track","duration_ms":120000}],"offset":0,"total":1,"next":null}}"# }
        case "/v1/me/player/devices": json = #"{"devices":[{"id":"DeviceA","name":"Mac","type":"Computer","is_active":true,"is_restricted":false}]}"#
        case "/v1/me/player":
            json = "{\"is_playing\":true,\"progress_ms\":2000,\"device\":{\"id\":\"\(snapshotDevice)\",\"name\":\"Mac\"},\"item\":{\"id\":\"\(snapshotTrack)\",\"type\":\"track\",\"name\":\"Song\",\"duration_ms\":120000}}"
        case "/v1/me/player/play", "/v1/me/player/pause", "/v1/me/player/seek": json = ""; status = 204
        default: throw SpotifyAPIError.invalidRequest
        }
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor private func serviceEventually(_ predicate: @MainActor () async -> Bool) async throws {
    for _ in 0..<3_000 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw MusicError.message("Timed out waiting for test fixture")
}
