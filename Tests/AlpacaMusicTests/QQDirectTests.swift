import Foundation
import Synchronization
import Testing
@testable import AlpacaMusic

private let qqCookies = [MusicSessionCookie(name: "uin", value: "o12345678", domain: ".y.qq.com"), MusicSessionCookie(name: "qqmusic_key", value: "test-session-key", domain: ".y.qq.com")]
private let qqWechatCookies = [MusicSessionCookie(name: "wxuin", value: "12345678901234567", domain: ".y.qq.com"), MusicSessionCookie(name: "wxopenid", value: "fixture-wechat-id", domain: ".y.qq.com"), MusicSessionCookie(name: "qm_keyst", value: "fixture-wechat-key", domain: ".y.qq.com")]
private func qqSong(_ mid: String) -> [String: Any] {
    ["mid": mid, "title": "<em>雨</em> &amp; 风", "interval": 181, "singer": [["name": "Artist"]], "album": ["mid": "album1", "title": "Album"]]
}
private func qqReply(_ request: URLRequest, _ value: [String: Any]) throws -> (Data, HTTPURLResponse) {
    (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}
private func qqRPC(_ request: URLRequest) throws -> [String: Any] {
    let root = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
    return try #require(root?["req_0"] as? [String: Any])
}
struct QQDirectTests {
    @Test func qrcUsesSignedOfficialRPCAndMeasuredTimes() async throws {
        let value = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            #expect(request.url?.host == "u.y.qq.com")
            #expect(request.url?.path == "/cgi-bin/musics.fcg")
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            let operation = try #require(body["req_0"] as? [String: Any])
            #expect(operation["module"] as? String == "music.musichallSong.PlayLyricInfo")
            #expect(operation["method"] as? String == "GetPlayLyricInfo")
            let params = try #require(operation["param"] as? [String: Any])
            #expect(params["qrc"] as? Int == 1)
            #expect(params["trans"] as? Int == 1)
            #expect(params["songMid"] as? String == "fixtureMID")
            #expect(request.timeoutInterval == 8)
            return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": [
                "lyric": "[1000,4200]青(1000,500)山(1800,600)远(3100,2100)",
                "trans": Data("[00:01]Fixture translation".utf8).base64EncodedString()
            ]]])
        }))
        let track = Track(id: "qq:fixtureMID", title: "Fixture", artist: "", album: "", duration: 100, source: .qq, sourceID: "fixtureMID")
        let payload = try #require(try await value.lyrics(track, cookies: qqCookies))
        let document = try LyricsParser.parse(payload, sourceDescription: "Fixture")
        #expect(document.timing == .word)
        #expect(document.lines[0].words.map(\.start) == [1, 1.8, 3.1])
        #expect(document.lines[0].translation == "Fixture translation")
    }

    @Test func malformedOrUnavailableQrcFallsBackWithoutLosingTranslation() async throws {
        for status in [0, 500] {
            let requests = Mutex<[String]>([])
            let value = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                requests.withLock { $0.append(request.url?.path ?? "") }
                if request.url?.host == "u.y.qq.com" {
                    return try qqReply(request, ["code": 0, "req_0": ["code": status, "data": ["lyric": "[1000,1000]青(500,600)"]]])
                }
                return try qqReply(request, ["code": 0, "lyric": Data("[00:01]Fallback fixture".utf8).base64EncodedString(), "trans": Data("[00:01]译文".utf8).base64EncodedString()])
            }))
            let track = Track(id: "qq:fixtureMID", title: "Fixture", artist: "", album: "", duration: 100, source: .qq, sourceID: "fixtureMID")
            let payload = try #require(try await value.lyrics(track, cookies: qqCookies))
            #expect(payload.document == nil)
            #expect(payload.text == "[00:01]Fallback fixture")
            #expect(payload.translation == "[00:01]译文")
            #expect(requests.withLock { $0 } == ["/cgi-bin/musics.fcg", "/lyric/fcgi-bin/fcg_query_lyric_new.fcg"])
        }
    }

    @Test func validLrcFromNewRPCDoesNotRequireLegacyRequest() async throws {
        let value = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            #expect(request.url?.host == "u.y.qq.com")
            return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": [
                "lyric": Data("[00:01]New line fixture".utf8).base64EncodedString(),
                "trans": Data("[00:01]译文".utf8).base64EncodedString()
            ]]])
        }))
        let track = Track(id: "qq:fixtureMID", title: "Fixture", artist: "", album: "", duration: 100, source: .qq, sourceID: "fixtureMID")
        let payload = try #require(try await value.lyrics(track, cookies: qqCookies))
        #expect(payload.text == "[00:01]New line fixture")
        #expect(payload.translation == "[00:01]译文")
    }

    @Test func qrcCancellationDoesNotStartLegacyRequest() async {
        let value = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            #expect(request.url?.path == "/cgi-bin/musics.fcg")
            throw CancellationError()
        }))
        let track = Track(id: "qq:fixtureMID", title: "Fixture", artist: "", album: "", duration: 100, source: .qq, sourceID: "fixtureMID")
        await #expect(throws: CancellationError.self) { try await value.lyrics(track, cookies: qqCookies) }
    }

    @Test func checksumUsesExactUTF8WireBytes() {
        #expect(QQWebSigning.signature(for: Data()) == "zzcf0e03e5gx4qeiq5cfgdyqwu7sdqfsb5fro3aa45053")
        #expect(QQWebSigning.signature(for: Data("测试 🎵".utf8)) == "zzc52ecb01okzpdhy0kdwnjqrotbkldsdeumcb14112ca")
        #expect(QQWebSigning.csrfToken("") == 5381)
        #expect(QQWebSigning.csrfToken("a") == 177670)
    }
    @Test func missingExpiredOrOffDomainCookiesNeverSendRequests() async {
        let requests = Mutex(0)
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            requests.withLock { $0 += 1 }; return try qqReply(request, ["code": 0])
        }))
        let expired = qqCookies.map { value in var value = value; value.expires = Date(timeIntervalSince1970: 0); return value }
        let unrelated = qqCookies.map { value in var value = value; value.domain = ".example.com"; return value }
        for cookies in [[], expired, unrelated, [qqCookies[0]]] {
            do { _ = try await provider.profile(cookies: cookies); Issue.record("Accepted invalid session") } catch { }
        }
        #expect(requests.withLock { $0 } == 0)
    }
    @Test func profileValidatesAuthenticatedSelfNotPublicUserPage() async throws {
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.contains { $0.name == "userid" && $0.value == "0" })
            #expect(query.contains { $0.name == "needNewCode" && $0.value == "0" })
            #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("qqmusic_key=test-session-key") == true)
            return try qqReply(request, ["code": 0, "data": ["creator": ["uin": 12345678, "nick": "Alpaca &amp; Music"]]])
        }))
        let account = try await provider.profile(cookies: qqCookies)
        #expect(account.id == "12345678"); #expect(account.displayName == "Alpaca & Music")
    }
    @Test func wechatIdentityPreservesLongUinWithoutNumericRounding() async throws {
        let identifier = "12345678901234567"
        let cookies = [MusicSessionCookie(name: "wxuin", value: identifier, domain: ".y.qq.com"), MusicSessionCookie(name: "login_type", value: "2", domain: ".y.qq.com"), MusicSessionCookie(name: "qm_keyst", value: "wechat-session", domain: ".y.qq.com")]
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.contains { $0.name == "uin" && $0.value == identifier })
            return try qqReply(request, ["code": 0, "data": ["creator": ["uin": identifier, "nick": "Wechat"]]])
        }))
        #expect(try await provider.profile(cookies: cookies).id == identifier)
    }
    @Test func paddedQQCookieAndProfileIdentitiesUseTheSameDecimalForm() async throws {
        let cookies = [MusicSessionCookie(name: "uin", value: "o0012345678", domain: ".y.qq.com"), qqCookies[1]]
        for responseID in [12345678, "0012345678", "o0012345678"] as [Any] {
            let response = try JSONSerialization.data(withJSONObject: ["code": 0, "data": ["creator": ["uin": responseID, "nick": "Fixture"]]])
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                #expect(query.contains { $0.name == "uin" && $0.value == "12345678" })
                return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
            #expect(try await provider.profile(cookies: cookies).id == "12345678")
        }
    }
    @Test func longNumericWechatProfileDoesNotPassThroughFloatingPoint() async throws {
        let identifier = "12345678901234567"
        let cookies = [MusicSessionCookie(name: "wxuin", value: identifier, domain: ".y.qq.com"), MusicSessionCookie(name: "wxopenid", value: "fixture-wechat-id", domain: ".y.qq.com"), qqCookies[0], qqCookies[1]]
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            let response = Data(#"{"code":0,"data":{"creator":{"uin":12345678901234567,"nick":"Fixture"}}}"#.utf8)
            return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }))
        #expect(try await provider.profile(cookies: cookies).id == identifier)
    }
    @Test func wechatHiddenNumericIdentityRequiresAuthenticatedSelfEncryptedIdentity() async throws {
        for hiddenID in [nil, NSNull(), "", "0", 0] as [Any?] {
            var creator: [String: Any] = ["nick": "微信测试昵称", "encrypt_uin": "fixtureEncryptedSelf**"]
            if let hiddenID { creator["uin"] = hiddenID }
            let data = try JSONSerialization.data(withJSONObject: ["code": 0, "data": ["creator": creator]])
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                #expect(query.contains { $0.name == "userid" && $0.value == "0" })
                #expect(query.contains { $0.name == "needNewCode" && $0.value == "0" })
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
            let profile = try await provider.profile(cookies: qqWechatCookies)
            #expect(profile.id == "12345678901234567")
            #expect(profile.displayName == "微信测试昵称")
        }
    }
    @Test func qqHiddenNumericIdentityRequiresAuthenticatedSelfEncryptedIdentity() async throws {
        for hiddenID in [nil, NSNull(), "", "0", 0] as [Any?] {
            var creator: [String: Any] = ["nick": "QQ fixture", "encrypt_uin": "fixtureEncryptedQQSelf**"]
            if let hiddenID { creator["uin"] = hiddenID }
            let data = try JSONSerialization.data(withJSONObject: ["code": 0, "data": ["creator": creator]])
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                #expect(query.contains { $0.name == "userid" && $0.value == "0" })
                #expect(query.contains { $0.name == "needNewCode" && $0.value == "0" })
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
            let profile = try await provider.profile(cookies: qqCookies)
            #expect(profile.id == "12345678")
            #expect(profile.displayName == "QQ fixture")
        }
    }
    @Test func encryptedIdentityCannotOverrideMismatchedOrMalformedNumericIdentity() async throws {
        for numericID in ["99999999", "invalid-private-id", "123"] {
            let data = try JSONSerialization.data(withJSONObject: ["code": 0, "data": ["creator": ["uin": numericID, "nick": "Private fixture nickname", "encrypt_uin": "fixtureEncryptedSelf**"]]])
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
            for cookies in [qqCookies, qqWechatCookies] {
                do { _ = try await provider.profile(cookies: cookies); Issue.record("Encrypted field overrode invalid account") }
                catch {
                    #expect(error.localizedDescription == (numericID == "99999999" ? L10n.string("QQ 音乐返回的账户与本次登录不一致，请重新完成官网登录。") : L10n.string("QQ 音乐返回的账户资料缺少有效账号标识（本人资料：数字标识字段格式不支持），请稍后重试。")))
                    #expect(!error.localizedDescription.contains(numericID))
                    #expect(!error.localizedDescription.contains("fixtureEncryptedSelf"))
                }
            }
        }
    }
    @Test func encryptedSelfStillRequiresSuccessfulResponseAndNickname() async throws {
        let cases: [([String: Any], String)] = [
            (["code": 1000, "data": ["creator": ["uin": 0, "nick": "Private fixture nickname", "encrypt_uin": "fixtureEncryptedSelf**"]]], L10n.string("QQ 音乐登录已失效，请重新登录（平台返回码 \(String(1000))）。")),
            (["code": 0, "data": ["creator": ["uin": 0, "encrypt_uin": "fixtureEncryptedSelf**"]]], L10n.string("QQ 音乐未返回当前账户昵称，请稍后重试。")),
            (["code": 0, "data": ["creator": ["uin": 0, "nick": "<b> </b>", "encrypt_uin": "fixtureEncryptedSelf**"]]], L10n.string("QQ 音乐未返回当前账户昵称，请稍后重试。")),
            (["code": 0, "data": ["creator": ["uin": 0, "nick": "Private fixture nickname"]]], L10n.string("QQ 音乐返回的账户资料缺少有效账号标识（本人资料：数字标识隐藏；\(L10n.string("缺少加密标识"))），请稍后重试。"))
        ]
        for (payload, explanation) in cases {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
            for cookies in [qqCookies, qqWechatCookies] {
                do { _ = try await provider.profile(cookies: cookies); Issue.record("Incomplete encrypted profile accepted") }
                catch { #expect(error.localizedDescription == explanation) }
            }
        }
    }
    @Test func encryptedIdentityIsBoundedForQQAndWechatSessions() async throws {
        for encryptedID in ["", "0", "has space", "line\nbreak", "control\u{0}value", String(repeating: "x", count: 513), 123, NSNull()] as [Any] {
            let data = try JSONSerialization.data(withJSONObject: ["code": 0, "data": ["creator": ["uin": 0, "nick": "Fixture", "encrypt_uin": encryptedID]]])
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
            for cookies in [qqCookies, qqWechatCookies] {
                do { _ = try await provider.profile(cookies: cookies); Issue.record("Invalid opaque identity accepted") }
                catch {
                    let category = encryptedID is NSNull || (encryptedID as? String)?.isEmpty == true ? L10n.string("缺少加密标识") : L10n.string("加密标识字段格式不支持")
                    #expect(error.localizedDescription == L10n.string("QQ 音乐返回的账户资料缺少有效账号标识（本人资料：数字标识隐藏；\(category)），请稍后重试。"))
                    #expect(!error.localizedDescription.contains("test-session-key"))
                }
            }
        }
    }
    @Test func profileFailuresExplainTheMissingPartWithoutDisclosingAccountData() async throws {
        let cases: [([String: Any], String)] = [
            (["code": 0, "data": [:]], L10n.string("QQ 音乐没有返回当前账户资料，请重新完成官网登录。")),
            (["code": 0, "data": ["creator": ["nick": "Private fixture nickname"]]], L10n.string("QQ 音乐返回的账户资料缺少有效账号标识（本人资料：数字标识隐藏；\(L10n.string("缺少加密标识"))），请稍后重试。")),
            (["code": 0, "data": ["creator": ["uin": "invalid-private-id", "nick": "Private fixture nickname"]]], L10n.string("QQ 音乐返回的账户资料缺少有效账号标识（本人资料：数字标识字段格式不支持），请稍后重试。")),
            (["code": 0, "data": ["creator": ["uin": "99999999", "nick": "Private fixture nickname"]]], L10n.string("QQ 音乐返回的账户与本次登录不一致，请重新完成官网登录。")),
            (["code": 0, "data": ["creator": ["uin": "12345678"]]], L10n.string("QQ 音乐未返回当前账户昵称，请稍后重试。")),
            (["code": 0, "data": ["creator": ["uin": "12345678", "nick": "<b> </b>"]]], L10n.string("QQ 音乐未返回当前账户昵称，请稍后重试。"))
        ]
        for (payload, explanation) in cases {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
            do { _ = try await provider.profile(cookies: qqCookies); Issue.record("Incomplete profile was accepted") }
            catch {
                #expect(error.localizedDescription == explanation)
                for secret in ["12345678", "99999999", "invalid-private-id", "Private fixture nickname", "test-session-key"] {
                    #expect(!error.localizedDescription.contains(secret))
                }
            }
        }
    }
    @Test func profileTimeoutIsPropagatedAsAnActionableRedactedFailure() async {
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { _ in throw URLError(.timedOut) }))
        do { _ = try await provider.profile(cookies: qqCookies); Issue.record("Timeout was swallowed") }
        catch { #expect(error.localizedDescription == expectedQQTimeout()) }
    }
    @Test func profileRejectsExpiredServerSessionAndMismatchedIdentity() async {
        for payload in [["code": 1000, "data": [:]], ["code": 0, "data": ["creator": ["uin": "99999999", "nick": "Wrong person"]]]] as [[String: Any]] {
            let data = try! JSONSerialization.data(withJSONObject: payload)
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
            do { _ = try await provider.profile(cookies: qqCookies); Issue.record("Accepted nonauthenticated profile") } catch { }
        }
    }
    @Test func signedSearchMapsSongsAndDoesNotLeakCredentialIntoURL() async throws {
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            #expect(request.url?.host == "u.y.qq.com"); #expect(request.url?.path == "/cgi-bin/musics.fcg"); #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString.contains("test-session-key") == false)
            let body = try #require(request.httpBody)
            let sign = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "sign" }?.value
            #expect(sign == QQWebSigning.signature(for: body))
            let rpc = try qqRPC(request), parameters = try #require(rpc["param"] as? [String: Any])
            #expect(rpc["method"] as? String == "DoSearchForQQMusicDesktop"); #expect(parameters["query"] as? String == "雨")
            return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["meta": ["is_filter": 0], "body": ["song": ["list": [qqSong("mid1"), qqSong("mid1")]]]]]])
        }))
        let tracks = try await provider.search(" 雨 ", cookies: qqCookies)
        #expect(tracks.count == 1); #expect(tracks[0].id == "qq:mid1"); #expect(tracks[0].title == "雨 & 风"); #expect(tracks[0].duration == 181); #expect(tracks[0].url == nil)
    }
    @Test func filteredSearchIsNotReportedAsAnEmptySuccess() async {
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["meta": ["is_filter": -2], "body": ["song": ["list": []]]]]])
        }))
        do { _ = try await provider.search("test", cookies: qqCookies); Issue.record("Filtered response appeared successful") } catch { #expect(error.localizedDescription == L10n.string("QQ 音乐限制了本次搜索，请重新登录或稍后重试。")) }
    }
    @Test func searchAndPlaylistShareAllSupportedTrackContainers() async throws {
        for wrapper in ["", "track_info", "songInfo", "songinfo", "song"] {
            let row: [String: Any] = wrapper.isEmpty ? qqSong("wrapped1") : [wrapper: qqSong("wrapped1")]
            let searchBody = try JSONSerialization.data(withJSONObject: ["code": 0, "req_0": ["code": 0, "data": ["body": ["song": ["list": [row]]]]]])
            let playlistBody = try JSONSerialization.data(withJSONObject: ["code": 0, "req_0": ["code": 0, "data": ["songlist": [row], "total_song_num": 1]]])
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                let search = try qqRPC(request)["method"] as? String == "DoSearchForQQMusicDesktop"
                return (search ? searchBody : playlistBody, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
            let search = try await provider.search("Fixture", cookies: qqCookies)
            let playlist = try await provider.tracks(in: .init(id: "123", name: "Fixture", trackCount: 1, source: .qq), cookies: qqCookies)
            #expect(search.count == 1); #expect(playlist.count == 1)
            let searchTrack = try #require(search.first), playlistTrack = try #require(playlist.first)
            #expect(searchTrack.id == playlistTrack.id); #expect(searchTrack.sourceID == playlistTrack.sourceID)
            #expect(searchTrack.title == playlistTrack.title); #expect(searchTrack.artist == playlistTrack.artist)
            #expect(searchTrack.album == playlistTrack.album); #expect(searchTrack.artworkURL == playlistTrack.artworkURL)
            #expect(searchTrack.duration == playlistTrack.duration)
            #expect(playlist.first?.id == "qq:wrapped1"); #expect(playlist.first?.title == "雨 & 风")
            #expect(playlist.first?.duration == 181)
        }
    }
    @Test func playlistContainersDoNotInventIdentityOrSilentlySelectConflictingRows() async throws {
        let cases: [([String: Any], String)] = [
            (["track_info": NSNull()], L10n.string("曲目包裹字段 \("track_info")=\(L10n.string("空值"))，预期对象")),
            (["song": "private-value"], L10n.string("曲目包裹字段 \("song")=\(L10n.string("文本"))，预期对象")),
            (["songInfo": qqSong("mid1"), "songinfo": qqSong("mid2")], L10n.string("曲目含多个包裹字段，格式不明确")),
            (["songinfo": ["id": -12345, "title": "private-title"]], expectedQQIdentityIssue(idType: L10n.string("数字或布尔值"))),
            (["song": ["songid": -12345, "title": "private-title"]], expectedQQIdentityIssue(songIDType: L10n.string("数字或布尔值")))
        ]
        for (row, reason) in cases {
            let body = try JSONSerialization.data(withJSONObject: ["code": 0, "req_0": ["code": 0, "data": ["songlist": [row], "total_song_num": 1]]])
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
            do { _ = try await provider.tracks(in: .init(id: "123", name: "Fixture", trackCount: 1, source: .qq), cookies: qqCookies); Issue.record("Invalid track container accepted") }
            catch {
                #expect(error.localizedDescription == expectedQQUnimportedPlaylist(issue: reason))
                #expect(!error.localizedDescription.contains("private"))
                #expect(!error.localizedDescription.contains("12345"))
            }
        }
    }
    @Test func accountPlaylistsMergeCreatedFavoritesWithoutDuplicates() async throws {
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            if request.url!.path.contains("created_diss") {
                return try qqReply(request, ["code": 0, "data": ["disslist": [["tid": "123", "diss_name": "Mine", "song_cnt": 2, "dirid": 201], ["tid": "space", "diss_name": "QQ空间", "song_cnt": 1, "dirid": 205]]]])
            }
            return try qqReply(request, ["code": 0, "data": ["totaldiss": 2, "cdlist": [["dissid": "123", "dissname": "Mine", "songnum": 2], ["dissid": "456", "dissname": "Saved", "songnum": 3]]]])
        }))
        let playlists = try await provider.playlists(profile: .init(id: "12345678", displayName: "Alpaca"), cookies: qqCookies)
        #expect(playlists.map(\.id) == ["123", "456"]); #expect(playlists[1].trackCount == 3)
    }
    @Test func playlistPaginationFetchesAllTracks() async throws {
        let calls = Mutex(0)
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            calls.withLock { $0 += 1 }
            let rpc = try qqRPC(request), params = try #require(rpc["param"] as? [String: Any]), offset = try #require(params["song_begin"] as? Int)
            #expect(params["disstid"] as? Int == 123)
            #expect(!(params["disstid"] is String))
            let list = offset == 0 ? (0..<100).map { qqSong("song\($0)") } : [qqSong("song100")]
            return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["code": 0, "total_song_num": 101, "songlist": list]]])
        }))
        let tracks = try await provider.tracks(in: .init(id: "123", name: "List", trackCount: 101, source: .qq), cookies: qqCookies)
        #expect(tracks.count == 101); #expect(calls.withLock { $0 } == 2)
    }
    @Test func playlistIdentifiersMustBePositiveJSONIntegersBeforeTransport() async {
        let calls = Mutex(0)
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            calls.withLock { $0 += 1 }; return try qqReply(request, ["code": 0])
        }))
        for identifier in ["", "abc", "0", "-1", "+123", "999999999999999999999999"] {
            do { _ = try await provider.tracks(in: .init(id: identifier, name: "Fixture", trackCount: 1, source: .qq), cookies: qqCookies); Issue.record("Invalid numeric playlist ID accepted") }
            catch { #expect(error.localizedDescription == L10n.string("QQ 音乐歌单标识无效，请刷新歌单列表。")) }
        }
        #expect(calls.withLock { $0 } == 0)
    }
    @Test func playlistPlatformFailureNamesTheOperationWithoutGuessingPermissions() async {
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            try qqReply(request, ["code": 0, "req_0": ["code": 10006, "message": "fixture-wechat-key private detail"]])
        }))
        do { _ = try await provider.tracks(in: .init(id: "123", name: "Fixture", trackCount: 1, source: .qq), cookies: qqWechatCookies); Issue.record("RPC failure accepted") }
        catch {
            #expect(error.localizedDescription == expectedQQRPCFailure(operation: L10n.string("读取歌单曲目"), code: 10006))
            #expect(!error.localizedDescription.contains("fixture-wechat-key"))
        }
    }
    @Test func createdPlaylistPaginationReadsOfficialMisspelledTotal() async throws {
        let createdCalls = Mutex(0)
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            guard request.url!.path.contains("created_diss") else { return try qqReply(request, ["code": 0, "data": ["cdlist": [], "totaldiss": 0]]) }
            createdCalls.withLock { $0 += 1 }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let offset = query.first { $0.name == "sin" }?.value ?? ""
            return try qqReply(request, ["code": 0, "data": ["totoal": 2, "disslist": [["tid": offset == "0" ? "123" : "456", "diss_name": "Fixture", "song_cnt": 1]]]])
        }))
        let playlists = try await provider.playlists(profile: .init(id: "12345678", displayName: "Fixture"), cookies: qqCookies)
        #expect(playlists.map(\.id) == ["123", "456"])
        #expect(createdCalls.withLock { $0 } == 2)
    }
    @Test func repeatedPlaylistPageDoesNotPretendCollectionIsComplete() async {
        let requests = Mutex(0)
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            requests.withLock { $0 += 1 }
            return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["code": 0, "total_song_num": 200, "songlist": (0..<100).map { qqSong("song\($0)") }]]])
        }))
        do { _ = try await provider.tracks(in: .init(id: "123", name: "List", trackCount: 200, source: .qq), cookies: qqCookies); Issue.record("Repeated page was accepted") }
        catch { #expect(error.localizedDescription == L10n.string("QQ 音乐返回了重复的歌单分页，本次未导入，请稍后重试。")) }
        #expect(requests.withLock { $0 } == 2)
    }
    @Test func missingPageOrMalformedTrackCannotBecomePartialImportSuccess() async {
        for malformed in [false, true] {
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                let rpc = try qqRPC(request), params = try #require(rpc["param"] as? [String: Any]), offset = try #require(params["song_begin"] as? Int)
                let rows: [[String: Any]] = malformed ? [qqSong("valid"), ["title": "Missing identity"]] : (offset == 0 ? [qqSong("valid")] : [])
                return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["code": 0, "total_song_num": 2, "songlist": rows]]])
            }))
            do { _ = try await provider.tracks(in: .init(id: "123", name: "List", trackCount: 2, source: .qq), cookies: qqCookies); Issue.record("Incomplete playlist import appeared successful") }
            catch let MusicError.incompletePlaylist(partial) { #expect(partial.failedCount == 1); #expect(partial.tracks.count == 1) }
            catch { #expect(error.localizedDescription == L10n.string("QQ 音乐歌单分页格式不完整（第 \(2) 页为空，已读取 \(1)/\(2) 首），本次未导入。")) }
        }
    }
    @Test func playlistBadRowReportsPositionAndParsedCountWithoutPrivateValues() async throws {
        var rows = (0..<82).map { qqSong("song\($0)") }
        rows[36] = ["title": "private-song-title", "account": "private-account", "debug": "private-cookie"]
        let body = try JSONSerialization.data(withJSONObject: ["code": 0, "req_0": ["code": 0, "data": ["total_song_num": 82, "songlist": rows]]])
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }))
        do { _ = try await provider.tracks(in: .init(id: "123", name: "Fixture", trackCount: 82, source: .qq), cookies: qqCookies); Issue.record("Bad row became a successful partial import") }
        catch let MusicError.incompletePlaylist(partial) {
            let message = partial.message + partial.issues.joined(separator: "；")
            #expect(partial.message == expectedQQPartialSummary(total: 82, parsed: 81, failed: 1, firstPosition: 37,
                                                               firstFailure: L10n.string("：歌曲资料缺少有效标识或标题。")))
            #expect(partial.issues == [expectedQQPlaylistIssue(position: 37, failure: L10n.string("：\(expectedQQIdentityIssue())"))])
            #expect(!message.contains("private"))
            #expect(partial.failedCount == 1); #expect(partial.totalCount == 82); #expect(partial.tracks.count == 81)
        }
    }
    @Test func validMIDAliasAvoidsUnnecessaryPlaylistHydration() async throws {
        for invalidMID in ["", "private/bad", String(repeating: "x", count: 81)] {
            var row = qqSong(invalidMID); row["songmid"] = "validAlias"; row["id"] = 12345
            let listData = try JSONSerialization.data(withJSONObject: ["code": 0, "req_0": ["code": 0, "data": ["songlist": [row], "total_song_num": 1]]])
            let searchData = try JSONSerialization.data(withJSONObject: ["code": 0, "req_0": ["code": 0, "data": ["body": ["song": ["list": [row]]]]]])
            let calls = Mutex(0)
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                calls.withLock { $0 += 1 }
                let method = try qqRPC(request)["method"] as? String
                #expect(method != "get_song_detail_yqq")
                return (method == "uniform_get_Dissinfo" ? listData : searchData, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
            #expect(try await provider.tracks(in: .init(id: "123", name: "Fixture", trackCount: 1, source: .qq), cookies: qqCookies).first?.sourceID == "validAlias")
            #expect(try await provider.search("Fixture", cookies: qqCookies).first?.sourceID == "validAlias")
            #expect(calls.withLock { $0 } == 2)
        }
    }
    @Test func playlistHydratesOneDamagedIdentityAndPreservesItsPosition() async throws {
        var rows = (0..<82).map { qqSong("song\($0)") }
        rows[14] = ["songinfo": ["mid": "private/invalid", "id": 12345, "title": "private-old-title"]]
        let body = try JSONSerialization.data(withJSONObject: ["code": 0, "req_0": ["code": 0, "data": ["songlist": rows, "total_song_num": 82]]])
        let details = Mutex(0)
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            let rpc = try qqRPC(request)
            if rpc["method"] as? String == "uniform_get_Dissinfo" {
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            details.withLock { $0 += 1 }
            #expect(request.url?.path == "/cgi-bin/musics.fcg")
            #expect(rpc["method"] as? String == "get_song_detail_yqq")
            let params = try #require(rpc["param"] as? [String: Any])
            #expect(params["song_id"] as? Int == 12345); #expect(params["song_mid"] == nil)
            var info = qqSong("recoveredMID"); info["id"] = "12345"
            return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["track_info": info]]])
        }))
        let tracks = try await provider.tracks(in: .init(id: "123", name: "Fixture", trackCount: 82, source: .qq), cookies: qqCookies)
        #expect(tracks.count == 82); #expect(details.withLock { $0 } == 1)
        #expect(tracks[13].sourceID == "song13"); #expect(tracks[14].sourceID == "recoveredMID"); #expect(tracks[15].sourceID == "song15")
    }
    @Test func completePlaylistWithOneFailedDetailOffersAllOtherTracksInOrder() async throws {
        var rows = (0..<82).map { qqSong("song\($0)") }
        rows[14] = ["mid": "", "id": 12345, "title": "private-title"]
        let body = try JSONSerialization.data(withJSONObject: ["code": 0, "req_0": ["code": 0, "data": ["songlist": rows, "total_song_num": 82]]])
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            if try qqRPC(request)["method"] as? String == "uniform_get_Dissinfo" {
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return try qqReply(request, ["code": 0, "req_0": ["code": 500, "message": "private-response"]])
        }))
        do { _ = try await provider.tracks(in: .init(id: "123", name: "Fixture", trackCount: 82, source: .qq), cookies: qqCookies); Issue.record("Partial result reported as complete") }
        catch let MusicError.incompletePlaylist(partial) {
            #expect(partial.tracks.count == 81); #expect(partial.totalCount == 82); #expect(partial.failedCount == 1)
            #expect(partial.tracks.map(\.sourceID) == (0..<82).filter { $0 != 14 }.map { "song\($0)" })
            let failure = L10n.string("补资料失败：\(expectedQQRPCFailure(operation: L10n.string("读取歌曲资料"), code: 500))")
            #expect(partial.issues == [expectedQQPlaylistIssue(position: 15, failure: failure)])
            #expect(partial.message == expectedQQPartialSummary(total: 82, parsed: 81, failed: 1, firstPosition: 15, firstFailure: failure))
            #expect(!partial.message.contains("private"))
        }
    }
    @Test func originalPageFailureOrMismatchNeverOffersPartialTracks() async throws {
        for failure in ["request", "empty", "repeat", "total"] {
            let calls = Mutex(0)
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                calls.withLock { $0 += 1 }
                let rpc = try qqRPC(request), params = try #require(rpc["param"] as? [String: Any]), offset = try #require(params["song_begin"] as? Int)
                if offset > 0, failure == "request" { throw URLError(.timedOut) }
                var rows = (0..<100).map { qqSong("song\($0)") }
                rows[14] = ["title": "private-missing-id"]
                if offset > 0, failure != "repeat" { rows = [] }
                let total = offset > 0 && failure == "total" ? 102 : 101
                return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["songlist": rows, "total_song_num": total]]])
            }))
            do { _ = try await provider.tracks(in: .init(id: "123", name: "Fixture", trackCount: 101, source: .qq), cookies: qqCookies); Issue.record("Missing original page accepted") }
            catch MusicError.incompletePlaylist { Issue.record("Incomplete original pagination offered partial import") }
            catch { #expect(!error.localizedDescription.contains("private")) }
            #expect(calls.withLock { $0 } == 2)
        }
    }
    @Test func failedHydrationIsCachedAndIssueDisplayIsBounded() async throws {
        let rows = [qqSong("validFirst")] + (0..<23).map { _ in ["mid": "", "id": 12345, "title": "private-title"] as [String: Any] } + [qqSong("validLast")]
        let body = try JSONSerialization.data(withJSONObject: ["code": 0, "req_0": ["code": 0, "data": ["songlist": rows, "total_song_num": 25]]])
        let details = Mutex(0)
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            if try qqRPC(request)["method"] as? String == "uniform_get_Dissinfo" {
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            details.withLock { $0 += 1 }
            return try qqReply(request, ["code": 0, "req_0": ["code": 500]])
        }))
        do { _ = try await provider.tracks(in: .init(id: "123", name: "Fixture", trackCount: 25, source: .qq), cookies: qqCookies); Issue.record("Repeated failure hidden") }
        catch let MusicError.incompletePlaylist(partial) {
            #expect(partial.tracks.map(\.sourceID) == ["validFirst", "validLast"])
            #expect(partial.totalCount == 25); #expect(partial.failedCount == 23); #expect(partial.issues.count == 20)
            let failure = L10n.string("补资料失败：\(expectedQQRPCFailure(operation: L10n.string("读取歌曲资料"), code: 500))")
            #expect(partial.message == expectedQQPartialSummary(total: 25, parsed: 2, failed: 23, firstPosition: 2, firstFailure: failure, omitted: 3))
            #expect(!partial.message.contains("private"))
        }
        #expect(details.withLock { $0 } == 1)
    }
    @Test func entirelyUnreadablePageDoesNotStopFetchingLaterReadablePage() async throws {
        let calls = Mutex(0)
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            calls.withLock { $0 += 1 }
            let params = try #require(try qqRPC(request)["param"] as? [String: Any]), offset = try #require(params["song_begin"] as? Int)
            let rows = offset == 0 ? (0..<100).map { ["title": "Fixture \($0)"] } : [qqSong("lastSong")]
            return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["songlist": rows, "total_song_num": 101]]])
        }))
        do { _ = try await provider.tracks(in: .init(id: "123", name: "Fixture", trackCount: 101, source: .qq), cookies: qqCookies); Issue.record("Unreadable page ignored") }
        catch let MusicError.incompletePlaylist(partial) {
            #expect(partial.tracks.map(\.sourceID) == ["lastSong"]); #expect(partial.totalCount == 101)
            #expect(partial.failedCount == 100); #expect(partial.issues.count == 20)
            #expect(partial.message == expectedQQPartialSummary(total: 101, parsed: 1, failed: 100, firstPosition: 1,
                                                               firstFailure: L10n.string("：歌曲资料缺少有效标识或标题。"), omitted: 80))
        }
        #expect(calls.withLock { $0 } == 2)
    }
    @Test func invalidNumericSongIDsNeverTriggerHydrationAndDiagnosticsAreStatic() async throws {
        let values: [(Any, String)] = [
            (NSNull(), L10n.string("空值")), (true, L10n.string("数字或布尔值")),
            (false, L10n.string("数字或布尔值")), (1.5, L10n.string("数字或布尔值")),
            (-12345, L10n.string("数字或布尔值")), (0, L10n.string("数字或布尔值")),
            ("1e3", L10n.string("文本")), ("999999999999999999999999999999", L10n.string("文本")),
            ("private-value", L10n.string("文本")), (["private": "value"], L10n.string("对象"))
        ]
        var rows: [([String: Any], String)] = values.map { value, type in
            (["mid": "", "id": value, "title": "private-title"],
             expectedQQIdentityIssue(midType: L10n.string("空文本"), idType: type))
        }
        rows.append((["mid": "private/invalid", "id": 12345, "songid": 67890, "title": "private-title"],
                     expectedQQIdentityIssue(midType: L10n.string("含不支持字符"), idType: L10n.string("数字或布尔值"),
                                             songIDType: L10n.string("数字或布尔值"), idValid: true, songIDValid: true, conflict: true)))
        for (row, issue) in rows {
            let body = try JSONSerialization.data(withJSONObject: ["code": 0, "req_0": ["code": 0, "data": ["songlist": [row], "total_song_num": 1]]])
            let calls = Mutex(0)
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                calls.withLock { $0 += 1 }
                let method = try qqRPC(request)["method"] as? String
                #expect(method == "uniform_get_Dissinfo")
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
            do { _ = try await provider.tracks(in: .init(id: "123", name: "Fixture", trackCount: 1, source: .qq), cookies: qqCookies); Issue.record("Invalid numeric identity accepted") }
            catch {
                let message = error.localizedDescription
                #expect(message == expectedQQUnimportedPlaylist(issue: issue))
                #expect(message.contains("id=")); #expect(message.contains("songid="))
                #expect(!message.contains("private")); #expect(!message.contains("12345")); #expect(!message.contains("67890"))
            }
            #expect(calls.withLock { $0 } == 1)
        }
    }
    @Test func playlistHydrationRequiresSuccessfulMatchingCompleteDetail() async throws {
        let cases: [([String: Any], String)] = [
            (["code": 0, "req_0": ["code": 104003, "msg": "private-value"]], expectedQQRPCFailure(operation: L10n.string("读取歌曲资料"), code: 104003)),
            (["code": 0, "req_0": ["code": 0, "data": ["code": 10006]]], expectedQQRPCFailure(operation: L10n.string("读取歌曲资料"), code: 10006)),
            (["code": 0, "req_0": ["code": 0, "data": [:]]], L10n.string("平台详情缺少曲目对象，无法确认该歌曲是否仍存在。")),
            (["code": 0, "req_0": ["code": 0, "data": ["track_info": ["mid": "good", "title": "private-title"]]]], L10n.string("平台详情缺少有效数字歌曲编号。")),
            (["code": 0, "req_0": ["code": 0, "data": ["track_info": ["id": true, "mid": "good", "title": "private-title"]]]], L10n.string("平台详情缺少有效数字歌曲编号。")),
            (["code": 0, "req_0": ["code": 0, "data": ["track_info": ["id": 67890, "mid": "good", "title": "private-title"]]]], L10n.string("平台返回的歌曲与请求编号不一致。")),
            (["code": 0, "req_0": ["code": 0, "data": ["track_info": ["id": 12345, "mid": "bad/private", "title": "private-title"]]]], L10n.string("平台详情仍没有合法歌曲 MID。")),
            (["code": 0, "req_0": ["code": 0, "data": ["track_info": ["id": 12345, "mid": true, "title": "private-title"]]]], L10n.string("平台详情仍没有合法歌曲 MID。")),
            (["code": 0, "req_0": ["code": 0, "data": ["track_info": ["id": 12345, "mid": 67890, "title": "private-title"]]]], L10n.string("平台详情仍没有合法歌曲 MID。")),
            (["code": 0, "req_0": ["code": 0, "data": ["track_info": ["id": 12345, "mid": "good"]]]], L10n.string("平台详情缺少可用标题或曲目结构不受支持。"))
        ]
        for (payload, reason) in cases {
            let response = try JSONSerialization.data(withJSONObject: payload), calls = Mutex(0)
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                calls.withLock { $0 += 1 }
                if try qqRPC(request)["method"] as? String == "uniform_get_Dissinfo" {
                    return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["songlist": [qqSong("validBefore"), ["mid": "", "songid": "12345", "title": "private-title"]], "total_song_num": 2]]])
                }
                return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
            do { _ = try await provider.tracks(in: .init(id: "123", name: "Fixture", trackCount: 2, source: .qq), cookies: qqCookies); Issue.record("Invalid hydration became partial success") }
            catch let MusicError.incompletePlaylist(partial) {
                let message = partial.message + partial.issues.joined(separator: "；")
                #expect(partial.tracks.count == 1); #expect(partial.failedCount == 1)
                let failure = L10n.string("补资料失败：\(reason)")
                #expect(partial.issues == [expectedQQPlaylistIssue(position: 2, failure: failure)])
                #expect(partial.message == expectedQQPartialSummary(total: 2, parsed: 1, failed: 1, firstPosition: 2, firstFailure: failure))
                #expect(!message.contains("private")); #expect(!message.contains("12345")); #expect(!message.contains("67890"))
            }
            #expect(calls.withLock { $0 } == 2)
        }
    }
    @Test func playlistHydrationCachesDuplicateNumericIdentitiesAndStopsAtTwentyRequests() async throws {
        for exceedsLimit in [false, true] {
            let count = exceedsLimit ? 21 : 20
            var rows = (1...count).map { ["mid": "", "id": $0, "title": "Fixture"] as [String: Any] }
            rows.insert(["mid": "", "songid": "1", "title": "Duplicate"], at: 1)
            let body = try JSONSerialization.data(withJSONObject: ["code": 0, "req_0": ["code": 0, "data": ["songlist": rows, "total_song_num": rows.count]]])
            let detailIDs = Mutex<[Int]>([])
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                let rpc = try qqRPC(request)
                if rpc["method"] as? String == "uniform_get_Dissinfo" {
                    return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
                let params = try #require(rpc["param"] as? [String: Any]), id = try #require(params["song_id"] as? Int)
                detailIDs.withLock { $0.append(id) }
                var info = qqSong("mid\(id)"); info["id"] = id
                return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["track_info": info]]])
            }))
            do {
                let tracks = try await provider.tracks(in: .init(id: "123", name: "Fixture", trackCount: count + 1, source: .qq), cookies: qqCookies)
                #expect(!exceedsLimit); #expect(tracks.map(\.sourceID) == (1...20).map { "mid\($0)" })
            } catch let MusicError.incompletePlaylist(partial) {
                #expect(exceedsLimit)
                let failure = L10n.string("补资料失败：已达到每次导入最多 20 次的补充请求上限。")
                #expect(partial.message == expectedQQPartialSummary(total: 22, parsed: 21, failed: 1, firstPosition: 22, firstFailure: failure))
                #expect(partial.issues == [expectedQQPlaylistIssue(position: 22, failure: failure)])
                #expect(partial.failedCount == 1); #expect(partial.tracks.count == 20)
            }
            #expect(detailIDs.withLock { $0 } == Array(1...20))
        }
    }
    @Test func playlistHydrationTimeoutStaysSpecificAndCancellationIsNotSwallowed() async {
        for cancel in [false, true] {
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                if try qqRPC(request)["method"] as? String == "uniform_get_Dissinfo" {
                    return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["songlist": [["mid": "", "id": 12345]], "total_song_num": 1]]])
                }
                if cancel { throw CancellationError() }
                throw URLError(.timedOut)
            }))
            do { _ = try await provider.tracks(in: .init(id: "123", name: "Fixture", trackCount: 1, source: .qq), cookies: qqCookies); Issue.record("Failed hydration accepted") }
            catch is CancellationError { #expect(cancel) }
            catch {
                #expect(!cancel)
                let failure = L10n.string("补资料失败：\(expectedQQTimeout())")
                let row = expectedQQPlaylistIssue(position: 1, failure: failure)
                #expect(error.localizedDescription == L10n.string("QQ 音乐歌单曲目格式不完整（成功解析 \(0)/\(1) 首；\(row)\("")），本次未导入。"))
            }
        }
    }
    @Test func playlistMalformedFieldsUseStaticTypeDiagnostics() async throws {
        let cases: [(Any, String)] = [
            (["private": "private-value"], L10n.string("QQ 音乐歌单响应格式异常（读取歌单曲目：第 \(1) 页 songlist 为\(L10n.string("对象"))，预期列表），本次未导入。")),
            (NSNull(), L10n.string("QQ 音乐歌单响应格式异常（读取歌单曲目：第 \(1) 页 songlist 为\(L10n.string("空值"))，预期列表），本次未导入。")),
            (["private-row"], expectedQQUnimportedPlaylist(issue: L10n.string("曲目为\(L10n.string("文本"))，预期对象"))),
            ([["mid": "private-invalid-id/", "title": "private-title"]], expectedQQUnimportedPlaylist(issue: expectedQQIdentityIssue(midType: L10n.string("含不支持字符")))),
            ([["mid": "valid", "title": ["private": "value"], "name": NSNull()]], expectedQQUnimportedPlaylist(issue: L10n.string("标题字段 title=\(L10n.string("对象"))、name=\(L10n.string("空值"))、songname=\(L10n.string("缺失"))")))
        ]
        for (list, category) in cases {
            let body = try JSONSerialization.data(withJSONObject: ["code": 0, "req_0": ["code": 0, "data": ["songlist": list]]])
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
            do { _ = try await provider.tracks(in: .init(id: "123", name: "Fixture", trackCount: 1, source: .qq), cookies: qqCookies); Issue.record("Malformed playlist accepted") }
            catch {
                #expect(error.localizedDescription == category)
                #expect(!error.localizedDescription.contains("private"))
            }
        }
    }
    @Test func playlistLatePageFailureDoesNotReturnEarlierTracks() async throws {
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            let rpc = try qqRPC(request), params = try #require(rpc["param"] as? [String: Any]), offset = try #require(params["song_begin"] as? Int)
            let rows = offset == 0 ? (0..<100).map { qqSong("song\($0)") } : [["title": "private-title"]]
            return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["total_song_num": 101, "songlist": rows]]])
        }))
        do { _ = try await provider.tracks(in: .init(id: "123", name: "Fixture", trackCount: 101, source: .qq), cookies: qqCookies); Issue.record("Earlier page returned after a later bad row") }
        catch let MusicError.incompletePlaylist(partial) {
            #expect(partial.issues == [expectedQQPlaylistIssue(page: 2, position: 101, failure: L10n.string("：\(expectedQQIdentityIssue())"))])
            #expect(partial.message == expectedQQPartialSummary(total: 101, parsed: 100, failed: 1, firstPosition: 101,
                                                               firstFailure: L10n.string("：歌曲资料缺少有效标识或标题。")))
            #expect(!partial.message.contains("private")); #expect(partial.tracks.count == 100); #expect(partial.failedCount == 1)
        }
    }
    @Test func freshAuthorizedURLIsHTTPSAndNeverUsesTrackCachedURL() async throws {
        let calls = Mutex(0)
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            calls.withLock { $0 += 1 }; let rpc = try qqRPC(request)
            if rpc["method"] as? String == "get_song_detail_yqq" { return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["track_info": ["mid": "mid1", "file": ["media_mid": "media1"]]]]]) }
            let parameters = try #require(rpc["param"] as? [String: Any])
            #expect(rpc["module"] as? String == "vkey.GetVkeyServer"); #expect(rpc["method"] as? String == "CgiGetVkey")
            #expect(parameters["filename"] as? [String] == ["M500media1.mp3"])
            #expect(parameters["songmid"] as? [String] == ["mid1"])
            #expect(parameters["songtype"] as? [Int] == [0])
            #expect(parameters["xcdn"] == nil); #expect(parameters["ctx"] == nil)
            #expect(request.url?.path == "/cgi-bin/musicu.fcg"); #expect(request.url?.query == nil)
            return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["sip": ["http://isure.stream.qqmusic.qq.com/"], "midurlinfo": [["songmid": "mid1", "filename": "M500media1.mp3", "result": 0, "purl": "M500media1.mp3?vkey=authorized"]]]]])
        }))
        let track = Track(id: "qq:mid1", title: "Song", artist: "", album: "", duration: 10, source: .qq, sourceID: "mid1", url: URL(string: "https://example.com/stale"))
        let first = try await provider.resolve(track, cookies: qqCookies); _ = try await provider.resolve(track, cookies: qqCookies)
        #expect(first.scheme == "https"); #expect(first.host == "isure.stream.qqmusic.qq.com"); #expect(calls.withLock { $0 } == 4)
    }
    @Test func wechatPlaybackUsesScopedTicketAndExactLongUinSeparatelyFromMetadata() async throws {
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            let body = try #require(request.httpBody)
            let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let comm = try #require(root["comm"] as? [String: Any])
            #expect(comm["uin"] as? String == "12345678901234567")
            #expect(comm["tmeLoginType"] == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("qm_keyst=fixture-wechat-key") == true)
            let rpc = try qqRPC(request)
            if rpc["method"] as? String == "get_song_detail_yqq" {
                #expect(comm["authst"] == nil)
                #expect(comm["g_tk"] as? UInt32 == 5381)
                #expect(comm["g_tk_new_20200303"] as? UInt32 == 5381)
                return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["track_info": ["mid": "mid1", "type": 0, "file": ["media_mid": "media1"]]]]])
            }
            #expect(comm["authst"] as? String == "fixture-wechat-key")
            #expect(comm["ct"] as? Int == 19); #expect(comm["cv"] as? Int == 0)
            #expect(comm["g_tk"] == nil); #expect(comm["g_tk_new_20200303"] == nil)
            let parameters = try #require(rpc["param"] as? [String: Any])
            #expect(parameters["uin"] as? String == "12345678901234567")
            return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["midurlinfo": [["songmid": "mid1", "purl": "https://ws6.stream.qqmusic.qq.com/M500fixture.mp3?vkey=fixture"]]]]])
        }))
        let track = Track(id: "qq:mid1", title: "Fixture", artist: "", album: "", duration: 1, source: .qq, sourceID: "mid1")
        #expect(try await provider.resolve(track, cookies: qqWechatCookies).host == "ws6.stream.qqmusic.qq.com")
    }
    @Test func webUinEncodingMatchesBrowserLengthBoundary() async throws {
        let cases: [(String, String, Bool)] = [
            ("o0012345678", "12345678", false),
            ("1234567890123", "1234567890123", false),
            ("12345678901234", "12345678901234", true),
            ("12345678901234567", "12345678901234567", true),
            ("o00000012345678", "00000012345678", true)
        ]
        for (raw, expected, expectsString) in cases {
            let cookies = [MusicSessionCookie(name: "uin", value: raw, domain: ".y.qq.com"), qqCookies[1]]
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                let body = try #require(request.httpBody)
                let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let comm = try #require(root["comm"] as? [String: Any])
                let rpc = try qqRPC(request)
                if expectsString || rpc["method"] as? String == "CgiGetVkey" { #expect(comm["uin"] as? String == expected) }
                else {
                    #expect(!(comm["uin"] is String))
                    #expect((comm["uin"] as? NSNumber)?.stringValue == expected)
                }
                if rpc["method"] as? String == "get_song_detail_yqq" {
                    return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["track_info": ["mid": "mid1", "type": 0, "file": ["media_mid": "media1"]]]]])
                }
                let parameters = try #require(rpc["param"] as? [String: Any])
                // Ticket-based playback uses text for both UIN fields.
                #expect(parameters["uin"] as? String == expected)
                #expect(parameters["ctx"] == nil)
                return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["midurlinfo": [["songmid": "mid1", "purl": "https://ws6.stream.qqmusic.qq.com/M500fixture.mp3"]]]]])
            }))
            let track = Track(id: "qq:mid1", title: "Fixture", artist: "", album: "", duration: 1, source: .qq, sourceID: "mid1")
            #expect(try await provider.resolve(track, cookies: cookies).host == "ws6.stream.qqmusic.qq.com")
        }
    }
    @Test func csrfUsesOnlyOfficialCookiePrioritiesAndEmptySeed() async throws {
        let cases: [([String: String], UInt32, UInt32)] = [
            (["qm_keyst": "a"], 5381, 5381),
            (["p_lskey": "b"], 177671, 5381),
            (["qm_keyst": "a", "lskey": "c"], 177672, 5381),
            (["qm_keyst": "a", "p_lskey": "b", "lskey": "c"], 177671, 5381),
            (["qm_keyst": "a", "p_skey": "d", "skey": "e"], 177673, 177674),
            (["qqmusic_key": "f", "p_skey": "d", "skey": "e"], 177675, 177674),
            (["qqmusic_key": "f"], 177675, 177675)
        ]
        for (values, expectedNew, expectedLegacy) in cases {
            let cookies = [qqCookies[0]] + values.map { MusicSessionCookie(name: $0.key, value: $0.value, domain: ".y.qq.com") }
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                let body = try #require(request.httpBody)
                let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let comm = try #require(root["comm"] as? [String: Any])
                #expect(comm["g_tk_new_20200303"] as? UInt32 == expectedNew)
                #expect(comm["g_tk"] as? UInt32 == expectedLegacy)
                return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["body": ["song": ["list": []]]]]])
            }))
            #expect(try await provider.search("fixture", cookies: cookies).isEmpty)
        }
    }
    @Test func encodedCookiesAreDecodedOnlyForProtocolFields() async throws {
        let cases = [("private%2Bticket%2Fpart%3D%3D", "private+ticket/part=="),
                     ("private%252Bticket%252Fpart%253D%253D", "private+ticket/part=="),
                     ("private+ticket", "private+ticket")]
        for (raw, decoded) in cases {
            let diagnostics = Mutex<[QQDirectProvider.PlaybackTicketDiagnostic]>([])
            let calls = Mutex(0)
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                calls.withLock { $0 += 1 }
                let header = request.value(forHTTPHeaderField: "Cookie") ?? ""
                #expect(header.contains("qqmusic_key=\(raw)"))
                #expect(header.contains("uin=o%31%32%33%34%35%36%37%38"))
                let body = try #require(request.httpBody)
                let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let comm = try #require(root["comm"] as? [String: Any])
                if try qqRPC(request)["method"] as? String == "get_song_detail_yqq" {
                    #expect(comm["uin"] as? Int == 12345678)
                    #expect(comm["g_tk_new_20200303"] as? UInt32 == QQWebSigning.csrfToken(decoded))
                    #expect(comm["g_tk"] as? UInt32 == QQWebSigning.csrfToken(decoded))
                    return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["track_info": ["mid": "mid1", "file": ["media_mid": "media1"]]]]])
                }
                #expect(comm["uin"] as? String == "12345678")
                #expect(comm["authst"] as? String == decoded)
                return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["midurlinfo": [["songmid": "mid1", "result": 104003]]]]])
            }), playbackFailureReporter: { diagnostic in diagnostics.withLock { $0.append(diagnostic) } })
            let cookies = [MusicSessionCookie(name: "uin", value: "o%31%32%33%34%35%36%37%38", domain: ".y.qq.com"), MusicSessionCookie(name: "qqmusic_key", value: raw, domain: ".y.qq.com")]
            let track = Track(id: "qq:mid1", title: "Fixture", artist: "", album: "", duration: 1, source: .qq, sourceID: "mid1")
            do { _ = try await provider.resolve(track, cookies: cookies); Issue.record("Denied playback accepted") }
            catch { #expect(error.localizedDescription.contains("104003")); #expect(!error.localizedDescription.contains("private")) }
            let diagnostic = try #require(diagnostics.withLock { $0.first })
            #expect(diagnostic.selectedValueWasDecoded == (raw != decoded))
            #expect(!diagnostic.safeDescription.contains("private"))
            #expect(calls.withLock { $0 } == 2)
        }
    }
    @Test func malformedOrExcessivelyEncodedSessionIsRejectedWithoutSending() async {
        var nested = "private+key"
        for _ in 0..<12 { nested = nested.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
        for raw in ["private%ZZ", "private%FF", nested] {
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { _ in
                Issue.record("Malformed session reached the network")
                throw CancellationError()
            }))
            let cookies = [qqCookies[0], MusicSessionCookie(name: "qqmusic_key", value: raw, domain: ".y.qq.com")]
            do { _ = try await provider.profile(cookies: cookies); Issue.record("Malformed session accepted") }
            catch { #expect(error.localizedDescription == L10n.string("QQ 音乐登录信息的编码无法识别，请重新完成官网登录。")); #expect(!error.localizedDescription.contains("private")) }
        }
    }
    @Test func playbackPrefersWebTicketWithSafeFailureDiagnosticsAndNoRetry() async throws {
        for legacyValue in ["private-legacy-ticket", "private-web-ticket"] {
            let calls = Mutex(0)
            let diagnostics = Mutex<[QQDirectProvider.PlaybackTicketDiagnostic]>([])
            let cookies = [qqCookies[0], MusicSessionCookie(name: "qm_keyst", value: legacyValue, domain: ".y.qq.com"), MusicSessionCookie(name: "qqmusic_key", value: "private-web-ticket", domain: ".y.qq.com")]
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                calls.withLock { $0 += 1 }
                if try qqRPC(request)["method"] as? String == "get_song_detail_yqq" {
                    return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["track_info": ["mid": "mid1", "file": ["media_mid": "media1"]]]]])
                }
                let body = try #require(request.httpBody)
                let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let comm = try #require(root["comm"] as? [String: Any])
                #expect(comm["authst"] as? String == "private-web-ticket")
                #expect(comm["uin"] as? String == "12345678")
                #expect(request.url?.path == "/cgi-bin/musicu.fcg")
                return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["midurlinfo": [["songmid": "mid1", "result": 104003, "msg": "private-server-response"]]]]])
            }), playbackFailureReporter: { diagnostic in diagnostics.withLock { $0.append(diagnostic) } })
            let track = Track(id: "qq:mid1", title: "Fixture", artist: "", album: "", duration: 1, source: .qq, sourceID: "mid1")
            do { _ = try await provider.resolve(track, cookies: cookies); Issue.record("Denied playback accepted") }
            catch {
                #expect(error.localizedDescription.contains("104003"))
                for hidden in ["private", "qqmusic_key", "qm_keyst", "12345678"] { #expect(!error.localizedDescription.contains(hidden)) }
            }
            let diagnostic = try #require(diagnostics.withLock { $0 }.first)
            #expect(diagnostic.selectedCookieName == "qqmusic_key")
            #expect(diagnostic.primaryCandidatesBothPresent)
            #expect(diagnostic.primaryCandidatesDiffer == (legacyValue != "private-web-ticket"))
            #expect(diagnostic.safeDescription == "ticket=qqmusic_key both_primary_present=true primary_differ=\(legacyValue != "private-web-ticket") percent_decoded=false")
            for hidden in ["private", "12345678", "https://", "vkey=", "mid1"] { #expect(!diagnostic.safeDescription.contains(hidden)) }
            #expect(diagnostics.withLock { $0.count } == 1)
            #expect(calls.withLock { $0 } == 2)
        }
    }
    @Test func preferredPlaybackTicketRespectsScopeAndKeepsLegacyFallback() async throws {
        let legacy = MusicSessionCookie(name: "qm_keyst", value: "private-legacy", domain: ".y.qq.com")
        let cases: [([MusicSessionCookie], String, String, Bool)] = [
            ([], "private-legacy", "qm_keyst", false),
            ([MusicSessionCookie(name: "qqmusic_key", value: "private-expired", domain: ".y.qq.com", expires: .distantPast)], "private-legacy", "qm_keyst", false),
            ([MusicSessionCookie(name: "qqmusic_key", value: "private-untrusted", domain: ".example.com")], "private-legacy", "qm_keyst", false),
            ([MusicSessionCookie(name: "qqmusic_key", value: "private-other-host", domain: "c.y.qq.com")], "private-legacy", "qm_keyst", false),
            ([MusicSessionCookie(name: "qqmusic_key", value: "private-metadata", domain: ".y.qq.com", path: "/cgi-bin/musics.fcg")], "private-legacy", "qm_keyst", false),
            ([MusicSessionCookie(name: "qqmusic_key", value: "private-child-path", domain: ".y.qq.com", path: "/cgi-bin/musicu.fcg/child")], "private-legacy", "qm_keyst", false),
            ([MusicSessionCookie(name: "qqmusic_key", value: "", domain: ".y.qq.com")], "private-legacy", "qm_keyst", false),
            ([MusicSessionCookie(name: "qqmusic_key", value: "private-root", domain: ".y.qq.com"), MusicSessionCookie(name: "qqmusic_key", value: "private-scoped", domain: ".y.qq.com", path: "/cgi-bin/musicu.fcg")], "private-scoped", "qqmusic_key", true)
        ]
        for (extra, expectedValue, expectedName, bothPresent) in cases {
            let diagnostics = Mutex<[QQDirectProvider.PlaybackTicketDiagnostic]>([])
            let calls = Mutex(0)
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                calls.withLock { $0 += 1 }
                if try qqRPC(request)["method"] as? String == "get_song_detail_yqq" {
                    return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["track_info": ["mid": "mid1", "file": ["media_mid": "media1"]]]]])
                }
                let body = try #require(request.httpBody)
                let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let comm = try #require(root["comm"] as? [String: Any])
                #expect(comm["authst"] as? String == expectedValue)
                let cookieHeader = request.value(forHTTPHeaderField: "Cookie") ?? ""
                #expect(cookieHeader.components(separatedBy: "; ").first { $0.hasPrefix("\(expectedName)=") } == "\(expectedName)=\(expectedValue)")
                for rejected in ["private-expired", "private-untrusted", "private-other-host", "private-metadata", "private-child-path"] { #expect(!cookieHeader.contains(rejected)) }
                return try qqReply(request, ["code": 104003, "msg": "private-platform-error"])
            }), playbackFailureReporter: { diagnostic in diagnostics.withLock { $0.append(diagnostic) } })
            let track = Track(id: "qq:mid1", title: "Fixture", artist: "", album: "", duration: 1, source: .qq, sourceID: "mid1")
            do { _ = try await provider.resolve(track, cookies: [qqCookies[0], legacy] + extra); Issue.record("Denied playback accepted") }
            catch { #expect(error.localizedDescription.contains("104003")) }
            let diagnostic = try #require(diagnostics.withLock { $0 }.first)
            #expect(diagnostic.selectedCookieName == expectedName)
            #expect(diagnostic.primaryCandidatesBothPresent == bothPresent)
            #expect(diagnostic.primaryCandidatesDiffer == bothPresent)
            #expect(!diagnostic.safeDescription.contains("private"))
            #expect(diagnostics.withLock { $0.count } == 1)
            #expect(calls.withLock { $0 } == 2)
        }
    }
    @Test func successfulOrCancelledPlaybackDoesNotReportTicketFailure() async throws {
        for cancel in [false, true] {
            let diagnostics = Mutex<[QQDirectProvider.PlaybackTicketDiagnostic]>([])
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                if try qqRPC(request)["method"] as? String == "get_song_detail_yqq" {
                    return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["track_info": ["mid": "mid1", "file": ["media_mid": "media1"]]]]])
                }
                if cancel { throw CancellationError() }
                return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["midurlinfo": [["songmid": "mid1", "purl": "https://ws6.stream.qqmusic.qq.com/M500media1.mp3"]]]]])
            }), playbackFailureReporter: { diagnostic in diagnostics.withLock { $0.append(diagnostic) } })
            let track = Track(id: "qq:mid1", title: "Fixture", artist: "", album: "", duration: 1, source: .qq, sourceID: "mid1")
            do { _ = try await provider.resolve(track, cookies: qqCookies); #expect(!cancel) }
            catch is CancellationError { #expect(cancel) }
            #expect(diagnostics.withLock { $0.isEmpty })
        }
    }
    @Test func playbackTicketUsesOnlyMatchingOfficialCookiesAndLongestPath() async throws {
        let ticket = "private-playback-ticket"
        let validNames = ["qm_keyst", "qqmusic_key", "music_key", "wxskey"]
        var cases: [([MusicSessionCookie], String?)] = validNames.map {
            ([MusicSessionCookie(name: $0, value: ticket, domain: ".y.qq.com")], ticket)
        }
        cases += [
            ([MusicSessionCookie(name: "qm_keyst", value: ticket, domain: "example.com")], nil),
            ([MusicSessionCookie(name: "music_key", value: ticket, domain: "c.y.qq.com")], nil),
            ([MusicSessionCookie(name: "wxskey", value: ticket, domain: ".y.qq.com", expires: .distantPast)], nil),
            ([MusicSessionCookie(name: "qm_keyst", value: ticket, domain: ".y.qq.com", path: "/cgi-bin/musics.fcg")], nil),
            ([MusicSessionCookie(name: "qm_keyst", value: "private-root-ticket", domain: ".y.qq.com"), MusicSessionCookie(name: "qm_keyst", value: ticket, domain: ".y.qq.com", path: "/cgi-bin/musicu.fcg")], ticket)
        ]
        for (extra, expected) in cases {
            let calls = Mutex(0)
            let cookies = [qqCookies[0], MusicSessionCookie(name: "p_lskey", value: "private-profile-only", domain: ".y.qq.com")] + extra
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                calls.withLock { $0 += 1 }
                if try qqRPC(request)["method"] as? String == "get_song_detail_yqq" {
                    return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["track_info": ["mid": "mid1", "type": 0, "file": ["media_mid": "media1"]]]]])
                }
                let body = try #require(request.httpBody)
                let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let comm = try #require(root["comm"] as? [String: Any])
                #expect(comm["authst"] as? String == expected)
                #expect(comm["uin"] as? String == "12345678")
                #expect(request.url?.absoluteString == "https://u.y.qq.com/cgi-bin/musicu.fcg")
                #expect(!request.url!.absoluteString.contains("private"))
                if extra.count == 2 {
                    #expect(request.value(forHTTPHeaderField: "Cookie")?.hasPrefix("qm_keyst=private-playback-ticket;") == true)
                }
                return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["sip": ["https://ws6.stream.qqmusic.qq.com/"], "midurlinfo": [["songmid": "mid1", "result": 0, "purl": "M500media1.mp3"]]]]])
            }))
            let track = Track(id: "qq:mid1", title: "Fixture", artist: "", album: "", duration: 1, source: .qq, sourceID: "mid1")
            do { _ = try await provider.resolve(track, cookies: cookies); #expect(expected != nil) }
            catch {
                #expect(expected == nil); #expect(error.localizedDescription == L10n.string("QQ 音乐网页登录有效，但本次会话缺少播放票据，请重新打开应用内官网窗口完成登录。"))
                #expect(!error.localizedDescription.contains("private"))
            }
            #expect(calls.withLock { $0 } == (expected == nil ? 0 : 2))
        }
    }
    @Test func metadataAndPlaybackEachUseTheirOwnMatchingCookieScope() async throws {
        let cookies = [
            qqCookies[0],
            MusicSessionCookie(name: "qqmusic_key", value: "metadata-root-ticket", domain: ".y.qq.com"),
            MusicSessionCookie(name: "qqmusic_key", value: "playback-path-ticket", domain: ".y.qq.com", path: "/cgi-bin/musicu.fcg"),
            MusicSessionCookie(name: "uin", value: "o0012345678", domain: ".y.qq.com", path: "/cgi-bin/musicu.fcg")
        ]
        let calls = Mutex(0)
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            calls.withLock { $0 += 1 }
            let body = try #require(request.httpBody)
            let root = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let comm = try #require(root["comm"] as? [String: Any])
            let header = request.value(forHTTPHeaderField: "Cookie") ?? ""
            if try qqRPC(request)["method"] as? String == "get_song_detail_yqq" {
                #expect(request.url?.path == "/cgi-bin/musics.fcg")
                #expect(comm["uin"] as? UInt64 == 12345678)
                #expect(comm["g_tk"] as? UInt32 == QQWebSigning.csrfToken("metadata-root-ticket"))
                #expect(comm["g_tk_new_20200303"] as? UInt32 == QQWebSigning.csrfToken("metadata-root-ticket"))
                #expect(comm["authst"] == nil)
                #expect(header.contains("qqmusic_key=metadata-root-ticket"))
                #expect(!header.contains("playback-path-ticket"))
                #expect(!String(decoding: body, as: UTF8.self).contains("playback-path-ticket"))
                return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["track_info": ["mid": "mid1", "file": ["media_mid": "media1"]]]]])
            }
            #expect(request.url?.path == "/cgi-bin/musicu.fcg")
            #expect(comm["uin"] as? String == "12345678")
            #expect(comm["authst"] as? String == "playback-path-ticket")
            #expect(header.components(separatedBy: "; ").first { $0.hasPrefix("qqmusic_key=") } == "qqmusic_key=playback-path-ticket")
            return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["sip": ["https://ws6.stream.qqmusic.qq.com/"], "midurlinfo": [["songmid": "mid1", "result": 0, "purl": "M500media1.mp3"]]]]])
        }))
        let track = Track(id: "qq:mid1", title: "Fixture", artist: "", album: "", duration: 1, source: .qq, sourceID: "mid1")
        #expect(try await provider.resolve(track, cookies: cookies).host == "ws6.stream.qqmusic.qq.com")
        #expect(calls.withLock { $0 } == 2)
    }
    @Test func conflictingPathScopedAccountIdentitiesRejectBeforeTransport() async {
        let calls = Mutex(0)
        let cookies = qqCookies + [MusicSessionCookie(name: "uin", value: "o87654321", domain: ".y.qq.com", path: "/cgi-bin/musicu.fcg")]
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            calls.withLock { $0 += 1 }; return try qqReply(request, ["code": 0])
        }))
        let track = Track(id: "qq:mid1", title: "Fixture", artist: "", album: "", duration: 1, source: .qq, sourceID: "mid1")
        do { _ = try await provider.resolve(track, cookies: cookies); Issue.record("Different scoped accounts accepted") }
        catch {
            #expect(error.localizedDescription == L10n.string("QQ 音乐资料与播放会话的账户不一致，请重新打开应用内官网窗口完成登录。"))
            #expect(!error.localizedDescription.contains("12345678"))
            #expect(!error.localizedDescription.contains("87654321"))
        }
        #expect(calls.withLock { $0 } == 0)
    }
    @Test func missingMediaIdentifierNeverSubstitutesSongMID() async throws {
        for file in [NSNull(), [:], ["media_mid": ""], ["media_mid": 123], ["media_mid": "bad/private"]] as [Any] {
            let calls = Mutex(0)
            let data = try JSONSerialization.data(withJSONObject: ["code": 0, "req_0": ["code": 0, "data": ["track_info": ["mid": "mid1", "file": file]]]])
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                calls.withLock { $0 += 1 }
                let rpc = try qqRPC(request)
                #expect(rpc["method"] as? String == "get_song_detail_yqq")
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
            let track = Track(id: "qq:mid1", title: "Fixture", artist: "", album: "", duration: 1, source: .qq, sourceID: "mid1")
            do { _ = try await provider.resolve(track, cookies: qqCookies); Issue.record("Missing media ID accepted") }
            catch { #expect(error.localizedDescription == L10n.string("QQ 音乐未返回这首歌的有效媒体编号，暂时无法请求播放地址。")); #expect(!error.localizedDescription.contains("private")) }
            #expect(calls.withLock { $0 } == 1)
        }
    }
    @Test func playbackRejectsEveryResponseLayerWithoutAlternateRequest() async throws {
        let payloads: [[String: Any]] = [
            ["code": 104003, "msg": "private-server-detail"],
            ["code": 0, "req_0": ["code": 104003, "data": [:]]],
            ["code": 0, "req_0": ["code": 0, "data": ["code": 104003]]]
        ]
        for payload in payloads {
            let calls = Mutex(0), data = try JSONSerialization.data(withJSONObject: payload)
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                calls.withLock { $0 += 1 }
                if try qqRPC(request)["method"] as? String == "get_song_detail_yqq" {
                    return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["track_info": ["mid": "mid1", "file": ["media_mid": "media1"]]]]])
                }
                #expect(request.url?.path == "/cgi-bin/musicu.fcg")
                let rpc = try qqRPC(request)
                #expect(rpc["method"] as? String == "CgiGetVkey")
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
            let track = Track(id: "qq:mid1", title: "Fixture", artist: "", album: "", duration: 1, source: .qq, sourceID: "mid1")
            do { _ = try await provider.resolve(track, cookies: qqCookies); Issue.record("Platform rejection ignored") }
            catch { #expect(error.localizedDescription.contains("104003")); #expect(!error.localizedDescription.contains("private")) }
            #expect(calls.withLock { $0 } == 2)
        }
    }
    @Test func authorizationFailuresKeepDistinctSafeReasonsAndNeverRetryOtherRoutes() async throws {
        let cases: [([String: Any], String)] = [
            ([:], L10n.string("QQ 音乐播放授权响应缺少歌曲列表，请稍后重试或更新应用。")),
            (["midurlinfo": [["songmid": "different-mid", "purl": "M500fixture.mp3"]]], L10n.string("QQ 音乐未返回所选歌曲的播放授权，请在官网查看其可播放状态。")),
            (["midurlinfo": [["songmid": "mid1", "result": 104003, "msg": "fixture-wechat-key private info"]]], L10n.string("QQ 音乐未能返回这首歌的播放地址（平台返回码 \(String(104003))），平台未说明具体原因。")),
            (["midurlinfo": [["songmid": "mid1", "result": 0, "filename": "M500other.mp3", "purl": "M500other.mp3"]]], L10n.string("QQ 音乐返回的音频文件与本次请求不一致，暂未播放。")),
            (["midurlinfo": [["songmid": "mid1", "result": 104005, "purl": "M500fixture.mp3", "msg": "fixture-wechat-key private info"]]], L10n.string("QQ 音乐未能返回这首歌的播放地址（平台返回码 \(String(104005))），平台未说明具体原因。")),
            (["midurlinfo": [["songmid": "mid1", "purl": ""]]], L10n.string("QQ 音乐未提供当前账户可播放的完整音频链接，请在官网查看这首歌的可播放状态。")),
            (["midurlinfo": [["songmid": "mid1", "purl": "RS02fixture.mp3"]]], L10n.string("QQ 音乐仅返回了试听音频，暂不播放；请在官网查看完整歌曲的可播放状态。")),
            (["midurlinfo": [["songmid": "mid1", "purl": "F000fixture.mflac"]]], L10n.string("QQ 音乐返回的音频格式暂不支持；加密文件不会被解密或播放。"))
        ]
        for (payload, explanation) in cases {
            let calls = Mutex(0), data = try JSONSerialization.data(withJSONObject: ["code": 0, "req_0": ["code": 0, "data": payload]])
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                calls.withLock { $0 += 1 }
                if try qqRPC(request)["method"] as? String == "get_song_detail_yqq" {
                    return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["track_info": ["mid": "mid1", "file": ["media_mid": "media1"]]]]])
                }
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
            let track = Track(id: "qq:mid1", title: "Fixture", artist: "", album: "", duration: 1, source: .qq, sourceID: "mid1")
            do { _ = try await provider.resolve(track, cookies: qqWechatCookies); Issue.record("Denied or unsupported audio accepted") }
            catch {
                #expect(error.localizedDescription == explanation); #expect(!error.localizedDescription.contains("fixture-wechat-key"))
            }
            #expect(calls.withLock { $0 } == 2)
        }
    }
    @Test func deniedPreviewOrUntrustedAudioNeverFallsBack() async {
        for purl in ["", "RS02preview.m4a", "https://example.com/M500media1.mp3", "M500media1.mp3"] {
            let calls = Mutex(0)
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                calls.withLock { $0 += 1 }
                let rpc = try qqRPC(request)
                if rpc["method"] as? String == "get_song_detail_yqq" { return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["track_info": ["mid": "mid1", "file": ["media_mid": "media1"]]]]]) }
                return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["sip": ["https://example.com/"], "midurlinfo": [["songmid": "mid1", "purl": purl]]]]])
            }))
            let track = Track(id: "qq:mid1", title: "Song", artist: "", album: "", duration: 10, source: .qq, sourceID: "mid1")
            do { _ = try await provider.resolve(track, cookies: qqCookies); Issue.record("Accepted denied/preview/untrusted stream") } catch { }
            #expect(calls.withLock { $0 } == 2)
        }
    }
    @Test func rejectedAudioHostDiagnosticNeverIncludesSignedURLOrUserInfo() async throws {
        let cases: [(String, String)] = [
            ("https://unverified.example.com/private-path.mp3?vkey=private-vkey&uin=private-account", L10n.string("QQ 音乐返回了不受信任的音频地址（主机：\("unverified.example.com")），暂未播放。")),
            ("https://private-user:private-pass@unverified.example.com/private-path.mp3?vkey=private-vkey", L10n.string("QQ 音乐返回的音频连接参数不受支持（主机：\("unverified.example.com")）。")),
            ("https://unverified.example.com:8443/private-path.mp3?vkey=private-vkey", L10n.string("QQ 音乐返回的音频连接参数不受支持（主机：\("unverified.example.com")）。")),
            ("https://127.0.0.1/private-path.mp3?vkey=private-vkey", L10n.string("QQ 音乐返回了不受信任的音频地址（主机：\("127.0.0.1")），暂未播放。"))
        ]
        for (purl, explanation) in cases {
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                if try qqRPC(request)["method"] as? String == "get_song_detail_yqq" {
                    return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["track_info": ["mid": "mid1", "file": ["media_mid": "media1"]]]]])
                }
                return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["midurlinfo": [["songmid": "mid1", "purl": purl]]]]])
            }))
            let track = Track(id: "qq:mid1", title: "Fixture", artist: "", album: "", duration: 1, source: .qq, sourceID: "mid1")
            do { _ = try await provider.resolve(track, cookies: qqWechatCookies); Issue.record("Rejected host accepted") }
            catch {
                #expect(error.localizedDescription == explanation)
                #expect(error.localizedDescription.contains(purl.contains("127.0.0.1") ? "127.0.0.1" : "unverified.example.com"))
                for secret in ["private-path", "private-vkey", "private-account", "private-user", "private-pass", "https://", "?", "8443"] {
                    #expect(!error.localizedDescription.contains(secret))
                }
            }
        }
    }
    @Test func suppliedSipRemainsEligibleAfterUnusableThirdipAndPreservesPriority() async throws {
        let cases: [([String], String)] = [
            (["http://192.0.2.1/"], "ws6.stream.qqmusic.qq.com"),
            ([""], "ws6.stream.qqmusic.qq.com"),
            (["https://unverified.example.com/"], "ws6.stream.qqmusic.qq.com"),
            (["http://isure.stream.qqmusic.qq.com:8080/"], "ws6.stream.qqmusic.qq.com"),
            (["http://192.0.2.1/", "https://isure.stream.qqmusic.qq.com/"], "isure.stream.qqmusic.qq.com")
        ]
        for (thirdip, expectedHost) in cases {
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                if try qqRPC(request)["method"] as? String == "get_song_detail_yqq" {
                    return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["track_info": ["mid": "mid1", "file": ["media_mid": "media1"]]]]])
                }
                return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["thirdip": thirdip, "sip": ["https://ws6.stream.qqmusic.qq.com/"], "midurlinfo": [["songmid": "mid1", "purl": "M500fixture.mp3?vkey=fixture&fromtag=fixture"]]]]])
            }))
            let track = Track(id: "qq:mid1", title: "Fixture", artist: "", album: "", duration: 1, source: .qq, sourceID: "mid1")
            let url = try await provider.resolve(track, cookies: qqCookies)
            #expect(url.host == expectedHost)
            #expect(url.path == "/M500fixture.mp3")
            #expect(url.query == "vkey=fixture&fromtag=fixture")
        }
    }
    @Test func onlyHTTPDefaultPortIsNormalizedDuringHTTPSUpgrade() async throws {
        let cases: [(String, Bool)] = [
            ("http://ws6.stream.qqmusic.qq.com:80/", true),
            ("https://ws6.stream.qqmusic.qq.com:80/", false),
            ("http://ws6.stream.qqmusic.qq.com:8080/", false),
            ("https://ws6.stream.qqmusic.qq.com:8080/", false)
        ]
        for (server, expectedSuccess) in cases {
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                if try qqRPC(request)["method"] as? String == "get_song_detail_yqq" {
                    return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["track_info": ["mid": "mid1", "file": ["media_mid": "media1"]]]]])
                }
                return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["thirdip": [server], "midurlinfo": [["songmid": "mid1", "purl": "M500fixture.mp3?vkey=fixture"]]]]])
            }))
            let track = Track(id: "qq:mid1", title: "Fixture", artist: "", album: "", duration: 1, source: .qq, sourceID: "mid1")
            do {
                let url = try await provider.resolve(track, cookies: qqCookies)
                #expect(expectedSuccess); #expect(url.scheme == "https"); #expect(url.port == nil)
            } catch {
                #expect(!expectedSuccess)
                #expect(error.localizedDescription == L10n.string("QQ 音乐返回的音频连接参数不受支持（主机：\("ws6.stream.qqmusic.qq.com")）。"))
            }
        }
    }
    @Test func rejectedServersDoNotActivateDefaultCDNOrRewriteAbsoluteURLHost() async throws {
        let cases: [([String: Any], String)] = [
            (["thirdip": ["https://192.0.2.1/"], "midurlinfo": [["songmid": "mid1", "purl": "M500fixture.mp3?vkey=fixture"]]], "192.0.2.1"),
            (["thirdip": ["https://192.0.2.1/"], "sip": ["https://ws6.stream.qqmusic.qq.com/"], "midurlinfo": [["songmid": "mid1", "purl": "https://unverified.example.com/M500fixture.mp3?vkey=fixture"]]], "unverified.example.com")
        ]
        for (payload, expectedHost) in cases {
            let data = try JSONSerialization.data(withJSONObject: ["code": 0, "req_0": ["code": 0, "data": payload]])
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                if try qqRPC(request)["method"] as? String == "get_song_detail_yqq" {
                    return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["track_info": ["mid": "mid1", "file": ["media_mid": "media1"]]]]])
                }
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
            let track = Track(id: "qq:mid1", title: "Fixture", artist: "", album: "", duration: 1, source: .qq, sourceID: "mid1")
            do { _ = try await provider.resolve(track, cookies: qqCookies); Issue.record("Rejected address was replaced with a default CDN") }
            catch { #expect(error.localizedDescription == L10n.string("QQ 音乐返回了不受信任的音频地址（主机：\(expectedHost)），暂未播放。")); #expect(error.localizedDescription.contains(expectedHost)) }
        }
    }
    @Test func malformedAudioAddressIsDistinctAndDoesNotEchoUnboundedHost() async throws {
        let cases: [(String, String, String)] = [
            ("not-an-absolute-server", "M500private-path.mp3?vkey=private-vkey", L10n.string("QQ 音乐返回的音频地址不可用（\(L10n.string("候选地址缺少协议"))），请稍后重试。")),
            ("https://" + String(repeating: "x", count: 254) + "/", "M500private-path.mp3?vkey=private-vkey", L10n.string("QQ 音乐返回的音频地址不可用（\(L10n.string("主机名格式不受支持"))），请稍后重试。")),
            ("ftp://private-host/", "M500private-path.mp3?vkey=private-vkey", L10n.string("QQ 音乐返回的音频地址不可用（\(L10n.string("地址协议不受支持"))），请稍后重试。")),
            ("https:///", "M500private-path.mp3?vkey=private-vkey", L10n.string("QQ 音乐返回的音频地址不可用（\(L10n.string("候选地址缺少主机"))），请稍后重试。")),
            ("https://[2001:db8::1]/", "M500private-path.mp3?vkey=private-vkey", L10n.string("QQ 音乐返回的音频地址不可用（\(L10n.string("IP 地址格式不受支持"))），请稍后重试。")),
            ("https://[invalid-private-host/", "M500private-path.mp3?vkey=private-vkey", L10n.string("QQ 音乐返回的音频地址不可用（\(L10n.string("候选地址无法解析"))），请稍后重试。")),
            ("https://ws6.stream.qqmusic.qq.com/", "https://[invalid-private-host/M500private-path.mp3?vkey=private-vkey", L10n.string("QQ 音乐返回的音频地址无法解析，请稍后重试。"))
        ]
        for (server, purl, reason) in cases {
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                if try qqRPC(request)["method"] as? String == "get_song_detail_yqq" {
                    return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["track_info": ["mid": "mid1", "file": ["media_mid": "media1"]]]]])
                }
                return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["thirdip": [server], "midurlinfo": [["songmid": "mid1", "purl": purl]]]]])
            }))
            let track = Track(id: "qq:mid1", title: "Fixture", artist: "", album: "", duration: 1, source: .qq, sourceID: "mid1")
            do { _ = try await provider.resolve(track, cookies: qqCookies); Issue.record("Malformed address accepted") }
            catch {
                #expect(error.localizedDescription == reason)
                #expect(error.localizedDescription.utf8.count < 200)
                #expect(!error.localizedDescription.contains("private"))
                #expect(!error.localizedDescription.contains("2001:db8"))
                #expect(!error.localizedDescription.contains("https://"))
            }
        }
    }
    @Test func malformedAndRawServerTextAreRedacted() async {
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            (Data("<html>test-session-key upstream debug</html>".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }))
        do { _ = try await provider.profile(cookies: qqCookies); Issue.record("Accepted HTML") }
        catch { #expect(!error.localizedDescription.contains("test-session-key")); #expect(error.localizedDescription == L10n.string("QQ 音乐响应格式已变化，请稍后重试或更新应用。")) }
    }
    @Test func cancellationDiscardsTransportLateResult() async {
        let called = Mutex(false)
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            called.withLock { $0 = true }
            await withCheckedContinuation { continuation in DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { continuation.resume() } }
            return try qqReply(request, ["code": 0, "data": ["creator": ["uin": "12345678", "nick": "Alpaca"]]])
        }))
        let task = Task { try await provider.profile(cookies: qqCookies) }
        while !called.withLock({ $0 }) { await Task.yield() }; task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled profile succeeded") } catch { #expect(error is CancellationError) }
    }
}

private func expectedQQTimeout() -> String {
    let reason = L10n.string("请求超时，请重试")
    return L10n.string("\(MusicSource.qq.title)：\(reason)（网络错误 \(String(-1001))）")
}
private func expectedQQRPCFailure(operation: String, code: Int) -> String {
    L10n.string("QQ 音乐\(operation)失败（平台返回码 \(String(code))），请稍后重试。")
}
private func expectedQQPlaylistIssue(page: Int = 1, position: Int, failure: String) -> String {
    L10n.string("第 \(page) 页，第 \(position) 首\(failure)")
}
private func expectedQQPartialSummary(total: Int, parsed: Int, failed: Int, firstPosition: Int,
                                      firstFailure: String, omitted: Int = 0) -> String {
    let first = L10n.string("第 \(firstPosition) 首\(firstFailure)")
    let remainder = omitted > 0 ? L10n.string("；另有 \(omitted) 条失败原因未展开") : ""
    return L10n.string("已读完整份 \(total) 首歌单，成功解析 \(parsed)/\(total) 首，\(failed) 首未能读取。\(first)\(remainder)")
}
private func expectedQQUnimportedPlaylist(issue: String) -> String {
    let failure = L10n.string("：\(issue)")
    let row = expectedQQPlaylistIssue(position: 1, failure: failure)
    return L10n.string("QQ 音乐歌单曲目格式不完整（成功解析 \(0)/\(1) 首；\(row)\("")），本次未导入。")
}

private func expectedQQIdentityIssue(midType: String = L10n.string("缺失"), songMIDType: String = L10n.string("缺失"),
                                      idType: String = L10n.string("缺失"), songIDType: String = L10n.string("缺失"),
                                      idValid: Bool = false, songIDValid: Bool = false, conflict: Bool = false) -> String {
    let mid = L10n.string("mid=\(midType)、songmid=\(songMIDType)")
    let idValidity = idValid ? L10n.string("有效正整数") : L10n.string("非有效正整数")
    let songIDValidity = songIDValid ? L10n.string("有效正整数") : L10n.string("非有效正整数")
    let id = L10n.string("\(idType)（\(idValidity)）")
    let songID = L10n.string("\(songIDType)（\(songIDValidity)）")
    let numeric = L10n.string("id=\(id)、songid=\(songID)")
    let mismatch = conflict ? L10n.string("；两个数字编号冲突") : ""
    return L10n.string("歌曲标识格式不支持（\(mid)；\(numeric)\(mismatch)）")
}
