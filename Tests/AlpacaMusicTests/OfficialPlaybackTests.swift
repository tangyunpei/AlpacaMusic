import AppKit
import Foundation
import Testing
import WebKit
@testable import AlpacaMusic

private struct OfficialFixtureProvider: DirectMusicProvider {
    let source = MusicSource.qq
    func profile(cookies: [MusicSessionCookie]) async throws -> MusicAccountProfile { .init(id: "fixture-account", displayName: "Fixture") }
    func search(_ query: String, cookies: [MusicSessionCookie]) async throws -> [Track] { [] }
    func playlists(profile: MusicAccountProfile, cookies: [MusicSessionCookie]) async throws -> [RemoteMusicPlaylist] { [] }
    func tracks(in playlist: RemoteMusicPlaylist, cookies: [MusicSessionCookie]) async throws -> [Track] { [] }
    func resolve(_ track: Track, cookies: [MusicSessionCookie]) async throws -> URL { throw MusicError.message("Fixture has no audio") }
}
private actor OfficialCredentialProbe: MusicCredentialStoring {
    private(set) var reads = 0
    private(set) var writes = 0
    private(set) var deletes = 0
    func load(for source: MusicSource) -> [MusicSessionCookie] { reads += 1; return [] }
    func save(_ cookies: [MusicSessionCookie], for source: MusicSource) { writes += 1 }
    func delete(for source: MusicSource) { deletes += 1 }
}
private let officialFixtureCookies = [MusicSessionCookie(name: "qqmusic_key", value: "synthetic-session", domain: ".y.qq.com"), MusicSessionCookie(name: "uin", value: "1234", domain: ".qq.com")]
private func officialFixtureTrack(_ mid: String = "001cqmMK0EHs9L", source: MusicSource = .qq) -> Track {
    .init(id: "qq:\(mid)", title: "Fixture", artist: "Fixture", album: "Fixture", duration: 1, source: source, sourceID: mid)
}

@Suite(.serialized) struct OfficialPlaybackTests {
    @Test func detailAddressOnlyAcceptsQQAndSafeSongIdentifier() {
        #expect(QQOfficialPlaybackPolicy.detailURL(for: officialFixtureTrack())?.absoluteString == "https://y.qq.com/n/ryqq_v2/songDetail/001cqmMK0EHs9L")
        for mid in ["", "../player", "abc?token=secret", "abc#fragment", "abc/def", "with space", "中文", String(repeating: "a", count: 65)] {
            #expect(QQOfficialPlaybackPolicy.detailURL(for: officialFixtureTrack(mid)) == nil)
        }
        for source in [MusicSource.netease, .appleMusic, .local, .demo, .url] {
            #expect(QQOfficialPlaybackPolicy.detailURL(for: officialFixtureTrack(source: source)) == nil)
        }
    }
    @Test func officialNavigationKeepsTheExistingExactHostBoundary() {
        for url in ["https://y.qq.com/n/ryqq_v2/player", "https://y.qq.com/n/ryqq_v2/songDetail/001cqmMK0EHs9L", "https://ssl.ptlogin2.graph.qq.com/check_sig"] {
            #expect(QQOfficialPlaybackPolicy.allows(URL(string: url)))
        }
        for url in ["http://y.qq.com/", "https://y.qq.com.evil.example/", "https://y.qq.com:8443/", "https://user:pass@y.qq.com/", "https://music.163.com/", "file:///tmp/a", "javascript:alert(1)", "mqqmusic://player", "about:blank"] {
            #expect(!QQOfficialPlaybackPolicy.allows(URL(string: url)))
        }
        #expect(QQOfficialPlaybackPolicy.allows(URL(string: "about:blank"), isMainFrame: false))
    }
    @Test func cookieConversionPreservesScopeAndRejectsUnrelatedData() throws {
        let cookie = MusicSessionCookie(name: "qqmusic_key", value: "synthetic-only", domain: ".y.qq.com", path: "/cgi-bin/", expires: Date().addingTimeInterval(500))
        let converted = try #require(QQOfficialPlaybackPolicy.webCookie(cookie))
        #expect(converted.domain == cookie.domain)
        #expect(converted.path == cookie.path)
        #expect(converted.isSecure)
        #expect(abs(try #require(converted.expiresDate).timeIntervalSince(try #require(cookie.expires))) < 1)
        for invalid in [MusicSessionCookie(name: "password", value: "synthetic-only", domain: ".y.qq.com"), MusicSessionCookie(name: "uin", value: "1234", domain: ".evil.example"), MusicSessionCookie(name: "uin", value: "1234", domain: ".qq.com", expires: .distantPast), MusicSessionCookie(name: "uin", value: "bad;value", domain: ".qq.com"), MusicSessionCookie(name: "uin", value: "1234", domain: ".qq.com", path: "not/a/path")] {
            #expect(QQOfficialPlaybackPolicy.webCookie(invalid) == nil)
        }
    }
    @Test func websiteLeaseUsesOnlyMemoryAndNeverWritesCredentials() async throws {
        let store = OfficialCredentialProbe()
        let client = NativeMusicClient(providers: [OfficialFixtureProvider()], credentials: store)
        await #expect(throws: MusicError.self) { try await client.officialQQPlaybackSession() }
        _ = try await client.connect(.qq, cookies: officialFixtureCookies)
        let session = try await client.officialQQPlaybackSession()
        #expect(session.cookies == officialFixtureCookies)
        try await client.validateOfficialQQPlaybackSession(session)
        await client.releaseOfficialQQPlaybackSession(session.id)
        await #expect(throws: CancellationError.self) { try await client.validateOfficialQQPlaybackSession(session) }
        #expect(await store.reads == 0)
        #expect(await store.writes == 1)
        #expect(await store.deletes == 0)
    }
    @Test func reconnectingSameAccountAndLogoutInvalidateGenerationLeases() async throws {
        let client = NativeMusicClient(providers: [OfficialFixtureProvider()], credentials: OfficialCredentialProbe())
        _ = try await client.connect(.qq, cookies: officialFixtureCookies)
        let first = try await client.officialQQPlaybackSession()
        _ = try await client.connect(.qq, cookies: officialFixtureCookies)
        var invalidated = first.invalidations.makeAsyncIterator()
        #expect(await invalidated.next() != nil)
        await #expect(throws: CancellationError.self) { try await client.validateOfficialQQPlaybackSession(first) }
        let second = try await client.officialQQPlaybackSession()
        #expect(first.generation != second.generation)
        try await client.disconnect(.qq)
        var loggedOut = second.invalidations.makeAsyncIterator()
        #expect(await loggedOut.next() != nil)
        await #expect(throws: CancellationError.self) { try await client.validateOfficialQQPlaybackSession(second) }
    }
    @Test @MainActor func temporaryBrowserSeedsBeforeLoadAndClearsOnClose() async throws {
        _ = NSApplication.shared
        let client = NativeMusicClient(providers: [OfficialFixtureProvider()], credentials: OfficialCredentialProbe())
        _ = try await client.connect(.qq, cookies: officialFixtureCookies)
        var loadedURL: URL?
        var countAtLoad: Task<Int, Never>?
        let browser = QQOfficialPlaybackBrowser { view, url in
            loadedURL = url
            // Take the observation at the exact navigation handoff. The default
            // loader would load the page here; this fixture performs no network.
            countAtLoad = Task { @MainActor in await view.configuration.websiteDataStore.httpCookieStore.allCookies().count }
        }
        let isolated = QQOfficialPlaybackBrowser { _, _ in Issue.record("Second browser should remain empty") }
        let view = try #require(browser.mainWebView)
        let other = try #require(isolated.mainWebView)
        let store = view.configuration.websiteDataStore
        #expect(!browser.usesPersistentStorage)
        #expect(store !== other.configuration.websiteDataStore)
        #expect(view.configuration.mediaTypesRequiringUserActionForPlayback.isEmpty)
        #expect(loadedURL == nil)
        await browser.prepare(track: officialFixtureTrack(), client: client)
        #expect(loadedURL == QQOfficialPlaybackPolicy.detailURL(for: officialFixtureTrack()))
        #expect(browser.hasLoadedPage)
        #expect(await countAtLoad?.value == 2)
        #expect(await store.httpCookieStore.allCookies().count == 2)
        #expect(await other.configuration.websiteDataStore.httpCookieStore.allCookies().isEmpty)
        await browser.invalidate()?.value
        #expect(browser.isClosed && browser.mainWebView == nil)
        #expect(await store.httpCookieStore.allCookies().isEmpty)
        await isolated.invalidate()?.value
    }
    @Test @MainActor func canceledPreparationAndClosedBrowserCannotLoadLater() async throws {
        _ = NSApplication.shared
        let client = NativeMusicClient(providers: [OfficialFixtureProvider()], credentials: OfficialCredentialProbe())
        _ = try await client.connect(.qq, cookies: officialFixtureCookies)
        let canceled = QQOfficialPlaybackBrowser { _, _ in Issue.record("Canceled window navigated") }
        let task = Task { await canceled.prepare(track: officialFixtureTrack(), client: client) }
        task.cancel(); await task.value
        #expect(canceled.isClosed)
        let closed = QQOfficialPlaybackBrowser { _, _ in Issue.record("Closed window navigated") }
        await closed.invalidate()?.value
        await closed.prepare(track: officialFixtureTrack(), client: client)
        #expect(!closed.hasLoadedPage)
    }
    @Test @MainActor func generationChangeClosesAlreadyPreparedWindowAndSafeDiagnosticsHideURLDetails() async throws {
        _ = NSApplication.shared
        let client = NativeMusicClient(providers: [OfficialFixtureProvider()], credentials: OfficialCredentialProbe())
        _ = try await client.connect(.qq, cookies: officialFixtureCookies)
        let browser = QQOfficialPlaybackBrowser { _, _ in }
        await browser.prepare(track: officialFixtureTrack(), client: client)
        #expect(!browser.permitsNavigation(to: URL(string: "https://blocked.example/private?token=synthetic-secret"), isMainFrame: false))
        #expect(browser.message?.contains("https://blocked.example") == true)
        #expect(browser.message?.contains("synthetic-secret") == false)
        #expect(browser.message?.contains("private") == false)
        let priorMessage = browser.message
        #expect(!browser.permitsNavigation(to: nil, isMainFrame: true))
        #expect(browser.message == priorMessage)
        _ = try await client.connect(.qq, cookies: officialFixtureCookies)
        for _ in 0..<100 { if browser.isClosed { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(browser.isClosed)
        #expect(browser.visibleWebView == nil)
    }
}
