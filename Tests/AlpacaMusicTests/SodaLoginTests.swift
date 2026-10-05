import Foundation
import Testing
import WebKit
@testable import AlpacaMusic

private actor SodaQRResponseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private struct SodaQRReply: Sendable {
    var json: String
    var status = 200
    var headers: [String: String] = [:]
    var gate: SodaQRResponseGate?
}

private actor SodaQRFixture {
    private var replies: [SodaQRReply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [SodaQRReply]) { self.replies = replies }
    func respond(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw MusicError.message("Missing synthetic QR response") }
        let reply = replies.removeFirst()
        if let gate = reply.gate { await gate.wait() }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            throw MusicError.message("Invalid synthetic QR response")
        }
        return (Data(reply.json.utf8), response)
    }
}

@MainActor private final class SodaQRTestClock {
    var now = Date(timeIntervalSince1970: 1000)
    func advance(_ seconds: TimeInterval) { now.addTimeInterval(seconds) }
}

private struct SodaQRCookieSnapshot: Sendable {
    var cookies: [MusicSessionCookie] = []
    var gate: SodaQRResponseGate?
}

/// Models the production browser seam without a WKWebView, shared cookie store
/// or live network. Response headers intentionally cannot substitute its jar.
@MainActor private final class SodaQRBrowserFixture: SodaLoginSessionBackend {
    var webView: WKWebView? { nil }
    private let replies: SodaQRFixture
    private var snapshots: [SodaQRCookieSnapshot]
    var prepareGate: SodaQRResponseGate?
    var prepareError: MusicError?
    private(set) var preparations = 0
    private(set) var cancellations = 0
    private(set) var snapshotReads = 0

    init(_ replies: SodaQRFixture, snapshots: [SodaQRCookieSnapshot] = []) {
        self.replies = replies
        self.snapshots = snapshots
    }
    func prepare() async throws {
        preparations += 1
        if let prepareGate { await prepareGate.wait() }
        if let prepareError { throw prepareError }
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await replies.respond(request)
    }
    func snapshotCookies() async throws -> [MusicSessionCookie] {
        snapshotReads += 1
        guard !snapshots.isEmpty else { return [] }
        let snapshot = snapshots.removeFirst()
        if let gate = snapshot.gate { await gate.wait() }
        return snapshot.cookies
    }
    func cancel() { cancellations += 1 }
}

@Suite @MainActor struct SodaLoginTests {
    private var creation: String {
        #"{"message":"success","data":{"error_code":0,"token":"synthetic-qr-token","expire_time":1300,"qrcode_index_url":"https://bff-pc.qishui.com/ucenter_web/app/sdk-next?token=synthetic-qr-token&uc_sdk=scan-auth","copywriting":"抖音 APP"}}"#
    }
    private let csrf = "passport_csrf_token=synthetic-csrf; Domain=.qishui.com; Path=/; Secure"
    private let session = "sessionid=synthetic-session; Domain=.qishui.com; Path=/; Secure"

    private func authentication(_ fixture: SodaQRFixture, clock: SodaQRTestClock) -> SodaQRAuthentication {
        SodaQRAuthentication(transport: { request in try await fixture.respond(request) }, now: { clock.now })
    }

    @Test func browserURLGuardAcceptsTheActualTrailingSlashEndpoints() throws {
        let origin = URL(string: "https://api.qishui.com")!
        for path in ["/passport/web/get_qrcode/", "/passport/web/check_qrconnect/"] {
            let requestURL = origin.appending(path: path)
            #expect(SodaWebLoginSession.isPassportURL(requestURL))
            #expect(SodaWebLoginSession.isPassportURL(URL(string: requestURL.absoluteString + "?aid=386088")!))
        }
    }

    @Test func browserURLGuardRejectsPathAliasesAndForeignOrigins() throws {
        for text in [
            "https://api.qishui.com/passport/web/get_qrcode",
            "https://api.qishui.com/passport/web/%67et_qrcode/",
            "https://api.qishui.com/passport/web/get_qrcode%2F",
            "https://api.qishui.com/passport/callback/",
            "https://bff-pc.qishui.com/passport/web/get_qrcode/",
            "https://api.qishui.com.example/passport/web/get_qrcode/",
            "http://api.qishui.com/passport/web/get_qrcode/",
            "https://api.qishui.com:8443/passport/web/get_qrcode/",
            "https://someone@api.qishui.com/passport/web/get_qrcode/",
            "https://api.qishui.com/passport/web/get_qrcode/#fragment"
        ] {
            let url = try #require(URL(string: text))
            #expect(!SodaWebLoginSession.isPassportURL(url))
        }
    }

    @Test func currentOfficialPCScanTargetAndRequestHaveThreeMinuteDeadline() async throws {
        let clock = SodaQRTestClock()
        let fixture = SodaQRFixture([.init(json: creation, headers: ["Set-Cookie": csrf])])
        let value = authentication(fixture, clock: clock)
        let code = try await value.create()
        #expect(code.scanURL.absoluteString == "https://bff-pc.qishui.com/light/invoke/scan_login?token=synthetic-qr-token&os=Mac&computer_name=AlpacaMusic")
        #expect(code.expiresAt == Date(timeIntervalSince1970: 1180))
        #expect(value.phase == .waiting)
        let request = try #require(await fixture.requests.first)
        let url = try #require(request.url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "aid", value: "386088")))
        #expect(query.contains(URLQueryItem(name: "need_short_url", value: "false")))
        #expect(query.contains(URLQueryItem(name: "device_platform", value: "PC")))
        #expect(query.contains(URLQueryItem(name: "version_code", value: "3.7.0")))
        #expect(!query.contains { ["device_id", "did", "iid", "install_id"].contains($0.name) })
        #expect(value.message.contains("汽水音乐 App") && value.message.contains("扫一扫"))
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "x-tt-passport-csrf-token") == "")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json, text/javascript")
        #expect(request.httpShouldHandleCookies == false)
    }

    @Test func newAndScannedStatesNeverBecomeConnectedAndPollingIsBounded() async throws {
        let clock = SodaQRTestClock()
        let fixture = SodaQRFixture([
            .init(json: creation, headers: ["Set-Cookie": csrf]),
            .init(json: #"{"data":{"error_code":0,"status":"new"}}"#),
            .init(json: #"{"data":{"error_code":0,"status":"scanned"}}"#)
        ])
        let value = authentication(fixture, clock: clock)
        try await value.create()
        #expect(try await value.poll() == nil)
        #expect(value.phase == .waiting)
        #expect(try await value.poll() == nil)
        #expect(await fixture.requests.count == 2)
        clock.advance(2.5)
        #expect(try await value.poll() == nil)
        #expect(value.phase == .scanned)
        let request = try #require(await fixture.requests.last)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "passport_csrf_token=synthetic-csrf")
        #expect(request.value(forHTTPHeaderField: "x-tt-passport-csrf-token") == "synthetic-csrf")
        #expect(request.httpMethod == "POST")
        let url = try #require(request.url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(URLQueryItem(name: "is_new_login", value: "1")))
        #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("is_new_login=1"))
        #expect(!query.contains { ["device_id", "did", "iid", "install_id"].contains($0.name) })
        #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("token=synthetic-qr-token"))
    }

    @Test func missingMismatchedOrRepeatedOfficialQRTokenIsRejected() async throws {
        let urls = [
            "https://bff-pc.qishui.com/ucenter_web/app/sdk-next",
            "https://bff-pc.qishui.com/ucenter_web/app/sdk-next?token=different-synthetic-token",
            "https://bff-pc.qishui.com/ucenter_web/app/sdk-next?token=synthetic-qr-token&token=synthetic-qr-token",
            "https://bff-pc.qishui.com.evil.example/ucenter_web/app/sdk-next?token=synthetic-qr-token"
        ]
        for url in urls {
            let clock = SodaQRTestClock()
            let json = "{\"data\":{\"error_code\":0,\"token\":\"synthetic-qr-token\",\"qrcode_index_url\":\"\(url)\"}}"
            let fixture = SodaQRFixture([.init(json: json)])
            let value = authentication(fixture, clock: clock)
            await #expect(throws: MusicError.self) { try await value.create() }
            #expect(value.phase == .failed && value.challenge == nil)
        }
    }

    @Test func confirmedSessionRequiresProfileValidationBeforeSuccess() async throws {
        let clock = SodaQRTestClock()
        let fixture = SodaQRFixture([
            .init(json: creation),
            .init(json: #"{"data":{"error_code":0,"status":"confirmed"}}"#, headers: ["Set-Cookie": session])
        ])
        let value = authentication(fixture, clock: clock)
        try await value.create()
        let cookies = try #require(try await value.poll())
        #expect(value.phase == .verifying)
        var validations = 0
        try await value.validate(cookies) { incoming in
            #expect(incoming.first?.name == "sessionid")
            validations += 1
        }
        #expect(validations == 1)
        #expect(value.phase == .connected)
        #expect(value.challenge == nil)
    }

    @Test func confirmedWithoutRealCookieOrWithSyntheticBodySessionDoesNotConnect() async throws {
        let clock = SodaQRTestClock()
        let fixture = SodaQRFixture([
            .init(json: creation),
            .init(json: #"{"data":{"error_code":0,"status":"confirmed","sessionid":"must-not-create-cookie"}}"#)
        ])
        let value = authentication(fixture, clock: clock)
        try await value.create()
        await #expect(throws: MusicError.self) { try await value.poll() }
        #expect(value.phase == .failed)
        #expect(value.message.contains("未向本次扫码返回有效会话"))
        #expect(!value.message.contains("must-not-create-cookie"))
    }

    @Test func rejectedProfileIsNotMarkedConnected() async throws {
        let clock = SodaQRTestClock()
        let fixture = SodaQRFixture([
            .init(json: creation),
            .init(json: #"{"data":{"error_code":0,"status":"confirmed"}}"#, headers: ["Set-Cookie": session])
        ])
        let value = authentication(fixture, clock: clock)
        try await value.create()
        let cookies = try #require(try await value.poll())
        await #expect(throws: MusicError.self) {
            try await value.validate(cookies) { _ in throw MusicError.message("账号会话已失效") }
        }
        #expect(value.phase == .failed)
    }

    @Test func errorSevenAndHTTP429RetryOnlyThreeTimesAtFiveSeconds() async throws {
        for status in [200, 429] {
            let clock = SodaQRTestClock()
            let limited = SodaQRReply(json: #"{"data":{"error_code":7,"description":"synthetic-secret-must-not-display"}}"#, status: status)
            let fixture = SodaQRFixture([.init(json: creation), limited, limited, limited, limited])
            let value = authentication(fixture, clock: clock)
            try await value.create()
            for index in 1...3 {
                #expect(try await value.poll() == nil)
                #expect(value.phase == .throttled)
                #expect(value.pollInterval == 5)
                #expect(value.message.contains("\(index)/3"))
                #expect(!value.message.contains("synthetic-secret"))
                #expect(try await value.poll() == nil)
                clock.advance(5)
            }
            await #expect(throws: MusicError.self) { try await value.poll() }
            #expect(value.phase == .failed)
            #expect(await fixture.requests.count == 5)
        }
    }

    @Test func secondVerificationStopsWithSpecificReason() async throws {
        let clock = SodaQRTestClock()
        let fixture = SodaQRFixture([
            .init(json: creation),
            .init(json: #"{"data":{"error_code":2046,"biz_params":{"token":"private-decision"}}}"#)
        ])
        let value = authentication(fixture, clock: clock)
        try await value.create()
        await #expect(throws: MusicError.self) { try await value.poll() }
        #expect(value.phase == .failed)
        #expect(value.message.contains("2046") && value.message.contains("二次身份验证"))
        #expect(!value.message.contains("private-decision"))
        #expect(try await value.poll() == nil)
        #expect(await fixture.requests.count == 2)
    }

    @Test func malformedPresentErrorCodeCannotTrapOrBecomeSuccess() async throws {
        for encoded in ["1e300", "-1e300", "1.5", "true", "null", #""invalid""#] {
            let clock = SodaQRTestClock()
            let fixture = SodaQRFixture([
                .init(json: creation),
                .init(json: "{\"data\":{\"error_code\":\(encoded),\"status\":\"confirmed\"}}", headers: ["Set-Cookie": session])
            ])
            let value = authentication(fixture, clock: clock)
            try await value.create()
            await #expect(throws: MusicError.self) { try await value.poll() }
            #expect(value.phase == .failed)
            #expect(value.message.contains("无效的登录错误码"))
        }
        let clock = SodaQRTestClock()
        let fixture = SodaQRFixture([.init(json: #"{"data":{"error_code":1e300,"token":"synthetic-qr-token","qrcode_index_url":"https://bff-pc.qishui.com/ucenter_web/app/sdk-next"}}"#)])
        let value = authentication(fixture, clock: clock)
        await #expect(throws: MusicError.self) { try await value.create() }
        #expect(value.phase == .failed)
    }

    @Test func expiredQRStopsBeforeRequestAndNeverAcceptsLateConfirmation() async throws {
        let clock = SodaQRTestClock()
        let fixture = SodaQRFixture([.init(json: creation)])
        let value = authentication(fixture, clock: clock)
        try await value.create(); clock.advance(180)
        await #expect(throws: MusicError.self) { try await value.poll() }
        #expect(value.phase == .expired)
        #expect(await fixture.requests.count == 1)

        let gate = SodaQRResponseGate()
        let lateFixture = SodaQRFixture([
            .init(json: creation),
            .init(json: #"{"data":{"error_code":0,"status":"confirmed"}}"#, headers: ["Set-Cookie": session], gate: gate)
        ])
        clock.now = Date(timeIntervalSince1970: 1000)
        let late = authentication(lateFixture, clock: clock)
        try await late.create()
        let pending = Task { @MainActor in try await late.poll() }
        for _ in 0..<100 where !(await gate.waiting) { await Task.yield() }
        #expect(await gate.waiting)
        clock.advance(181); await gate.release()
        await #expect(throws: MusicError.self) { try await pending.value }
        #expect(late.phase == .expired)
    }

    @Test func cancellationDiscardsLateConfirmationAndCannotCallValidator() async throws {
        let clock = SodaQRTestClock(), gate = SodaQRResponseGate()
        let fixture = SodaQRFixture([
            .init(json: creation),
            .init(json: #"{"data":{"error_code":0,"status":"confirmed"}}"#, headers: ["Set-Cookie": session], gate: gate)
        ])
        let value = authentication(fixture, clock: clock)
        try await value.create()
        var validations = 0
        let pending = Task { @MainActor in
            if let cookies = try await value.poll() { try await value.validate(cookies) { _ in validations += 1 } }
        }
        for _ in 0..<100 where !(await gate.waiting) { await Task.yield() }
        #expect(await gate.waiting)
        value.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(value.phase == .cancelled)
        #expect(validations == 0)
    }

    @Test func cancellingValidationCannotMarkCompletedAfterItsLateResult() async throws {
        let clock = SodaQRTestClock(), gate = SodaQRResponseGate()
        let fixture = SodaQRFixture([
            .init(json: creation),
            .init(json: #"{"data":{"error_code":0,"status":"confirmed"}}"#, headers: ["Set-Cookie": session])
        ])
        let value = authentication(fixture, clock: clock)
        try await value.create()
        let cookies = try #require(try await value.poll())
        let pending = Task { @MainActor in try await value.validate(cookies) { _ in await gate.wait() } }
        for _ in 0..<100 where !(await gate.waiting) { await Task.yield() }
        #expect(await gate.waiting)
        value.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(value.phase == .cancelled)
    }

    @Test func refreshAndSeparateInstancesDoNotReuseCookies() async throws {
        let clock = SodaQRTestClock()
        let fixture = SodaQRFixture([
            .init(json: creation, headers: ["Set-Cookie": session]),
            .init(json: creation),
            .init(json: creation)
        ])
        let first = authentication(fixture, clock: clock)
        try await first.create(); try await first.create()
        let second = authentication(fixture, clock: clock)
        try await second.create()
        #expect(await fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
    }

    @Test func callbackAllowsOnlyOfficialHTTPSAndNeverRequestsCrossOrigin() async throws {
        for address in ["http://api.qishui.com/callback", "https://api.qishui.com.evil.example/", "https://user:pass@api.qishui.com/", "https://api.qishui.com:8443/", "https://auth.zijieapi.com/", "file:///private/tmp/login"] {
            let url = try #require(URL(string: address))
            #expect(!SodaQRAuthentication.allowedRedirect(url))
        }
        let clock = SodaQRTestClock()
        let fixture = SodaQRFixture([
            .init(json: creation, headers: ["Set-Cookie": csrf]),
            .init(json: #"{"data":{"error_code":0,"status":"confirmed","redirect_url":"https://bff-pc.qishui.com/confirmed"}}"#)
        ])
        let value = authentication(fixture, clock: clock)
        try await value.create()
        await #expect(throws: MusicError.self) { try await value.poll() }
        #expect(value.phase == .failed)
        #expect(value.message.contains("跨域登录回调") && value.message.contains("暂未支持"))
        #expect(await fixture.requests.count == 2)
        #expect(await fixture.requests.allSatisfy { $0.url?.host == "api.qishui.com" })
    }

    @Test func offPlatformRedirectAndWrongDomainCookiesAreRejected() async throws {
        let clock = SodaQRTestClock()
        let badRedirect = SodaQRFixture([
            .init(json: creation),
            .init(json: #"{"data":{"error_code":0,"status":"confirmed","redirect_url":"https://api.qishui.com.evil.example/private-token"}}"#)
        ])
        let first = authentication(badRedirect, clock: clock)
        try await first.create()
        await #expect(throws: MusicError.self) { try await first.poll() }
        #expect(await badRedirect.requests.count == 2)
        #expect(!first.message.contains("private-token"))
        let badCookie = SodaQRFixture([
            .init(json: creation),
            .init(json: #"{"data":{"error_code":0,"status":"confirmed"}}"#, headers: ["Set-Cookie": "sessionid=synthetic-wrong-domain; Domain=evil.example; Path=/; Secure"])
        ])
        let second = authentication(badCookie, clock: clock)
        try await second.create()
        await #expect(throws: MusicError.self) { try await second.poll() }
        #expect(second.phase == .failed)
    }

    @Test func csrfUsesOnlyMatchingPrivateCookiesAndPrimaryThenFallback() async throws {
        let cases: [(String, String)] = [
            ("passport_csrf_token_default=synthetic-fallback; Domain=.qishui.com; Path=/; Secure", "synthetic-fallback"),
            ("passport_csrf_token=synthetic-wrong-path; Domain=.qishui.com; Path=/luna; Secure", ""),
            ("passport_csrf_token=synthetic-wrong-host; Domain=bff-pc.qishui.com; Path=/; Secure", ""),
            ("passport_csrf_token=synthetic-primary; Domain=.qishui.com; Path=/; Secure, passport_csrf_token_default=synthetic-fallback; Domain=.qishui.com; Path=/; Secure", "synthetic-primary")
        ]
        for (header, expected) in cases {
            let clock = SodaQRTestClock()
            let fixture = SodaQRFixture([
                .init(json: creation, headers: ["Set-Cookie": header]),
                .init(json: #"{"data":{"error_code":0,"status":"new"}}"#)
            ])
            let value = authentication(fixture, clock: clock)
            try await value.create(); _ = try await value.poll()
            #expect(await fixture.requests.last?.value(forHTTPHeaderField: "x-tt-passport-csrf-token") == expected)
        }
    }

    @Test func portraitAndPublicSDKMetadataMatchWithinAttemptAndRefreshChangesPortrait() async throws {
        let clock = SodaQRTestClock()
        let fixture = SodaQRFixture([
            .init(json: creation), .init(json: #"{"data":{"error_code":0,"status":"new"}}"#),
            .init(json: creation)
        ])
        let value = authentication(fixture, clock: clock)
        try await value.create(); _ = try await value.poll(); try await value.create()
        let requests = await fixture.requests
        let first = try #require(requests[0].value(forHTTPHeaderField: "x-tt-passport-verify-portrait"))
        #expect(first.hasSuffix(".login"))
        #expect(UUID(uuidString: String(first.dropLast(6))) != nil)
        #expect(requests[1].value(forHTTPHeaderField: "x-tt-passport-verify-portrait") == first)
        #expect(requests[2].value(forHTTPHeaderField: "x-tt-passport-verify-portrait") != first)
        let trace = try #require(requests[0].value(forHTTPHeaderField: "x-tt-passport-trace-id"))
        #expect(trace.range(of: "^[0-9a-f]{8}$", options: .regularExpression) != nil)
        #expect(requests[1].value(forHTTPHeaderField: "x-tt-passport-trace-id") == trace)
        #expect(requests[2].value(forHTTPHeaderField: "x-tt-passport-trace-id") != trace)
        for request in requests {
            let url = try #require(request.url)
            let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(query.contains(URLQueryItem(name: "biz_trace_id", value: request.value(forHTTPHeaderField: "x-tt-passport-trace-id"))))
            #expect(query.contains(URLQueryItem(name: "p_js_v", value: "2.4.13")))
            #expect(query.contains(URLQueryItem(name: "p_js_t", value: "pro")))
            #expect(query.contains(URLQueryItem(name: "p_ver", value: "1.0.29")))
            #expect(query.contains(URLQueryItem(name: "passport_jssdk_type", value: "normal")))
            #expect(query.contains(URLQueryItem(name: "account_sdk_source", value: "web")))
            #expect(query.contains(URLQueryItem(name: "language", value: "zh")))
            #expect(!query.contains { ["p_zt", "p_bd", "request_host"].contains($0.name) })
        }
    }

    @Test func currentFailureCodePreservesSafePlatformExplanationAndStopsPolling() async throws {
        let clock = SodaQRTestClock()
        let fixture = SodaQRFixture([
            .init(json: creation, headers: ["Set-Cookie": csrf]),
            .init(json: #"{"message":"success","data":{"error_code":2156,"description":"扫码确认未完成 synthetic-qr-token synthetic-csrf https://api.qishui.com/path?token=other-secret 13812345678 private@example.com abcdefghijklmnopqrstuvwxyz0123456789"}}"#)
        ])
        let value = authentication(fixture, clock: clock)
        try await value.create()
        await #expect(throws: MusicError.self) { try await value.poll() }
        #expect(value.phase == .failed)
        #expect(value.message.contains("扫码确认") && value.message.contains("2156"))
        #expect(value.message.contains("平台说明：扫码确认未完成"))
        for secret in ["synthetic-qr-token", "synthetic-csrf", "other-secret", "13812345678", "private@example.com", "abcdefghijklmnopqrstuvwxyz0123456789"] {
            #expect(!value.message.contains(secret))
        }
        #expect(!value.message.contains("success"))
        #expect(try await value.poll() == nil)
        #expect(await fixture.requests.count == 2)
    }

    @Test func outerErrorCannotBecomeInnerSuccessAndMalformedOuterCodeIsRejected() async throws {
        for json in [
            #"{"error_code":2156,"description":"外层平台拒绝 short-root-token short-session","token":"short-root-token","sessionid":"short-session","data":{"error_code":0,"status":"confirmed"}}"#,
            #"{"error_code":1e300,"data":{"error_code":0,"status":"confirmed"}}"#
        ] {
            let clock = SodaQRTestClock()
            let fixture = SodaQRFixture([
                .init(json: creation), .init(json: json, headers: ["Set-Cookie": session])
            ])
            let value = authentication(fixture, clock: clock)
            try await value.create()
            await #expect(throws: MusicError.self) { try await value.poll() }
            #expect(value.phase == .failed)
            if json.contains("2156") {
                #expect(value.message.contains("2156") && value.message.contains("外层平台拒绝"))
                #expect(!value.message.contains("short-root-token") && !value.message.contains("short-session"))
            } else { #expect(value.message.contains("无效的登录错误码")) }
        }
    }

    @Test func wrapperSuccessIsNotAnExplanationAndPlatformDescriptionsAreBounded() async throws {
        for detail in ["success", String(repeating: "平台失败原因", count: 1000)] {
            let clock = SodaQRTestClock()
            let fixture = SodaQRFixture([
                .init(json: creation),
                .init(json: "{\"message\":\"success\",\"data\":{\"error_code\":2156,\"description\":\"\(detail)\"}}")
            ])
            let value = authentication(fixture, clock: clock)
            try await value.create()
            await #expect(throws: MusicError.self) { try await value.poll() }
            #expect(value.message.count <= 290)
            #expect(!value.message.contains("success"))
            if detail == "success" { #expect(value.message.contains("未提供具体原因")) }
        }
    }

    @Test func responseCanSetSessionForLaterProfilePath() async throws {
        let clock = SodaQRTestClock()
        let fixture = SodaQRFixture([
            .init(json: creation),
            .init(json: #"{"data":{"error_code":0,"status":"confirmed"}}"#,
                  headers: ["Set-Cookie": "sessionid=synthetic-later-path; Domain=.qishui.com; Path=/luna; Secure"])
        ])
        let value = authentication(fixture, clock: clock)
        try await value.create()
        let cookies = try #require(try await value.poll())
        #expect(cookies.contains { $0.name == "sessionid" && $0.path == "/luna" })
        #expect(value.phase == .verifying)
    }

    @Test func maxAgeZeroAndPastExpiryDeletePrivateCookies() async throws {
        for deletion in [
            "passport_csrf_token=deleted; Domain=.qishui.com; Path=/; Secure; Max-Age=0",
            "passport_csrf_token=deleted; Domain=.qishui.com; Path=/; Secure; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
        ] {
            let clock = SodaQRTestClock()
            // Foundation converts Max-Age to an absolute real-clock Expires
            // and does not retain maximumAge in HTTPCookie.properties.
            clock.now = Date()
            let freshCreation = creation.replacingOccurrences(of: "\"expire_time\":1300", with: "\"expire_time\":\(Int(clock.now.timeIntervalSince1970) + 180)")
            let fixture = SodaQRFixture([
                .init(json: freshCreation, headers: ["Set-Cookie": csrf]),
                .init(json: #"{"data":{"error_code":0,"status":"new"}}"#, headers: ["Set-Cookie": deletion]),
                .init(json: #"{"data":{"error_code":0,"status":"new"}}"#)
            ])
            let value = authentication(fixture, clock: clock)
            try await value.create(); _ = try await value.poll()
            // Foundation converted Max-Age using real time while these actor
            // awaits could be suspended behind rendering tests. Move the fake
            // clock beyond that conversion as well as the polling interval.
            clock.now = max(clock.now.addingTimeInterval(2.5), Date().addingTimeInterval(2.5))
            _ = try await value.poll()
            #expect(await fixture.requests.last?.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(await fixture.requests.last?.value(forHTTPHeaderField: "x-tt-passport-csrf-token") == "")
        }
    }

    @Test func failureEnvelopeWithoutNumericCodeCannotBecomeConfirmedSuccess() async throws {
        let clock = SodaQRTestClock()
        let fixture = SodaQRFixture([
            .init(json: creation),
            .init(json: #"{"message":"error","description":"平台无法确认登录","data":{"error_code":0,"status":"confirmed"}}"#,
                  headers: ["Set-Cookie": session])
        ])
        let value = authentication(fixture, clock: clock)
        try await value.create()
        await #expect(throws: MusicError.self) { try await value.poll() }
        #expect(value.phase == .failed)
        #expect(value.message.contains("平台无法确认登录"))
        #expect(!value.message.contains("错误 0") && !value.message.contains("错误 -1"))
        #expect(try await value.poll() == nil)
    }

    @Test func explicitlyInjectedTransportNeverStartsBrowserOrLiveNetwork() async throws {
        let clock = SodaQRTestClock()
        let fixture = SodaQRFixture([.init(json: creation)])
        var browserCreations = 0
        let browser = SodaQRBrowserFixture(SodaQRFixture([]))
        let value = SodaQRAuthentication(transport: { try await fixture.respond($0) }, browserFactory: {
            browserCreations += 1
            return browser
        }, now: { clock.now })
        defer { value.cancel() }
        try await value.create()
        #expect(browserCreations == 0 && browser.preparations == 0)
        #expect(value.webView == nil)
        #expect(await fixture.requests.count == 1)
    }

    @Test func browserConfirmationUsesCookieStoreAndSkipsUnnecessaryCallback() async throws {
        let clock = SodaQRTestClock()
        let fixture = SodaQRFixture([
            .init(json: creation, headers: ["Set-Cookie": "sessionid=header-must-not-create-session; Domain=.qishui.com; Path=/; Secure"]),
            .init(json: #"{"data":{"error_code":0,"status":"confirmed","redirect_url":"https://bff-pc.qishui.com/confirmed"}}"#)
        ])
        let actualSession = MusicSessionCookie(name: "sessionid", value: "synthetic-cookie-store-session", domain: ".qishui.com", path: "/luna")
        let wrongDomain = MusicSessionCookie(name: "sessionid_ss", value: "synthetic-foreign-session", domain: ".evil.example")
        let browser = SodaQRBrowserFixture(fixture, snapshots: [
            .init(), .init(cookies: [actualSession, wrongDomain])
        ])
        let value = SodaQRAuthentication(browserFactory: { browser }, now: { clock.now })
        try await value.create()
        let cookies = try #require(try await value.poll())
        #expect(cookies == [actualSession])
        #expect(value.phase == .verifying)
        #expect(browser.preparations == 1 && browser.snapshotReads == 2)
        #expect(browser.cancellations == 0)
        #expect(await fixture.requests.count == 2)
        #expect(await fixture.requests.allSatisfy {
            $0.url?.host == "api.qishui.com" && $0.value(forHTTPHeaderField: "Cookie") == nil &&
            $0.value(forHTTPHeaderField: "Origin") == nil && $0.value(forHTTPHeaderField: "User-Agent") == nil &&
            $0.value(forHTTPHeaderField: "x-tt-passport-csrf-token") == nil
        })
        // Once confirmed, the QR lifetime does not revoke a profile validation.
        clock.advance(181)
        try await value.validate(cookies) { #expect($0 == [actualSession]) }
        #expect(value.phase == .connected && value.challenge == nil)
        #expect(browser.cancellations == 1 && value.webView == nil)
    }

    @Test func browserHeadersAndBodyCannotManufactureAuthenticatedCookies() async throws {
        let clock = SodaQRTestClock()
        let fixture = SodaQRFixture([
            .init(json: creation, headers: ["Set-Cookie": session]),
            .init(json: #"{"data":{"error_code":0,"status":"confirmed","sessionid":"synthetic-body-cookie"}}"#,
                  headers: ["Set-Cookie": session])
        ])
        let browser = SodaQRBrowserFixture(fixture)
        let value = SodaQRAuthentication(browserFactory: { browser }, now: { clock.now })
        try await value.create()
        await #expect(throws: MusicError.self) { try await value.poll() }
        #expect(value.phase == .failed && value.challenge == nil)
        #expect(value.message.contains("未向本次扫码返回有效会话"))
        #expect(!value.message.contains("synthetic-body-cookie"))
        #expect(browser.snapshotReads == 2 && browser.cancellations == 1)
    }

    @Test func preparationUsesSameThreeMinuteBudgetAndExpiryClosesBrowser() async throws {
        for delay in [60.0, 180.0] {
            let clock = SodaQRTestClock(), gate = SodaQRResponseGate()
            let fixture = SodaQRFixture([.init(json: creation)])
            let browser = SodaQRBrowserFixture(fixture)
            browser.prepareGate = gate
            let value = SodaQRAuthentication(browserFactory: { browser }, now: { clock.now })
            let pending = Task { @MainActor in try await value.create() }
            for _ in 0..<100 where !(await gate.waiting) { await Task.yield() }
            #expect(await gate.waiting)
            #expect(value.phase == .creating && browser.preparations == 1)
            #expect(await fixture.requests.isEmpty)
            clock.advance(delay)
            await gate.release()
            if delay < 180 {
                let qr = try await pending.value
                #expect(qr.expiresAt == Date(timeIntervalSince1970: 1180))
                #expect(value.phase == .waiting && browser.cancellations == 0)
                value.cancel()
            } else {
                await #expect(throws: MusicError.self) { try await pending.value }
                #expect(value.phase == .expired && value.challenge == nil)
                #expect(await fixture.requests.isEmpty)
                #expect(browser.snapshotReads == 0)
            }
            #expect(browser.cancellations == 1)
        }
    }

    @Test func QRCreationTransportFailureReportsExpiryOnlyAfterDeadline() async throws {
        for delay in [10.0, 181.0] {
            let clock = SodaQRTestClock()
            let value = SodaQRAuthentication(transport: { _ in
                await MainActor.run { clock.advance(delay) }
                throw MusicError.message("合成的获取二维码请求超时")
            }, now: { clock.now })
            await #expect(throws: MusicError.self) { try await value.create() }
            #expect(value.challenge == nil)
            if delay >= 180 {
                #expect(value.phase == .expired)
                #expect(value.message == "二维码已过期，请重新获取。")
            } else {
                #expect(value.phase == .failed)
                #expect(value.message == "合成的获取二维码请求超时")
            }
        }
    }

    @Test func QRConfirmationTransportFailureReportsExpiryOnlyAfterDeadline() async throws {
        for delay in [10.0, 181.0] {
            let clock = SodaQRTestClock()
            let fixture = SodaQRFixture([.init(json: creation)])
            let value = SodaQRAuthentication(transport: { request in
                if let url = request.url,
                   URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/passport/web/get_qrcode/" {
                    return try await fixture.respond(request)
                }
                await MainActor.run { clock.advance(delay) }
                throw MusicError.message("合成的扫码确认请求超时")
            }, now: { clock.now })
            try await value.create()
            await #expect(throws: MusicError.self) { try await value.poll() }
            #expect(value.challenge == nil)
            if delay >= 180 {
                #expect(value.phase == .expired)
                #expect(value.message == "二维码已过期，请重新获取。")
            } else {
                #expect(value.phase == .failed)
                #expect(value.message == "合成的扫码确认请求超时")
            }
            #expect(await fixture.requests.count == 1)
        }
    }

    @Test func profileValidationFailureAfterQRDeadlineKeepsAccountFailureReason() async throws {
        let clock = SodaQRTestClock()
        let fixture = SodaQRFixture([
            .init(json: creation),
            .init(json: #"{"data":{"error_code":0,"status":"confirmed"}}"#, headers: ["Set-Cookie": session])
        ])
        let value = authentication(fixture, clock: clock)
        try await value.create()
        let cookies = try #require(try await value.poll())
        clock.advance(181)
        await #expect(throws: MusicError.self) {
            try await value.validate(cookies) { _ in
                throw MusicError.message("合成的账号验证失败")
            }
        }
        #expect(value.phase == .failed)
        #expect(value.message == "合成的账号验证失败")
        #expect(value.challenge == nil)
    }

    @Test func alreadyCancelledCreationCannotReplaceActiveBrowserAttempt() async throws {
        let clock = SodaQRTestClock()
        let fixture = SodaQRFixture([.init(json: creation)])
        let browser = SodaQRBrowserFixture(fixture)
        var browserCreations = 0
        let value = SodaQRAuthentication(browserFactory: {
            browserCreations += 1
            return browser
        }, now: { clock.now })
        defer { value.cancel() }
        let challenge = try await value.create()
        let message = value.message

        // This actor cannot enter the new Task before the synchronous cancel.
        // A stale queued refresh must not close the newer live login attempt.
        let staleRefresh = Task { @MainActor in try await value.create() }
        staleRefresh.cancel()
        await #expect(throws: CancellationError.self) { try await staleRefresh.value }

        #expect(value.phase == .waiting && value.challenge == challenge)
        #expect(value.message == message)
        #expect(browserCreations == 1 && browser.preparations == 1)
        #expect(browser.cancellations == 0 && browser.snapshotReads == 1)
        #expect(await fixture.requests.count == 1)
    }

    @Test func cancelledPreparationCannotPublishQRorSendRequest() async throws {
        let clock = SodaQRTestClock(), gate = SodaQRResponseGate()
        let fixture = SodaQRFixture([.init(json: creation)])
        let browser = SodaQRBrowserFixture(fixture)
        browser.prepareGate = gate
        let value = SodaQRAuthentication(browserFactory: { browser }, now: { clock.now })
        let pending = Task { @MainActor in try await value.create() }
        for _ in 0..<100 where !(await gate.waiting) { await Task.yield() }
        #expect(await gate.waiting)
        value.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(value.phase == .cancelled && value.challenge == nil)
        #expect(await fixture.requests.isEmpty)
        #expect(browser.snapshotReads == 0 && browser.cancellations == 1)
    }

    @Test func refreshCreatesNewBrowserAndRejectsOldLatePoll() async throws {
        let clock = SodaQRTestClock(), gate = SodaQRResponseGate()
        let oldFixture = SodaQRFixture([
            .init(json: creation),
            .init(json: #"{"data":{"error_code":0,"status":"confirmed"}}"#, gate: gate)
        ])
        let first = SodaQRBrowserFixture(oldFixture, snapshots: [
            .init(cookies: [MusicSessionCookie(name: "passport_csrf_token", value: "synthetic-old-csrf", domain: ".qishui.com")]),
            .init(cookies: [MusicSessionCookie(name: "sessionid", value: "synthetic-old-session", domain: ".qishui.com")])
        ])
        let newFixture = SodaQRFixture([.init(json: creation)])
        let second = SodaQRBrowserFixture(newFixture)
        var creations = 0
        let value = SodaQRAuthentication(browserFactory: {
            creations += 1
            return creations == 1 ? first : second
        }, now: { clock.now })
        try await value.create()
        let oldPoll = Task { @MainActor in try await value.poll() }
        for _ in 0..<100 where !(await gate.waiting) { await Task.yield() }
        #expect(await gate.waiting)
        try await value.create()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await oldPoll.value }
        #expect(creations == 2 && first.cancellations == 1 && second.preparations == 1)
        #expect(first.snapshotReads == 1 && second.snapshotReads == 1)
        #expect(value.phase == .waiting)
        #expect(await newFixture.requests.first?.value(forHTTPHeaderField: "Cookie") == nil)
        value.cancel()
        #expect(second.cancellations == 1)
    }

    @Test func cancelledCookieSnapshotCannotReachProfileValidation() async throws {
        let clock = SodaQRTestClock(), gate = SodaQRResponseGate()
        let fixture = SodaQRFixture([
            .init(json: creation), .init(json: #"{"data":{"error_code":0,"status":"confirmed"}}"#)
        ])
        let browser = SodaQRBrowserFixture(fixture, snapshots: [
            .init(), .init(cookies: [MusicSessionCookie(name: "sessionid", value: "synthetic-late-session", domain: ".qishui.com")], gate: gate)
        ])
        let value = SodaQRAuthentication(browserFactory: { browser }, now: { clock.now })
        try await value.create()
        var validations = 0
        let pending = Task { @MainActor in
            if let cookies = try await value.poll() {
                try await value.validate(cookies) { _ in validations += 1 }
            }
        }
        for _ in 0..<100 where !(await gate.waiting) { await Task.yield() }
        #expect(await gate.waiting)
        value.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(validations == 0 && value.phase == .cancelled)
        #expect(browser.cancellations == 1)
    }

    @Test func preparationFailureCannotFallBackToNativeHTTP() async throws {
        let clock = SodaQRTestClock()
        let fixture = SodaQRFixture([.init(json: creation)])
        let browser = SodaQRBrowserFixture(fixture)
        browser.prepareError = .message("合成的网页运行环境未就绪")
        let value = SodaQRAuthentication(browserFactory: { browser }, now: { clock.now })
        await #expect(throws: MusicError.self) { try await value.create() }
        #expect(value.phase == .failed && value.message == "合成的网页运行环境未就绪")
        #expect(browser.cancellations == 1 && browser.snapshotReads == 0)
        #expect(await fixture.requests.isEmpty)
    }

    @Test func realSessionDoesNotPermitUntrustedCallbackAndSameOriginWithoutSessionIsUnsupported() async throws {
        for (callback, snapshot, expected) in [
            ("https://foreign.example/private-redirect-token", [MusicSessionCookie(name: "sessionid", value: "synthetic-session", domain: ".qishui.com")], "不受信任"),
            ("https://api.qishui.com/passport/callback", [], "暂未支持该登录回调")
        ] {
            let clock = SodaQRTestClock()
            let fixture = SodaQRFixture([
                .init(json: creation),
                .init(json: "{\"data\":{\"error_code\":0,\"status\":\"confirmed\",\"redirect_url\":\"\(callback)\"}}")
            ])
            let browser = SodaQRBrowserFixture(fixture, snapshots: [.init(), .init(cookies: snapshot)])
            let value = SodaQRAuthentication(browserFactory: { browser }, now: { clock.now })
            try await value.create()
            await #expect(throws: MusicError.self) { try await value.poll() }
            #expect(value.phase == .failed && value.message.contains(expected))
            #expect(!value.message.contains("private-redirect-token"))
            #expect(await fixture.requests.count == 2)
            #expect(browser.cancellations == 1)
        }
    }

}
