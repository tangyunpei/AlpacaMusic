import Foundation
import Testing
@testable import AlpacaMusic

private actor NativeFixtureProvider: DirectMusicProvider {
    nonisolated let source = MusicSource.netease
    var delayed = false
    private(set) var profileCalls = 0
    private var pendingPartial: CheckedContinuation<Void, Never>?
    private var shouldReturnPartial = false
    private(set) var partialReadStarted = false
    private var pauseProfile = false
    private var pauseSearch = false
    private var pendingProfile: CheckedContinuation<Void, Never>?
    private var pendingSearch: CheckedContinuation<Void, Never>?
    private var profilePauseObserver: CheckedContinuation<Void, Never>?
    private var searchPauseObserver: CheckedContinuation<Void, Never>?
    private(set) var pausedSearchCookies: [MusicSessionCookie] = []
    func delay(_ value: Bool) { delayed = value }
    func preparePartial() { shouldReturnPartial = true; partialReadStarted = false }
    func releasePartial() { pendingPartial?.resume(); pendingPartial = nil }
    func prepareAccountSwitch() { pauseProfile = true; pauseSearch = true; pausedSearchCookies = [] }
    func waitForProfilePause() async {
        if pendingProfile != nil { return }
        await withCheckedContinuation { profilePauseObserver = $0 }
    }
    func waitForSearchPause() async {
        if pendingSearch != nil { return }
        await withCheckedContinuation { searchPauseObserver = $0 }
    }
    func releaseProfile() { pendingProfile?.resume(); pendingProfile = nil }
    func releaseSearch() { pendingSearch?.resume(); pendingSearch = nil }
    private func wait() async { if delayed { try? await Task.sleep(for: .milliseconds(100)) } }
    func profile(cookies: [MusicSessionCookie]) async throws -> MusicAccountProfile {
        profileCalls += 1
        if pauseProfile {
            pauseProfile = false
            await withCheckedContinuation { continuation in
                pendingProfile = continuation
                profilePauseObserver?.resume(); profilePauseObserver = nil
            }
        }
        await wait()
        guard let value = cookies.first(where: { $0.name == "MUSIC_U" }), ["fixture-session", "fixture-other"].contains(value.value) else { throw MusicError.message("登录失效") }
        return .init(id: value.value == "fixture-session" ? "42" : "84", displayName: "Fixture")
    }
    func search(_ query: String, cookies: [MusicSessionCookie]) async throws -> [Track] {
        if pauseSearch {
            pauseSearch = false; pausedSearchCookies = cookies
            await withCheckedContinuation { continuation in
                pendingSearch = continuation
                searchPauseObserver?.resume(); searchPauseObserver = nil
            }
        }
        await wait(); return [nativeTrack("1")]
    }
    func playlists(profile: MusicAccountProfile, cookies: [MusicSessionCookie]) async throws -> [RemoteMusicPlaylist] { [.init(id: "p1", name: "歌单", trackCount: 1, source: .netease)] }
    func tracks(in playlist: RemoteMusicPlaylist, cookies: [MusicSessionCookie]) async throws -> [Track] {
        if shouldReturnPartial {
            shouldReturnPartial = false; partialReadStarted = true
            await withCheckedContinuation { pendingPartial = $0 }
            throw MusicError.incompletePlaylist(.init(tracks: [nativeTrack("1")], totalCount: 2, failedCount: 1, issues: ["第 2 首暂时无法读取"], message: "可读取 1 首，1 首未能读取"))
        }
        await wait(); return [nativeTrack("1")]
    }
    func resolve(_ track: Track, cookies: [MusicSessionCookie]) async throws -> URL { await wait(); return URL(string: "https://music.126.net/fixture.mp3")! }
}
private func nativeTrack(_ id: String) -> Track { .init(id: "netease:\(id)", title: id, artist: "Fixture", album: "Fixture", duration: 60, source: .netease, sourceID: id) }
private let nativeCookies = [MusicSessionCookie(name: "MUSIC_U", value: "fixture-session", domain: ".music.163.com")]

private actor NativeRequestRecorder {
    var requests: [URLRequest] = []
    func receive(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor SlowCredentialStore: MusicCredentialStoring {
    var cookies: [MusicSessionCookie] = []
    var saving = false
    func load(for source: MusicSource) -> [MusicSessionCookie] { cookies }
    func save(_ values: [MusicSessionCookie], for source: MusicSource) async {
        saving = true
        try? await Task.sleep(for: .milliseconds(100))
        cookies = values
    }
    func delete(for source: MusicSource) { cookies = [] }
}

private actor RestoreCredentialStore: MusicCredentialStoring {
    private var cookies: [MusicSessionCookie]
    private(set) var reads = 0
    private(set) var writes = 0
    private(set) var deletes = 0
    init(_ cookies: [MusicSessionCookie]) { self.cookies = cookies }
    func load(for source: MusicSource) -> [MusicSessionCookie] { reads += 1; return cookies }
    func save(_ values: [MusicSessionCookie], for source: MusicSource) { writes += 1; cookies = values }
    func delete(for source: MusicSource) { deletes += 1; cookies = [] }
}

@Suite struct NativeAccountTests {
    @Test func restoreValidatesSavedSessionWithoutRewritingCredentials() async throws {
        let provider = NativeFixtureProvider(), store = RestoreCredentialStore(nativeCookies)
        let client = NativeMusicClient(providers: [provider], credentials: store)
        #expect(try await client.restore(.netease)?.id == "42")
        #expect(await provider.profileCalls == 1)
        #expect(await store.reads == 1)
        #expect(await store.writes == 0)
        #expect(await store.deletes == 0)
        #expect(await client.connectedSources() == [.netease])
        #expect(try await client.search("test", source: .netease).count == 1)
    }
    @Test func canceledRestoreCannotPublishLateValidationOrRewriteCredentials() async throws {
        let provider = NativeFixtureProvider(), store = RestoreCredentialStore(nativeCookies)
        let client = NativeMusicClient(providers: [provider], credentials: store)
        await provider.delay(true)
        let pending = Task { try await client.restore(.netease) }
        for _ in 0..<100 { if await provider.profileCalls > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(await provider.profileCalls == 1)
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await client.connectedSources().isEmpty)
        #expect(await store.writes == 0)
        #expect(await store.deletes == 0)
        #expect(await store.load(for: .netease) == nativeCookies)
    }
    @Test func disconnectDuringRestoreCannotReviveTheSavedAccount() async throws {
        let provider = NativeFixtureProvider(), store = RestoreCredentialStore(nativeCookies)
        let client = NativeMusicClient(providers: [provider], credentials: store)
        await provider.delay(true)
        let pending = Task { try await client.restore(.netease) }
        for _ in 0..<100 { if await provider.profileCalls > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(await provider.profileCalls == 1)
        try await client.disconnect(.netease)
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await client.connectedSources().isEmpty)
        #expect(await store.writes == 0)
        #expect(await store.deletes == 1)
        #expect(await store.load(for: .netease).isEmpty)
    }
    @Test func invalidSavedSessionDoesNotBecomeConnectedOrChangeCredentials() async throws {
        let provider = NativeFixtureProvider()
        let store = RestoreCredentialStore([.init(name: "MUSIC_U", value: "invalid-fixture-session", domain: ".music.163.com")])
        let client = NativeMusicClient(providers: [provider], credentials: store)
        await #expect(throws: MusicError.self) { try await client.restore(.netease) }
        #expect(await provider.profileCalls == 1)
        #expect(await client.connectedSources().isEmpty)
        #expect(await store.writes == 0)
        #expect(await store.deletes == 0)
    }
    @Test func connectedAccountsWorkWithoutAnyCustomServerAndNeverFallBack() async throws {
        let provider = NativeFixtureProvider(), store = MemoryMusicCredentialStore()
        let client = NativeMusicClient(providers: [provider], credentials: store)
        let service = SourceService(transport: { _ in Issue.record("Native account must not contact the custom server"); throw MusicError.message("unexpected") }, native: client)
        _ = try await client.connect(.netease, cookies: nativeCookies)
        let result = await service.search("test", configurations: [.init(kind: .netease, endpoint: "https://custom.example", enabled: true)])
        #expect(result.first?.tracks.first?.source == .netease)
        #expect(try await service.resolve(nativeTrack("1"), configurations: []).host == "music.126.net")
        #expect(try await store.load(for: .netease) == nativeCookies)
        try await client.disconnect(.netease)
        #expect(await client.connectedSources().isEmpty)
        #expect(try await store.load(for: .netease).isEmpty)
    }
    @Test func canceledConnectionCannotPersistOrPublishLateProfile() async throws {
        let provider = NativeFixtureProvider(), store = MemoryMusicCredentialStore()
        let client = NativeMusicClient(providers: [provider], credentials: store)
        await provider.delay(true)
        let pending = Task { try await client.connect(.netease, cookies: nativeCookies) }
        try await Task.sleep(for: .milliseconds(20))
        try await client.cancelConnection(.netease)
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await client.connectedSources().isEmpty)
        #expect(try await store.load(for: .netease).isEmpty)
    }
    @Test func logoutWaitsForInFlightCredentialSaveThenErasesIt() async throws {
        let store = SlowCredentialStore()
        let client = NativeMusicClient(providers: [NativeFixtureProvider()], credentials: store)
        let pending = Task { try await client.connect(.netease, cookies: nativeCookies) }
        for _ in 0..<100 { if await store.saving { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(await store.saving)
        try await client.disconnect(.netease)
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await store.load(for: .netease).isEmpty)
        #expect(await client.connectedSources().isEmpty)
    }
    @Test func logoutRejectsLateSearchAndPlaylistResults() async throws {
        let provider = NativeFixtureProvider()
        let client = NativeMusicClient(providers: [provider], credentials: MemoryMusicCredentialStore())
        _ = try await client.connect(.netease, cookies: nativeCookies)
        await provider.delay(true)
        let search = Task { try await client.search("test", source: .netease) }
        let tracks = Task { try await client.tracks(in: .init(id: "p1", name: "test", trackCount: 1, source: .netease)) }
        try await Task.sleep(for: .milliseconds(20))
        try await client.disconnect(.netease)
        await #expect(throws: CancellationError.self) { try await search.value }
        await #expect(throws: CancellationError.self) { try await tracks.value }
    }
    @Test func accountSwitchRejectsRequestsStartedDuringAuthentication() async throws {
        let provider = NativeFixtureProvider()
        let client = NativeMusicClient(providers: [provider], credentials: MemoryMusicCredentialStore())
        _ = try await client.connect(.netease, cookies: nativeCookies)
        // Gate both provider calls so CPU load cannot reorder authentication and search.
        await provider.prepareAccountSwitch()
        let replacement = Task { try await client.connect(.netease, cookies: [.init(name: "MUSIC_U", value: "fixture-other", domain: ".music.163.com")]) }
        await provider.waitForProfilePause()
        let oldAccountSearch = Task { try await client.search("test", source: .netease) }
        await provider.waitForSearchPause()
        #expect(await provider.pausedSearchCookies == nativeCookies)
        await provider.releaseProfile()
        let replacementResult = await replacement.result
        await provider.releaseSearch()
        #expect(try replacementResult.get().id == "84")
        await #expect(throws: CancellationError.self) { try await oldAccountSearch.value }
    }
    @Test func partialPlaylistFromOldAccountOrCanceledReadCannotEscape() async throws {
        for shouldSwitch in [true, false] {
            let provider = NativeFixtureProvider()
            let client = NativeMusicClient(providers: [provider], credentials: MemoryMusicCredentialStore())
            _ = try await client.connect(.netease, cookies: nativeCookies)
            await provider.preparePartial()
            let pending = Task { try await client.tracks(in: .init(id: "p1", name: "Fixture", trackCount: 2, source: .netease)) }
            while !(await provider.partialReadStarted) { await Task.yield() }
            if shouldSwitch {
                _ = try await client.connect(.netease, cookies: [.init(name: "MUSIC_U", value: "fixture-other", domain: ".music.163.com")])
            } else { pending.cancel() }
            await provider.releasePartial()
            await #expect(throws: CancellationError.self) { try await pending.value }
        }
    }
    @Test func partialPlaylistForCurrentAccountRemainsExplicitDataBearingFailure() async throws {
        let provider = NativeFixtureProvider()
        let client = NativeMusicClient(providers: [provider], credentials: MemoryMusicCredentialStore())
        _ = try await client.connect(.netease, cookies: nativeCookies)
        await provider.preparePartial()
        let pending = Task { try await client.tracks(in: .init(id: "p1", name: "Fixture", trackCount: 2, source: .netease)) }
        while !(await provider.partialReadStarted) { await Task.yield() }
        await provider.releasePartial()
        do { _ = try await pending.value; Issue.record("Partial playlist appeared complete") }
        catch MusicError.incompletePlaylist(let partial) {
            #expect(partial.tracks.map(\.id) == ["netease:1"])
            #expect(partial.totalCount == 2 && partial.failedCount == 1)
        }
    }
    @Test func cancelAfterCommitRestoresPreviousAccountAndStaleCancelCannotUndoNewLogin() async throws {
        let client = NativeMusicClient(providers: [NativeFixtureProvider()], credentials: MemoryMusicCredentialStore())
        let first = UUID(), second = UUID(), third = UUID()
        _ = try await client.connect(.netease, cookies: nativeCookies, attemptID: first)
        await client.completeConnection(.netease, attemptID: first)
        let other = [MusicSessionCookie(name: "MUSIC_U", value: "fixture-other", domain: ".music.163.com")]
        _ = try await client.connect(.netease, cookies: other, attemptID: second)
        #expect(try await client.cancelConnection(.netease, attemptID: second)?.id == "42")
        _ = try await client.connect(.netease, cookies: other, attemptID: third)
        await client.completeConnection(.netease, attemptID: third)
        #expect(try await client.cancelConnection(.netease, attemptID: second)?.id == "84")
        #expect(try await client.search("test", source: .netease).count == 1)
    }
    @Test func nativeHTTPScopesCookiesAndRejectsOtherHosts() async throws {
        let recorder = NativeRequestRecorder(), http = NativeMusicHTTP(transport: { await recorder.receive($0) })
        let cookies = nativeCookies + [
            MusicSessionCookie(name: "__csrf", value: "expired", domain: ".music.163.com", expires: Date(timeIntervalSince1970: 0)),
            MusicSessionCookie(name: "MUSIC_U", value: "wrong-path", domain: ".music.163.com", path: "/account"),
            MusicSessionCookie(name: "MUSIC_U", value: "wrong-domain", domain: ".music.163.com.attacker.example"),
            MusicSessionCookie(name: "MUSIC_U", value: "bad\r\nHeader:value", domain: ".music.163.com")
        ]
        _ = try await http.data(for: URLRequest(url: URL(string: "https://music.163.com/weapi/test")!), source: .netease, cookies: cookies)
        let requests = await recorder.requests
        #expect(requests.count == 1)
        #expect(requests[0].value(forHTTPHeaderField: "Cookie") == "MUSIC_U=fixture-session")
        await #expect(throws: MusicError.self) { try await http.data(for: URLRequest(url: URL(string: "https://attacker.example/")!), source: .netease, cookies: cookies) }
        #expect(await recorder.requests.count == 1)
    }
    @MainActor @Test func staleSheetCancellationCannotInvalidateNewAccountUI() async throws {
        let provider = NativeFixtureProvider()
        let client = NativeMusicClient(providers: [provider], credentials: MemoryMusicCredentialStore())
        let accounts = ConnectedMusicAccounts(client: client), first = UUID(), second = UUID()
        try await accounts.connect(.netease, cookies: nativeCookies, attemptID: first)
        await accounts.completeConnection(.netease, attemptID: first)
        await provider.delay(true)
        let pending = Task { try await accounts.connect(.netease, cookies: [.init(name: "MUSIC_U", value: "fixture-other", domain: ".music.163.com")], attemptID: second) }
        try await Task.sleep(for: .milliseconds(20))
        await accounts.cancelConnection(.netease, attemptID: first)
        try await pending.value
        #expect(accounts.state(.netease).profile?.id == "84")
        #expect(!accounts.state(.netease).busy)
    }
    @MainActor @Test func importedPlaylistsMergePersistAndRemainSeparateAcrossAccounts() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "alpaca-direct-library-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"version":1,"tracks":[],"favorites":[],"playlists":[],"sources":[]}"#.utf8).write(to: folder.appending(path: "library-v1.json"))
        let library = MusicLibrary(directory: folder)
        await library.load()
        let remote = RemoteMusicPlaylist(id: "p1", name: "旧日收藏", trackCount: 2, source: .netease)
        let first = try library.importRemotePlaylist(remote, accountID: "42", tracks: [nativeTrack("1"), nativeTrack("1")])
        library.addToPlaylist(first.id, track: nativeTrack("local-edit"))
        let again = try library.importRemotePlaylist(remote, accountID: "42", tracks: [nativeTrack("1"), nativeTrack("2")])
        #expect(first.id == again.id)
        #expect(again.trackIDs == ["netease:1", "netease:local-edit", "netease:2"])
        let other = try library.importRemotePlaylist(remote, accountID: "43", tracks: [nativeTrack("1")])
        #expect(other.id != first.id)
        await library.flushPersistence()
        let restored = MusicLibrary(directory: folder)
        await restored.load()
        #expect(restored.playlists.count == 2)
        #expect(restored.playlists.first?.trackIDs == again.trackIDs)
        #expect(restored.tracks.count == 3)
    }
}
