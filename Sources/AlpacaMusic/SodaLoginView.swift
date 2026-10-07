import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import WebKit

@MainActor
struct SodaLoginView: View {
    @Environment(\.appPalette) private var palette
    let onConnect: @MainActor ([MusicSessionCookie]) async throws -> Void
    let onCancel: @MainActor () -> Void
    let onComplete: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var authentication = SodaQRAuthentication()
    @State private var connectionTask: Task<Void, Never>?
    @State private var image: NSImage?
    @State private var didComplete = false
    @State private var didCancel = false

    init(onConnect: @escaping @MainActor ([MusicSessionCookie]) async throws -> Void,
         onCancel: @escaping @MainActor () -> Void,
         onComplete: @escaping @MainActor () -> Void = {}) {
        self.onConnect = onConnect; self.onCancel = onCancel; self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Text(L10n.string("汽水音乐登录")).font(.title3.weight(.semibold))
                Spacer()
                Button(L10n.string("取消"), action: cancel).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("sodaLoginCancel")
            }
            Spacer(minLength: 0)
            if let image, authentication.challenge != nil,
               ![.expired, .failed, .cancelled].contains(authentication.phase) {
                Image(nsImage: image).interpolation(.none).resizable()
                    .frame(width: 240, height: 240).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel(L10n.string("使用汽水音乐 App 扫一扫登录的二维码"))
                    .accessibilityIdentifier("sodaLoginQR")
            } else if authentication.phase == .creating || authentication.phase == .idle {
                ProgressView().frame(width: 272, height: 272)
            } else {
                Image(systemName: "qrcode").font(.system(size: 64)).foregroundStyle(palette.secondary)
                    .frame(width: 272, height: 272)
            }
            HStack(spacing: 10) {
                if authentication.phase == .verifying { ProgressView().controlSize(.small) }
                Text(authentication.message).font(.callout)
                    .foregroundStyle([.failed, .expired].contains(authentication.phase) ? Color.orange : palette.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sodaLoginStatus")
            }
            Button(L10n.string("重新获取二维码"), action: start)
                .disabled([.creating, .verifying, .connected].contains(authentication.phase))
                .accessibilityIdentifier("sodaLoginRefresh")
            Spacer(minLength: 0)
            HStack(spacing: 18) {
                Link(L10n.string("汽水音乐用户协议"), destination: URL(string: "https://luna-web.douyin.com/terms")!)
                Link(L10n.string("隐私政策"), destination: URL(string: "https://luna-web.douyin.com/privacy")!)
            }.font(.caption).foregroundStyle(palette.secondary)
        }
        .padding(24).frame(minWidth: 560, minHeight: 540)
        .background(palette.panel).foregroundStyle(palette.text)
        .background {
            if let webView = authentication.webView {
                SodaLoginBrowserHost(webView: webView)
                    .id(ObjectIdentifier(webView))
                    .frame(width: 400, height: 160)
                    .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onAppear(perform: start)
        .onDisappear {
            connectionTask?.cancel(); connectionTask = nil
            authentication.cancel(); notifyCancellation()
        }
    }

    private func start() {
        connectionTask?.cancel(); authentication.cancel(); image = nil
        connectionTask = Task { @MainActor in
            do {
                let challenge = try await authentication.create()
                try Task.checkCancellation()
                image = Self.qrImage(challenge.scanURL.absoluteString)
                guard image != nil else { throw MusicError.message(L10n.string("无法显示二维码，请重新获取。")) }
                while !Task.isCancelled {
                    if let cookies = try await authentication.poll() {
                        try Task.checkCancellation()
                        try await authentication.validate(cookies, onConnect: onConnect)
                        try Task.checkCancellation()
                        guard authentication.phase == .connected, !didCancel else { return }
                        didComplete = true; onComplete(); dismiss(); return
                    }
                    try await Task.sleep(for: .seconds(authentication.pollInterval))
                }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, ![.cancelled, .expired, .failed].contains(authentication.phase) else { return }
                authentication.fail(error.localizedDescription)
            }
        }
    }

    private func cancel() {
        connectionTask?.cancel(); connectionTask = nil; authentication.cancel()
        notifyCancellation(); dismiss()
    }
    private func notifyCancellation() {
        guard !didComplete, !didCancel else { return }
        didCancel = true; onCancel()
    }
    private static func qrImage(_ content: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let pixels = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: pixels, size: NSSize(width: pixels.width, height: pixels.height))
    }
}

/// Keep this attempt's WebKit view in the sheet's native view lifecycle while
/// the QR and connection status remain the visible login interface.
private struct SodaLoginBrowserHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) { }
}
