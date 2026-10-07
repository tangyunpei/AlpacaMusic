import Foundation
import Testing
@testable import AlpacaMusic

@Suite struct NativeMusicHTTPTests {
    @Test(arguments: [401, 403, 404, 429, 500, 503, 418])
    func responseStatusExplainsTheFailureWithoutExposingServerContent(_ status: Int) async throws {
        let expected: String
        switch status {
        case 401: expected = L10n.string("请求需要有效登录，请在音源页重新登录后重试")
        case 403: expected = L10n.string("平台拒绝访问，请在官网确认账号权限或验证提示；具体原因未确认")
        case 404: expected = L10n.string("请求的接口或资源未找到，具体原因未确认")
        case 429: expected = L10n.string("请求过于频繁，请稍后重试")
        case 500..<600: expected = L10n.string("平台服务暂时异常，请稍后重试")
        default: expected = L10n.string("平台未能完成请求，请稍后重试")
        }
        let url = try #require(URL(string: "https://music.163.com/weapi/fixture?token=private-url"))
        let http = NativeMusicHTTP(transport: { request in
            (Data("private-response MUSIC_U=private-cookie".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        do {
            _ = try await http.data(for: URLRequest(url: url), source: .netease,
                                    cookies: [.init(name: "MUSIC_U", value: "private-cookie", domain: ".music.163.com")])
            Issue.record("An unsuccessful HTTP response was accepted")
        } catch {
            let message = error.localizedDescription
            #expect(message == L10n.string("\(MusicSource.netease.title)：\(expected)（HTTP \(String(status))）"))
            #expect(!message.contains("private-") && !message.contains("MUSIC_U") && !message.contains("https://"))
        }
    }

    @Test func offPlatformResponseDoesNotBecomeAnAuthenticationFailure() async throws {
        let url = try #require(URL(string: "https://music.163.com/weapi/fixture"))
        let http = NativeMusicHTTP(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "https://unrelated.invalid/private-url")!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        })
        do {
            _ = try await http.data(for: URLRequest(url: url), source: .netease, cookies: [])
            Issue.record("An off-platform response was accepted")
        } catch {
            #expect(error.localizedDescription == L10n.string("已阻止偏离\(MusicSource.netease.title)原请求地址的响应（HTTP \(String(401))）"))
            #expect(error.localizedDescription.contains("HTTP 401"))
            #expect(!error.localizedDescription.contains("unrelated.invalid"))
        }
    }
}
