import Foundation
import Testing
@testable import AlpacaMusic

@Suite struct NeteaseBrowseTests {
    private var cookies: [MusicSessionCookie] {
        [.init(name: "MUSIC_U", value: "fixture-session", domain: ".music.163.com")]
    }
    private func provider(_ fixture: NEBrowseFixture) -> NeteaseDirectProvider {
        NeteaseDirectProvider(http: NativeMusicHTTP(transport: { request in try await fixture.respond(request) }))
    }
    private let chartsPath = "/weapi/toplist/detail/v2"
    private let playlistsPath = "/weapi/personalized/playlist"
    private let songsPath = "/weapi/v3/discovery/recommend/songs"
    private let detailPath = "/weapi/v6/playlist/detail"
    private let songDetailPath = "/weapi/v3/song/detail"

    // MARK: Charts

    @Test func chartsKeepPlaylistChartsInPlatformOrderWithoutWebPagesOrRepeats() async throws {
        let body = #"""
        {"code":200,"msg":"","message":"","data":[
          {"name":"榜单推荐","categoryCode":"TOPPING","list":[
            {"id":991319590,"targetType":"PLAYLIST","name":"中文说唱榜","updateFrequency":"每周五更新","coverUrl":"https://p1.music.126.net/a==/1.jpg",
             "tracks":[{"first":"一","second":"甲"},{"first":"二","second":"乙"},{"first":"三","second":"丙"},{"first":"四","second":"丁"}]},
            {"id":"13372522766","targetType":"PLAYLIST","name":"潮流风向榜","updateFrequency":" 更新83首 ","coverUrl":""}
          ]},
          {"name":"官方榜","categoryCode":"OFFICIAL","displayType":"TOP_3","list":[
            {"id":19723756,"targetType":"PLAYLIST","name":"飙升榜","updateFrequency":"刚刚更新","coverUrl":"https://p1.music.126.net/b==/2.jpg"},
            {"id":991319590,"targetType":"PLAYLIST","name":"中文说唱榜（重复）"},
            {"id":0,"targetType":"H5","name":"畅销榜","tracks":[{"first":"专辑","second":"歌手"}]},
            {"id":0,"targetType":"PLAYLIST","name":"无效榜"},
            {"id":{"odd":true},"targetType":"PLAYLIST","name":"异常标识"},
            {"id":5059633707,"targetType":"H5","name":"网页榜"},
            {"id":5059633708,"name":"缺少类型"},
            "not-an-object",
            {"id":18512097939,"targetType":"PLAYLIST","name":null,"updateFrequency":7,"coverUrl":{"odd":true},"tracks":"odd"}
          ]},
          {"name":"异常分组","list":"odd"},
          {"name":"空分组"}
        ]}
        """#
        let fixture = NEBrowseFixture([.init(path: chartsPath, json: body)])
        let charts = try await provider(fixture).charts(cookies: cookies)
        #expect(charts.map(\.remoteID) == ["991319590", "13372522766", "19723756", "18512097939"])
        #expect(charts.map(\.id) == ["netease:chart:991319590", "netease:chart:13372522766", "netease:chart:19723756", "netease:chart:18512097939"])
        #expect(charts.map(\.title) == ["中文说唱榜", "潮流风向榜", "飙升榜", L10n.string("未命名歌单")])
        #expect(charts.map(\.caption) == ["每周五更新", "更新83首", "刚刚更新", ""])
        #expect(charts.map(\.artworkURL?.absoluteString) == ["https://p1.music.126.net/a==/1.jpg?param=300y300", nil, "https://p1.music.126.net/b==/2.jpg?param=300y300", nil])
        #expect(charts[0].preview == [.init(title: "一", artist: "甲"), .init(title: "二", artist: "乙"), .init(title: "三", artist: "丙")])
        #expect(charts[3].preview.isEmpty)
        #expect(charts.allSatisfy { $0.source == .netease && $0.kind == .chart && $0.trackCount == nil && $0.tracks == nil })
        #expect(await fixture.paths == [chartsPath])
        let request = try #require(await fixture.requests.first)
        #expect(request.url?.host == "music.163.com" && request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "MUSIC_U=fixture-session")
        #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self).hasPrefix("params="))
    }

    @Test func chartsStopAtThirty() async throws {
        let items = (1...40).map { #"{"id":\#(1000 + $0),"targetType":"PLAYLIST","name":"榜\#($0)"}"# }.joined(separator: ",")
        let fixture = NEBrowseFixture([.init(path: chartsPath, json: #"{"code":200,"data":[{"list":[\#(items)]}]}"#)])
        let charts = try await provider(fixture).charts(cookies: cookies)
        #expect(charts.map(\.remoteID) == (1001...1030).map(String.init))
        #expect(await fixture.count == 1)
    }

    @Test func chartPreviewFallsBackToRankListOnlyWhenTracksHaveNoTitles() async throws {
        let body = #"""
        {"code":200,"data":[{"list":[
          {"id":1,"targetType":"PLAYLIST","name":"排名榜","tracks":[],
           "trackRankList":[{"trackId":11,"rank":1,"lastRank":0,"songName":"甲歌","artistName":"甲","coverImgUrl":"http://p2.music.126.net/c.jpg"},
                            {"songName":" ","artistName":"空"},{"songName":"乙歌","artistName":null},{"songName":"丙歌","artistName":"丙"},{"songName":"丁歌","artistName":"丁"}]},
          {"id":2,"targetType":"PLAYLIST","name":"无预览"},
          {"id":3,"targetType":"PLAYLIST","name":"空标题","tracks":[{"first":"","second":"无"}],"trackRankList":[{"songName":"榜歌","artistName":"榜"}]},
          {"id":4,"targetType":"PLAYLIST","name":"两者都有","tracks":[{"first":"首选","second":"甲"}],"trackRankList":[{"songName":"不用","artistName":"乙"}]}
        ]}]}
        """#
        let fixture = NEBrowseFixture([.init(path: chartsPath, json: body)])
        let charts = try await provider(fixture).charts(cookies: cookies)
        #expect(charts.map(\.preview) == [
            [.init(title: "甲歌", artist: "甲"), .init(title: "乙歌", artist: ""), .init(title: "丙歌", artist: "丙")],
            [],
            [.init(title: "榜歌", artist: "榜")],
            [.init(title: "首选", artist: "甲")]
        ])
    }

    @Test(arguments: [
        ("http://p2.music.126.net/x==/1.jpg", "https://p2.music.126.net/x==/1.jpg?param=300y300"),
        ("https://p1.music.126.net/x==/1.jpg", "https://p1.music.126.net/x==/1.jpg?param=300y300"),
        ("http://p1.music.126.net:80/x.jpg", "https://p1.music.126.net/x.jpg?param=300y300"),
        ("https://p5.music.126.net/obj/w/1/a.png", "https://p5.music.126.net/obj/w/1/a.png?param=300y300"),
        ("https://p1.music.126.net/x.jpg?param=140y140", "https://p1.music.126.net/x.jpg?param=140y140"),
        ("http://p1.music.126.net/x.jpg?token=a%2Bb", "https://p1.music.126.net/x.jpg?token=a%2Bb"),
        ("http://p1.music.126.net:8080/x.jpg", "http://p1.music.126.net:8080/x.jpg"),
        ("http://music.126.net.example.com/x.jpg", "http://music.126.net.example.com/x.jpg"),
        ("http://example.com/cover.jpg", "http://example.com/cover.jpg")
    ])
    func chartArtworkUsesHTTPSThumbnailsOnlyOnNeteaseImageHosts(_ cover: String, _ expected: String) async throws {
        let fixture = NEBrowseFixture([.init(path: chartsPath, json: #"{"code":200,"data":[{"list":[{"id":1,"targetType":"PLAYLIST","name":"榜","coverUrl":"\#(cover)"}]}]}"#)])
        #expect(try await provider(fixture).charts(cookies: cookies).first?.artworkURL?.absoluteString == expected)
    }

    @Test(arguments: ["http://user:secret@p1.music.126.net/x.jpg", "ftp://p1.music.126.net/x.jpg", "file:///tmp/x.jpg", "", "not a url"])
    func unusableChartArtworkIsDropped(_ cover: String) async throws {
        let fixture = NEBrowseFixture([.init(path: chartsPath, json: #"{"code":200,"data":[{"list":[{"id":1,"targetType":"PLAYLIST","name":"榜","coverUrl":"\#(cover)"}]}]}"#)])
        let chart = try #require(try await provider(fixture).charts(cookies: cookies).first)
        #expect(chart.artworkURL == nil)
    }

    @Test(arguments: [
        #"{"code":200,"data":null}"#,
        #"{"code":200}"#,
        #"{"code":200,"data":{"list":[]}}"#,
        #"{"code":200,"data":[]}"#,
        #"{"code":200,"data":[{"list":[{"id":0,"targetType":"H5","name":"网页榜"}]}]}"#
    ])
    func chartsFailOnlyWhenNoReadableChartRemains(_ body: String) async {
        let fixture = NEBrowseFixture([.init(path: chartsPath, json: body)])
        let message = await failure { try await provider(fixture).charts(cookies: cookies) }
        #expect(message == L10n.string("网易云响应格式已变化（阶段：\(L10n.string("读取榜单"))；接口码：200），请稍后重试"))
        #expect(await fixture.count == 1)
    }

    @Test func chartLoginAndThrottleCodesKeepTheirMeaning() async {
        for (code, expected) in [(301, L10n.string("网易云尚未登录或登录已失效，请在应用内重新登录")), (429, "")] {
            let fixture = NEBrowseFixture([.init(path: chartsPath, json: #"{"code":\#(code),"msg":"secret"}"#)])
            let message = await failure { try await provider(fixture).charts(cookies: cookies) }
            let diagnostic = L10n.string("阶段：\(L10n.string("读取榜单"))；接口码：\(String(code))")
            #expect(message == (code == 429 ? L10n.string("网易云请求过于频繁，请稍后重试（\(diagnostic)）") : L10n.string("\(expected)（\(diagnostic)）")))
            #expect(!message.contains("secret"))
        }
    }

    // MARK: Recommendations

    private let personalizedBody = #"""
    {"hasTaste":false,"code":200,"category":0,"result":[
      {"id":638864394,"type":0,"name":"国产HipHop","copywriter":"","picUrl":"http://p1.music.126.net/t==/1.jpg","canDislike":true,"playCount":4.085566E7,"trackCount":958,"highQuality":false,"alg":"alg_high_quality"},
      {"id":"5269469196","type":0,"name":"三件事","copywriter":" 根据你的口味推荐 ","picUrl":"https://example.com/c.jpg","trackCount":-1},
      {"id":638864394,"name":"重复歌单"},
      {"id":0,"name":"无效歌单"},
      {"name":"缺少标识"},
      {"id":8055396278,"name":"","copywriter":5,"picUrl":null,"trackCount":"many"}
    ]}
    """#
    private let dailyBody = #"""
    {"code":200,"data":{"fromCache":false,"dailySongs":[
      {"id":3334675802,"name":"我恨明月不照我","ar":[{"id":1,"name":"阿YueYue"},{"name":"合唱"}],"al":{"id":2,"name":"同名专辑","picUrl":"http://p2.music.126.net/a==/1.jpg"},"dt":252162,"st":0,"fee":1,"privilege":null,"reason":null,"alg":"re_hot_toplist_fill"},
      {"id":2,"name":"已下架","ar":[{"name":"甲"}],"al":{"name":"甲专辑"},"dt":1000,"st":-200},
      {"id":3,"name":"权限受限","ar":[{"name":"乙"}],"al":{"name":"乙专辑"},"dt":1000},
      {"id":4,"name":"灰色歌曲","ar":[{"name":"丙"}],"al":{"name":"丙专辑"},"dt":1000,"st":0},
      {"id":5,"name":"可播放等级","ar":[{"name":"丁"}],"al":{"name":"丁专辑"},"dt":1000,"st":0},
      {"id":3334675802,"name":"重复歌曲"},
      {"name":"缺少标识"}
    ],"orderSongs":[],"recommendReasons":[{"songId":2,"reason":"fixture","reasonId":"1"}],"mvResourceInfos":null,"demote":false,"dailyRecommendInfo":null,
    "privileges":[{"id":3,"st":-100,"pl":0},{"id":4,"st":-100,"pl":0},{"id":5,"st":-100,"pl":128000},"odd"]}}
    """#

    @Test func recommendationsMapPlaylistsAndDailySongsFromTwoRequests() async throws {
        let fixture = NEBrowseFixture([.init(path: playlistsPath, json: personalizedBody), .init(path: songsPath, json: dailyBody)])
        let result = try await provider(fixture).recommendations(cookies: cookies)
        let lists = result.collections
        #expect(lists.map(\.remoteID) == ["638864394", "5269469196", "8055396278"])
        #expect(lists.map(\.id) == ["netease:playlist:638864394", "netease:playlist:5269469196", "netease:playlist:8055396278"])
        #expect(lists.map(\.title) == ["国产HipHop", "三件事", L10n.string("未命名歌单")])
        #expect(lists.map(\.caption) == ["", "根据你的口味推荐", ""])
        #expect(lists.map(\.trackCount) == [958, nil, nil])
        #expect(lists.map(\.artworkURL?.absoluteString) == ["https://p1.music.126.net/t==/1.jpg?param=300y300", "https://example.com/c.jpg", nil])
        #expect(lists.allSatisfy { $0.source == .netease && $0.kind == .playlist && $0.preview.isEmpty && $0.tracks == nil })

        let songs = result.songs
        #expect(songs.map(\.id) == ["netease:3334675802", "netease:2", "netease:3", "netease:4", "netease:5"])
        #expect(songs.map(\.sourceID) == ["3334675802", "2", "3", "4", "5"])
        // Real rows always say `st: 0`, so a grey privilege without a play level
        // decides; a play level keeps a grey-marked song playable.
        #expect(songs.map(\.unavailable) == [false, true, true, true, false])
        let first = try #require(songs.first)
        #expect(first.title == "我恨明月不照我" && first.artist == "阿YueYue / 合唱" && first.album == "同名专辑")
        #expect(first.duration == 252.162 && first.source == .netease)
        #expect(first.artworkURL?.absoluteString == "http://p2.music.126.net/a==/1.jpg")
        #expect(result.refreshesAt == nil)
        #expect(result.partialError == nil)

        #expect(Set(await fixture.paths) == [playlistsPath, songsPath])
        #expect(await fixture.count == 2)
        let requests = await fixture.requests
        #expect(requests.allSatisfy { $0.url?.host == "music.163.com" && $0.httpMethod == "POST" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "MUSIC_U=fixture-session" })
    }

    @Test func recommendationRequestPayloadsMatchTheWebsite() throws {
        let playlists = try payload(NeteaseDirectProvider.recommendedPlaylistsPayload())
        #expect(Set(playlists.keys) == ["limit", "total", "n", "csrf_token"])
        #expect(playlists["limit"] as? Int == 12 && playlists["total"] as? Bool == true && playlists["n"] as? Int == 1000)
        #expect(playlists["csrf_token"] as? String == "")
    }

    @Test(arguments: [
        #"{"code":503}"#,
        #"{"code":200,"result":null}"#,
        #"{"code":200,"result":{"odd":true}}"#
    ])
    func dailySongsSurviveAFailedPlaylistRequest(_ playlists: String) async throws {
        let fixture = NEBrowseFixture([.init(path: playlistsPath, json: playlists), .init(path: songsPath, json: dailyBody)])
        let result = try await provider(fixture).recommendations(cookies: cookies)
        #expect(result.collections.isEmpty)
        #expect(result.songs.count == 5)
        // The failed half is reported, so the page shows it and asks again later.
        #expect(result.partialError?.isEmpty == false)
        #expect(await fixture.count == 2)
    }

    @Test(arguments: [
        (#"{"code":301}"#, 200),
        (#"{"code":200,"data":null}"#, 200),
        (#"{"code":200,"data":{"orderSongs":[]}}"#, 200),
        (#"{"code":200}"#, 500)
    ])
    func playlistsSurviveAFailedDailySongRequest(_ songs: String, _ status: Int) async throws {
        let fixture = NEBrowseFixture([.init(path: playlistsPath, json: personalizedBody), .init(path: songsPath, json: songs, status: status)])
        let result = try await provider(fixture).recommendations(cookies: cookies)
        #expect(result.collections.count == 3)
        #expect(result.songs.isEmpty)
        #expect(result.partialError?.isEmpty == false)
        #expect(await fixture.count == 2)
    }

    @Test func bothFailedHalvesReportThePlaylistError() async {
        let fixture = NEBrowseFixture([.init(path: playlistsPath, json: #"{"code":503}"#), .init(path: songsPath, json: #"{"code":404}"#)])
        let message = await failure { try await provider(fixture).recommendations(cookies: cookies) }
        let diagnostic = L10n.string("阶段：\(L10n.string("读取推荐歌单"))；接口码：\(String(503))")
        #expect(message == L10n.string("网易云拒绝了请求（\(diagnostic)），平台未提供可确认的具体原因"))
        #expect(await fixture.count == 2)
    }

    @Test(arguments: ["/weapi/personalized/playlist", "/weapi/v3/discovery/recommend/songs"])
    func cancellingEitherHalfIsNeverAPartialResult(_ cancelledPath: String) async {
        let bodies = [playlistsPath: personalizedBody, songsPath: dailyBody]
        let value = NeteaseDirectProvider(http: NativeMusicHTTP(transport: { request in
            guard let url = request.url, let body = bodies[url.path] else { throw MusicError.message("Unexpected fixture request") }
            if url.path == cancelledPath { throw CancellationError() }
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }))
        await #expect(throws: CancellationError.self) { try await value.recommendations(cookies: cookies) }
    }

    // MARK: Songs of one chart or playlist

    @Test func collectionSongsComeFromOneDetailRequestTrimmedToTheLimit() async throws {
        let body = #"""
        {"code":200,"playlist":{"id":19723756,"name":"飙升榜","trackCount":100,
          "trackIds":[{"id":11,"lr":0},{"id":12},{"id":13},{"id":14},{"id":15},{"id":16},{"id":17}],
          "tracks":[
            {"id":11,"name":"行状态可播","ar":[{"name":"甲"}],"al":{"name":"甲专辑","picUrl":"https://p1.music.126.net/s.jpg"},"dt":200000,"st":0},
            {"id":12,"name":"权限下架","ar":[{"name":"乙"}],"al":{"name":"乙专辑"},"dt":1000},
            {"id":13,"name":"内嵌权限","ar":[{"name":"丙"}],"al":{"name":"丙专辑"},"dt":1000,"privilege":{"id":13,"st":0,"pl":320000}},
            {"id":14,"name":"行状态下架","ar":[{"name":"丁"}],"al":{"name":"丁专辑"},"dt":1000,"st":-1},
            {"id":15,"name":"超出上限"},
            {"id":16,"name":"超出上限"}
          ]},
         "privileges":[{"id":11,"st":0,"pl":320000},{"id":12,"st":-200,"pl":0},{"id":13,"st":-100,"pl":0},{"id":14,"st":0,"pl":320000}]}
        """#
        let fixture = NEBrowseFixture([.init(path: detailPath, json: body)])
        let chart = BrowseCollection(source: .netease, kind: .chart, remoteID: "19723756", title: "飙升榜")
        let tracks = try await provider(fixture).tracks(in: chart, limit: 4, cookies: cookies)
        #expect(tracks.map(\.sourceID) == ["11", "12", "13", "14"])
        #expect(tracks.map(\.unavailable) == [false, true, false, true])
        #expect(tracks.first?.title == "行状态可播" && tracks.first?.duration == 200)
        #expect(tracks.allSatisfy { $0.source == .netease && $0.id == "netease:\($0.sourceID ?? "")" })
        #expect(await fixture.paths == [detailPath])
        let request = try #require(await fixture.requests.first)
        #expect(request.url?.host == "music.163.com" && request.httpMethod == "POST")
        #expect(String(decoding: request.httpBody ?? Data(), as: UTF8.self).hasPrefix("params="))

        let detail = try payload(NeteaseDirectProvider.collectionTracksPayload(id: "19723756", limit: 4))
        #expect(Set(detail.keys) == ["id", "n", "s", "csrf_token"])
        #expect(detail["id"] as? String == "19723756" && detail["n"] as? Int == 4 && detail["s"] as? Int == 0)
    }

    @Test func partlySentRowsAreFilledByOneBatchInListOrder() async throws {
        let ids = (1...30).map { #"{"id":\#($0)}"# }.joined(separator: ",")
        let rows = (1...10).map { #"{"id":\#($0),"name":"已有 \#($0)","st":0}"# }.joined(separator: ",")
        let detail = #"{"code":200,"playlist":{"id":8,"trackCount":30,"trackIds":["# + ids + #"],"tracks":["# + rows + #"]},"privileges":[]}"#
        let extra = (11...25).reversed().map { #"{"id":\#($0),"name":"补全 \#($0)","st":0}"# }.joined(separator: ",")
        let songs = #"{"code":200,"songs":["# + extra + #"],"privileges":[{"id":12,"st":-200,"pl":0}]}"#
        let fixture = NEBrowseFixture([.init(path: detailPath, json: detail), .init(path: songDetailPath, json: songs)])
        let playlist = BrowseCollection(source: .netease, kind: .playlist, remoteID: "8", title: "推荐")
        let tracks = try await provider(fixture).tracks(in: playlist, limit: 25, cookies: cookies)
        #expect(tracks.map(\.sourceID) == (1...25).map(String.init))
        #expect(tracks[0].title == "已有 1" && tracks[24].title == "补全 25")
        #expect(tracks.filter(\.unavailable).map(\.sourceID) == ["12"])
        #expect(await fixture.paths == [detailPath, songDetailPath])
    }

    @Test func recommendedPlaylistOpensThroughTheSameDetailRoute() async throws {
        let fixture = NEBrowseFixture([.init(path: detailPath, json: #"{"code":200,"playlist":{"id":5,"trackIds":[{"id":1},{"id":2}],"tracks":[{"id":1,"name":"一"},{"id":1,"name":"重复"},{"id":2,"name":"二"}]}}"#)])
        let playlist = BrowseCollection(source: .netease, kind: .playlist, remoteID: "5", title: "推荐")
        let tracks = try await provider(fixture).tracks(in: playlist, limit: 100, cookies: cookies)
        #expect(tracks.map(\.title) == ["一", "二"])
        #expect(tracks.allSatisfy { !$0.unavailable })
        #expect(await fixture.count == 1)
    }

    @Test func emptySongRowsFallBackToOneSongDetailBatchInListOrder() async throws {
        let detail = #"{"code":200,"playlist":{"id":7,"trackCount":6,"trackIds":[{"id":21},{"id":22},{"id":21},{"id":23},{"id":24},{"id":25}],"tracks":[]},"privileges":[]}"#
        let songs = #"{"code":200,"songs":[{"id":23,"name":"三","ar":[{"name":"丙"}]},{"id":21,"name":"一","ar":[{"name":"甲"}],"st":0},{"id":99,"name":"未请求"}],"privileges":[{"id":23,"st":-200},{"id":21,"st":0}]}"#
        let fixture = NEBrowseFixture([.init(path: detailPath, json: detail), .init(path: songDetailPath, json: songs)])
        let chart = BrowseCollection(source: .netease, kind: .chart, remoteID: "7", title: "榜")
        let tracks = try await provider(fixture).tracks(in: chart, limit: 3, cookies: cookies)
        // 22 was asked for but not returned; it is left out rather than invented.
        #expect(tracks.map(\.sourceID) == ["21", "23"])
        #expect(tracks.map(\.unavailable) == [false, true])
        #expect(await fixture.paths == [detailPath, songDetailPath])
        let batch = try payload(NeteaseDirectProvider.songDetailPayload(["21", "22", "23"]))
        #expect(Set(batch.keys) == ["c", "csrf_token"])
        #expect(batch["c"] as? String == #"[{"id":"21"},{"id":"22"},{"id":"23"}]"#)
    }

    @Test func emptyListNeedsNoSecondRequestAndMissingPlaylistFails() async throws {
        let empty = NEBrowseFixture([.init(path: detailPath, json: #"{"code":200,"playlist":{"id":7,"trackCount":0,"trackIds":[],"tracks":[]}}"#)])
        let chart = BrowseCollection(source: .netease, kind: .chart, remoteID: "7", title: "榜")
        #expect(try await provider(empty).tracks(in: chart, limit: 10, cookies: cookies).isEmpty)
        #expect(await empty.count == 1)

        let missing = NEBrowseFixture([.init(path: detailPath, json: #"{"code":200,"playlist":null}"#)])
        let message = await failure { try await provider(missing).tracks(in: chart, limit: 10, cookies: cookies) }
        #expect(message == L10n.string("无法读取网易云歌单，请检查登录状态或歌单权限"))
        #expect(await missing.count == 1)

        let changed = NEBrowseFixture([.init(path: detailPath, json: #"{"code":200,"playlist":{"id":7,"trackIds":[{"id":1}],"tracks":[]}}"#), .init(path: songDetailPath, json: #"{"code":200,"songs":null}"#)])
        let changedMessage = await failure { try await provider(changed).tracks(in: chart, limit: 10, cookies: cookies) }
        #expect(changedMessage == L10n.string("网易云响应格式已变化（阶段：\(L10n.string("读取歌曲资料"))；接口码：200），请稍后重试"))
    }

    @Test func onlyNeteaseChartsAndPlaylistsWithValidIDsOpen() async throws {
        let fixture = NEBrowseFixture([]), value = provider(fixture)
        let rejected: [(BrowseCollection, String)] = [
            (.init(source: .netease, kind: .album, remoteID: "42", title: "专辑"), L10n.string("该歌单不是网易云歌单")),
            (.init(source: .qq, kind: .chart, remoteID: "26", title: "QQ 榜"), L10n.string("该歌单不是网易云歌单")),
            (.init(source: .netease, kind: .chart, remoteID: "0", title: "榜"), L10n.string("网易云资源标识无效")),
            (.init(source: .netease, kind: .playlist, remoteID: "12a", title: "歌单"), L10n.string("网易云资源标识无效")),
            (.init(source: .netease, kind: .playlist, remoteID: "", title: "歌单"), L10n.string("网易云资源标识无效"))
        ]
        for (collection, expected) in rejected {
            #expect(await failure { try await value.tracks(in: collection, limit: 10, cookies: cookies) } == expected)
        }
        let chart = BrowseCollection(source: .netease, kind: .chart, remoteID: "7", title: "榜")
        #expect(try await value.tracks(in: chart, limit: 0, cookies: cookies).isEmpty)
        #expect(await fixture.count == 0)
    }

    @Test func browsingWithoutASignedInSessionSendsNothing() async {
        let fixture = NEBrowseFixture([]), value = provider(fixture)
        let loggedOut: [MusicSessionCookie] = [.init(name: "__csrf", value: "fixture", domain: ".music.163.com")]
        let chart = BrowseCollection(source: .netease, kind: .chart, remoteID: "7", title: "榜")
        await #expect(throws: MusicError.self) { try await value.charts(cookies: loggedOut) }
        await #expect(throws: MusicError.self) { try await value.recommendations(cookies: loggedOut) }
        await #expect(throws: MusicError.self) { try await value.tracks(in: chart, limit: 10, cookies: loggedOut) }
        #expect(await fixture.count == 0)
    }

    private func payload(_ value: [String: Any]) throws -> [String: Any] {
        let body = try NeteaseDirectProvider.requestPayload(value, matchingCookies: [])
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func failure<T>(_ operation: () async throws -> T) async -> String {
        do { _ = try await operation(); Issue.record("Expected a failure"); return "" }
        catch { return error.localizedDescription }
    }
}

/// Replies by path, so the two concurrent recommendation requests may arrive in any order.
private actor NEBrowseFixture {
    struct Reply: Sendable { var path: String; var json: String; var status: Int = 200 }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    var count: Int { requests.count }
    var paths: [String] { requests.compactMap { $0.url?.path } }
    init(_ replies: [Reply]) { self.replies = replies }
    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard let url = request.url, let index = replies.firstIndex(where: { $0.path == url.path }) else {
            throw MusicError.message("Unexpected fixture request")
        }
        let reply = replies.remove(at: index)
        return (Data(reply.json.utf8), HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil)!)
    }
}
