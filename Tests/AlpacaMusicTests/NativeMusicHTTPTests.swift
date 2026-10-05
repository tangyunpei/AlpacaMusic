import Foundation
import Testing
@testable import AlpacaMusic

@Suite struct NativeMusicHTTPTests {
    @Test(arguments: [(401, "需要有效登录"), (403, "平台拒绝访问"), (404, "接口或资源未找到"), (429, "请求过于频繁"), (500, "平台服务暂时异常"), (503, "平台服务暂时异常"), (418, "平台未能完成请求")])
    func responseStatusExplainsTheFailureWithoutExposingServerContent(_ status: Int, _ expected: String) async throws {
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
            #expect(message.contains(expected) && message.contains("HTTP \(status)"))
            #expect(!message.contains("private-") && !message.contains("MUSIC_U") && !message.contains("https://"))
            if status != 401 { #expect(!message.contains("重新登录")) }
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
            #expect(error.localizedDescription.contains("已阻止偏离"))
            #expect(error.localizedDescription.contains("HTTP 401"))
            #expect(!error.localizedDescription.contains("重新登录") && !error.localizedDescription.contains("unrelated.invalid"))
        }
    }
}
