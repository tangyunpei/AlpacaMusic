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

    @Test func newLyricEnvelopeMatchesIndependentNodeAESVector() throws {
        let payload = Data(#"{"id":"9","yv":0}"#.utf8)
        #expect(String(decoding: try NeteaseLyricCrypto.encrypt(payload), as: UTF8.self) == "params=04AE33D34A93FE3EC22DA8FA305D290AB337D0FE5F36D211DE0D338CC6AA89D05E0BF73CD9F7CC4CE2B580F8F6AD4D1CCC094C41C35F758FAF9C81EFFFDDD51C36FA967D6E8D085FFF7761F600E8829657EE41157690F3EDAFF398893AD1AEAD")
    }

    @Test func yrcUsesNewOfficialRouteAndKeepsMeasuredTimes() async throws {
        let fixture = NEFixture([.init(path: "/eapi/song/lyric/v1", json: try json([
            "code": 200, "lrc": ["lyric": "[00:01]青山远"],
            "yrc": ["lyric": "[1000,4200](1000,500,0)青(1800,600,0)山(3100,2100,0)远"],
            "tlyric": ["lyric": "[00:01]Fixture translation"]
        ]))])
        let payload = try #require(try await provider(fixture).lyrics(playbackTrack, cookies: cookies))
        let document = try LyricsParser.parse(payload, sourceDescription: "Fixture")
        #expect(document.timing == .word)
        #expect(document.lines[0].words.map(\.start) == [1, 1.8, 3.1])
        #expect(document.lines[0].end == 5.2)
        #expect(document.lines[0].translation == "Fixture translation")
        #expect(await fixture.count == 1)
        let request = try #require(await fixture.requests.first)
        #expect(request.url?.host == "interface3.music.163.com")
        #expect(request.timeoutInterval == 8)
        #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("MUSIC_U=fixture-session") == true)
        #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self).hasPrefix("params="))
    }

    @Test func malformedYrcDoesNotDiscardValidLrcFromSameResponse() async throws {
        let fixture = NEFixture([.init(path: "/eapi/song/lyric/v1", json: try json([
            "code": 200, "lrc": ["lyric": "[00:01]Fixture fallback"],
            "yrc": ["lyric": "[1000,2000](999,500,0)bad timing"],
            "tlyric": ["lyric": "[00:01]译文"]
        ]))])
        let payload = try #require(try await provider(fixture).lyrics(playbackTrack, cookies: cookies))
        #expect(payload.document == nil)
        #expect(payload.text == "[00:01]Fixture fallback")
        #expect(payload.translation == "[00:01]译文")
        #expect(await fixture.count == 1)
    }

    @Test func newLyricFailureFallsBackToLegacyScopedRoute() async throws {
        let fixture = NEFixture([
            .init(path: "/eapi/song/lyric/v1", json: #"{"code":500}"#),
            .init(path: "/weapi/song/lyric", json: #"{"code":200,"lrc":{"lyric":"[00:01]Legacy fixture"}}"#)
        ])
        #expect(try await provider(fixture).lyrics(playbackTrack, cookies: cookies)?.text == "[00:01]Legacy fixture")
        #expect(await fixture.count == 2)
    }

    @Test func optionalYrcCancellationDoesNotStartFallbackRequest() async {
        let value = NeteaseDirectProvider(http: NativeMusicHTTP(transport: { request in
            #expect(request.url?.path == "/eapi/song/lyric/v1")
            throw CancellationError()
        }))
        await #expect(throws: CancellationError.self) { try await value.lyrics(playbackTrack, cookies: cookies) }
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
        #expect(message == L10n.string("网易云返回的试听标记格式已变化，无法确认完整播放，已停止播放（\(neteasePlaybackDiagnosticExpectation(code: "200"))）"))
        #expect(!message.contains("secret") && !message.contains("https://"))
        #expect(await fixture.count == 1)
    }

    @Test func recognizedPreviewKeepsItsSpecificMessageAndDoesNotLookUpOtherAudio() async {
        let fixture = NEFixture([.init(path: "/weapi/song/enhance/player/url/v1", json: #"{"code":200,"data":[{"id":9,"url":"https://m801.music.126.net/trial.m4a","freeTrialInfo":{"start":0,"end":30,"unknownFutureField":1}}]}"#)])
        let message = await failure { try await provider(fixture).resolve(playbackTrack, cookies: cookies) }
        #expect(message == L10n.string("网易云仅返回试听片段，未提供完整播放（\(neteasePlaybackDiagnosticExpectation(code: nil))）；本应用不播放试听替代完整歌曲"))
        #expect(await fixture.count == 1)
    }

    @Test func http404AndBusiness404RemainDistinctWithoutInferringSongRights() async {
        let transport = NEFixture([.init(path: "/weapi/song/enhance/player/url/v1", json: #"{"code":401,"message":"secret"}"#, status: 404)])
        let transportMessage = await failure { try await provider(transport).resolve(playbackTrack, cookies: cookies) }
        let reason = L10n.string("请求的接口或资源未找到，具体原因未确认")
        let transportFailure = L10n.string("\(MusicSource.netease.title)：\(reason)（HTTP \(String(404))）")
        #expect(transportMessage == L10n.string("\(transportFailure)（阶段：\(L10n.string("获取播放地址"))）"))
        #expect(!transportMessage.contains("secret"))
        #expect(await transport.count == 1)
        let business = NEFixture([.init(path: "/weapi/song/enhance/player/url/v1", json: #"{"code":404}"#)])
        let businessMessage = await failure { try await provider(business).resolve(playbackTrack, cookies: cookies) }
        let diagnostic = L10n.string("阶段：\(L10n.string("获取播放地址"))；接口码：\(String(404))")
        #expect(businessMessage == L10n.string("网易云拒绝了请求（\(diagnostic)），平台未提供可确认的具体原因"))
        #expect(!businessMessage.contains("HTTP 404"))
        #expect(await business.count == 1)
    }

    @Test(arguments: [
        (#"{"id":9,"fee":1,"payed":0,"pl":0,"st":0}"#, L10n.string("平台权限资料显示当前账户没有这首歌的付费播放权限"), "st=0，pl=0，fee=1，payed=0"),
        (#"{"id":9,"fee":1,"payed":1,"pl":320000,"st":0}"#, L10n.string("权限资料显示可播放，但地址接口未提供完整播放地址"), "st=0，pl=320000，fee=1，payed=1"),
        (#"{"id":9,"fee":0,"payed":0,"pl":0,"st":-200}"#, L10n.string("平台将这首歌标记为当前不可用；此标记不能单独区分下架或地区限制"), "st=-200，pl=0，fee=0，payed=0"),
        (#"{"id":9,"fee":4,"payed":1,"pl":320000,"st":0,"flag":2048}"#, L10n.string("平台标记这首歌需要下载后播放，请使用官方客户端；本应用未提供下载播放"), "st=0，pl=320000，fee=4，payed=1，flag=2048"),
        (#"{"id":9,"fee":1}"#, L10n.string("平台未提供足够信息，无法确定具体原因"), "fee=1"),
        (#"{"id":8,"fee":1,"payed":0,"pl":0,"st":0}"#, "", "")
    ])
    func rejectedSongReportsConfirmedRightsWithoutGuessing(_ privilege: String, _ expected: String, _ fields: String) async {
        let fixture = NEFixture([
            .init(path: "/weapi/song/enhance/player/url/v1", json: #"{"code":200,"data":[{"id":9,"code":404,"url":null,"fee":1}]}"#),
            .init(path: "/weapi/v3/song/detail", json: "{\"code\":200,\"songs\":[],\"privileges\":[\(privilege)]}")
        ])
        let message = await failure { try await provider(fixture).resolve(playbackTrack, cookies: cookies) }
        let base = L10n.string("\(L10n.string("网易云拒绝提供这首歌的播放地址"))（\(neteasePlaybackDiagnosticExpectation(code: "404", fee: 1))）")
        if fields.isEmpty {
            #expect(message == L10n.string("\(base)。平台未提供可核对的权限详情，无法确定具体原因"))
        } else {
            let localizedFields = fields.components(separatedBy: "，").joined(separator: L10n.string("，"))
            #expect(message == L10n.string("\(base)。\(expected)（\(localizedFields)）"))
        }
        #expect(await fixture.count == 2)
        #expect(await fixture.requests.last?.timeoutInterval == 5)
    }

    @Test func emptyURLAndMissingResultHaveDifferentDiagnostics() async {
        for response in [#"{"code":200,"data":[]}"#, #"{"code":200,"data":[{"id":8,"code":200,"url":null}]}"#] {
            let fixture = NEFixture([.init(path: "/weapi/song/enhance/player/url/v1", json: response)])
            let message = await failure { try await provider(fixture).resolve(playbackTrack, cookies: cookies) }
            #expect(message == L10n.string("网易云未返回所选歌曲的播放结果（阶段：获取播放地址；接口码：200）"))
            #expect(await fixture.count == 1)
        }
        let fixture = NEFixture([
            .init(path: "/weapi/song/enhance/player/url/v1", json: #"{"code":200,"data":[{"id":9,"code":200,"url":"  ","fee":0}]}"#),
            .init(path: "/weapi/v3/song/detail", json: #"{"code":200,"songs":[],"privileges":[]}"#)
        ])
        let message = await failure { try await provider(fixture).resolve(playbackTrack, cookies: cookies) }
        let base = L10n.string("\(L10n.string("网易云返回的播放地址为空"))（\(neteasePlaybackDiagnosticExpectation(code: "200", fee: 0))）")
        #expect(message == L10n.string("\(base)。平台未提供可核对的权限详情，无法确定具体原因"))
    }

    @Test func diagnosticFailurePreservesOriginalPlaybackCode() async {
        let fixture = NEFixture([
            .init(path: "/weapi/song/enhance/player/url/v1", json: #"{"code":200,"data":[{"id":9,"code":-110,"url":null}]}"#),
            .init(path: "/weapi/v3/song/detail", json: #"{"code":500,"message":"sensitive-response-must-not-escape"}"#)
        ])
        let message = await failure { try await provider(fixture).resolve(playbackTrack, cookies: cookies) }
        let base = L10n.string("\(L10n.string("网易云拒绝提供这首歌的播放地址"))（\(neteasePlaybackDiagnosticExpectation(code: "-110"))）")
        #expect(message == L10n.string("\(base)。补充权限查询未完成，无法确定具体原因"))
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
            let expected: String
            if response.contains("503") {
                let diagnostic = L10n.string("阶段：\(L10n.string("获取播放地址"))；接口码：\(String(503))")
                expected = L10n.string("网易云拒绝了请求（\(diagnostic)），平台未提供可确认的具体原因")
            } else if response.contains("untrusted.example") {
                expected = L10n.string("网易云返回的播放地址格式无效或不属于已允许的官方音频域名，已停止播放（\(neteasePlaybackDiagnosticExpectation(code: "200"))）")
            } else if response.contains("freeTrialInfo") {
                expected = L10n.string("网易云仅返回试听片段，未提供完整播放（\(neteasePlaybackDiagnosticExpectation(code: "200"))）；本应用不播放试听替代完整歌曲")
            } else {
                expected = L10n.string("网易云响应格式已变化（阶段：\(L10n.string("获取播放地址"))；接口码：200），请稍后重试")
            }
            #expect(message == expected)
            #expect(!message.contains("secret"))
            #expect(!message.contains("MUSIC_U"))
            #expect(!message.contains("https://"))
            #expect(await fixture.count == 1)
        }
    }

    @Test func playbackTimeoutRetainsItsPhaseAndCancellationStaysCancellation() async {
        let timeoutProvider = NeteaseDirectProvider(http: NativeMusicHTTP(transport: { _ in throw URLError(.timedOut) }))
        let message = await failure { try await timeoutProvider.resolve(playbackTrack, cookies: cookies) }
        let reason = L10n.string("请求超时，请重试")
        let failure = L10n.string("\(MusicSource.netease.title)：\(reason)（网络错误 \(String(URLError.timedOut.rawValue))）")
        #expect(message == L10n.string("\(failure)（阶段：\(L10n.string("获取播放地址"))）"))
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

private func neteasePlaybackDiagnosticExpectation(code: String?, fee: Int? = nil) -> String {
    L10n.string("阶段：获取播放地址；接口码：200；歌曲码：\(code ?? L10n.string("未提供"))")
        + (fee.map { L10n.string("；fee=\(String($0))") } ?? "")
}
