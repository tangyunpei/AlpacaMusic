import Foundation
import WebKit

/// One login attempt owns one real, memory-only WebKit browsing context. The
/// official public SDK is loaded remotely into the actual API origin; no page,
/// origin, signature, device identity or Set-Cookie response is manufactured.
@MainActor
final class SodaWebLoginSession: NSObject, SodaLoginSessionBackend, WKNavigationDelegate {
    private(set) var webView: WKWebView?

    private enum Phase { case fresh, navigating, initializing, ready, cancelled }
    private var phase = Phase.fresh
    private var generation = UUID()
    private var navigationID: UUID?
    private var navigationContinuation: CheckedContinuation<Void, Error>?
    private var receivedHTML = false
    private var terminalFailure: MusicError?
    private var pending: [UUID: @MainActor (Error) -> Void] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    private static let origin = URL(string: "https://api.qishui.com/")!
    private static let responseLimit = 512 * 1024
    private static let passportPaths: Set<String> = ["/passport/web/get_qrcode/", "/passport/web/check_qrconnect/"]
    private static let headerNames = ["Accept", "Content-Type", "x-tt-passport-verify-portrait", "x-tt-passport-trace-id"]

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView?.navigationDelegate = self
    }

    /// The caller mounts `webView` before awaiting this method. Reuse is only
    /// allowed inside the same live attempt; cancelled instances stay invalid.
    func prepare() async throws {
        try Task.checkCancellation()
        if let terminalFailure { throw terminalFailure }
        if phase == .ready { return }
        guard phase == .fresh, let view = webView else {
            throw MusicError.message("汽水音乐登录会话已结束，请重新获取二维码。")
        }
        let attempt = generation
        do {
            phase = .navigating
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let id = UUID()
                    navigationID = id; navigationContinuation = continuation
                    register(id, seconds: 20, message: "汽水音乐登录网页加载超时，请重新获取二维码。") { [weak self] error in
                        self?.navigationID = nil; self?.navigationContinuation = nil
                        continuation.resume(throwing: error)
                    }
                    view.load(URLRequest(url: Self.origin, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
                }
            } onCancel: { [weak self] in
                Task { @MainActor in self?.cancel() }
            }
            try ensureActive(attempt)
            phase = .initializing
            let encoded = try await runScript(Self.prepareScript, arguments: [:], seconds: 25,
                                              timeoutMessage: "汽水音乐登录安全组件初始化超时，请重新获取二维码。")
            let result = try Self.scriptResult(encoded)
            try ensureActive(attempt)
            guard result["ok"] as? Bool == true,
                  result["fetchHookReady"] as? Bool == true,
                  result["xhrHookReady"] as? Bool == true else {
                throw scriptFailure(result, preparing: true)
            }
            let identityData = try await runScript(SodaWebIdentityBootstrap.script, arguments: [:], seconds: 11,
                                                   timeoutMessage: "汽水音乐登录身份初始化超时，请重新获取二维码。")
            let identity = try Self.scriptResult(identityData)
            try ensureActive(attempt)
            guard identity["ok"] as? Bool == true else {
                throw Self.identityFailure(identity)
            }
            let contextData = try await runScript(SodaBrowserContext.script, arguments: [:], seconds: 6,
                                                  timeoutMessage: "汽水音乐登录环境准备超时，请重新获取二维码。")
            let context = try Self.scriptResult(contextData)
            try ensureActive(attempt)
            guard context["ok"] as? Bool == true else {
                throw MusicError.message("汽水音乐登录环境准备失败，请重新获取二维码。")
            }
            phase = .ready
        } catch {
            cancel()
            throw error
        }
    }

    /// The browser controls cookies, origin, UA, redirects and security policy.
    /// All request/response values exist only for this call and its caller.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        if let terminalFailure { throw terminalFailure }
        guard phase != .cancelled else { throw CancellationError() }
        guard phase == .ready else {
            throw MusicError.message("汽水音乐登录初始化尚未完成，请重新打开登录。")
        }
        guard let url = request.url, url.absoluteString.utf8.count <= 32 * 1024, Self.isPassportURL(url) else {
            throw MusicError.message("汽水音乐登录请求地址校验失败，已停止连接。")
        }
        let method = (request.httpMethod ?? "GET").uppercased()
        guard ["GET", "POST"].contains(method), request.httpBodyStream == nil,
              (request.httpBody?.count ?? 0) <= 32 * 1024,
              method != "GET" || request.httpBody == nil else {
            throw MusicError.message("汽水音乐登录请求格式无效。")
        }
        var headers: [String: String] = [:]
        for name in Self.headerNames {
            guard let value = request.value(forHTTPHeaderField: name) else { continue }
            guard value.utf8.count <= 2048,
                  !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
                throw MusicError.message("汽水音乐登录请求格式无效。")
            }
            headers[name] = value
        }
        if let contentType = headers["Content-Type"], contentType.lowercased() != "application/x-www-form-urlencoded" {
            throw MusicError.message("汽水音乐登录请求格式无效。")
        }
        headers["Accept"] = "application/json, text/javascript"
        let body: String
        if let data = request.httpBody {
            guard let text = String(data: data, encoding: .utf8) else { throw MusicError.message("汽水音乐登录请求格式无效。") }
            body = text
        } else { body = "" }
        let attempt = generation
        let timeout = min(20, max(0.1, request.timeoutInterval))
        let encodedResult = try await runScript(Self.sendScript,
                                               arguments: ["requestURL": url.absoluteString, "method": method,
                                                           "headers": headers, "body": body, "limit": Self.responseLimit,
                                                           "timeoutMS": timeout * 1000],
                                               seconds: timeout + 1, timeoutMessage: "汽水音乐登录请求超时，请重新获取二维码。")
        let result = try Self.scriptResult(encodedResult)
        try ensureActive(attempt)
        guard result["ok"] as? Bool == true else { throw scriptFailure(result, preparing: false) }
        guard let responseURLString = result["url"] as? String, responseURLString.utf8.count <= 32 * 1024,
              let responseURL = URL(string: responseURLString), Self.isPassportURL(responseURL), responseURL.path == url.path,
              let status = result["status"] as? Int, (100...599).contains(status),
              let encoded = result["bytes"] as? String, encoded.utf8.count <= ((Self.responseLimit + 2) / 3) * 4,
              let data = Data(base64Encoded: encoded), data.count <= Self.responseLimit else {
            throw MusicError.message("汽水音乐登录网页返回了无效响应，已停止连接。")
        }
        var responseHeaders: [String: String] = [:]
        if let contentType = result["contentType"] as? String, contentType.utf8.count <= 256,
           !contentType.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            responseHeaders["Content-Type"] = contentType
        }
        // Browser requests never expose Set-Cookie. Account state is obtained separately
        // from this view's actual WKHTTPCookieStore, never a fabricated header.
        guard let response = HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: nil, headerFields: responseHeaders) else {
            throw MusicError.message("汽水音乐登录网页返回了无效响应，已停止连接。")
        }
        return (data, response)
    }

    func snapshotCookies() async throws -> [MusicSessionCookie] {
        try Task.checkCancellation()
        if let terminalFailure { throw terminalFailure }
        let attempt = generation
        guard phase == .ready, let store = webView?.configuration.websiteDataStore.httpCookieStore else { throw CancellationError() }
        let cookies: [MusicSessionCookie] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let id = UUID()
                register(id, seconds: 15, message: "汽水音乐登录会话读取超时，请重新获取二维码。") { error in continuation.resume(throwing: error) }
                store.getAllCookies { [weak self] values in
                    guard let self, self.finish(id) else { return }
                    guard self.generation == attempt, self.phase == .ready else { continuation.resume(throwing: CancellationError()); return }
                    // Persistable scope belongs solely to the new Soda session.
                    let cookies = DirectMusicAccess.sessionCookies(values.map(MusicSessionCookie.init), for: .soda)
                    continuation.resume(returning: cookies)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
        try ensureActive(attempt)
        return cookies
    }

    func cancel() {
        close(with: CancellationError())
    }

    private func close(with failure: Error) {
        guard phase != .cancelled else { return }
        generation = UUID(); phase = .cancelled
        let failures = Array(pending.values)
        pending.removeAll()
        timeouts.values.forEach { $0.cancel() }; timeouts.removeAll()
        navigationID = nil; navigationContinuation = nil
        failures.forEach { $0(failure) }
        guard let view = webView else { return }
        webView = nil
        view.callAsyncJavaScript(Self.cancelScript, arguments: [:], in: nil, in: .page, completionHandler: nil)
        view.stopLoading(); view.navigationDelegate = nil; view.removeFromSuperview()
        // Unload the old document even if the SwiftUI host still briefly owns
        // this view. Its memory-only store is cleared and never reused.
        view.load(URLRequest(url: URL(string: "about:blank")!))
        view.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast, completionHandler: {})
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard phase == .navigating, let url = navigationAction.request.url, Self.isRootURL(url) else { return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard phase == .navigating, navigationResponse.isForMainFrame,
              let response = navigationResponse.response as? HTTPURLResponse,
              let url = response.url, Self.isRootURL(url), response.mimeType == "text/html", navigationResponse.canShowMIMEType else {
            failNavigation(MusicError.message("汽水音乐当前未提供可运行的官方登录网页，已停止连接。"))
            return .cancel
        }
        receivedHTML = true
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard phase == .navigating, receivedHTML, let url = webView.url, Self.isRootURL(url),
              let id = navigationID, let continuation = navigationContinuation, finish(id) else { return }
        navigationID = nil; navigationContinuation = nil
        continuation.resume()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failNavigation(MusicError.message("汽水音乐官方登录网页无法加载，请检查网络后重新获取二维码。"))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failNavigation(MusicError.message("汽水音乐官方登录网页无法加载，请检查网络后重新获取二维码。"))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard self.webView === webView, phase != .cancelled else { return }
        let failure = MusicError.message("汽水音乐登录网页进程已中断，请重新打开登录。")
        terminalFailure = failure
        close(with: failure)
    }

    private func failNavigation(_ error: Error) {
        guard let id = navigationID, let reject = pending[id], finish(id) else { return }
        reject(error)
    }

    private func register(_ id: UUID, seconds: TimeInterval, message: String, reject: @escaping @MainActor (Error) -> Void) {
        pending[id] = reject
        timeouts[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, let rejection = self.pending[id], self.finish(id) else { return }
            rejection(MusicError.message(message))
            self.cancel()
        }
    }

    @discardableResult
    private func finish(_ id: UUID) -> Bool {
        guard pending.removeValue(forKey: id) != nil else { return false }
        timeouts.removeValue(forKey: id)?.cancel()
        return true
    }

    private func runScript(_ body: String, arguments: [String: Any], seconds: TimeInterval, timeoutMessage: String) async throws -> Data {
        try Task.checkCancellation()
        if let terminalFailure { throw terminalFailure }
        let attempt = generation
        guard let view = webView, phase != .cancelled else { throw CancellationError() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let id = UUID()
                var supplied = arguments; supplied["operationID"] = id.uuidString
                register(id, seconds: seconds, message: timeoutMessage) { error in continuation.resume(throwing: error) }
                view.callAsyncJavaScript(body, arguments: supplied, in: nil, in: .page) { [weak self] result in
                    guard let self, self.finish(id) else { return }
                    guard self.generation == attempt, self.phase != .cancelled else { continuation.resume(throwing: CancellationError()); return }
                    switch result {
                    case .success(let value):
                        // WebKit's dynamically bridged objects cannot cross a
                        // continuation's sending boundary. Copy JSON to bounded
                        // Sendable Data, then decode locally on the caller actor.
                        guard let dictionary = value as? [String: Any],
                              let encoded = try? JSONSerialization.data(withJSONObject: dictionary),
                              encoded.count <= 1024 * 1024 else {
                            continuation.resume(throwing: MusicError.message("汽水音乐登录网页返回了无效或过大的结果。")); return
                        }
                        continuation.resume(returning: encoded)
                    case .failure:
                        // WK errors can contain URL parameters or script text.
                        continuation.resume(throwing: MusicError.message("汽水音乐登录网页执行失败，请重新获取二维码。"))
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
    }

    private func ensureActive(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard generation == attempt, phase != .cancelled else { throw CancellationError() }
    }
    private static func scriptResult(_ data: Data) throws -> [String: Any] {
        guard data.count <= 1024 * 1024,
              let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw MusicError.message("汽水音乐登录网页返回了无效结果。")
        }
        return result
    }
    private static func isOrigin(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "api.qishui.com" && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil && url.fragment == nil
    }
    private static func isRootURL(_ url: URL) -> Bool { isOrigin(url) && ["", "/"].contains(url.path) && url.query == nil }
    static func isPassportURL(_ url: URL) -> Bool {
        // Foundation's URL.path removes a final slash. Compare the actual
        // encoded request path, which also rejects encoded path aliases.
        guard isOrigin(url), let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return false }
        return passportPaths.contains(path)
    }

    private func scriptFailure(_ result: [String: Any], preparing: Bool) -> MusicError {
        switch result["failure"] as? String {
        case "notHTML", "origin": return .message("汽水音乐当前未提供可运行的官方登录网页，已停止连接。")
        case "sdkLoad": return .message("汽水音乐官方登录安全组件无法加载，请检查网络后重新获取二维码。")
        case "sdkInit", "hooks": return .message("汽水音乐官方登录安全组件未能就绪，已停止连接；请重新获取二维码。")
        case "context": return .message("汽水音乐登录环境尚未就绪，请重新获取二维码。")
        case "tooLarge": return .message("汽水音乐登录响应过大，已停止连接。")
        case "timeout": return .message("汽水音乐登录请求超时，请重新获取二维码。")
        case "cancelled": return .message("汽水音乐登录请求已结束，请重新获取二维码。")
        default: return .message(preparing ? "汽水音乐登录安全组件初始化失败，请重新获取二维码。" : "汽水音乐登录请求未完成，请检查网络后重新获取二维码。")
        }
    }

    private static func identityFailure(_ result: [String: Any]) -> MusicError {
        let failure = result["failure"] as? String ?? ""
        if failure.hasSuffix("Timeout") {
            return .message("汽水音乐登录身份初始化超时，请检查网络后重新获取二维码。")
        }
        if failure.hasPrefix("webIdentityRecheck") {
            return .message("汽水音乐未能确认本次登录身份，请重新获取二维码。")
        }
        if failure.hasPrefix("webIdentityRegister") {
            return .message("汽水音乐未能建立本次登录身份，请稍后重新获取二维码。")
        }
        return .message("汽水音乐登录身份检查未完成，请检查网络后重新获取二维码。")
    }

    private static let prepareScript = #"""
    if (location.origin !== 'https://api.qishui.com' || location.pathname !== '/') return {ok:false,failure:'origin'};
    if (document.contentType !== 'text/html' || document.documentElement?.tagName !== 'HTML' || !isSecureContext) return {ok:false,failure:'notHTML'};
    const state = {controllers:new Map(), cancelled:false};
    window.__alpacaSodaLogin = state;
    const previous = {fetch:window.fetch, open:XMLHttpRequest.prototype.open, send:XMLHttpRequest.prototype.send};
    const deadline = Date.now() + 23000;
    try {
      await new Promise((resolve,reject) => {
        const script = document.createElement('script');
        const timer = setTimeout(() => reject(new Error('load')), 16000);
        script.onload = () => {clearTimeout(timer);resolve();};
        script.onerror = () => {clearTimeout(timer);reject(new Error('load'));};
        script.src = 'https://lf-headquarters-speed.yhgfb-cn-static.com/obj/rc-client-security/web/glue/1.0.0.36/sdk-glue.js';
        document.head.appendChild(script);
      });
    } catch (_) {return {ok:false,failure:'sdkLoad'};}
    if (state.cancelled) return {ok:false,failure:'cancelled'};
    if (typeof window._SdkGlueInit !== 'function') return {ok:false,failure:'sdkInit'};
    try {await Promise.resolve(window._SdkGlueInit({self:{aid:386088,pageId:24554},bdms:{aid:386088,paths:['/passport']}}));}
    catch (_) {return {ok:false,failure:'sdkInit'};}
    const hooksReady = () => !!window.bdms && typeof window.bdms.init === 'function' && window.fetch !== previous.fetch && XMLHttpRequest.prototype.open !== previous.open && XMLHttpRequest.prototype.send !== previous.send;
    while (!state.cancelled && Date.now() < deadline && !hooksReady()) await new Promise(resolve => setTimeout(resolve, 200));
    if (state.cancelled) return {ok:false,failure:'cancelled'};
    if (!hooksReady()) return {ok:false,failure:'hooks'};
    return {ok:true,fetchHookReady:true,xhrHookReady:true};
    """#

    private static let sendScript = #"""
    const state = window.__alpacaSodaLogin;
    if (!state || state.cancelled) return {ok:false,failure:'cancelled'};
    if (location.origin !== 'https://api.qishui.com' || location.pathname !== '/') return {ok:false,failure:'origin'};
    const target = new URL(requestURL);
    if (target.origin !== location.origin || !['/passport/web/get_qrcode/','/passport/web/check_qrconnect/'].includes(target.pathname)) return {ok:false,failure:'origin'};
    if (typeof state.accountSourceInfo !== 'string' || state.accountSourceInfo.length < 1 || state.accountSourceInfo.length > 24576) return {ok:false,failure:'context'};
    target.searchParams.set('account_sdk_source_info',state.accountSourceInfo);
    // The account SDK reports versions from this browsing context. These are
    // runtime metadata, never copied device IDs or authentication signatures.
    const version = value => typeof value === 'string' && /^[A-Za-z0-9._-]{1,64}$/.test(value) ? value : '0';
    target.searchParams.set('p_bd',version(window._sdkGlueVersionMap?.bdmsVersion));
    target.searchParams.set('p_zt',version(window.$SECURE_VERSION));
    target.searchParams.set('request_host',encodeURIComponent(location.origin));
    const trace = headers['x-tt-passport-trace-id'];
    if (trace) {
      if (!/^[a-f0-9]{8}$/.test(trace) || target.searchParams.get('biz_trace_id') !== trace) return {ok:false,failure:'request'};
      document.cookie = 'biz_trace_id=' + trace + '; Path=/; Domain=qishui.com; Secure; SameSite=Lax';
    }
    // The official consumer account SDK uses Axios' browser XHR adapter. Keep
    // its remote security hooks in this same browsing context, including POST
    // body handling; the browser owns credentials, redirects and CORS policy.
    return await new Promise(resolve => {
      let xhr;
      let settled = false;
      let timer;
      const finish = result => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        state.controllers.delete(operationID);
        if (xhr) xhr.onload = xhr.onerror = xhr.ontimeout = xhr.onabort = xhr.onreadystatechange = xhr.onprogress = null;
        resolve(result);
      };
      const abortWith = failure => {
        finish({ok:false,failure});
        try {xhr?.abort();} catch (_) {}
      };
      state.controllers.set(operationID,{abort:() => abortWith('cancelled')});
      timer = setTimeout(() => abortWith(state.cancelled ? 'cancelled' : 'timeout'), timeoutMS);
      try {
        const cookiePairs = document.cookie.split(';').map(item => item.trim().split('='));
        const readCookie = name => {
          const pair = cookiePairs.find(item => item[0] === name);
          if (!pair) return '';
          try {return decodeURIComponent(pair.slice(1).join('='));} catch (_) {return '';}
        };
        const safeHeaders = {...headers,'x-tt-passport-csrf-token':readCookie('passport_csrf_token') || readCookie('passport_csrf_token_default') || ''};
        xhr = new XMLHttpRequest();
        xhr.open(method,target.href,true);
        xhr.withCredentials = true;
        xhr.timeout = timeoutMS;
        xhr.responseType = 'arraybuffer';
        for (const [name,value] of Object.entries(safeHeaders)) xhr.setRequestHeader(name,value);
        xhr.onreadystatechange = () => {
          if (settled || xhr.readyState !== 2) return;
          try {
            const contentLength = Number(xhr.getResponseHeader('Content-Length'));
            if (Number.isFinite(contentLength) && contentLength > limit) {abortWith('tooLarge');return;}
            if (xhr.responseURL) {
              const responseURL = new URL(xhr.responseURL);
              if (responseURL.origin !== location.origin || responseURL.pathname !== target.pathname) abortWith('origin');
            }
          } catch (_) {abortWith('request');}
        };
        xhr.onprogress = event => {if (event.loaded > limit) abortWith('tooLarge');};
        xhr.onabort = () => finish({ok:false,failure:state.cancelled ? 'cancelled' : 'request'});
        xhr.ontimeout = () => finish({ok:false,failure:state.cancelled ? 'cancelled' : 'timeout'});
        xhr.onerror = () => finish({ok:false,failure:state.cancelled ? 'cancelled' : 'request'});
        xhr.onload = () => {
          if (settled) return;
          if (state.cancelled) {finish({ok:false,failure:'cancelled'});return;}
          try {
            const responseURL = new URL(xhr.responseURL);
            if (responseURL.origin !== location.origin || responseURL.pathname !== target.pathname) {finish({ok:false,failure:'origin'});return;}
            if (xhr.status < 100 || xhr.status > 599 || !(xhr.response instanceof ArrayBuffer)) {finish({ok:false,failure:'request'});return;}
            const bytes = new Uint8Array(xhr.response);
            if (bytes.byteLength > limit) {abortWith('tooLarge');return;}
            let binary = '';
            for (let offset = 0; offset < bytes.length; offset += 4096) binary += String.fromCharCode(...bytes.subarray(offset,offset+4096));
            finish({ok:true,url:xhr.responseURL,status:xhr.status,contentType:xhr.getResponseHeader('Content-Type') || '',bytes:btoa(binary)});
          } catch (_) {finish({ok:false,failure:'request'});}
        };
        if (state.cancelled) {abortWith('cancelled');return;}
        xhr.send(method === 'POST' ? body : null);
      } catch (_) {abortWith(state.cancelled ? 'cancelled' : 'request');}
    });
    """#

    private static let cancelScript = #"""
    const state = window.__alpacaSodaLogin;
    if (state) {state.cancelled = true;for (const controller of state.controllers.values()) controller.abort();state.controllers.clear();}
    """#
}
