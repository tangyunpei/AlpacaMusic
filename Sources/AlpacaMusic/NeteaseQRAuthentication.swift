import Foundation
import Observation
import WebKit

/// The QR code and any 8821 verification are owned by the current official
/// CtWebLogin component, in a fresh, real music.163.com browsing context.
/// No native code creates device tokens, captcha answers or login cookies.
@MainActor @Observable
final class NeteaseQRAuthentication: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var isLoading = false
    private(set) var message: String?
    private(set) var mainWebView: WKWebView?
    private(set) var popupWebView: WKWebView?
    var visibleWebView: WKWebView? { popupWebView ?? mainWebView }

    private enum Phase { case idle, loading, ready, completed, failed, cancelled }
    @ObservationIgnored private var phase = Phase.idle
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var navigationTimeout: Task<Void, Never>?
    @ObservationIgnored private var terminalFailure: MusicError?
    @ObservationIgnored private var failedAttempt: UUID?
    @ObservationIgnored private var pending: [UUID: @MainActor (Error) -> Void] = [:]
    @ObservationIgnored private var timeouts: [UUID: Task<Void, Never>] = [:]
    private static let origin = URL(string: "https://music.163.com/")!
    private static let accountURL = URL(string: "https://music.163.com/weapi/w/nuser/account/get")!

    func start() {
        cancel()
        message = nil; terminalFailure = nil; failedAttempt = nil; phase = .loading; isLoading = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        configure(view); mainWebView = view
        let attempt = generation
        navigationTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(35)) } catch { return }
            guard let self, self.generation == attempt, self.phase == .loading else { return }
            self.fail(L10n.string("网易云官方扫码组件加载超时，请重新载入或使用网页登录。"))
        }
        view.load(URLRequest(url: Self.origin, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25))
    }

    private func configure(_ view: WKWebView) {
        view.navigationDelegate = self; view.uiDelegate = self
        view.isInspectable = false; view.pageZoom = 1
        view.allowsBackForwardNavigationGestures = false
    }

    /// The official success callback is only a signal. A real MUSIC_U cookie
    /// from this attempt is also required; the caller must then validate the
    /// account through the provider before saving or replacing any session.
    func waitForCookies() async throws -> [MusicSessionCookie] {
        let attempt = generation
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        var cookieDeadline: ContinuousClock.Instant?
        do {
            while ContinuousClock.now < deadline {
                try ensureActive(attempt)
                if phase == .ready {
                    let state = try await script(Self.statusScript, attempt: attempt)
                    guard state["ok"] as? Bool == true else {
                        throw MusicError.message(L10n.string("网易云官方扫码页面已变化，请重新载入或使用网页登录。"))
                    }
                    if state["succeeded"] as? Bool == true {
                        if cookieDeadline == nil { cookieDeadline = .now.advanced(by: .seconds(10)) }
                        let cookies = try await snapshotCookies(attempt: attempt)
                        try ensureActive(attempt)
                        if let session = Self.confirmedSession(cookies, signalled: true) {
                            phase = .completed
                            return session
                        }
                        if let cookieDeadline, .now >= cookieDeadline {
                            throw MusicError.message(L10n.string("网易云已确认扫码，但未返回有效登录会话，请重新载入或使用网页登录。"))
                        }
                    }
                }
                try await Task.sleep(for: .milliseconds(350))
            }
            throw MusicError.message(L10n.string("网易云登录等待已超时，请重新载入。"))
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if failedAttempt == attempt, let terminalFailure { throw terminalFailure }
            if generation != attempt { throw CancellationError() }
            if let failure = error as? MusicError { fail(failure.localizedDescription) }
            throw error
        }
    }

    static func confirmedSession(_ cookies: [MusicSessionCookie], signalled: Bool, now: Date = Date()) -> [MusicSessionCookie]? {
        guard signalled else { return nil }
        let session = DirectMusicAccess.sessionCookies(cookies, for: .netease).filter {
            $0.expires.map { $0 > now } ?? true
        }
        guard session.contains(where: { $0.name == "MUSIC_U" && !$0.value.isEmpty && $0.matches(accountURL, now: now) }) else { return nil }
        return session
    }

    func cancel() {
        terminalFailure = nil; failedAttempt = nil
        close(with: CancellationError(), phase: .cancelled)
    }

    private func fail(_ text: String) {
        let error = MusicError.message(text)
        terminalFailure = error; failedAttempt = generation; message = text
        close(with: error, phase: .failed)
    }

    private func close(with error: Error, phase: Phase) {
        generation = UUID(); self.phase = phase; isLoading = false
        bootstrapTask?.cancel(); bootstrapTask = nil
        navigationTimeout?.cancel(); navigationTimeout = nil
        let rejections = Array(pending.values); pending.removeAll()
        timeouts.values.forEach { $0.cancel() }; timeouts.removeAll()
        rejections.forEach { $0(error) }
        let store = mainWebView?.configuration.websiteDataStore
        for view in [mainWebView, popupWebView].compactMap({ $0 }) {
            view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
            view.load(URLRequest(url: URL(string: "about:blank")!))
            view.removeFromSuperview()
        }
        mainWebView = nil; popupWebView = nil
        store?.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast, completionHandler: {})
    }

    private func ensureActive(_ attempt: UUID) throws {
        try Task.checkCancellation()
        if failedAttempt == attempt, let terminalFailure { throw terminalFailure }
        guard generation == attempt, [.loading, .ready].contains(phase), mainWebView != nil else { throw CancellationError() }
    }

    static func isRoot(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.host?.lowercased() == "music.163.com",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.query == nil, let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return false }
        return path.isEmpty || path == "/"
    }

    static func allows(_ url: URL?, main: Bool, popup: Bool = false) -> Bool {
        if main && !popup { return isRoot(url) }
        return DirectLoginPolicy.allows(url, source: .netease, isMainFrame: main)
    }

    private func owns(_ view: WKWebView) -> Bool {
        [.loading, .ready].contains(phase) && (view === mainWebView || view === popupWebView)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard owns(webView) else { return .cancel }
        let main = navigationAction.targetFrame?.isMainFrame ?? true
        return Self.allows(navigationAction.request.url, main: main, popup: webView === popupWebView || navigationAction.targetFrame == nil) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard owns(webView), Self.allows(navigationResponse.response.url, main: navigationResponse.isForMainFrame, popup: webView === popupWebView),
              navigationResponse.canShowMIMEType else { return .cancel }
        if webView === mainWebView && navigationResponse.isForMainFrame {
            guard let response = navigationResponse.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode), response.mimeType == "text/html" else {
                fail(L10n.string("网易云官方扫码页面暂时无法载入，请稍后重试。"))
                return .cancel
            }
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === mainWebView, phase == .loading, bootstrapTask == nil, Self.isRoot(webView.url) else { return }
        let attempt = generation
        bootstrapTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // The homepage itself downloads the current component through
                // user#webLoginJSLink. Never pin a copied/minified SDK or fake an
                // official origin with loadHTMLString.
                while self.generation == attempt && self.phase == .loading {
                    let state = try await self.script(Self.mountScript, attempt: attempt)
                    if state["ready"] as? Bool == true {
                        self.phase = .ready; self.isLoading = false
                        self.navigationTimeout?.cancel(); self.navigationTimeout = nil
                        return
                    }
                    guard state["ok"] as? Bool == true else { throw MusicError.message(L10n.string("网易云官方扫码组件无法启动，请使用网页登录。")) }
                    try await Task.sleep(for: .milliseconds(250))
                }
            } catch {
                guard self.generation == attempt, !(error is CancellationError) else { return }
                self.fail(L10n.string("网易云官方扫码组件无法载入，请检查网络后重试或使用网页登录。"))
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(webView, error) }
    private func navigationFailed(_ view: WKWebView, _ error: Error) {
        guard owns(view), view === mainWebView, (error as NSError).code != NSURLErrorCancelled else { return }
        fail(L10n.string("网易云官方扫码页面无法载入，请检查网络后重试。"))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard owns(webView) else { return }
        fail(L10n.string("网易云扫码页面已停止，请重新载入。"))
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard owns(webView), popupWebView == nil, let store = mainWebView?.configuration.websiteDataStore,
              Self.allows(navigationAction.request.url, main: true, popup: true) else { return nil }
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
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) { completionHandler(nil) }

    private func register(_ id: UUID, reject: @escaping @MainActor (Error) -> Void) {
        pending[id] = reject
        timeouts[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard let self, let reject = self.pending[id], self.finish(id) else { return }
            reject(MusicError.message(L10n.string("网易云扫码页面响应超时，请重新载入。")))
        }
    }
    private func finish(_ id: UUID) -> Bool {
        guard pending.removeValue(forKey: id) != nil else { return false }
        timeouts.removeValue(forKey: id)?.cancel()
        return true
    }
    private func script(_ body: String, attempt: UUID) async throws -> [String: Any] {
        try ensureActive(attempt)
        guard let view = mainWebView, Self.isRoot(view.url) else { throw MusicError.message(L10n.string("网易云扫码页面地址已变化，请重新载入。")) }
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let id = UUID()
                register(id) { continuation.resume(throwing: $0) }
                view.callAsyncJavaScript(body, arguments: ["attempt": attempt.uuidString], in: nil, in: .page) { [weak self, weak view] result in
                    guard let self, self.finish(id) else { return }
                    guard self.generation == attempt, view === self.mainWebView, Self.isRoot(view?.url) else { continuation.resume(throwing: CancellationError()); return }
                    switch result {
                    case .success(let value):
                        guard let object = value as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 4096 else {
                            continuation.resume(throwing: MusicError.message(L10n.string("网易云扫码组件返回了无效状态。"))); return
                        }
                        continuation.resume(returning: data)
                    case .failure:
                        continuation.resume(throwing: MusicError.message(L10n.string("网易云扫码组件未能响应，请重新载入。")))
                    }
                }
            }
        } onCancel: { [weak self] in Task { @MainActor in if self?.generation == attempt { self?.cancel() } } }
        try ensureActive(attempt)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    private func snapshotCookies(attempt: UUID) async throws -> [MusicSessionCookie] {
        try ensureActive(attempt)
        guard let store = mainWebView?.configuration.websiteDataStore.httpCookieStore else { throw CancellationError() }
        let cookies: [MusicSessionCookie] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let id = UUID()
                register(id) { continuation.resume(throwing: $0) }
                store.getAllCookies { [weak self] values in
                    guard let self, self.finish(id) else { return }
                    guard self.generation == attempt else { continuation.resume(throwing: CancellationError()); return }
                    continuation.resume(returning: DirectMusicAccess.sessionCookies(values.map(MusicSessionCookie.init), for: .netease))
                }
            }
        } onCancel: { [weak self] in Task { @MainActor in if self?.generation == attempt { self?.cancel() } } }
        try ensureActive(attempt)
        return cookies
    }

    // Hide only pre-existing homepage content, before mounting the component.
    // New official CAPTCHA, consent and safety dialogs remain visible; neither
    // their state nor their verification result is inspected or synthesized.
    static let mountScript = #"""
    if (location.origin !== 'https://music.163.com' || location.pathname !== '/' || window.top !== window || document.contentType !== 'text/html') return {ok:false};
    if (!document.body || typeof window.CtWebLogin?.LoginModal !== 'function') return {ok:true,ready:false};
    if (window.__alpacaNeteaseLogin) return {ok:window.__alpacaNeteaseLogin.attempt === attempt,ready:window.__alpacaNeteaseLogin.attempt === attempt};
    const state = {attempt,succeeded:false};
    window.__alpacaNeteaseLogin = state;
    const children = Array.from(document.body.children);
    for (const child of children) {if (!['SCRIPT','STYLE','LINK'].includes(child.tagName)) child.style.display = 'none';}
    document.documentElement.style.minWidth = '0';
    document.body.style.minWidth = '0';
    document.body.style.margin = '0';
    document.body.style.background = '#fff';
    const root = document.createElement('div');
    root.id = 'alpaca-official-netease-login';
    root.style.cssText = 'width:100%;min-height:480px;display:flex;align-items:center;justify-content:center;background:#fff;';
    document.body.appendChild(root);
    try {
      window.CtWebLogin.LoginModal({parentNode:root,type:'page',onSuccess:() => {
        if (window.__alpacaNeteaseLogin === state && state.attempt === attempt) state.succeeded = true;
      }});
    } catch (_) {return {ok:false};}
    return {ok:true,ready:true};
    """#

    static let statusScript = #"""
    if (location.origin !== 'https://music.163.com' || location.pathname !== '/' || window.top !== window || document.contentType !== 'text/html') return {ok:false};
    const state = window.__alpacaNeteaseLogin;
    if (!state || state.attempt !== attempt) return {ok:false};
    return {ok:true,succeeded:state.succeeded === true};
    """#
}
