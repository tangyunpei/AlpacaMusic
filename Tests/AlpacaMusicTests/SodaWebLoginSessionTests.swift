import Foundation
import Testing
import WebKit
@testable import AlpacaMusic

@Suite @MainActor struct SodaWebLoginSessionTests {
    private var request: URLRequest {
        URLRequest(url: URL(string: "https://api.qishui.com/passport/web/get_qrcode/")!)
    }

    private func expectMusicFailure(_ message: String,
                                    operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("Expected a login failure without starting network navigation")
        } catch {
            #expect(error is MusicError)
            #expect(!(error is CancellationError))
            #expect(error.localizedDescription == message)
        }
    }

    @Test func unpreparedBrowserReportsInitializationRatherThanInvalidRequest() async {
        let session = SodaWebLoginSession()
        defer { session.cancel() }
        await expectMusicFailure(L10n.string("汽水音乐登录初始化尚未完成，请重新打开登录。")) {
            _ = try await session.send(request)
        }
    }

    @Test func terminatedBrowserReportsActionableFailureBeforeAnyNetwork() async throws {
        let session = SodaWebLoginSession()
        let view = try #require(session.webView)
        session.webViewWebContentProcessDidTerminate(view)
        #expect(session.webView == nil)

        await expectMusicFailure(L10n.string("汽水音乐登录网页进程已中断，请重新打开登录。")) {
            _ = try await session.send(request)
        }
        await expectMusicFailure(L10n.string("汽水音乐登录网页进程已中断，请重新打开登录。")) {
            _ = try await session.snapshotCookies()
        }
    }

    @Test func explicitCancelStaysCancellationEvenWithLateProcessTermination() async throws {
        let session = SodaWebLoginSession()
        let view = try #require(session.webView)
        session.cancel()
        session.webViewWebContentProcessDidTerminate(view)
        #expect(session.webView == nil)

        await #expect(throws: CancellationError.self) { try await session.send(request) }
        await #expect(throws: CancellationError.self) { try await session.snapshotCookies() }
    }
}
