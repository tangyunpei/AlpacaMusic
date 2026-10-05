import Foundation
import Testing
@testable import AlpacaMusic

struct QQMusicQRLoginTests {
    private func callback(method: QQMusicQRPolicy.Method, state: String = "fixture-state") -> URL {
        let authorization = QQMusicQRPolicy.authorizationURL(method: method, state: state)
        let redirect = URLComponents(url: authorization, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "redirect_uri" }!.value!
        var url = URLComponents(string: redirect)!
        url.queryItems! += [URLQueryItem(name: "state", value: state), URLQueryItem(name: "code", value: "fixture-code")]
        return url.url!
    }
    private func qqCookies() -> [MusicSessionCookie] {
        [MusicSessionCookie(name: "uin", value: "o0012345678", domain: ".qq.com"),
         MusicSessionCookie(name: "qqmusic_key", value: "fixture-music-key", domain: ".y.qq.com")]
    }
    @Test func officialWidgetsUseMusicOwnedCallbackAndSeparateMethods() {
        for method in QQMusicQRPolicy.Method.allCases {
            let url = QQMusicQRPolicy.authorizationURL(method: method, state: "fixture-state")
            #expect(url.scheme == "https")
            #expect(url.host == (method == .qq ? "graph.qq.com" : "open.weixin.qq.com"))
            #expect(QQMusicQRPolicy.validCallback(callback(method: method), method: method, state: "fixture-state"))
            let values = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
            #expect(values["state"] == "fixture-state")
            if method == .qq {
                #expect(values["client_id"] == "100497308")
                #expect(values["scope"] == "get_user_info,get_app_friends")
            } else {
                #expect(values["appid"] == "wx48db31d50e334801")
                #expect(values["fast_login"] == "0")
                #expect(values["scope"] == "snsapi_login")
            }
        }
    }
    @Test func callbacksCannotCrossMethodOrGeneration() {
        #expect(!QQMusicQRPolicy.validCallback(callback(method: .qq), method: .wechat, state: "fixture-state"))
        #expect(!QQMusicQRPolicy.validCallback(callback(method: .wechat), method: .qq, state: "fixture-state"))
        #expect(!QQMusicQRPolicy.validCallback(callback(method: .qq), method: .qq, state: "older-state"))
        #expect(!QQMusicQRPolicy.validCallback(callback(method: .qq), method: .qq, state: ""))
    }
    @Test func callbackRejectsUntrustedOriginsDestinationsAndDuplicateParameters() {
        let original = callback(method: .qq)
        for replacement in ["http", "file"] {
            var url = URLComponents(url: original, resolvingAgainstBaseURL: false)!
            url.scheme = replacement
            #expect(!QQMusicQRPolicy.validCallback(url.url, method: .qq, state: "fixture-state"))
        }
        for host in ["y.qq.com.attacker.example", "graph.qq.com", "localhost"] {
            var url = URLComponents(url: original, resolvingAgainstBaseURL: false)!
            url.host = host
            #expect(!QQMusicQRPolicy.validCallback(url.url, method: .qq, state: "fixture-state"))
        }
        for name in ["state", "code", "login_type", "surl"] {
            var url = URLComponents(url: original, resolvingAgainstBaseURL: false)!
            url.queryItems!.append(URLQueryItem(name: name, value: "duplicate"))
            #expect(!QQMusicQRPolicy.validCallback(url.url, method: .qq, state: "fixture-state"))
            url = URLComponents(url: original, resolvingAgainstBaseURL: false)!
            url.queryItems!.removeAll { $0.name == name }
            #expect(!QQMusicQRPolicy.validCallback(url.url, method: .qq, state: "fixture-state"))
        }
        var url = URLComponents(url: original, resolvingAgainstBaseURL: false)!
        url.queryItems!.removeAll { $0.name == "surl" }
        url.queryItems!.append(URLQueryItem(name: "surl", value: "https://example.com/"))
        #expect(!QQMusicQRPolicy.validCallback(url.url, method: .qq, state: "fixture-state"))
    }
    @Test func returnNavigationIsExactAndContainsNoSecrets() {
        #expect(QQMusicQRPolicy.isReturn(QQMusicQRPolicy.returnURL))
        for value in ["https://y.qq.com/n/ryqq/?code=fixture", "https://y.qq.com/n/ryqq/#fixture", "https://graph.qq.com/n/ryqq/", "http://y.qq.com/n/ryqq/", "https://y.qq.com:444/n/ryqq/"] {
            #expect(!QQMusicQRPolicy.isReturn(URL(string: value)))
        }
    }
    @Test func intermediateQQSignInDoesNotFinishMusicConnection() {
        let intermediate = [MusicSessionCookie(name: "uin", value: "o12345678", domain: ".qq.com"),
                            MusicSessionCookie(name: "p_skey", value: "fixture-qq-only", domain: ".qq.com"),
                            MusicSessionCookie(name: "skey", value: "fixture-qq-only", domain: ".qq.com")]
        #expect(QQMusicQRPolicy.completedCookies(intermediate, method: .qq) == nil)
        #expect(QQMusicQRPolicy.completedCookies([], method: .qq) == nil)
        #expect(QQMusicQRPolicy.completedCookies(qqCookies(), method: .qq) == qqCookies())
    }
    @Test func sessionsMustMatchChosenProviderIdentityAndUseMusicCookieScope() {
        let wechat = [MusicSessionCookie(name: "wxuin", value: "12345678901234567", domain: ".y.qq.com"),
                      MusicSessionCookie(name: "login_type", value: "2", domain: ".qq.com"),
                      MusicSessionCookie(name: "qm_keyst", value: "fixture-wechat", domain: ".y.qq.com")]
        #expect(QQMusicQRPolicy.completedCookies(wechat, method: .wechat) == wechat)
        #expect(QQMusicQRPolicy.completedCookies(wechat, method: .qq) == nil)
        #expect(QQMusicQRPolicy.completedCookies(qqCookies(), method: .wechat) == nil)
        for mutate in ["expired", "host", "path", "control"] {
            var cookies = qqCookies()
            switch mutate {
            case "expired": cookies[1].expires = .distantPast
            case "host": cookies[1].domain = "y.qq.com"
            case "path": cookies[1].path = "/not-music/"
            default: cookies[1].value = "bad;cookie"
            }
            #expect(QQMusicQRPolicy.completedCookies(cookies, method: .qq) == nil)
        }
    }
    @Test func onlyExistingFilteredMusicCookiesAreReturned() {
        let expected = qqCookies()
        let cookies = expected + [MusicSessionCookie(name: "private-other-cookie", value: "fixture", domain: ".qq.com"),
                                  MusicSessionCookie(name: "qqmusic_key", value: "unrelated", domain: ".example.com")]
        #expect(QQMusicQRPolicy.completedCookies(cookies, method: .qq) == expected)
        for id in ["0", "o000000", "12abc", "１２３４", String(repeating: "1", count: 25)] {
            var values = expected; values[0].value = id
            #expect(QQMusicQRPolicy.completedCookies(values, method: .qq) == nil)
        }
    }
    @MainActor @Test func idleAndCancelledSessionsNeverExposeAResult() async {
        let session = QQMusicQRSession()
        #expect(!session.usesPersistentStorage)
        #expect(session.visibleWebView == nil)
        do { _ = try await session.waitForCookies(); Issue.record("An idle session returned cookies") }
        catch is CancellationError { }
        catch { Issue.record("Unexpected idle error") }
        session.cancel(); session.cancel()
        #expect(session.phase == .cancelled)
        #expect(session.visibleWebView == nil)
        do { _ = try await session.waitForCookies(); Issue.record("A cancelled session returned cookies") }
        catch is CancellationError { }
        catch { Issue.record("Unexpected cancellation error") }
    }
}
