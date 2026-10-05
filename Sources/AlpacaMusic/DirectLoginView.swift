import AppKit
import Foundation
import Observation
import SwiftUI
import WebKit

enum DirectLoginPolicy {
    static func startURL(for source: MusicSource) -> URL? {
        switch source {
        case .netease: URL(string: "https://music.163.com/")
        case .qq: URL(string: "https://y.qq.com/")
        default: nil
        }
    }
    static func allowedHosts(for source: MusicSource) -> Set<String> {
        switch source {
        case .netease: ["music.163.com", "reg.163.com", "dl.reg.163.com"]
        case .qq: ["y.qq.com", "ptlogin2.qq.com", "xui.ptlogin2.qq.com",
                   "ssl.ptlogin2.qq.com", "ssl.xui.ptlogin2.qq.com", "ssl.ptlogin2.graph.qq.com",
                   "graph.qq.com", "open.weixin.qq.com"]
        default: []
        }
    }
    static func allows(_ url: URL?, source: MusicSource, isMainFrame: Bool = true) -> Bool {
        guard startURL(for: source) != nil, let url else { return false }
        // Empty same-document frames are needed by official login widgets. They
        // are never allowed to replace the main page or launch an external app.
        if !isMainFrame && ["about:blank", "about:srcdoc"].contains(url.absoluteString) { return true }
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        if allowedHosts(for: source).contains(host) { return true }
        let verificationHosts: Set<String>
        switch source {
        case .qq: verificationHosts = ["t.captcha.qq.com", "ssl.captcha.qq.com"]
        case .netease: verificationHosts = ["c.dun.163.com"]
        default: return false
        }
        return !isMainFrame && verificationHosts.contains(host)
    }
    /// Report only the destination's origin: callback paths and query values may
    /// contain one-time authorization codes, account IDs, or login signatures.
    static func safeOrigin(of url: URL?) -> String {
        guard let scheme = url?.scheme?.lowercased(), !scheme.isEmpty, scheme.count <= 24,
              scheme.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [43, 45, 46].contains($0) }) else {
            return "未知协议 / 主机"
        }
        guard let host = url?.host?.lowercased(), !host.isEmpty, host.count <= 253,
              host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || [45, 46, 58, 91, 93].contains($0) }) else {
            return "\(scheme)（无可显示主机）"
        }
        return "\(scheme)://\(host)"
    }
}

@MainActor
struct DirectLoginView: View {
    @Environment(\.appPalette) private var palette
    let source: MusicSource
    let onConnect: @MainActor ([MusicSessionCookie]) async throws -> Void
    let onCancel: @MainActor () -> Void
    let onComplete: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var browser: DirectLoginBrowser?
    @State private var connectionTask: Task<Void, Never>?
    @State private var isConnecting = false
    @State private var connectionError: String?
    @State private var didComplete = false
    @State private var didCancel = false

    init(source: MusicSource,
         onConnect: @escaping @MainActor ([MusicSessionCookie]) async throws -> Void,
         onCancel: @escaping @MainActor () -> Void,
         onComplete: @escaping @MainActor () -> Void = {}) {
        self.source = source; self.onConnect = onConnect
        self.onCancel = onCancel; self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: source.symbol).font(.title2).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(source.title)网页登录").font(.title3.weight(.semibold))
                    Text("在官网登录或扫码后，点击「连接曲库」。")
                        .font(.callout).foregroundStyle(palette.secondary)
                }
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "lock.shield").foregroundStyle(palette.secondary)
                Text(browser?.displayHost ?? DirectLoginPolicy.startURL(for: source)?.host ?? "")
                    .font(.callout.monospaced()).textSelection(.enabled)
                if browser?.isLoading == true { ProgressView().controlSize(.small) }
                Spacer()
                if browser?.hasPopup == true {
                    Button("返回官网") { browser?.closePopup() }.disabled(isConnecting)
                }
                Button("重新载入") { connectionError = nil; browser?.reload() }.disabled(isConnecting)
            }.padding(.horizontal, 20).padding(.vertical, 10)
            if let message = browser?.message {
                Text(message).font(.callout).foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 10)
                    .accessibilityIdentifier("directLoginNavigationMessage")
            }
            if let browser, let webView = browser.visibleWebView {
                LoginWebView(webView: webView).id(ObjectIdentifier(webView))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let connectionError {
                    Label(connectionError, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("directLoginMessage")
                }
                HStack(spacing: 16) {
                    Text("仅保存验证通过的登录信息；取消会清除临时数据。")
                        .font(.caption).foregroundStyle(palette.secondary)
                    Spacer()
                    if isConnecting { ProgressView().controlSize(.small) }
                    Button(isConnecting ? "正在验证…" : "连接曲库", action: connect)
                        .buttonStyle(.borderedProminent)
                        .disabled(isConnecting || browser?.canConnect != true)
                        .accessibilityIdentifier("directLoginConnect")
                }
            }.padding(20)
        }
        .frame(minWidth: 960, minHeight: 660)
        .background(palette.panel).foregroundStyle(palette.text)
        .onAppear {
            if browser == nil { browser = DirectLoginBrowser(source: source); browser?.start() }
        }
        .onDisappear {
            connectionTask?.cancel(); connectionTask = nil
            browser?.invalidate(); browser = nil
            notifyCancellation()
        }
    }
    private func cancel() {
        connectionTask?.cancel(); connectionTask = nil
        browser?.invalidate(); notifyCancellation(); dismiss()
    }
    private func notifyCancellation() {
        guard !didComplete, !didCancel else { return }
        didCancel = true; onCancel()
    }
    private func connect() {
        guard !isConnecting, let browser, browser.canConnect else { return }
        isConnecting = true; connectionError = nil
        connectionTask = Task { @MainActor in
            defer { isConnecting = false; connectionTask = nil }
            do {
                let cookies = await browser.sessionCookies()
                try Task.checkCancellation()
                guard !browser.isClosed else { return }
                guard !cookies.isEmpty else { throw MusicError.message("还未取得有效登录信息，请先在官网完成登录后重试") }
                try await onConnect(cookies)
                try Task.checkCancellation()
                guard !browser.isClosed else { return }
                didComplete = true; onComplete(); browser.invalidate(); dismiss()
            } catch is CancellationError {
                if !Task.isCancelled && !browser.isClosed { connectionError = "连接已中断，请重试。" }
            }
            catch {
                guard !browser.isClosed else { return }
                connectionError = error.localizedDescription
            }
        }
    }
}

@MainActor
private struct LoginWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) { }
}

/// One presentation owns one isolated, nonpersistent website data store. The
/// app never reads DOM passwords, Safari/Chrome storage, or ambient cookies.
@MainActor @Observable
final class DirectLoginBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    let source: MusicSource
    private(set) var isLoading = false
    private(set) var isClosed = false
    private(set) var message: String?
    private(set) var displayHost = ""
    private(set) var mainWebView: WKWebView?
    private(set) var popupWebView: WKWebView?
    @ObservationIgnored private let websiteDataStore: WKWebsiteDataStore
    private var mainPageLoaded = false
    var visibleWebView: WKWebView? { popupWebView ?? mainWebView }
    var hasPopup: Bool { popupWebView != nil }
    var canConnect: Bool { !isClosed && mainPageLoaded }
    var usesPersistentStorage: Bool { websiteDataStore.isPersistent }

    init(source: MusicSource) {
        self.source = source
        websiteDataStore = .nonPersistent()
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        configure(view); mainWebView = view
    }
    private func configure(_ webView: WKWebView) {
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.isInspectable = false
        webView.pageZoom = 0.8
        webView.allowsBackForwardNavigationGestures = false
    }
    func start() {
        guard !isClosed, let url = DirectLoginPolicy.startURL(for: source) else { return }
        displayHost = url.host ?? ""; mainWebView?.load(URLRequest(url: url))
    }
    func reload() {
        guard !isClosed else { return }
        message = nil
        if visibleWebView?.url == nil { start() } else { visibleWebView?.reload() }
    }
    func closePopup() {
        guard let popup = popupWebView else { return }
        popup.stopLoading(); popup.navigationDelegate = nil; popup.uiDelegate = nil
        popupWebView = nil; displayHost = mainWebView?.url?.host ?? ""
        isLoading = mainWebView?.isLoading ?? false
    }
    func sessionCookies() async -> [MusicSessionCookie] {
        guard !isClosed else { return [] }
        let cookies = await websiteDataStore.httpCookieStore.allCookies()
        guard !isClosed else { return [] }
        return DirectMusicAccess.sessionCookies(cookies.map(MusicSessionCookie.init), for: source)
    }
    @discardableResult func invalidate() -> Task<Void, Never>? {
        guard !isClosed else { return nil }
        isClosed = true; mainPageLoaded = false
        for view in [mainWebView, popupWebView].compactMap({ $0 }) {
            view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
        }
        mainWebView = nil; popupWebView = nil
        let store = websiteDataStore
        return Task { @MainActor in
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }
    func permitsNavigation(to url: URL?, isMainFrame: Bool) -> Bool {
        guard !isClosed else { return false }
        guard DirectLoginPolicy.allows(url, source: source, isMainFrame: isMainFrame) else {
            message = "已阻止登录\(isMainFrame ? "主页面" : "子页面")跳转（\(DirectLoginPolicy.safeOrigin(of: url))）。此地址尚未获准用于当前平台登录。"
            return false
        }
        return true
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        permitsNavigation(to: navigationAction.request.url, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true) ? .allow : .cancel
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard permitsNavigation(to: navigationResponse.response.url, isMainFrame: navigationResponse.isForMainFrame) else { return .cancel }
        guard navigationResponse.canShowMIMEType else {
            message = "登录页面返回了无法显示的内容（\(DirectLoginPolicy.safeOrigin(of: navigationResponse.response.url))），请重新载入后重试。"
            return .cancel
        }
        return .allow
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !isClosed else { return }
        isLoading = true
        if webView === mainWebView { mainPageLoaded = false }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isClosed else { return }
        isLoading = false
        if webView === mainWebView { mainPageLoaded = DirectLoginPolicy.allows(webView.url, source: source) }
        if webView === visibleWebView { displayHost = webView.url?.host ?? "" }
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !isClosed else { return }
        // Third-party resources can keep loading long after the official login
        // page is usable. Account verification, not didFinish, confirms login.
        if webView === mainWebView { mainPageLoaded = DirectLoginPolicy.allows(webView.url, source: source) }
        if webView === visibleWebView { displayHost = webView.url?.host ?? "" }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed(error) }
    private func failed(_ error: any Error) {
        guard !isClosed else { return }
        isLoading = false
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        message = "官网暂时无法载入，请检查网络后重新载入。"
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isClosed else { return }
        isLoading = false; mainPageLoaded = false
        message = "登录页面已停止，请重新载入后再试。"
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard permitsNavigation(to: navigationAction.request.url, isMainFrame: true) else { return nil }
        guard popupWebView == nil else {
            message = "已阻止额外登录窗口（\(DirectLoginPolicy.safeOrigin(of: navigationAction.request.url))）。请先返回官网，再使用登录入口。"; return nil
        }
        // Preserve official window.opener behavior, within this same temporary
        // store, instead of faking an OAuth callback or launching another browser.
        configuration.websiteDataStore = websiteDataStore
        let popup = WKWebView(frame: .zero, configuration: configuration)
        configure(popup); popupWebView = popup
        displayHost = navigationAction.request.url?.host ?? ""
        return popup
    }
    func webViewDidClose(_ webView: WKWebView) {
        if webView === popupWebView { closePopup() }
    }
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision { .deny }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        completionHandler(nil)
    }
}
