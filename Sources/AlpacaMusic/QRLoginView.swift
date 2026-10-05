import AppKit
import SwiftUI
import WebKit

@MainActor
struct QRLoginView: View {
    let source: MusicSource
    let onConnect: @MainActor ([MusicSessionCookie]) async throws -> Void
    let onCancel: @MainActor () -> Void
    let onComplete: @MainActor () -> Void
    @State private var usesWebLogin = false

    var body: some View {
        VStack(spacing: 0) {
            if usesWebLogin {
                DirectLoginView(source: source, onConnect: onConnect, onCancel: onCancel, onComplete: onComplete)
            } else if source == .netease {
                NeteaseQRLoginView(onConnect: onConnect, onCancel: cancelQR, onComplete: onComplete,
                                  onWebLogin: { usesWebLogin = true })
            } else {
                QQMusicQRLoginView(onConnect: onConnect, onCancel: cancelQR, onComplete: onComplete,
                                  onWebLogin: { usesWebLogin = true })
            }
        }
    }
    private func cancelQR() {
        // Switching presentation keeps the same account attempt. Only closing
        // the replacement web view should cancel/roll back that attempt.
        if !usesWebLogin { onCancel() }
    }
}

@MainActor
private struct NeteaseQRLoginView: View {
    @Environment(\.appPalette) private var palette
    let onConnect: @MainActor ([MusicSessionCookie]) async throws -> Void
    let onCancel: @MainActor () -> Void
    let onComplete: @MainActor () -> Void
    let onWebLogin: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var authentication = NeteaseQRAuthentication()
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var error: String?
    @State private var isConnecting = false
    @State private var didComplete = false
    @State private var didCancel = false

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("网易云音乐登录").font(.title3.weight(.semibold))
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
            }
            ZStack {
                if let webView = authentication.visibleWebView {
                    QRLoginWebView(webView: webView).id(ObjectIdentifier(webView))
                        .allowsHitTesting(!isConnecting)
                        .opacity(authentication.isLoading || error != nil ? 0 : 1)
                        .accessibilityHidden(authentication.isLoading || error != nil)
                        .accessibilityIdentifier("neteaseLoginQRWidget")
                }
                if authentication.isLoading {
                    ProgressView().padding(18).background(.regularMaterial, in: .rect(cornerRadius: 12))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: 600, height: 500)
            .background(.white, in: .rect(cornerRadius: 14))
            .clipShape(.rect(cornerRadius: 14))
            HStack(spacing: 8) {
                if isConnecting { ProgressView().controlSize(.small) }
                Text(isConnecting ? "正在连接曲库…" : error ?? authentication.message ?? "扫码确认后自动连接曲库")
                    .font(.callout).foregroundStyle(error == nil ? palette.secondary : Color.orange)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("neteaseLoginStatus")
            }
            HStack(spacing: 18) {
                Button("刷新二维码", action: start)
                    .disabled(isConnecting).accessibilityIdentifier("neteaseLoginRefresh")
                Button("使用网页登录") { stop(); onWebLogin() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(palette.secondary)
                    .disabled(isConnecting).accessibilityIdentifier("neteaseLoginWebFallback")
            }
        }
        .padding(24).frame(width: 648).background(palette.panel).foregroundStyle(palette.text)
        .onAppear(perform: start)
        .onDisappear { stop(); notifyCancellation() }
    }

    private func start() {
        guard !isConnecting, !didComplete, !didCancel else { return }
        stop(); error = nil
        let token = generation
        authentication.start()
        task = Task { @MainActor in
            do {
                let cookies = try await authentication.waitForCookies()
                try Task.checkCancellation()
                guard generation == token else { return }
                isConnecting = true
                try await onConnect(cookies)
                try Task.checkCancellation()
                guard generation == token else { return }
                didComplete = true; onComplete(); stop(); dismiss()
            } catch is CancellationError {
                if generation == token && !Task.isCancelled { error = "连接已中断，请刷新二维码后重试。" }
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            if generation == token { isConnecting = false; task = nil }
        }
    }
    private func stop() {
        generation = UUID(); task?.cancel(); task = nil
        authentication.cancel(); isConnecting = false
    }
    private func cancel() { stop(); notifyCancellation(); dismiss() }
    private func notifyCancellation() {
        guard !didComplete, !didCancel else { return }
        didCancel = true; onCancel()
    }
}

@MainActor
private struct QQMusicQRLoginView: View {
    @Environment(\.appPalette) private var palette
    let onConnect: @MainActor ([MusicSessionCookie]) async throws -> Void
    let onCancel: @MainActor () -> Void
    let onComplete: @MainActor () -> Void
    let onWebLogin: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var session = QQMusicQRSession()
    @State private var method = QQMusicQRSession.Method.qq
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var error: String?
    @State private var isConnecting = false
    @State private var didComplete = false
    @State private var didCancel = false

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("QQ 音乐登录").font(.title3.weight(.semibold))
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
            }
            Picker("扫码方式", selection: $method) {
                Text("QQ 扫码").tag(QQMusicQRSession.Method.qq)
                Text("微信扫码").tag(QQMusicQRSession.Method.wechat)
            }.pickerStyle(.segmented).frame(width: 270).disabled(isConnecting)
                .accessibilityIdentifier("qqLoginMethod")
            ZStack {
                if let webView = session.visibleWebView {
                    QRLoginWebView(webView: webView).id(ObjectIdentifier(webView))
                        .allowsHitTesting(!isConnecting)
                        .accessibilityIdentifier("qqLoginQRWidget")
                }
                if session.isLoading {
                    ProgressView().padding(18).background(.regularMaterial, in: .rect(cornerRadius: 12))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: 600, height: 400)
            .background(.white, in: .rect(cornerRadius: 14))
            .clipShape(.rect(cornerRadius: 14))
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    if isConnecting { ProgressView().controlSize(.small) }
                    Text(isConnecting ? "正在连接曲库…" : error ?? session.message ?? (method == .qq ? "使用手机 QQ 扫码并确认" : "使用微信扫一扫并确认"))
                        .font(.callout).foregroundStyle(error == nil ? palette.secondary : Color.orange)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("qqLoginStatus")
                }
                Button("刷新二维码", action: start).disabled(isConnecting)
                    .accessibilityIdentifier("qqLoginRefresh")
                Button("使用网页登录") { stop(); onWebLogin() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(palette.secondary)
                    .disabled(isConnecting).accessibilityIdentifier("qqLoginWebFallback")
            }.frame(minHeight: 56)
        }
        .padding(24).frame(width: 648).background(palette.panel).foregroundStyle(palette.text)
        .onAppear(perform: start)
        .onChange(of: method) { _, _ in start() }
        .onDisappear { stop(); notifyCancellation() }
    }

    private func start() {
        guard !isConnecting, !didComplete, !didCancel else { return }
        stop(); error = nil
        let token = generation
        session.start(method: method)
        task = Task { @MainActor in
            do {
                let cookies = try await session.waitForCookies()
                try Task.checkCancellation()
                guard generation == token else { return }
                isConnecting = true
                try await onConnect(cookies)
                try Task.checkCancellation()
                guard generation == token else { return }
                didComplete = true; onComplete(); stop(); dismiss()
            } catch is CancellationError {
                if generation == token && !Task.isCancelled { error = "连接已中断，请刷新二维码后重试。" }
            }
            catch {
                guard generation == token, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            if generation == token { isConnecting = false; task = nil }
        }
    }
    private func stop() {
        generation = UUID(); task?.cancel(); task = nil
        session.cancel(); isConnecting = false
    }
    private func cancel() { stop(); notifyCancellation(); dismiss() }
    private func notifyCancellation() {
        guard !didComplete, !didCancel else { return }
        didCancel = true; onCancel()
    }
}

@MainActor
private struct QRLoginWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) { }
}
