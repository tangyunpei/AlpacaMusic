import SwiftUI
import WebKit
import Observation

enum QQOfficialPlaybackPolicy {
    static func detailURL(for track: Track) -> URL? {
        guard track.source == .qq, let mid = track.sourceID,
              (1...64).contains(mid.utf8.count),
              mid.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        return URL(string: "https://y.qq.com/n/ryqq_v2/songDetail/\(mid)")
    }
    static func allows(_ url: URL?, isMainFrame: Bool = true) -> Bool {
        DirectLoginPolicy.allows(url, source: .qq, isMainFrame: isMainFrame)
    }
    static func webCookie(_ cookie: MusicSessionCookie) -> HTTPCookie? {
        guard cookie.path.hasPrefix("/"), DirectMusicAccess.sessionCookies([cookie], for: .qq).count == 1,
              !cookie.path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              !cookie.value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0.value == 0x3B }) else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [.name: cookie.name, .value: cookie.value, .domain: cookie.domain, .path: cookie.path]
        if cookie.secure { properties[.secure] = "TRUE" }
        if let expires = cookie.expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)
    }
}

@MainActor
struct QQOfficialPlaybackView: View {
    @Environment(\.appPalette) private var palette
    let track: Track
    let client: NativeMusicClient
    @Environment(\.dismiss) private var dismiss
    @State private var browser = QQOfficialPlaybackBrowser()
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("QQ 官网播放 · \(track.title)")).font(.title3.weight(.semibold))
                    Text(L10n.string("官网可能需要再次登录。"))
                        .font(.callout).foregroundStyle(palette.secondary)
                }
                Spacer()
                Button(L10n.string("关闭")) { browser.invalidate(); dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "lock.shield").foregroundStyle(palette.secondary)
                Text(browser.displayHost).font(.callout.monospaced())
                if browser.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                if browser.hasPopup { Button(L10n.string("返回歌曲页面")) { browser.closePopup() } }
                Button(L10n.string("重新载入")) { browser.reload() }.disabled(browser.isClosed || !browser.hasLoadedPage)
            }.padding(.horizontal, 20).padding(.vertical, 10)
            if let message = browser.message {
                Text(message).font(.callout).foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 10)
                    .accessibilityIdentifier("qqOfficialPlaybackMessage")
            }
            if let webView = browser.visibleWebView {
                QQOfficialWebView(webView: webView).id(ObjectIdentifier(webView))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(L10n.string("官网窗口已停止"), systemImage: "globe", description: Text(L10n.string("请关闭后从播放提示重新打开。")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            Text(L10n.string("在官网确认账号并播放；此窗口不会切换应用中的账号。"))
                .font(.caption).foregroundStyle(palette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        .frame(minWidth: 960, minHeight: 660)
        .background(palette.panel).foregroundStyle(palette.text)
        .task { await browser.prepare(track: track, client: client) }
        .onDisappear { browser.invalidate() }
    }
}

@MainActor private struct QQOfficialWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) { }
}

@MainActor @Observable
final class QQOfficialPlaybackBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var isClosed = false
    private(set) var isLoading = false
    private(set) var hasLoadedPage = false
    private(set) var message: String?
    private(set) var displayHost = "y.qq.com"
    private(set) var mainWebView: WKWebView?
    private(set) var popupWebView: WKWebView?
    @ObservationIgnored private let websiteDataStore: WKWebsiteDataStore
    @ObservationIgnored private let loadPage: @MainActor (WKWebView, URL) -> Void
    @ObservationIgnored private var invalidationTask: Task<Void, Never>?
    @ObservationIgnored private var lease: (client: NativeMusicClient, id: UUID)?
    private var preparing = false
    var visibleWebView: WKWebView? { popupWebView ?? mainWebView }
    var hasPopup: Bool { popupWebView != nil }
    var usesPersistentStorage: Bool { websiteDataStore.isPersistent }

    init(loadPage: @escaping @MainActor (WKWebView, URL) -> Void = { view, url in view.load(URLRequest(url: url)) }) {
        websiteDataStore = .nonPersistent()
        self.loadPage = loadPage
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // The user opened a dedicated player; async website audio startup must
        // not depend on retaining the original click across network requests.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        configure(view); mainWebView = view
    }
    private func configure(_ view: WKWebView) {
        view.navigationDelegate = self; view.uiDelegate = self
        view.isInspectable = false; view.pageZoom = 0.8
        view.allowsBackForwardNavigationGestures = false
    }
    func prepare(track: Track, client: NativeMusicClient) async {
        guard !isClosed, !preparing, !hasLoadedPage else { return }
        preparing = true; isLoading = true
        defer { preparing = false }
        do {
            guard let url = QQOfficialPlaybackPolicy.detailURL(for: track) else { throw MusicError.message(L10n.string("此歌曲暂时无法打开 QQ 官网页面。")) }
            let session = try await client.officialQQPlaybackSession()
            if isClosed || Task.isCancelled {
                await client.releaseOfficialQQPlaybackSession(session.id)
                throw CancellationError()
            }
            lease = (client, session.id)
            try Task.checkCancellation()
            guard !isClosed else { throw CancellationError() }
            let invalidations = session.invalidations
            invalidationTask = Task { @MainActor [weak self] in
                for await _ in invalidations {
                    guard !Task.isCancelled else { return }
                    self?.invalidate(message: L10n.string("应用中的 QQ 登录已改变，请关闭后重新打开官网窗口。"))
                    return
                }
            }
            for cookie in session.cookies {
                try Task.checkCancellation()
                try await client.validateOfficialQQPlaybackSession(session)
                guard !isClosed else { throw CancellationError() }
                if let value = QQOfficialPlaybackPolicy.webCookie(cookie) {
                    await websiteDataStore.httpCookieStore.setCookie(value)
                }
            }
            try await client.validateOfficialQQPlaybackSession(session)
            try Task.checkCancellation()
            guard !isClosed, let view = mainWebView else { throw CancellationError() }
            hasLoadedPage = true; loadPage(view, url)
        } catch is CancellationError {
            invalidate(message: L10n.string("官网窗口已取消，或应用中的 QQ 登录已改变。"))
        } catch {
            invalidate(message: error.localizedDescription)
        }
        // Closing can race a suspended cookie write. Clear once more after the
        // preparation returns, so that late writes cannot survive cancellation.
        if isClosed { await websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) }
    }
    @discardableResult func invalidate(message: String? = nil) -> Task<Void, Never>? {
        guard !isClosed else { return nil }
        isClosed = true; isLoading = false; self.message = message
        invalidationTask?.cancel(); invalidationTask = nil
        for view in [mainWebView, popupWebView].compactMap({ $0 }) {
            view.pauseAllMediaPlayback(completionHandler: nil)
            view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
        }
        mainWebView = nil; popupWebView = nil
        let store = websiteDataStore, oldLease = lease
        lease = nil
        return Task { @MainActor in
            if let oldLease { await oldLease.client.releaseOfficialQQPlaybackSession(oldLease.id) }
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }
    func reload() { guard !isClosed, hasLoadedPage else { return }; message = nil; visibleWebView?.reload() }
    func closePopup() {
        guard let popup = popupWebView else { return }
        popup.pauseAllMediaPlayback(completionHandler: nil)
        popup.stopLoading(); popup.navigationDelegate = nil; popup.uiDelegate = nil
        popupWebView = nil; displayHost = mainWebView?.url?.host ?? "y.qq.com"
        isLoading = mainWebView?.isLoading ?? false
    }
    func permitsNavigation(to url: URL?, isMainFrame: Bool) -> Bool {
        guard !isClosed else { return false }
        // WebKit can ask about an empty target. Deny it without presenting an
        // unknown destination as a concrete failure of the official player.
        guard let url else { return false }
        guard QQOfficialPlaybackPolicy.allows(url, isMainFrame: isMainFrame) else {
            message = L10n.string("已阻止非获准官网页面的跳转（\(DirectLoginPolicy.safeOrigin(of: url))）。")
            return false
        }
        return true
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        permitsNavigation(to: navigationAction.request.url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true) ? .allow : .cancel
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard permitsNavigation(to: navigationResponse.response.url, isMainFrame: navigationResponse.isForMainFrame), navigationResponse.canShowMIMEType else { return .cancel }
        return .allow
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { if !isClosed { isLoading = true } }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isClosed else { return }
        isLoading = false
        if webView === visibleWebView { displayHost = webView.url?.host ?? "y.qq.com" }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed(error) }
    private func failed(_ error: any Error) {
        guard !isClosed else { return }
        isLoading = false
        if (error as NSError).code != NSURLErrorCancelled { message = L10n.string("官网暂时无法载入，请检查网络后重新载入。") }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { invalidate(message: L10n.string("官网页面已停止，请关闭后重新打开。")) }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard permitsNavigation(to: navigationAction.request.url, isMainFrame: true) else { return nil }
        guard popupWebView == nil else { message = L10n.string("请先返回歌曲页面，再打开另一个官网窗口。"); return nil }
        configuration.websiteDataStore = websiteDataStore
        let popup = WKWebView(frame: .zero, configuration: configuration)
        configure(popup); popupWebView = popup
        displayHost = navigationAction.request.url?.host ?? "y.qq.com"
        return popup
    }
    func webViewDidClose(_ webView: WKWebView) { if webView === popupWebView { closePopup() } }
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin, initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision { .deny }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) { completionHandler(nil) }
}
