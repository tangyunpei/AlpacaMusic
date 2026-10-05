import AVFoundation
import Foundation
import Testing
@testable import AlpacaMusic

struct PlaybackErrorMessageTests {
    @Test func underlyingNetworkFailureIsExplainedWithoutLeakingSignedURLs() {
        let secret = "https://cdn.example/track.mp3?token=never-display"
        let network = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue,
                              userInfo: [NSLocalizedDescriptionKey: secret, NSURLErrorFailingURLErrorKey: URL(string: secret)!])
        let wrapper = NSError(domain: AVFoundationErrorDomain, code: AVError.failedToLoadMediaData.rawValue,
                              userInfo: [NSUnderlyingErrorKey: network, NSLocalizedDescriptionKey: secret])
        let message = PlaybackErrorMessage.describe(wrapper, source: .netease, fallback: "播放失败")
        #expect(message.contains("超时") && message.contains("-1001"))
        #expect(!message.contains("token") && !message.contains("cdn.example"))
    }
    @Test func explicitMediaStatusDoesNotInventARegionRestriction() {
        let message = PlaybackErrorMessage.describe(nil, source: .qq, fallback: "播放失败", logEvents: [.init(domain: "HTTP", code: 403)])
        #expect(message.contains("HTTP 403") && message.contains("未说明"))
        #expect(PlaybackErrorMessage.describe(nil, source: .qq, fallback: "播放失败", logEvents: [.init(domain: "HTTP", code: 429)]).contains("频率"))
    }
    @Test func trustedProviderMessagesSurviveAndUnknownErrorsAreRedacted() {
        #expect(PlaybackErrorMessage.describe(MusicError.message("网易云：平台拒绝（单曲码 -110）"), source: .netease, fallback: "错误").contains("-110"))
        #expect(PlaybackErrorMessage.describe(SourceFailure(message: "请先登录 QQ 音乐"), source: .qq, fallback: "错误").contains("请先登录"))
        let error = NSError(domain: "secret=do-not-echo", code: 1, userInfo: [NSLocalizedDescriptionKey: "token=hidden"])
        #expect(PlaybackErrorMessage.describe(error, source: .qq, fallback: "无法播放，原因未确认") == "无法播放，原因未确认")
    }
    @Test func nativeHTTPClassifiesNetworkFailuresAndCancellation() async throws {
        for code in [URLError.timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotFindHost] {
            let http = NativeMusicHTTP { _ in throw URLError(code, userInfo: [NSLocalizedDescriptionKey: "secret=hidden"]) }
            do {
                _ = try await http.data(for: URLRequest(url: URL(string: "https://music.163.com/weapi/test")!), source: .netease, cookies: [])
                Issue.record("Expected network failure")
            } catch {
                #expect(error.localizedDescription.contains(String(code.rawValue)))
                #expect(!error.localizedDescription.contains("secret"))
            }
        }
        let http = NativeMusicHTTP { _ in throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) {
            _ = try await http.data(for: URLRequest(url: URL(string: "https://music.163.com/weapi/test")!), source: .netease, cookies: [])
        }
    }
}
