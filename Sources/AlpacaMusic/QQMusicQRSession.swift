import AppKit
import Foundation
import Observation
import WebKit

/// Protocol constants read from QQ Music's own login component. The hosted
/// widgets retain their authorization UI and exchange their code on y.qq.com;
/// AlpacaMusic never implements QQ passwords or trades the code itself.
enum QQMusicQRPolicy {
    enum Method: String, CaseIterable, Identifiable, Sendable {
        case qq, wechat
        var id: String { rawValue }
        var title: String { self == .qq ? "QQ 扫码" : "微信扫码" }
    }
    static let returnURL = URL(string: "https://y.qq.com/n/ryqq/")!
    static let callbackPath = "/portal/wx_redirect.html"

    static func authorizationURL(method: Method, state: String) -> URL {
        var callback = URLComponents(string: "https://y.qq.com\(callbackPath)")!
        callback.queryItems = [URLQueryItem(name: "login_type", value: method == .qq ? "1" : "2"),
                               URLQueryItem(name: "surl", value: returnURL.absoluteString)]
        var url: URLComponents
        switch method {
        case .qq:
            url = URLComponents(string: "https://graph.qq.com/oauth2.0/authorize")!
            url.queryItems = [URLQueryItem(name: "response_type", value: "code"),
                              URLQueryItem(name: "client_id", value: "100497308"),
                              URLQueryItem(name: "redirect_uri", value: callback.url!.absoluteString),
                              URLQueryItem(name: "state", value: state),
                              URLQueryItem(name: "display", value: "pc"),
                              URLQueryItem(name: "scope", value: "get_user_info,get_app_friends")]
        case .wechat:
            url = URLComponents(string: "https://open.weixin.qq.com/connect/qrconnect")!
            url.queryItems = [URLQueryItem(name: "appid", value: "wx48db31d50e334801"),
                              URLQueryItem(name: "redirect_uri", value: callback.url!.absoluteString),
                              URLQueryItem(name: "response_type", value: "code"),
                              URLQueryItem(name: "scope", value: "snsapi_login"),
                              URLQueryItem(name: "state", value: state),
                              URLQueryItem(name: "href", value: "https://y.qq.com/mediastyle/music_v17/src/css/popup_wechat.css#wechat_redirect"),
                              // Explicit QR flow, not probing a running WeChat client.
                              URLQueryItem(name: "fast_login", value: "0")]
        }
        return url.url!
    }
    static func isCallback(_ url: URL?) -> Bool {
        url?.host?.lowercased() == "y.qq.com" && url?.path == callbackPath
    }
    static func validCallback(_ url: URL?, method: Method, state: String) -> Bool {
        guard isCallback(url), DirectLoginPolicy.allows(url, source: .qq),
              let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        func one(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            return matches.count == 1 ? matches[0].value : nil
        }
        guard !state.isEmpty, one("state") == state,
              one("login_type") == (method == .qq ? "1" : "2"),
              one("surl") == returnURL.absoluteString,
              let code = one("code"), !code.isEmpty, code.utf8.count <= 4096 else { return false }
        return !code.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
    static func isReturn(_ url: URL?) -> Bool {
        guard let url, DirectLoginPolicy.allows(url, source: .qq), url.host?.lowercased() == "y.qq.com" else { return false }
        return url.path == returnURL.path && url.query == nil && url.fragment == nil
    }
    /// An intermediate QQ/WeChat authentication cookie is insufficient. Wait for
    /// the official callback to set a music ticket usable by our API provider.
    static func completedCookies(_ cookies: [MusicSessionCookie], method: Method) -> [MusicSessionCookie]? {
        let filtered = DirectMusicAccess.sessionCookies(cookies, for: .qq)
        let endpoint = URL(string: "https://u.y.qq.com/cgi-bin/musics.fcg")!
        let usable = filtered.filter { $0.matches(endpoint) }.sorted { $0.path.count > $1.path.count }
        func value(_ name: String) -> String? {
            guard let raw = usable.first(where: { $0.name == name && !$0.value.isEmpty })?.value else { return nil }
            var value = raw
            for _ in 0..<8 {
                guard let next = value.removingPercentEncoding else { return nil }
                if next == value { return value }
                value = next
            }
            return nil
        }
        guard ["qqmusic_key", "qm_keyst", "music_key", "wxskey"].contains(where: { value($0) != nil }) else { return nil }
        let raw: String?
        switch method {
        case .qq:
            guard value("login_type") != "2", value("wxopenid") == nil else { return nil }
            raw = value("uin") ?? value("qqmusic_uin") ?? value("p_uin")
        case .wechat:
            guard value("login_type") == "2" || value("wxopenid") != nil else { return nil }
            raw = value("wxuin") ?? value("qqmusic_uin")
        }
        guard let raw else { return nil }
        let digits = raw.hasPrefix("o") && method == .qq ? raw.dropFirst() : Substring(raw)
        guard !digits.isEmpty, digits.count <= 24,
              digits.utf8.allSatisfy({ (48...57).contains($0) }), digits.contains(where: { $0 != "0" }) else { return nil }
        return filtered
    }
}

@MainActor @Observable
final class QQMusicQRSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    typealias Method = QQMusicQRPolicy.Method
    enum Phase: Equatable { case loading, waiting, exchanging, ready, failed, cancelled }
    private(set) var phase: Phase = .cancelled
    private(set) var method: Method = .qq
    private(set) var message: String?
    private(set) var isLoading = false
    private(set) var mainWebView: WKWebView?
    private(set) var popupWebView: WKWebView?
    var visibleWebView: WKWebView? { popupWebView ?? mainWebView }
    var usesPersistentStorage: Bool { websiteDataStore?.isPersistent ?? false }
    @ObservationIgnored private var websiteDataStore: WKWebsiteDataStore?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var callbackState = ""
    @ObservationIgnored private var callbackAccepted = false
    @ObservationIgnored private var exchangeStarted: ContinuousClock.Instant?

    func start(method: Method = .qq) {
        cleanUp()
        self.method = method
        generation = UUID(); callbackState = UUID().uuidString
        callbackAccepted = false; exchangeStarted = nil; message = nil; phase = .loading; isLoading = true
        let store = WKWebsiteDataStore.nonPersistent()
        websiteDataStore = store
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        configure(webView); mainWebView = webView
        webView.load(URLRequest(url: QQMusicQRPolicy.authorizationURL(method: method, state: callbackState)))
    }
    func refresh() { start(method: method) }
    func cancel() {
        generation = UUID(); callbackState = ""; callbackAccepted = false; exchangeStarted = nil
        phase = .cancelled; isLoading = false; message = nil
        cleanUp()
    }
    func waitForCookies() async throws -> [MusicSessionCookie] {
        let current = generation
        guard let store = websiteDataStore else { throw CancellationError() }
        let start = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            guard current == generation, phase != .cancelled else { throw CancellationError() }
            if phase == .failed { throw MusicError.message(message ?? "QQ 音乐扫码登录未完成，请刷新二维码重试。") }
            let cookies = await store.httpCookieStore.allCookies()
            try Task.checkCancellation()
            guard current == generation, phase != .cancelled else { throw CancellationError() }
            if phase == .failed { throw MusicError.message(message ?? "QQ 音乐扫码登录未完成，请刷新二维码重试。") }
            if callbackAccepted, phase == .exchanging || phase == .ready, let completed = QQMusicQRPolicy.completedCookies(cookies.map(MusicSessionCookie.init), method: method) {
                phase = .ready; isLoading = false
                // Leave temporary storage alive until the caller validates the
                // account, then cancel/onDisappear removes it.
                return completed
            }
            if let exchangeStarted, exchangeStarted.duration(to: .now) >= .seconds(30) {
                fail("手机确认后，QQ 音乐未能完成账号连接，请刷新二维码重试。")
                throw MusicError.message(message!)
            }
            guard start.duration(to: .now) < .seconds(600) else {
                fail("二维码已等待较久，请刷新后重新扫码。")
                throw MusicError.message(message!)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }
    private func configure(_ webView: WKWebView) {
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.isInspectable = false
        webView.allowsBackForwardNavigationGestures = false
        // QQ's official panel is 700 CSS pixels wide, including the scope
        // controls. Keep those controls visible rather than cropping them out.
        webView.pageZoom = method == .qq ? 0.84 : 1
    }
    private func cleanUp() {
        for webView in [mainWebView, popupWebView].compactMap({ $0 }) {
            webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil
        }
        mainWebView = nil; popupWebView = nil
        let store = websiteDataStore; websiteDataStore = nil
        if let store {
            Task { @MainActor in
                await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            }
        }
    }
    private func fail(_ text: String) {
        guard phase != .cancelled, phase != .ready else { return }
        phase = .failed; isLoading = false; message = text
    }
    private func permits(_ url: URL?, mainFrame: Bool) -> Bool {
        guard phase != .cancelled, phase != .failed else { return false }
        guard DirectLoginPolicy.allows(url, source: .qq, isMainFrame: mainFrame) else {
            // A blocked auxiliary link must not discard a usable QR session.
            message = "此链接不属于扫码登录流程，请继续扫码或刷新二维码。"
            return false
        }
        if QQMusicQRPolicy.isCallback(url) {
            guard QQMusicQRPolicy.validCallback(url, method: method, state: callbackState) else {
                fail("登录确认与当前二维码不匹配，请刷新二维码重试。")
                return false
            }
            if !callbackAccepted { exchangeStarted = .now }
            callbackAccepted = true; phase = .exchanging; isLoading = true
        }
        if mainFrame && QQMusicQRPolicy.isReturn(url) {
            // The official callback has already exchanged the code and set
            // cookies. Keep this compact surface from navigating to the home.
            if callbackAccepted { phase = .exchanging; isLoading = true }
            else { fail("QQ 音乐未返回本次扫码的确认，请刷新二维码重试。") }
            return false
        }
        return true
    }
    private func isActive(_ webView: WKWebView) -> Bool {
        webView === mainWebView || webView === popupWebView
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard isActive(webView) else { return .cancel }
        return permits(navigationAction.request.url, mainFrame: navigationAction.targetFrame?.isMainFrame ?? true) ? .allow : .cancel
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard isActive(webView), permits(navigationResponse.response.url, mainFrame: navigationResponse.isForMainFrame) else { return .cancel }
        guard navigationResponse.canShowMIMEType else {
            fail("官方扫码页面返回了无法显示的内容，请刷新二维码。")
            return .cancel
        }
        if let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            fail("官方扫码页面暂时无法载入（HTTP \(response.statusCode)），请稍后刷新。")
            return .cancel
        }
        return .allow
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isActive(webView), phase == .loading || phase == .waiting else { return }
        phase = .waiting; isLoading = false
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { if isActive(webView) { failedNavigation(error) } }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { if isActive(webView) { failedNavigation(error) } }
    private func failedNavigation(_ error: any Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        fail("官方扫码页面暂时无法载入，请检查网络后刷新二维码。")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard isActive(webView) else { return }
        fail("扫码页面已停止，请刷新二维码。")
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard isActive(webView), popupWebView == nil, let store = websiteDataStore,
              permits(navigationAction.request.url, mainFrame: true) else { return nil }
        configuration.websiteDataStore = store
        let popup = WKWebView(frame: .zero, configuration: configuration)
        configure(popup); popupWebView = popup
        return popup
    }
    func webViewDidClose(_ webView: WKWebView) {
        guard webView === popupWebView else { return }
        webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil
        popupWebView = nil
    }
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision { .deny }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        completionHandler(nil)
    }
}
