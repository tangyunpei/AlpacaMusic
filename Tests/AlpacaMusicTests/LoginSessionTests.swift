import AppKit
import Foundation
import Observation
import Security
import Synchronization
import Testing
import WebKit
@testable import AlpacaMusic

private actor RecordingMusicCredentialAccess: MusicCredentialAccess {
    var values: [MusicCredentialAccount: Data] = [:]
    var touched: [MusicCredentialAccount] = []
    func read(_ account: MusicCredentialAccount) -> Data? { touched.append(account); return values[account] }
    func write(_ data: Data, for account: MusicCredentialAccount) { touched.append(account); values[account] = data }
    func remove(_ account: MusicCredentialAccount) { touched.append(account); values.removeValue(forKey: account) }
    func setRaw(_ data: Data, for account: MusicCredentialAccount) { values[account] = data }
    func count() -> Int { touched.count }
}

@MainActor private final class LoginCommitProbe: NSObject, WKNavigationDelegate {
    let browser: DirectLoginBrowser
    var connectableAtCommit = false
    var loadingAtCommit = false
    var finished = false
    init(browser: DirectLoginBrowser) { self.browser = browser }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        await browser.webView(webView, decidePolicyFor: action)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        browser.webView(webView, didStartProvisionalNavigation: navigation)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        browser.webView(webView, didCommit: navigation)
        connectableAtCommit = browser.canConnect
        loadingAtCommit = browser.isLoading
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        browser.webView(webView, didFinish: navigation); finished = true
    }
}

@Suite(.serialized) struct LoginSessionTests {
    private let netease = MusicSessionCookie(name: "MUSIC_U", value: "test-session", domain: ".music.163.com")
    private let qq = MusicSessionCookie(name: "qqmusic_key", value: "test-qq-session", domain: ".qq.com")

    @Test func loginNavigationRequiresExactHTTPSOfficialHost() throws {
        for address in ["https://y.qq.com/", "https://xui.ptlogin2.qq.com/cgi-bin/xlogin", "https://ssl.ptlogin2.qq.com/login", "https://graph.qq.com/oauth2.0/show", "https://open.weixin.qq.com/connect/qrconnect"] {
            #expect(DirectLoginPolicy.allows(URL(string: address), source: .qq))
        }
        for address in ["http://y.qq.com/", "https://y.qq.com.evil.example/", "https://evil-y.qq.com/", "https://qq.com/", "https://mail.qq.com/", "https://user:pass@y.qq.com/", "https://y.qq.com:8443/", "file:///tmp/page.html", "javascript:alert(1)", "data:text/html,test", "mqq://login", "about:blank"] {
            #expect(!DirectLoginPolicy.allows(URL(string: address), source: .qq))
        }
        #expect(DirectLoginPolicy.allows(URL(string: "https://music.163.com/#/login"), source: .netease))
        #expect(!DirectLoginPolicy.allows(URL(string: "https://music.163.com/"), source: .qq))
        #expect(!DirectLoginPolicy.allows(URL(string: "https://y.qq.com/"), source: .netease))
        #expect(!DirectLoginPolicy.allows(nil, source: .qq))
        #expect(DirectLoginPolicy.startURL(for: .appleMusic) == nil)
    }

    @Test func emptyAndVerificationFramesCannotReplaceMainPage() {
        for address in ["about:blank", "about:srcdoc", "https://t.captcha.qq.com/cap_union_new_show"] {
            #expect(DirectLoginPolicy.allows(URL(string: address), source: .qq, isMainFrame: false))
            #expect(!DirectLoginPolicy.allows(URL(string: address), source: .qq, isMainFrame: true))
        }
        #expect(!DirectLoginPolicy.allows(URL(string: "https://example.com/login"), source: .qq, isMainFrame: false))
    }

    @Test func qqConfirmedPhoneCallbackUsesOnlyItsExactHTTPSHost() {
        let callback = URL(string: "https://ssl.ptlogin2.graph.qq.com/check_sig?uin=fixture&ptsigx=fixture")
        #expect(DirectLoginPolicy.allows(callback, source: .qq, isMainFrame: false))
        #expect(DirectLoginPolicy.allows(callback, source: .qq, isMainFrame: true))
        #expect(!DirectLoginPolicy.allows(callback, source: .netease, isMainFrame: false))
        #expect(!DirectLoginPolicy.allows(callback, source: .netease, isMainFrame: true))
        for address in ["http://ssl.ptlogin2.graph.qq.com/check_sig", "https://ssl.ptlogin2.graph.qq.com.evil.example/check_sig", "https://evil-ssl.ptlogin2.graph.qq.com/check_sig", "https://ptlogin2.graph.qq.com/check_sig", "https://ssl.ptlogin2.graph.qq.com:8443/check_sig", "https://user:pass@ssl.ptlogin2.graph.qq.com/check_sig"] {
            #expect(!DirectLoginPolicy.allows(URL(string: address), source: .qq, isMainFrame: false))
        }
    }

    @Test func navigationDiagnosticsNeverRevealCallbackSecrets() {
        let address = URL(string: "https://private-user:private-pass@callback.example:8443/private-path?code=private-code#private-fragment")
        #expect(DirectLoginPolicy.safeOrigin(of: address) == "https://callback.example")
        #expect(DirectLoginPolicy.safeOrigin(of: URL(string: "file:///private/path?secret=value")) == "file（无可显示主机）")
        #expect(DirectLoginPolicy.safeOrigin(of: URL(string: "javascript:privateCode()")) == "javascript（无可显示主机）")
        #expect(DirectLoginPolicy.safeOrigin(of: nil) == "未知协议 / 主机")
    }

    @Test @MainActor func deniedSubframeNavigationPublishesAnObservableSafeDiagnostic() async {
        _ = NSApplication.shared
        let browser = DirectLoginBrowser(source: .qq)
        let changed = Mutex(false)
        withObservationTracking { _ = browser.message } onChange: { changed.withLock { $0 = true } }
        let callback = URL(string: "https://blocked.example/private-callback?code=secret&uin=fixture#sensitive")
        #expect(!browser.permitsNavigation(to: callback, isMainFrame: false))
        #expect(browser.message?.contains("子页面") == true)
        #expect(browser.message?.contains("https://blocked.example") == true)
        #expect(browser.message?.contains("secret") == false)
        #expect(browser.message?.contains("fixture") == false)
        #expect(browser.message?.contains("private-callback") == false)
        #expect(changed.withLock { $0 })
        #expect(browser.permitsNavigation(to: URL(string: "https://graph.qq.com/oauth2.0/login_jump"), isMainFrame: false))
        await browser.invalidate()?.value
        #expect(!browser.permitsNavigation(to: URL(string: "https://y.qq.com/"), isMainFrame: true))
    }

    @Test func keychainQueriesNameOnlyThisApplicationsThreeEntries() {
        #expect(MusicCredentialAccount.allCases.count == 3)
        for account in MusicCredentialAccount.allCases {
            let query = KeychainMusicCredentialAccess.query(for: account)
            #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            #expect(query[kSecAttrService as String] as? String == "dev.byalpaca.music.direct-session.v1")
            #expect(query[kSecAttrAccount as String] as? String == account.rawValue)
            #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
            #expect(query[kSecAttrAccessGroup as String] == nil)
        }
    }

    @Test func qqWebsiteStateMarkerIsRetainedOnlyWhenActuallyProvided() async throws {
        let access = RecordingMusicCredentialAccess()
        let store = MusicCredentialStore(access: access)
        let marker = MusicSessionCookie(name: "music_ignore_pskey", value: "synthetic-site-value", domain: ".y.qq.com", path: "/", expires: Date().addingTimeInterval(600))
        try await store.save([qq, marker, .init(name: marker.name, value: "wrong-host", domain: ".example.com"), .init(name: marker.name, value: "expired", domain: ".y.qq.com", expires: .distantPast)], for: .qq)
        #expect(try await store.load(for: .qq) == [qq, marker])
        try await store.save([qq], for: .qq)
        #expect(try await store.load(for: .qq) == [qq])
        #expect(DirectMusicAccess.sessionCookies([marker], for: .netease).isEmpty)
    }

    @Test func memoryCredentialStoreKeepsSourcesSeparateAndDeletesIdempotently() async throws {
        let store = MemoryMusicCredentialStore()
        #expect(try await store.load(for: .netease).isEmpty)
        try await store.save([netease], for: .netease)
        try await store.save([qq], for: .qq)
        #expect(try await store.load(for: .netease) == [netease])
        #expect(try await store.load(for: .qq) == [qq])
        try await store.delete(for: .netease)
        try await store.delete(for: .netease)
        #expect(try await store.load(for: .netease).isEmpty)
        #expect(try await store.load(for: .qq) == [qq])
    }

    @Test func credentialsNeverPersistUnrelatedOrExpiredCookies() async throws {
        let access = RecordingMusicCredentialAccess()
        let store = MusicCredentialStore(access: access)
        let cookies = [netease,
                       MusicSessionCookie(name: "password", value: "never-store", domain: ".music.163.com"),
                       MusicSessionCookie(name: "MUSIC_U", value: "unrelated", domain: ".evil.example"),
                       MusicSessionCookie(name: "__csrf", value: "expired", domain: ".music.163.com", expires: .distantPast),
                       qq]
        try await store.save(cookies, for: .netease)
        let data = try #require(await access.read(.netease))
        #expect(try JSONDecoder().decode([MusicSessionCookie].self, from: data) == [netease])
        #expect(try await store.load(for: .qq).isEmpty)
        let otherQQService = MusicSessionCookie(name: "skey", value: "not-music", domain: ".mail.qq.com")
        #expect(DirectMusicAccess.sessionCookies([otherQQService], for: .qq).isEmpty)
    }

    @Test func unsupportedSourceNeverTouchesCredentialBackend() async {
        let access = RecordingMusicCredentialAccess()
        let store = MusicCredentialStore(access: access)
        for source in [MusicSource.local, .appleMusic, .url, .demo] {
            do { _ = try await store.load(for: source); Issue.record("Unsupported load succeeded") } catch { }
            do { try await store.save([netease], for: source); Issue.record("Unsupported save succeeded") } catch { }
            do { try await store.delete(for: source); Issue.record("Unsupported delete succeeded") } catch { }
        }
        #expect(await access.count() == 0)
    }

    @Test func invalidReplacementPreservesPreviouslyVerifiedSession() async throws {
        let store = MemoryMusicCredentialStore()
        try await store.save([netease], for: .netease)
        do { try await store.save([], for: .netease); Issue.record("Empty replacement succeeded") } catch { }
        let large = MusicSessionCookie(name: "MUSIC_U", value: String(repeating: "x", count: 16_000), domain: ".music.163.com")
        do { try await store.save(Array(repeating: large, count: 10), for: .netease); Issue.record("Oversize replacement succeeded") } catch { }
        #expect(try await store.load(for: .netease) == [netease])
    }

    @Test func corruptStoredDataFailsWithoutExposingContents() async {
        let access = RecordingMusicCredentialAccess()
        let secret = "private-session-fixture"
        await access.setRaw(Data(secret.utf8), for: .netease)
        let store = MusicCredentialStore(access: access)
        do { _ = try await store.load(for: .netease); Issue.record("Corrupt session loaded") }
        catch { #expect(!error.localizedDescription.contains(secret)) }
    }

    @Test @MainActor func loginBrowsersUseIndependentTemporaryCookiesAndClearOnClose() async throws {
        _ = NSApplication.shared
        let first = DirectLoginBrowser(source: .netease)
        let second = DirectLoginBrowser(source: .netease)
        let firstView = try #require(first.mainWebView)
        #expect(firstView.pageZoom == 0.8)
        let store = firstView.configuration.websiteDataStore
        #expect(!first.usesPersistentStorage)
        #expect(!second.usesPersistentStorage)
        let cookie = try #require(HTTPCookie(properties: [.name: "MUSIC_U", .value: "ephemeral-test", .domain: ".music.163.com", .path: "/", .secure: "TRUE"]))
        await store.httpCookieStore.setCookie(cookie)
        #expect(await first.sessionCookies().map(\.value) == ["ephemeral-test"])
        #expect(await second.sessionCookies().isEmpty)
        let cleanup = first.invalidate()
        #expect(first.isClosed && !first.canConnect)
        #expect(first.mainWebView == nil && first.popupWebView == nil)
        #expect(await first.sessionCookies().isEmpty)
        await cleanup?.value
        #expect(await store.httpCookieStore.allCookies().isEmpty)
        await second.invalidate()?.value
    }

    @Test @MainActor func committedOfficialPageCanConnectBeforeSubresourcesFinish() async throws {
        _ = NSApplication.shared
        let browser = DirectLoginBrowser(source: .netease)
        let view = try #require(browser.mainWebView)
        let probe = LoginCommitProbe(browser: browser)
        view.navigationDelegate = probe
        #expect(!browser.canConnect)
        let connectabilityChanged = Mutex(false)
        // Track the exact derived value used by SwiftUI's button. A direct read
        // alone misses @ObservationIgnored state that leaves the button disabled.
        withObservationTracking {
            _ = browser.canConnect
        } onChange: {
            connectabilityChanged.withLock { $0 = true }
        }
        // WebKit generates real navigation callbacks from this offline response.
        // No platform request, login, or user cookie is involved.
        view.loadSimulatedRequest(URLRequest(url: try #require(DirectLoginPolicy.startURL(for: .netease))),
                                  responseHTML: "<!doctype html><title>Offline login layout test</title><p>Ready</p>")
        for _ in 0..<150 {
            if probe.finished { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(probe.finished)
        #expect(probe.connectableAtCommit)
        #expect(probe.loadingAtCommit)
        #expect(browser.canConnect)
        #expect(connectabilityChanged.withLock { $0 })
        await browser.invalidate()?.value
        #expect(!browser.canConnect)
    }
}
