import Foundation
import Testing
@testable import AlpacaMusic

@Suite struct NeteaseDirectTests {
    private var cookies: [MusicSessionCookie] {
        [.init(name: "MUSIC_U", value: "fixture-session", domain: ".music.163.com"),
         .init(name: "__csrf", value: "fixture-csrf", domain: ".music.163.com")]
    }
    private func provider(_ fixture: NEFixture) -> NeteaseDirectProvider {
        NeteaseDirectProvider(http: NativeMusicHTTP(transport: { request in try await fixture.respond(request) }))
    }

    @Test func websiteEnvelopeMatchesIndependentAESAndRSAVector() throws {
        // Expected values computed independently with OpenSSL AES and integer RSA.
        let envelope = try NeteaseWebCrypto.encrypt(Data("{\"csrf_token\":\"\"}".utf8), secret: Data("0123456789abcdef".utf8))
        #expect(envelope.params == "echuH06dDs7OxMA2egejtvWuTbLs/0W4Iar5ZYYlrHZMs++29jrOmUM2kZbJQK22")
        #expect(envelope.encSecKey == "35701388baf89fed412e11269b9c76625d095ecaf17f03fa018abe19ea2d38b949debf242ee39a71ca1f6cda71b1b86a45aa909ee27f7e78e267d34e732f0de948206c3340a788d0003372183e2f753c1f78b66ac23d134ac1fc9b993156520ea826b8aa89a962d4491b4b8d7e08738e1da9b07aa39bf4a7ef0b1c210728cd52")
        let form = String(decoding: envelope.formData, as: UTF8.self)
        #expect(form.contains("%2B%2B"))
        #expect(!form.contains("+"))
        #expect(throws: MusicError.self) { try NeteaseWebCrypto.encrypt(Data(), secret: Data()) }
    }

    @Test func missingExpiredOrWrongDomainLoginNeverSendsARequest() async {
        let fixture = NEFixture([]), value = provider(fixture)
        let badCookies: [[MusicSessionCookie]] = [[], [.init(name: "MUSIC_U", value: "fixture", domain: ".qq.com")], [.init(name: "MUSIC_U", value: "fixture", domain: ".music.163.com", expires: .distantPast)]]
        for cookies in badCookies {
            await #expect(throws: MusicError.self) { try await value.profile(cookies: cookies) }
        }
        #expect(await fixture.count == 0)
    }

    @Test func profileAndSearchUseWebsiteEnvelopeWithoutPlaintextBody() async throws {
        let fixture = NEFixture([
            .init(path: "/weapi/w/nuser/account/get", json: #"{"code":200,"profile":{"userId":123,"nickname":"测试用户"}}"#),
            .init(path: "/weapi/cloudsearch/pc", json: #"{"code":200,"result":{"songCount":1,"songs":[{"id":456,"name":"测试歌曲","ar":[{"name":"艺术家"}],"al":{"name":"专辑","picUrl":"https://p1.music.126.net/cover.jpg"},"dt":125000}]}}"#)
        ])
        let value = provider(fixture)
        #expect(try await value.profile(cookies: cookies) == MusicAccountProfile(id: "123", displayName: "测试用户"))
        let tracks = try await value.search("fixture-secret-query", cookies: cookies)
        #expect(tracks.count == 1)
        #expect(tracks.first?.id == "netease:456")
        #expect(tracks.first?.duration == 125)
        #expect(tracks.first?.artworkURL?.host == "p1.music.126.net")
        let requests = await fixture.requests
        #expect(requests.allSatisfy { $0.url?.host == "music.163.com" && $0.httpMethod == "POST" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie")?.contains("MUSIC_U=fixture-session") == true })
        #expect(requests.allSatisfy { !String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains("fixture-secret-query") })
    }

    @Test func csrfPayloadAndHeaderUseTheSameScopedCookiePrecedence() async throws {
        let url = try #require(URL(string: "https://music.163.com/weapi/w/nuser/account/get"))
        let scoped = cookies + [
            MusicSessionCookie(name: "__csrf", value: "deeper-token", domain: ".music.163.com", path: "/weapi/w"),
            MusicSessionCookie(name: "__csrf", value: "wrong-path", domain: ".music.163.com", path: "/weapi/wrong"),
            MusicSessionCookie(name: "__csrf", value: "wrong-host", domain: "interface.music.163.com", path: "/weapi/w/nuser"),
            MusicSessionCookie(name: "__csrf", value: "expired", domain: ".music.163.com", path: "/weapi/w/nuser", expires: .distantPast)
        ]
        for values in [scoped, Array(scoped.reversed())] {
            let matched = DirectMusicAccess.requestCookies(values, for: .netease, url: url)
            let body = try NeteaseDirectProvider.requestPayload(["csrf_token": "payload-must-not-override-session"], matchingCookies: matched)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json["csrf_token"] == "deeper-token")
            let fixture = NEFixture([.init(path: url.path, json: #"{"code":200,"profile":{"userId":123,"nickname":"Fixture"}}"#)])
            _ = try await provider(fixture).profile(cookies: values)
            let request = try #require(await fixture.requests.first)
            let header = try #require(request.value(forHTTPHeaderField: "Cookie"))
            #expect(header.hasPrefix("__csrf=deeper-token;"))
            #expect(!header.contains("wrong-") && !header.contains("expired"))
        }
    }

    @Test func absentMatchingCsrfStaysEmptyWithoutCreatingACookie() async throws {
        let url = try #require(URL(string: "https://music.163.com/weapi/w/nuser/account/get"))
        let values = [cookies[0], MusicSessionCookie(name: "__csrf", value: "not-for-this-path", domain: ".music.163.com", path: "/other")]
        let matched = DirectMusicAccess.requestCookies(values, for: .netease, url: url)
        let body = try NeteaseDirectProvider.requestPayload([:], matchingCookies: matched)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["csrf_token"] == "")
        let fixture = NEFixture([.init(path: url.path, json: #"{"code":200,"profile":{"userId":123,"nickname":"Fixture"}}"#)])
        _ = try await provider(fixture).profile(cookies: values)
        #expect(await fixture.requests.first?.value(forHTTPHeaderField: "Cookie") == "MUSIC_U=fixture-session")
    }

    @Test func loggedOutProfileDoesNotBecomeAnAccount() async {
        let fixture = NEFixture([.init(path: "/weapi/w/nuser/account/get", json: #"{"code":200,"account":null,"profile":null}"#)])
        await #expect(throws: MusicError.self) { try await provider(fixture).profile(cookies: cookies) }
    }

    @Test func everyPlaylistPageIsReadAndRepeatedPagesFailClearly() async throws {
        let first = #"{"code":200,"more":true,"playlist":[{"id":1,"name":"第一张歌单","trackCount":2}]}"#
        let fixture = NEFixture([
            .init(path: "/weapi/user/playlist", json: first),
            .init(path: "/weapi/user/playlist", json: #"{"code":200,"more":false,"playlist":[{"id":"2","name":"第二张歌单","trackCount":3}]}"#)
        ])
        let playlists = try await provider(fixture).playlists(profile: .init(id: "123", displayName: "用户"), cookies: cookies)
        #expect(playlists.map(\.id) == ["1", "2"])
        #expect(await fixture.count == 2)
        let repeated = NEFixture([.init(path: "/weapi/user/playlist", json: first), .init(path: "/weapi/user/playlist", json: first)])
        await #expect(throws: MusicError.self) { try await provider(repeated).playlists(profile: .init(id: "123", displayName: "用户"), cookies: cookies) }
    }

    @Test func completePlaylistPreservesOrderAcrossBatchesAndUnavailableIDs() async throws {
        let ids = (1...205).map { ["id": $0] }
        let detail = try json(["code": 200, "playlist": ["id": 123, "trackCount": 205, "trackIds": ids, "tracks": []]])
        let batchOne = try json(["code": 200, "songs": (1...200).reversed().map { ["id": $0, "name": "歌曲\($0)"] }])
        // ID 203 has no available metadata; it must not silently disappear.
        let batchTwo = try json(["code": 200, "songs": [205, 204, 202, 201].map { ["id": $0, "name": "歌曲\($0)"] }])
        let fixture = NEFixture([.init(path: "/weapi/v6/playlist/detail", json: detail), .init(path: "/weapi/v3/song/detail", json: batchOne), .init(path: "/weapi/v3/song/detail", json: batchTwo)])
        let tracks = try await provider(fixture).tracks(in: .init(id: "123", name: "完整歌单", trackCount: 205, source: .netease), cookies: cookies)
        #expect(tracks.map(\.sourceID) == (1...205).map { String($0) })
        #expect(tracks[202].unavailable)
        #expect(tracks[204].title == "歌曲205")
        #expect(await fixture.count == 3)
    }

    @Test func incompletePlaylistAndInterruptedBatchNeverReturnPartialImport() async throws {
        let incomplete = NEFixture([.init(path: "/weapi/v6/playlist/detail", json: #"{"code":200,"playlist":{"id":1,"trackCount":2,"trackIds":[{"id":9}]}}"#)])
        let playlist = RemoteMusicPlaylist(id: "1", name: "歌单", trackCount: 2, source: .netease)
        await #expect(throws: MusicError.self) { try await provider(incomplete).tracks(in: playlist, cookies: cookies) }
        #expect(await incomplete.count == 1)
        let interrupted = NEFixture([
            .init(path: "/weapi/v6/playlist/detail", json: #"{"code":200,"playlist":{"id":1,"trackCount":2,"trackIds":[{"id":9},{"id":10}]}}"#),
            .init(path: "/weapi/v3/song/detail", json: #"{"code":301}"#)
        ])
        await #expect(throws: MusicError.self) { try await provider(interrupted).tracks(in: playlist, cookies: cookies) }
    }

    @Test func playbackAcceptsOfficialURLAndRejectsTrialsWithoutFallback() async throws {
        let track = Track(id: "netease:9", title: "歌曲", artist: "", album: "", duration: 100, source: .netease, sourceID: "9")
        let good = NEFixture([.init(path: "/weapi/song/enhance/player/url/v1", json: #"{"code":200,"data":[{"id":9,"code":200,"url":"https://m801.music.126.net/song.mp3","freeTrialInfo":null}]}"#)])
        #expect(try await provider(good).resolve(track, cookies: cookies).host == "m801.music.126.net")
        for result in [
            #"{"code":200,"data":[{"id":9,"code":200,"url":"https://m801.music.126.net/trial.mp3","freeTrialInfo":{"start":0,"end":30}}]}"#,
            #"{"code":200,"data":[{"id":9,"code":200,"url":"https://example.com/song.mp3"}]}"#
        ] {
            let rejected = NEFixture([.init(path: "/weapi/song/enhance/player/url/v1", json: result)])
            await #expect(throws: MusicError.self) { try await provider(rejected).resolve(track, cookies: cookies) }
            #expect(await rejected.count == 1)
        }
    }

    private var playbackTrack: Track {
        Track(id: "netease:9", title: "歌曲", artist: "", album: "", duration: 100, source: .netease, sourceID: "9")
    }

    @Test func absentItemCodeAndFeeFlagDoNotRejectAnAuthorizedFullURL() async throws {
        // The official website does not require an item-level code. A fee flag describes
        // the song's commercial category, not whether this session may play its URL.
        let fixture = NEFixture([.init(path: "/weapi/song/enhance/player/url/v1", json: #"{"code":200,"data":[{"id":9,"url":"https://m801.music.126.net/full.m4a","fee":1,"freeTrialInfo":null}]}"#)])
        #expect(try await provider(fixture).resolve(playbackTrack, cookies: cookies).lastPathComponent == "full.m4a")
        #expect(await fixture.count == 1)
    }

    @Test(arguments: [
        ("http://m801.music.126.net:80/a%2Fb/full.m4a?token=a%2Bb%2F&empty=&repeat=1&repeat=2", "https://m801.music.126.net/a%2Fb/full.m4a?token=a%2Bb%2F&empty=&repeat=1&repeat=2"),
        ("http://m801.music.126.net/full.m4a?token=fixture", "https://m801.music.126.net/full.m4a?token=fixture"),
        ("https://m801.music.126.net:443/a%2Fb/full.m4a?token=a%2Bb", "https://m801.music.126.net:443/a%2Fb/full.m4a?token=a%2Bb")
    ])
    func officialMediaUpgradesHTTPWithoutChangingSignedPathOrQuery(_ original: String, _ expected: String) async throws {
        let body = try json(["code": 200, "data": [["id": 9, "code": 200, "url": original]]])
        let fixture = NEFixture([.init(path: "/weapi/song/enhance/player/url/v1", json: body)])
        #expect(try await provider(fixture).resolve(playbackTrack, cookies: cookies).absoluteString == expected)
        #expect(await fixture.count == 1)
    }

    @Test(arguments: ["http://music.126.net.example.com/audio.m4a", "http://user:password@m801.music.126.net/audio.m4a", "file:///tmp/audio.m4a", "http://m801.music.126.net:8080/audio.m4a", "https://m801.music.126.net:80/audio.m4a", "https://m801.music.126.net:8443/audio.m4a"])
    func schemeUpgradeDoesNotAcceptUntrustedOrCredentialBearingURLs(_ address: String) async throws {
        let body = try json(["code": 200, "data": [["id": 9, "code": 200, "url": address]]])
        let fixture = NEFixture([.init(path: "/weapi/song/enhance/player/url/v1", json: body)])
        await #expect(throws: MusicError.self) { try await provider(fixture).resolve(playbackTrack, cookies: cookies) }
        #expect(await fixture.count == 1)
    }

    @Test(arguments: ["false", "true", "0", "1", #""unexpected-marker""#, "[]", "{}", #"{"start":0}"#, #"{"start":30,"end":0}"#])
    func unknownTrialShapeRefusesPlaybackWithoutClaimingAnActualPreview(_ marker: String) async {
        let body = "{\"code\":200,\"data\":[{\"id\":9,\"code\":200,\"url\":\"https://m801.music.126.net/full.m4a?token=secret\",\"freeTrialInfo\":\(marker)}]}"
        let fixture = NEFixture([.init(path: "/weapi/song/enhance/player/url/v1", json: body)])
        let message = await failure { try await provider(fixture).resolve(playbackTrack, cookies: cookies) }
        #expect(message.contains("无法确认完整播放") && message.contains("阶段：获取播放地址"))
        #expect(!message.contains("仅返回试听片段") && !message.contains("secret") && !message.contains("https://"))
        #expect(await fixture.count == 1)
    }

    @Test func recognizedPreviewKeepsItsSpecificMessageAndDoesNotLookUpOtherAudio() async {
        let fixture = NEFixture([.init(path: "/weapi/song/enhance/player/url/v1", json: #"{"code":200,"data":[{"id":9,"url":"https://m801.music.126.net/trial.m4a","freeTrialInfo":{"start":0,"end":30,"unknownFutureField":1}}]}"#)])
        let message = await failure { try await provider(fixture).resolve(playbackTrack, cookies: cookies) }
        #expect(message.contains("仅返回试听片段"))
        #expect(await fixture.count == 1)
    }

    @Test func http404AndBusiness404RemainDistinctWithoutInferringSongRights() async {
        let transport = NEFixture([.init(path: "/weapi/song/enhance/player/url/v1", json: #"{"code":401,"message":"secret"}"#, status: 404)])
        let transportMessage = await failure { try await provider(transport).resolve(playbackTrack, cookies: cookies) }
        #expect(transportMessage.contains("HTTP 404") && transportMessage.contains("阶段：获取播放地址"))
        #expect(!transportMessage.contains("重新登录") && !transportMessage.contains("会员") && !transportMessage.contains("secret"))
        #expect(await transport.count == 1)
        let business = NEFixture([.init(path: "/weapi/song/enhance/player/url/v1", json: #"{"code":404}"#)])
        let businessMessage = await failure { try await provider(business).resolve(playbackTrack, cookies: cookies) }
        #expect(businessMessage.contains("接口码：404") && !businessMessage.contains("HTTP 404"))
        #expect(!businessMessage.contains("下架") && !businessMessage.contains("会员"))
        #expect(await business.count == 1)
    }

    @Test(arguments: [
        (#"{"id":9,"fee":1,"payed":0,"pl":0,"st":0}"#, "当前账户没有这首歌的付费播放权限"),
        (#"{"id":9,"fee":1,"payed":1,"pl":320000,"st":0}"#, "权限资料显示可播放"),
        (#"{"id":9,"fee":0,"payed":0,"pl":0,"st":-200}"#, "标记为当前不可用"),
        (#"{"id":9,"fee":4,"payed":1,"pl":320000,"st":0,"flag":2048}"#, "需要下载后播放"),
        (#"{"id":9,"fee":1}"#, "无法确定具体原因"),
        (#"{"id":8,"fee":1,"payed":0,"pl":0,"st":0}"#, "未提供可核对的权限详情")
    ])
    func rejectedSongReportsConfirmedRightsWithoutGuessing(_ privilege: String, _ expected: String) async {
        let fixture = NEFixture([
            .init(path: "/weapi/song/enhance/player/url/v1", json: #"{"code":200,"data":[{"id":9,"code":404,"url":null,"fee":1}]}"#),
            .init(path: "/weapi/v3/song/detail", json: "{\"code\":200,\"songs\":[],\"privileges\":[\(privilege)]}")
        ])
        let message = await failure { try await provider(fixture).resolve(playbackTrack, cookies: cookies) }
        #expect(message.contains("阶段：获取播放地址"))
        #expect(message.contains("歌曲码：404"))
        #expect(message.contains(expected))
        #expect(await fixture.count == 2)
        #expect(await fixture.requests.last?.timeoutInterval == 5)
    }

    @Test func emptyURLAndMissingResultHaveDifferentDiagnostics() async {
        for response in [#"{"code":200,"data":[]}"#, #"{"code":200,"data":[{"id":8,"code":200,"url":null}]}"#] {
            let fixture = NEFixture([.init(path: "/weapi/song/enhance/player/url/v1", json: response)])
            let message = await failure { try await provider(fixture).resolve(playbackTrack, cookies: cookies) }
            #expect(message.contains("未返回所选歌曲"))
            #expect(!message.contains("订阅"))
            #expect(await fixture.count == 1)
        }
        let fixture = NEFixture([
            .init(path: "/weapi/song/enhance/player/url/v1", json: #"{"code":200,"data":[{"id":9,"code":200,"url":"  ","fee":0}]}"#),
            .init(path: "/weapi/v3/song/detail", json: #"{"code":200,"songs":[],"privileges":[]}"#)
        ])
        let message = await failure { try await provider(fixture).resolve(playbackTrack, cookies: cookies) }
        #expect(message.contains("播放地址为空"))
        #expect(message.contains("歌曲码：200"))
        #expect(message.contains("无法确定具体原因"))
    }

    @Test func diagnosticFailurePreservesOriginalPlaybackCode() async {
        let fixture = NEFixture([
            .init(path: "/weapi/song/enhance/player/url/v1", json: #"{"code":200,"data":[{"id":9,"code":-110,"url":null}]}"#),
            .init(path: "/weapi/v3/song/detail", json: #"{"code":500,"message":"sensitive-response-must-not-escape"}"#)
        ])
        let message = await failure { try await provider(fixture).resolve(playbackTrack, cookies: cookies) }
        #expect(message.contains("歌曲码：-110"))
        #expect(message.contains("补充权限查询未完成"))
        #expect(!message.contains("sensitive-response"))
    }

    @Test func errorsNeverExposeServiceTextCookiesOrSignedURLs() async {
        let responses = [
            #"{"code":503,"message":"MUSIC_U=fixture-session https://m801.music.126.net/a?token=secret"}"#,
            #"{"code":200,"data":[{"id":9,"code":200,"url":"https://untrusted.example/a?token=secret"}]}"#,
            #"{"code":200,"data":[{"id":9,"code":200,"url":"https://m801.music.126.net/a?token=secret","freeTrialInfo":{"start":0,"end":30}}]}"#,
            #"{"code":200,"data":"changed-schema-with-secret"}"#
        ]
        for response in responses {
            let fixture = NEFixture([.init(path: "/weapi/song/enhance/player/url/v1", json: response)])
            let message = await failure { try await provider(fixture).resolve(playbackTrack, cookies: cookies) }
            #expect(message.contains("阶段：获取播放地址"))
            #expect(!message.contains("secret"))
            #expect(!message.contains("MUSIC_U"))
            #expect(!message.contains("https://"))
            #expect(await fixture.count == 1)
        }
    }

    @Test func playbackTimeoutRetainsItsPhaseAndCancellationStaysCancellation() async {
        let timeoutProvider = NeteaseDirectProvider(http: NativeMusicHTTP(transport: { _ in throw URLError(.timedOut) }))
        let message = await failure { try await timeoutProvider.resolve(playbackTrack, cookies: cookies) }
        #expect(message.contains("超时"))
        #expect(message.contains("阶段：获取播放地址"))
        let cancelledProvider = NeteaseDirectProvider(http: NativeMusicHTTP(transport: { _ in throw CancellationError() }))
        await #expect(throws: CancellationError.self) { try await cancelledProvider.resolve(playbackTrack, cookies: cookies) }
    }

    @Test func cancellationDuringRightsLookupDoesNotTurnIntoBusinessFailure() async {
        let value = NeteaseDirectProvider(http: NativeMusicHTTP(transport: { request in
            if request.url?.path == "/weapi/v3/song/detail" { throw CancellationError() }
            return (Data(#"{"code":200,"data":[{"id":9,"code":404,"url":null}]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }))
        await #expect(throws: CancellationError.self) { try await value.resolve(playbackTrack, cookies: cookies) }
    }

    private func failure(_ operation: () async throws -> URL) async -> String {
        do { _ = try await operation(); Issue.record("Expected a playback failure"); return "" }
        catch { return error.localizedDescription }
    }

    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}

private actor NEFixture {
    struct Reply: Sendable { var path: String; var json: String; var status: Int = 200 }
    private let replies: [Reply]
    private(set) var requests: [URLRequest] = []
    var count: Int { requests.count }
    init(_ replies: [Reply]) { self.replies = replies }
    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let index = requests.count
        requests.append(request)
        guard index < replies.count, request.url?.path == replies[index].path, let url = request.url else {
            throw MusicError.message("Unexpected fixture request")
        }
        return (Data(replies[index].json.utf8), HTTPURLResponse(url: url, statusCode: replies[index].status, httpVersion: nil, headerFields: nil)!)
    }
}
