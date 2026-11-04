import Foundation
import Testing
@testable import AlpacaMusic

@Suite struct SodaDirectTests {
    private let songID = "7079108541549643812"
    private let playlistID = "7096700219496368135"
    private var session: [MusicSessionCookie] { [.init(name: "sessionid", value: "private-session", domain: ".qishui.com")] }

    private func client(_ fixture: SodaFixture) -> SodaShareClient {
        let transport: NativeMusicHTTP.Transport = { request in try await fixture.respond(request) }
        return SodaShareClient(http: NativeMusicHTTP(transport: transport), transport: transport)
    }
    private func provider(_ fixture: SodaFixture) -> SodaDirectProvider {
        SodaDirectProvider(http: NativeMusicHTTP(transport: { request in try await fixture.respond(request) }), share: client(fixture))
    }
    private func rawTrack(_ id: String = "7079108541549643812") -> [String: Any] {
        ["id": id, "name": "测试歌曲", "duration": 297240, "artists": [["id": "6776144869279664130", "name": "测试歌手"]], "album": ["name": "测试专辑", "url_cover": ["uri": "fixture/cover", "urls": ["https://p3-luna.douyinpic.com/img/"], "template_prefix": "tplv-b829550vbb"]]]
    }
    private func html(start: Double = 143.808, duration: Double = 30.047, encrypted: Bool = false, id: String = "7079108541549643812", url: String = "https://v3-luna.douyinvod.com/fixture.m4a?signature=private-stream") throws -> Data {
        let sentences: [[String: Any]] = [["startMs": 143000, "endMs": 146000, "text": "轻风拂过", "words": [["text": "轻", "startMs": 143000, "endMs": 143500], ["text": "风", "startMs": 143600, "endMs": 144200], ["text": "拂过", "startMs": 144500, "endMs": 146000]]]]
        let option: [String: Any] = ["track_id": id, "trackInfo": rawTrack(id), "status_code": 0, "duration": 297.24, "offsetStart": start, "offsetDuration": duration, "encrypt": encrypted, "kid": "", "url": url, "lyrics": ["sentences": sentences]]
        let data = try JSONSerialization.data(withJSONObject: ["loaderData": ["track_page": ["audioWithLyricsOption": option]]])
        return Data("<script>window._ROUTER_DATA = \(String(decoding: data, as: UTF8.self));</script>".utf8)
    }
    private func playlistPage(ids: [String], total: Int, cursor: String) throws -> Data {
        let items = ids.map { ["type": "track", "entity": ["track_wrapper": ["track": rawTrack($0)]]] as [String: Any] }
        return try JSONSerialization.data(withJSONObject: ["status_info": [:], "playlist": ["id": playlistID, "title": "公开测试歌单", "count_tracks": total], "media_resources": items, "next_cursor": cursor])
    }

    @Test func officialShareShapeImportsMetadataWithoutPersistingTemporaryURLs() async throws {
        let fixture = SodaFixture([.init(path: "/qishui/share/track", data: try html())])
        let imported = try await client(fixture).importShare("分享测试歌曲 https://music.douyin.com/qishui/share/track?track_id=\(songID)&share_token=private")
        let track = try #require(imported.tracks.first)
        #expect(track.id == "soda:\(songID)" && track.duration == 30.047 && track.sourceID == songID)
        #expect(track.url == nil && track.sodaPlayback?.fullDuration == 297.24 && track.sodaPlayback?.isPreview == true && track.sodaPlayback?.start == 143.808)
        #expect(track.artworkURL?.absoluteString == "https://p3-luna.douyinpic.com/img/fixture/cover~tplv-b829550vbb-resize:960:960.png")
        #expect(await fixture.requests.first?.url?.query == "track_id=\(songID)")
        #expect(await fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
    }

    @Test func preparedPreviewUsesClipDurationAndFreshURLAfterRangeVerification() async throws {
        let fixture = SodaFixture([.init(path: "/qishui/share/track", data: try html()), .init(path: "/qishui/share/track", data: try html(url: "https://v5-luna.douyinvod.com/new.m4a?signature=new-private"))])
        let value = provider(fixture), track = try SodaJSON.track(rawTrack())
        let prepared = try await value.preparePlayback(track, cookies: session)
        #expect(prepared.duration == 30.047 && prepared.sodaPlayback == SodaPlaybackRange(fullDuration: 297.24, start: 143.808, duration: 30.047, isPreview: true))
        let url = try await value.resolve(prepared, cookies: session)
        #expect(url.host == "v5-luna.douyinvod.com" && url != prepared.url)
        #expect(await fixture.requests.count == 2)
        #expect(await fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
    }

    @Test func changedRangeAndWrongSongIdentityCannotPlayAnOldPreparedVariant() async throws {
        let track = Track(id: "soda:\(songID)", title: "测试", artist: "测试", album: "", duration: 30.047, source: .soda, sourceID: songID, sodaPlayback: .init(fullDuration: 297.24, start: 143.808, duration: 30.047, isPreview: true))
        for data in [try html(start: 140), try html(id: "7304719759323564095")] {
            let fixture = SodaFixture([.init(path: "/qishui/share/track", data: data)])
            do { _ = try await provider(fixture).resolve(track, cookies: []); Issue.record("Mismatched stream was accepted") }
            catch { #expect(!error.localizedDescription.contains("private") && !error.localizedDescription.contains("https://")) }
        }
    }

    @Test func encryptedAudioNeverBecomesAPlayableURL() async throws {
        let fixture = SodaFixture([.init(path: "/qishui/share/track", data: try html(encrypted: true))])
        await #expect(throws: MusicError.self) { try await provider(fixture).preparePlayback(try SodaJSON.track(rawTrack()), cookies: []) }
        #expect(await fixture.requests.count == 1)
    }

    @Test func shareInputDoesNotAcceptUnrelatedHostsOrAmbiguousIDs() throws {
        for input in ["https://qishui.com.evil.invalid/track/\(songID)", "http://music.douyin.com/qishui/share/track?track_id=\(songID)", "https://evil.invalid/?track_id=\(songID)", "https://user:password@music.douyin.com/qishui/share/track?track_id=\(songID)", "https://music.douyin.com:444/qishui/share/track?track_id=\(songID)", "https://music.douyin.com/qishui/share/track?track_id=\(songID)&playlist_id=\(playlistID)"] {
            #expect(throws: MusicError.self) { try SodaShareClient.reference(input) }
        }
        #expect(try SodaShareClient.reference("https://www.qishui.com/playlist/\(playlistID)") == .playlist(playlistID))
        #expect(try SodaShareClient.reference("https://qishui.douyin.com/s/abc/") == .url(URL(string: "https://qishui.douyin.com/s/abc/")!))
        #expect(SodaJSON.mediaURL("https://evil.invalid/private.m4a") == nil)
        #expect(SodaJSON.mediaURL("https://v3-luna.douyinvod.com/file#auth=private") == nil)
    }

    @Test func publicShortLinkRedirectsStayOfficialAndSendNoAccountCookies() async throws {
        let final = "https://music.douyin.com/qishui/share/track?track_id=\(songID)"
        let fixture = SodaFixture([.init(path: "/s/abc", data: Data(), status: 302, headers: ["Location": final]), .init(path: "/qishui/share/track", data: try html()), .init(path: "/qishui/share/track", data: try html())])
        let result = try await client(fixture).importShare("https://qishui.douyin.com/s/abc/")
        #expect(result.tracks.first?.sourceID == songID)
        #expect(await fixture.requests.allSatisfy { $0.httpShouldHandleCookies == false && $0.value(forHTTPHeaderField: "Cookie") == nil && $0.value(forHTTPHeaderField: "Authorization") == nil })
        let rejected = SodaFixture([.init(path: "/s/abc", data: Data(), status: 302, headers: ["Location": "https://evil.invalid/private-token"])])
        await #expect(throws: MusicError.self) { try await client(rejected).importShare("https://qishui.douyin.com/s/abc/") }
        #expect(await rejected.requests.count == 1)
    }

    @Test func publicPlaylistRequiresTheFullDeclaredCountAndPreservesOrder() async throws {
        let other = "7304719759323564095"
        let fixture = SodaFixture([.init(path: "/luna/pc/playlist/detail", data: try playlistPage(ids: [songID], total: 2, cursor: "1")), .init(path: "/luna/pc/playlist/detail", data: try playlistPage(ids: [other], total: 2, cursor: "2"))])
        let result = try await client(fixture).importShare("https://www.qishui.com/playlist/\(playlistID)")
        #expect(result.tracks.map(\.sourceID) == [songID, other])
        #expect(result.playlistName == "公开测试歌单" && result.playlistID == playlistID)
        #expect(await fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
        let incomplete = SodaFixture([.init(path: "/luna/pc/playlist/detail", data: try playlistPage(ids: [songID], total: 2, cursor: "1")), .init(path: "/luna/pc/playlist/detail", data: try playlistPage(ids: [songID], total: 2, cursor: "1"))])
        await #expect(throws: MusicError.self) { try await client(incomplete).importShare("https://www.qishui.com/playlist/\(playlistID)") }
        let validEmpty = SodaFixture([.init(path: "/luna/pc/playlist/detail", data: try playlistPage(ids: [], total: 0, cursor: "0"))])
        #expect(try await client(validEmpty).playlist(playlistID).tracks.isEmpty)
    }

    @Test func realPublicSearchGroupShapeProducesTracksWithoutFalseRecommendations() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["status_info": [:], "result_groups": [["id": "tracks", "data": [["meta": ["item_type": "track"], "entity": ["track": rawTrack()]]]], ["id": "artists", "data": [["entity": ["track": rawTrack("7304719759323564095")]]]]]])
        let fixture = SodaFixture([.init(path: "/luna/search/track", data: body)])
        let tracks = try await provider(fixture).search("测试 + &", cookies: [])
        #expect(tracks.count == 1 && tracks.first?.sourceID == songID)
        let request = try #require(await fixture.requests.first)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.first { $0.name == "q" }?.value == "测试 + &")
        #expect(request.value(forHTTPHeaderField: "X-Helios") == nil && request.value(forHTTPHeaderField: "X-Medusa") == nil)
    }

    @Test func profileMustComeFromVerifiedPlatformIdentityAndEmptyPCIsDiagnosed() async throws {
        let noRequest = SodaFixture([])
        await #expect(throws: MusicError.self) { try await provider(noRequest).profile(cookies: [.init(name: "uid_tt", value: "claimed-id", domain: ".qishui.com")]) }
        #expect(await noRequest.requests.isEmpty)
        let missingIdentity = SodaFixture([.init(path: "/luna/pc/me", data: Data(#"{"status_info":{},"uid":"7079108541549643812"}"#.utf8))])
        await #expect(throws: MusicError.self) { try await provider(missingIdentity).profile(cookies: session) }
        let verified = SodaFixture([.init(path: "/luna/pc/me", data: Data(#"{"status_info":{},"my_info":{"id":"7079108541549643812","nickname":"真实测试账号"}}"#.utf8))])
        #expect(try await provider(verified).profile(cookies: session) == MusicAccountProfile(id: songID, displayName: "真实测试账号"))
        let empty = SodaFixture([.init(path: "/luna/pc/me", data: Data())])
        do { _ = try await provider(empty).profile(cookies: session); Issue.record("Empty PC response accepted") }
        catch {
            #expect(error.localizedDescription == L10n.string("汽水音乐网页接口返回空响应（阶段：\(L10n.string("确认登录身份"))；HTTP 200）；当前接口可能要求平台应用签名或访问验证，无法完成此操作"))
            #expect(!error.localizedDescription.contains("private-session"))
        }
    }

    @Test func wordTimingIsShiftedClippedAndExplicitGapsAreRetained() throws {
        let sentences: [SodaLyricSentence] = [
            .init(text: "轻风拂过", start: 8, end: 12, words: [.init(text: "轻", start: 8, end: 9), .init(text: "风", start: 9.5, end: 10.5), .init(text: "拂过", start: 11, end: 12)]),
            .init(text: "树影摇动", start: 14, end: 18, words: [.init(text: "树影", start: 14, end: 16), .init(text: "摇动", start: 16.5, end: 18)])]
        let document = SodaDirectProvider.lyricDocument(sentences, range: .init(fullDuration: 20, start: 10, duration: 7, isPreview: true), title: "原创", artist: "测试")
        #expect(document.timing == .word && document.lines.count == 2)
        #expect(document.lines[0].text == "风拂过" && document.lines[0].start == 0 && document.lines[0].end == 2)
        #expect(document.lines[0].words.first?.start == 0 && document.lines[0].words.first?.end == 0.5)
        #expect(document.activeIndex(at: 3) == nil)
        #expect(document.lines[1].end == 7 && document.lines[1].words.last?.end == 7)
        let payload = LyricsPayload(text: "", document: document)
        #expect(try LyricsParser.parse(payload, sourceDescription: L10n.string("汽水音乐")) == document)
    }

    @Test func balancedRouterParserHandlesQuotedBracesAndRejectsTruncation() throws {
        let object = try SodaShareClient.routerData(Data(#"<script>window._ROUTER_DATA={"loaderData":{"x":{"text":"{a} \"quoted\""}},"errors":null};</script>"#.utf8))
        #expect(object["loaderData"] != nil)
        #expect(throws: MusicError.self) { try SodaShareClient.routerData(Data("_ROUTER_DATA={\"broken\":".utf8)) }
    }


    @Test func privatePlaylistUsesOnlyItsOwnScopedAccountSession() async throws {
        let fixture = SodaFixture([.init(path: "/luna/pc/playlist/detail", data: try playlistPage(ids: [songID], total: 1, cursor: "1"))])
        let tracks = try await provider(fixture).tracks(in: .init(id: playlistID, name: "账号歌单", trackCount: 1, source: .soda), cookies: session + [.init(name: "sessionid", value: "other-platform", domain: ".douyin.com")])
        #expect(tracks.count == 1)
        #expect(await fixture.requests.first?.value(forHTTPHeaderField: "Cookie") == "sessionid=private-session")
    }

    @Test func missingPrivateListsAndUnexpectedSearchGroupsCannotBecomeFalseEmptyResults() async throws {
        let me = Data(#"{"status_info":{},"my_info":{"id":"7079108541549643812","nickname":"测试"}}"#.utf8)
        let privateMissing = SodaFixture([.init(path: "/luna/pc/me", data: me), .init(path: "/luna/pc/me/playlist", data: Data(#"{"status_info":{}}"#.utf8))])
        await #expect(throws: MusicError.self) { try await provider(privateMissing).playlists(profile: .init(id: songID, displayName: "测试"), cookies: session) }
        let badSearch = SodaFixture([.init(path: "/luna/search/track", data: Data(#"{"status_info":{},"result_groups":[{"id":"artists","data":[]}]}"#.utf8))])
        await #expect(throws: MusicError.self) { try await provider(badSearch).search("测试", cookies: []) }
        let emptySearch = SodaFixture([.init(path: "/luna/search/track", data: Data(#"{"status_info":{},"result_groups":[]}"#.utf8))])
        #expect(try await provider(emptySearch).search("无结果", cookies: []).isEmpty)
    }

    @Test func livePublicWebsiteIntegrationWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["ALPACA_LIVE_SODA"] == "1" else { return }
        let client = SodaShareClient(), value = SodaDirectProvider()
        let imported = try await client.importShare("https://music.douyin.com/qishui/share/track?track_id=" + songID)
        let track = try #require(imported.tracks.first)
        #expect(track.url == nil && track.sodaPlayback?.isPreview == true)
        let prepared = try await value.preparePlayback(track, cookies: [])
        #expect(prepared.sodaPlayback?.isPreview == true && prepared.duration > 0 && prepared.duration < 90)
        let url = try await value.resolve(prepared, cookies: [])
        #expect(url.host?.hasSuffix(".douyinvod.com") == true)
        let payload = try #require(try await value.lyrics(prepared, cookies: []))
        let document = try LyricsParser.parse(payload, sourceDescription: "汽水音乐")
        #expect(document.timing == .word && !document.lines.isEmpty)
        #expect(document.lines.allSatisfy { ($0.start ?? -1) >= 0 && ($0.end ?? 100000) <= prepared.duration })
        let search = try await value.search("陈粒", cookies: [])
        #expect(!search.isEmpty && search.allSatisfy { $0.source == .soda && $0.url == nil })
        let playlist = try await client.importShare("https://www.qishui.com/playlist/" + playlistID)
        #expect(playlist.playlistID == playlistID && !playlist.tracks.isEmpty)
    }

    @Test func cancellationAndBoundedResponsesNeverBecomeGenericPlaybackErrors() async throws {
        let transport: NativeMusicHTTP.Transport = { _ in throw CancellationError() }
        let cancelled = SodaShareClient(transport: transport)
        await #expect(throws: CancellationError.self) { try await cancelled.importShare(songID) }
        let oversized = SodaFixture([.init(path: "/qishui/share/track", data: Data(repeating: 32, count: 8 * 1024 * 1024 + 1))])
        await #expect(throws: MusicError.self) { try await client(oversized).importShare(songID) }
    }
}

private struct SodaFixtureResponse: Sendable {
    var path: String
    var data: Data
    var status: Int = 200
    var headers: [String: String] = [:]
}
private actor SodaFixture {
    let values: [SodaFixtureResponse]
    var requests: [URLRequest] = []
    init(_ values: [SodaFixtureResponse]) { self.values = values }
    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let index = requests.count; requests.append(request)
        guard values.indices.contains(index) else { throw MusicError.message("Fixture exhausted") }
        let value = values[index]
        #expect(request.url?.path == value.path)
        return (value.data, HTTPURLResponse(url: request.url!, statusCode: value.status, httpVersion: nil, headerFields: value.headers)!)
    }
}
