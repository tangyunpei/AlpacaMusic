import Foundation
import Testing
@testable import AlpacaMusic

private let albumSessionCookies = [MusicSessionCookie(name: "MUSIC_U", value: "fixture-album-session", domain: ".music.163.com")]
private let sessionAlbum = RemoteMusicAlbum(id: "42", name: "Saved album", artist: "Fixture", trackCount: 1, source: .netease)
private func sessionAlbumTrack() -> Track {
    .init(id: "netease:7", title: "Album track", artist: "Fixture", album: "Saved album", duration: 90, source: .netease, sourceID: "7")
}

private actor AlbumSessionProvider: DirectMusicProvider {
    enum Operation: Hashable, Sendable { case list, detail }
    nonisolated let source = MusicSource.netease
    private var held = Set<Operation>()
    private var pending: [Operation: CheckedContinuation<Void, Never>] = [:]
    private var observers: [Operation: CheckedContinuation<Void, Never>] = [:]
    private(set) var calls: [Operation: Int] = [:]
    private(set) var receivedCookies: [Operation: [MusicSessionCookie]] = [:]
    private(set) var receivedProfile: MusicAccountProfile?
    private(set) var receivedAlbum: RemoteMusicAlbum?

    func hold(_ operation: Operation) { held.insert(operation) }
    func waitUntilHeld(_ operation: Operation) async {
        if pending[operation] != nil { return }
        await withCheckedContinuation { observers[operation] = $0 }
    }
    func release(_ operation: Operation) {
        held.remove(operation)
        pending.removeValue(forKey: operation)?.resume()
    }
    private func record(_ operation: Operation, cookies: [MusicSessionCookie]) async {
        calls[operation, default: 0] += 1
        receivedCookies[operation] = cookies
        if held.contains(operation) {
            await withCheckedContinuation { continuation in
                pending[operation] = continuation
                observers.removeValue(forKey: operation)?.resume()
            }
        }
    }
    func profile(cookies: [MusicSessionCookie]) async throws -> MusicAccountProfile { .init(id: "same-account", displayName: "Fixture") }
    func search(_ query: String, cookies: [MusicSessionCookie]) async throws -> [Track] { [] }
    func playlists(profile: MusicAccountProfile, cookies: [MusicSessionCookie]) async throws -> [RemoteMusicPlaylist] { [] }
    func tracks(in playlist: RemoteMusicPlaylist, cookies: [MusicSessionCookie]) async throws -> [Track] { [] }
    func albums(profile: MusicAccountProfile, cookies: [MusicSessionCookie]) async throws -> [RemoteMusicAlbum] {
        receivedProfile = profile
        await record(.list, cookies: cookies)
        // Deliberately return despite cancellation to verify the client's boundary.
        return [sessionAlbum]
    }
    func tracks(in album: RemoteMusicAlbum, cookies: [MusicSessionCookie]) async throws -> [Track] {
        receivedAlbum = album
        await record(.detail, cookies: cookies)
        return [sessionAlbumTrack()]
    }
    func resolve(_ track: Track, cookies: [MusicSessionCookie]) async throws -> URL { throw MusicError.message("Fixture has no audio") }
}

/// Intentionally implements no album APIs, exercising the protocol defaults.
private struct UnsupportedAlbumProvider: DirectMusicProvider {
    let source = MusicSource.qq
    func profile(cookies: [MusicSessionCookie]) async throws -> MusicAccountProfile { .init(id: "qq-fixture", displayName: "Fixture") }
    func search(_ query: String, cookies: [MusicSessionCookie]) async throws -> [Track] { [] }
    func playlists(profile: MusicAccountProfile, cookies: [MusicSessionCookie]) async throws -> [RemoteMusicPlaylist] { [] }
    func tracks(in playlist: RemoteMusicPlaylist, cookies: [MusicSessionCookie]) async throws -> [Track] { [] }
    func resolve(_ track: Track, cookies: [MusicSessionCookie]) async throws -> URL { throw MusicError.message("Fixture has no audio") }
}

@Suite struct AlbumSessionTests {
    @Test func connectedAlbumOperationsUseVerifiedAccountAndCookies() async throws {
        let provider = AlbumSessionProvider(), store = MemoryMusicCredentialStore()
        let client = NativeMusicClient(providers: [provider], credentials: store)
        let account = try await client.connect(.netease, cookies: albumSessionCookies)
        let scope = try await client.libraryScope(for: .netease)
        #expect(try await client.albums(.netease) == [sessionAlbum])
        #expect(try await client.tracks(in: sessionAlbum).map(\.id) == ["netease:7"])
        try await client.validateLibraryScope(scope)
        #expect(scope.source == .netease)
        #expect(await provider.receivedProfile == account)
        #expect(await provider.receivedAlbum == sessionAlbum)
        #expect(await provider.receivedCookies[.list] == albumSessionCookies)
        #expect(await provider.receivedCookies[.detail] == albumSessionCookies)
        #expect(try await store.load(for: .netease) == albumSessionCookies)
    }

    @Test func disconnectedAlbumOperationsNeverReachProvider() async {
        let provider = AlbumSessionProvider()
        let client = NativeMusicClient(providers: [provider], credentials: MemoryMusicCredentialStore())
        await #expect(throws: MusicError.self) { try await client.albums(.netease) }
        await #expect(throws: MusicError.self) { try await client.tracks(in: sessionAlbum) }
        await #expect(throws: MusicError.self) { try await client.libraryScope(for: .netease) }
        #expect(await provider.calls.isEmpty)
    }

    @Test(arguments: [false, true]) func disconnectRejectsHeldResultsEvenAfterSameAccountReconnect(reconnect: Bool) async throws {
        let provider = AlbumSessionProvider(), store = MemoryMusicCredentialStore()
        let client = NativeMusicClient(providers: [provider], credentials: store)
        _ = try await client.connect(.netease, cookies: albumSessionCookies)
        let oldScope = try await client.libraryScope(for: .netease)
        await provider.hold(.list)
        await provider.hold(.detail)
        let list = Task { try await client.albums(.netease) }
        let detail = Task { try await client.tracks(in: sessionAlbum) }
        await provider.waitUntilHeld(.list)
        await provider.waitUntilHeld(.detail)

        try await client.disconnect(.netease)
        if reconnect { _ = try await client.connect(.netease, cookies: albumSessionCookies) }
        await provider.release(.list)
        await provider.release(.detail)

        await #expect(throws: CancellationError.self) { try await list.value }
        await #expect(throws: CancellationError.self) { try await detail.value }
        await #expect(throws: CancellationError.self) { try await client.validateLibraryScope(oldScope) }
        if reconnect {
            let newScope = try await client.libraryScope(for: .netease)
            #expect(newScope.generation != oldScope.generation)
            try await client.validateLibraryScope(newScope)
            #expect(try await client.albums(.netease) == [sessionAlbum])
            #expect(try await client.tracks(in: sessionAlbum).count == 1)
        } else {
            #expect(try await store.load(for: .netease).isEmpty)
        }
    }

    @Test func canceledReadsRejectLateDataWithoutInvalidatingCurrentSession() async throws {
        let provider = AlbumSessionProvider()
        let client = NativeMusicClient(providers: [provider], credentials: MemoryMusicCredentialStore())
        _ = try await client.connect(.netease, cookies: albumSessionCookies)
        let scope = try await client.libraryScope(for: .netease)
        await provider.hold(.list)
        await provider.hold(.detail)
        let list = Task { try await client.albums(.netease) }
        let detail = Task { try await client.tracks(in: sessionAlbum) }
        await provider.waitUntilHeld(.list)
        await provider.waitUntilHeld(.detail)
        list.cancel()
        detail.cancel()
        await provider.release(.list)
        await provider.release(.detail)
        await #expect(throws: CancellationError.self) { try await list.value }
        await #expect(throws: CancellationError.self) { try await detail.value }
        try await client.validateLibraryScope(scope)
        #expect(await client.isConnected(.netease, accountID: "same-account"))
        #expect(try await client.albums(.netease).count == 1)
    }

    @Test func reconnectWithoutDisconnectAlsoInvalidatesExistingScope() async throws {
        let provider = AlbumSessionProvider()
        let client = NativeMusicClient(providers: [provider], credentials: MemoryMusicCredentialStore())
        _ = try await client.connect(.netease, cookies: albumSessionCookies)
        let scope = try await client.libraryScope(for: .netease)
        _ = try await client.connect(.netease, cookies: albumSessionCookies)
        await #expect(throws: CancellationError.self) { try await client.validateLibraryScope(scope) }
        let fresh = try await client.libraryScope(for: .netease)
        try await client.validateLibraryScope(fresh)
    }

    @Test func unsupportedProviderThrowsInsteadOfReportingAnEmptyAlbumLibrary() async throws {
        let client = NativeMusicClient(providers: [UnsupportedAlbumProvider()], credentials: MemoryMusicCredentialStore())
        _ = try await client.connect(.qq, cookies: [.init(name: "qqmusic_key", value: "fixture-qq", domain: ".qq.com")])
        let album = RemoteMusicAlbum(id: "qq-album", name: "Fixture", source: .qq)
        do {
            _ = try await client.albums(.qq)
            Issue.record("Unsupported album list appeared empty")
        } catch {
            #expect(error.localizedDescription == L10n.string("此音源暂不支持专辑导入。"))
        }
        do {
            _ = try await client.tracks(in: album)
            Issue.record("Unsupported album detail appeared empty")
        } catch {
            #expect(error.localizedDescription == L10n.string("此音源暂不支持专辑导入。"))
        }
    }
}
