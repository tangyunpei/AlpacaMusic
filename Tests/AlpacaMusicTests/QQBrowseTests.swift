import Foundation
import Synchronization
import Testing
@testable import AlpacaMusic

private let qqCookies = [MusicSessionCookie(name: "uin", value: "o12345678", domain: ".y.qq.com"), MusicSessionCookie(name: "qqmusic_key", value: "test-session-key", domain: ".y.qq.com")]
private func qqSong(_ mid: String, title: String = "<em>雨</em> &amp; 风") -> [String: Any] {
    ["id": 1000, "mid": mid, "title": title, "interval": 181, "singer": [["mid": "singer1", "name": "Artist"]], "album": ["mid": "album1", "title": "Album"]]
}
private func qqReply(_ request: URLRequest, _ value: [String: Any]) throws -> (Data, HTTPURLResponse) {
    (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}
private func qqResponse(_ request: URLRequest, _ body: Data) -> (Data, HTTPURLResponse) {
    (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}
private func qqBody(_ request: URLRequest) throws -> [String: Any] {
    let root = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
    return try #require(root)
}
private func qqRPC(_ request: URLRequest, _ index: Int = 0) throws -> [String: Any] {
    try #require(try qqBody(request)["req_\(index)"] as? [String: Any])
}
private func qqParameters(_ request: URLRequest, _ index: Int = 0) throws -> [String: Any] {
    try #require(try qqRPC(request, index)["param"] as? [String: Any])
}
private func expectedQQRPCFailure(operation: String, code: Int) -> String {
    L10n.string("QQ 音乐\(operation)失败（平台返回码 \(String(code))），请稍后重试。")
}
/// A GetAll toplist entry modelled on the live response: http artwork and a
/// three-song preview without song MIDs.
private func qqChart(_ topID: Int, title: String = "热歌榜", updateType: Int = 1, period: String = "2026-11-07", total: Int = 100,
                     preview: Int = 3, front: String? = "http://y.gtimg.cn/music/photo_new/T003R300x300M000front.jpg",
                     head: String? = "http://y.gtimg.cn/music/photo_new/T003R500x500M000head.jpg") -> [String: Any] {
    var item: [String: Any] = ["topId": topID, "title": title, "updateType": updateType, "period": period, "totalNum": total, "updateTips": "每日更新",
                               "song": (0..<preview).map { ["rank": $0 + 1, "songId": 700 + $0, "albumMid": "albumMid", "title": "Song \($0 + 1)", "singerName": "Singer \($0 + 1)"] }]
    if let front { item["frontPicUrl"] = front }
    if let head { item["headPicUrl"] = head }
    return item
}
private func qqPlaylist(_ tid: Any, title: String = "Fixture list", count: Int = 30, nick: String? = "Curator",
                        cover: [String: Any] = ["small_url": "http://qpic.y.qq.com/small.jpg", "medium_url": "http://qpic.y.qq.com/medium.jpg", "big_url": "http://qpic.y.qq.com/big.jpg"]) -> [String: Any] {
    var basic: [String: Any] = ["tid": tid, "title": title, "song_cnt": count, "play_cnt": 10, "cover": cover]
    if let nick { basic["creator"] = ["uin": "1", "nick": nick] }
    return ["Playlist": ["basic": basic, "content": [:]], "WhereFrom": 0]
}
private func qqFeed(_ playlists: [[String: Any]]) -> [String: Any] {
    ["code": 0, "data": ["Msg": "", "List": playlists, "HasMore": true, "FromLimit": 400]]
}
private func qqDetail(_ rows: [[String: Any]], code: Int = 0) -> [String: Any] {
    ["code": 0, "req_0": ["code": code, "data": ["data": ["topId": 26, "period": "2026-11-07", "song": []], "songInfoList": rows, "extInfoList": [], "songTagInfoList": [], "indexInfoList": []]]]
}
private let qqChartCollection = BrowseCollection(source: .qq, kind: .chart, remoteID: "26", title: "热歌榜")
private let qqPlaylistCollection = BrowseCollection(source: .qq, kind: .playlist, remoteID: "7922374693", title: "Fixture list")

struct QQBrowseTests {
    // MARK: Batched transport

    @Test func recommendationsBatchPlaylistsAndRadioIntoOneSignedRequest() async throws {
        let requests = Mutex(0)
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            requests.withLock { $0 += 1 }
            #expect(request.httpMethod == "POST")
            #expect(request.url?.host == "u.y.qq.com")
            #expect(request.url?.path == "/cgi-bin/musics.fcg")
            let body = try #require(request.httpBody)
            let sign = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "sign" }?.value
            #expect(sign == QQWebSigning.signature(for: body))
            #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("qqmusic_key=test-session-key") == true)
            let root = try qqBody(request)
            #expect(Set(root.keys) == ["comm", "req_0", "req_1"])
            let comm = try #require(root["comm"] as? [String: Any])
            #expect(comm["uin"] as? Int == 12345678)
            #expect(comm["g_tk_new_20200303"] as? Int == Int(QQWebSigning.csrfToken("test-session-key")))
            #expect(comm["platform"] as? String == "yqq.json")
            let feed = try qqRPC(request, 0), radio = try qqRPC(request, 1)
            #expect(feed["module"] as? String == "music.playlist.PlaylistSquare")
            #expect(feed["method"] as? String == "GetRecommendFeed")
            let feedParameters = try qqParameters(request, 0)
            #expect(feedParameters.count == 2)
            #expect(feedParameters["From"] as? Int == 0)
            #expect(feedParameters["Size"] as? Int == 12)
            #expect(radio["module"] as? String == "music.radioProxy.MbTrackRadioSvr")
            #expect(radio["method"] as? String == "get_radio_track")
            let radioParameters = try qqParameters(request, 1)
            #expect(radioParameters["id"] as? Int == 99)
            #expect(radioParameters["num"] as? Int == 10)
            #expect(radioParameters["from"] as? Int == 0)
            #expect(radioParameters["scene"] as? Int == 0)
            #expect((radioParameters["song_ids"] as? [Any])?.isEmpty == true)
            return try qqReply(request, ["code": 0, "req_0": qqFeed([qqPlaylist(9_000_000_001)]), "req_1": ["code": 0, "data": ["id": 99, "tracks": [qqSong("radio1")]]]])
        }))
        let result = try await provider.recommendations(cookies: qqCookies)
        #expect(result.collections.map(\.remoteID) == ["9000000001"])
        #expect(result.songs.map(\.id) == ["qq:radio1"])
        #expect(requests.withLock { $0 } == 1)
    }

    @Test func singleCallsStillSendOnlyRequestZero() async throws {
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            let root = try qqBody(request)
            #expect(Set(root.keys) == ["comm", "req_0"])
            let sign = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "sign" }?.value
            #expect(sign == QQWebSigning.signature(for: try #require(request.httpBody)))
            return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["group": [], "refreshInterval": 1]]])
        }))
        #expect(try await provider.charts(cookies: qqCookies).isEmpty)
    }

    // MARK: Recommendations

    @Test func recommendedPlaylistsMapBasicFieldsAndSongsDedupe() async throws {
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            try qqReply(request, ["code": 0, "req_0": qqFeed([
                qqPlaylist(7_922_374_693, title: "抖音 &amp; 热歌", count: 1201, nick: "张大佛爷"),
                qqPlaylist(9_795_916_402, title: "Empty count", count: 0, nick: nil, cover: ["medium_url": "", "big_url": "//qpic.y.qq.com/big.jpg", "small_url": "http://qpic.y.qq.com/small.jpg"]),
                qqPlaylist(7_922_374_693, title: "Duplicate"),
                qqPlaylist("abc", title: "Invalid id"),
                qqPlaylist(0, title: "Zero id"),
                qqPlaylist(9_600_683_632, title: "   "),
                qqPlaylist("9654832328", title: "String id", cover: ["small_url": "http://qpic.y.qq.com/only-small.jpg"]),
                ["WhereFrom": 0]
            ]), "req_1": ["code": 0, "data": ["id": 99, "name": "猜你喜欢", "tracks": [qqSong("song1"), qqSong("song1"), ["id": 5, "title": "No mid"], qqSong("song2")]]]])
        }))
        let result = try await provider.recommendations(cookies: qqCookies)
        #expect(result.collections.map(\.remoteID) == ["7922374693", "9795916402", "9654832328"])
        #expect(result.collections.allSatisfy { $0.source == .qq && $0.kind == .playlist && $0.preview.isEmpty && $0.tracks == nil })
        let first = try #require(result.collections.first)
        #expect(first.id == "qq:playlist:7922374693")
        #expect(first.title == "抖音 & 热歌")
        #expect(first.caption == "张大佛爷")
        #expect(first.trackCount == 1201)
        #expect(first.artworkURL?.absoluteString == "https://qpic.y.qq.com/medium.jpg")
        #expect(result.collections[1].caption == "")
        #expect(result.collections[1].trackCount == nil)
        #expect(result.collections[1].artworkURL?.absoluteString == "https://qpic.y.qq.com/big.jpg")
        #expect(result.collections[2].artworkURL?.absoluteString == "https://qpic.y.qq.com/only-small.jpg")
        #expect(result.songs.map(\.id) == ["qq:song1", "qq:song2"])
        #expect(result.songs.first?.title == "雨 & 风")
        #expect(result.songs.first?.artworkURL?.absoluteString == "https://y.gtimg.cn/music/photo_new/T002R500x500M000album1.jpg")
    }

    @Test func radioFailureLeavesPlaylistsWithoutSongs() async throws {
        let radioReplies: [Any?] = [
            ["code": 1000, "data": ["id": 99, "tracks": NSNull()]],
            ["code": 500005],
            ["code": 0],
            ["code": 0, "data": ["id": 99, "tracks": NSNull()]],
            nil
        ]
        for radio in radioReplies {
            var root: [String: Any] = ["code": 0, "req_0": qqFeed([qqPlaylist(9_000_000_001)])]
            if let radio { root["req_1"] = radio }
            let body = try JSONSerialization.data(withJSONObject: root)
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in qqResponse(request, body) }))
            let result = try await provider.recommendations(cookies: qqCookies)
            #expect(result.collections.map(\.remoteID) == ["9000000001"])
            #expect(result.songs.isEmpty)
        }
    }

    @Test func playlistFeedFailureFailsRecommendationsEvenWithSongs() async throws {
        let radio: [String: Any] = ["code": 0, "data": ["tracks": [qqSong("song1")]]]
        let cases: [([String: Any], String)] = [
            (["code": 0, "req_0": ["code": 500], "req_1": radio], expectedQQRPCFailure(operation: L10n.string("读取推荐歌单"), code: 500)),
            (["code": 0, "req_0": ["code": 1000], "req_1": radio], L10n.string("QQ 音乐登录已失效，请重新登录（平台返回码 \(String(1000))）。")),
            (["code": 0, "req_0": ["code": 0, "data": ["Msg": ""]], "req_1": radio], L10n.string("QQ 音乐响应格式已变化，请稍后重试或更新应用。")),
            (["code": 0, "req_1": radio], L10n.string("QQ 音乐响应格式已变化，请稍后重试或更新应用。")),
            (["code": 2000], expectedQQRPCFailure(operation: L10n.string("读取推荐歌单"), code: 2000))
        ]
        for (root, message) in cases {
            let body = try JSONSerialization.data(withJSONObject: root)
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in qqResponse(request, body) }))
            do { _ = try await provider.recommendations(cookies: qqCookies); Issue.record("Failed playlist feed was accepted") }
            catch { #expect(error.localizedDescription == message) }
        }
    }

    @Test func recommendationsCancellationIsNotTreatedAsEmptyRadio() async {
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { _ in throw CancellationError() }))
        await #expect(throws: CancellationError.self) { try await provider.recommendations(cookies: qqCookies) }
    }

    // MARK: Charts

    @Test func chartsReadGetAllOnceAndKeepOnlyChartsWithSongs() async throws {
        let requests = Mutex(0)
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            requests.withLock { $0 += 1 }
            let rpc = try qqRPC(request)
            #expect(rpc["module"] as? String == "musicToplist.ToplistInfoServer")
            #expect(rpc["method"] as? String == "GetAll")
            #expect(try qqParameters(request).isEmpty)
            return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["refreshInterval": 1, "group": [
                ["groupId": 0, "groupName": "巅峰榜", "toplist": [
                    qqChart(62, title: "飙升榜", preview: 4),
                    qqChart(201, title: "MV榜", period: ""),
                    qqChart(27, title: "新歌榜", preview: 0),
                    qqChart(26, title: "热歌 &amp; 榜", total: 300)
                ]],
                ["groupId": 1, "groupName": "地区榜", "toplist": [
                    qqChart(5, title: "内地榜", updateType: 0, period: "2026_45", front: nil),
                    qqChart(59, title: "香港地区榜", updateType: 0, period: "2026_45", total: 0, front: ""),
                    qqChart(62, title: "飙升榜 again"),
                    qqChart(0, title: "Invalid"),
                    ["topId": "abc", "title": "Invalid", "song": [["title": "x", "singerName": "y"]]]
                ]],
                ["groupId": 3, "groupName": "全球榜", "toplist": [
                    qqChart(108, title: "Billboard", updateType: 7, period: "", head: nil),
                    qqChart(107, title: "   ")
                ]]
            ]]]])
        }))
        let charts = try await provider.charts(cookies: qqCookies)
        #expect(requests.withLock { $0 } == 1)
        #expect(charts.map(\.remoteID) == ["62", "26", "5", "59", "108"])
        #expect(charts.allSatisfy { $0.source == .qq && $0.kind == .chart && $0.tracks == nil })
        let rising = try #require(charts.first)
        #expect(rising.id == "qq:chart:62")
        #expect(rising.title == "飙升榜")
        #expect(rising.caption == L10n.string("每日更新"))
        #expect(rising.trackCount == 100)
        #expect(rising.preview == [.init(title: "Song 1", artist: "Singer 1"), .init(title: "Song 2", artist: "Singer 2"), .init(title: "Song 3", artist: "Singer 3")])
        #expect(rising.artworkURL?.absoluteString == "https://y.gtimg.cn/music/photo_new/T003R300x300M000front.jpg")
        #expect(charts[1].title == "热歌 & 榜")
        #expect(charts[1].trackCount == 300)
        #expect(charts[2].caption == L10n.string("每周更新"))
        #expect(charts[2].artworkURL?.absoluteString == "https://y.gtimg.cn/music/photo_new/T003R500x500M000head.jpg")
        #expect(charts[3].artworkURL?.absoluteString == "https://y.gtimg.cn/music/photo_new/T003R500x500M000head.jpg")
        #expect(charts[3].trackCount == nil)
        #expect(charts[4].caption == "")
    }

    @Test func chartsKeepPlatformOrderAndStopAtThirty() async throws {
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["group": [
                ["toplist": (1...20).map { qqChart($0, title: "Chart \($0)") }],
                ["toplist": (21...40).map { qqChart($0, title: "Chart \($0)") }]
            ]]]])
        }))
        let charts = try await provider.charts(cookies: qqCookies)
        #expect(charts.map(\.remoteID) == (1...30).map(String.init))
    }

    @Test func chartFailuresNameTheOperation() async throws {
        let cases: [([String: Any], String)] = [
            (["code": 0, "req_0": ["code": 500]], expectedQQRPCFailure(operation: L10n.string("读取榜单"), code: 500)),
            (["code": 2000], expectedQQRPCFailure(operation: L10n.string("读取榜单"), code: 2000)),
            (["code": 0, "req_0": ["code": 0, "data": ["refreshInterval": 1]]], L10n.string("QQ 音乐响应格式已变化，请稍后重试或更新应用。"))
        ]
        for (root, message) in cases {
            let body = try JSONSerialization.data(withJSONObject: root)
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in qqResponse(request, body) }))
            do { _ = try await provider.charts(cookies: qqCookies); Issue.record("Failed chart list was accepted") }
            catch { #expect(error.localizedDescription == message) }
        }
    }

    // MARK: Chart songs

    @Test func chartSongsSendNumericTopIDWithoutEditionAndTrimToLimit() async throws {
        let requests = Mutex(0)
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            requests.withLock { $0 += 1 }
            let rpc = try qqRPC(request), parameters = try qqParameters(request)
            #expect(rpc["module"] as? String == "musicToplist.ToplistInfoServer")
            #expect(rpc["method"] as? String == "GetDetail")
            #expect(parameters["topId"] as? Int == 26)
            #expect(!(parameters["topId"] is String))
            #expect(String(data: try #require(request.httpBody), encoding: .utf8)?.contains(#""topId":26"#) == true)
            #expect(parameters["offset"] as? Int == 0)
            #expect(parameters["num"] as? Int == 2)
            // Never the chart list's edition: QQ serves old editions without complaint.
            #expect(parameters["period"] == nil)
            #expect(Set(parameters.keys) == ["topId", "offset", "num"])
            return try qqReply(request, qqDetail([qqSong("chart1"), qqSong("chart1"), qqSong("chart2"), qqSong("chart3")]))
        }))
        let tracks = try await provider.tracks(in: qqChartCollection, limit: 2, cookies: qqCookies)
        #expect(tracks.map(\.id) == ["qq:chart1", "qq:chart2"])
        #expect(tracks.first?.title == "雨 & 风")
        #expect(tracks.first?.duration == 181)
        #expect(requests.withLock { $0 } == 1)
    }

    @Test func rejectedChartSongsAreOneRequestAndReported() async {
        for code in [2000, 10000, 10006] {
            let requests = Mutex(0)
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                requests.withLock { $0 += 1 }
                return try qqReply(request, qqDetail([], code: code))
            }))
            do { _ = try await provider.tracks(in: qqChartCollection, limit: 100, cookies: qqCookies); Issue.record("Rejected chart was accepted") }
            catch { #expect(error.localizedDescription == expectedQQRPCFailure(operation: L10n.string("读取榜单曲目"), code: code)) }
            #expect(requests.withLock { $0 } == 1)
        }
    }

    @Test func rootRejectionFailsTheChartSongs() async {
        let requests = Mutex(0)
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            requests.withLock { $0 += 1 }; return try qqReply(request, ["code": 2000])
        }))
        do { _ = try await provider.tracks(in: qqChartCollection, limit: 100, cookies: qqCookies); Issue.record("Rejected signature was accepted") }
        catch { #expect(error.localizedDescription == expectedQQRPCFailure(operation: L10n.string("读取榜单曲目"), code: 2000)) }
        #expect(requests.withLock { $0 } == 1)
    }

    @Test func chartWithoutReadableRowsIsAFormatChangeButEmptyChartIsEmpty() async throws {
        let unreadable = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            try qqReply(request, qqDetail([["id": 1, "title": "No mid"], ["songInfo": qqSong("a"), "track_info": qqSong("b")]]))
        }))
        do { _ = try await unreadable.tracks(in: qqChartCollection, limit: 100, cookies: qqCookies); Issue.record("Unreadable chart was accepted") }
        catch { #expect(error.localizedDescription == L10n.string("QQ 音乐响应格式已变化，请稍后重试或更新应用。")) }
        let empty = QQDirectProvider(http: NativeMusicHTTP(transport: { request in try qqReply(request, qqDetail([])) }))
        #expect(try await empty.tracks(in: qqChartCollection, limit: 100, cookies: qqCookies).isEmpty)
        let missing = QQDirectProvider(http: NativeMusicHTTP(transport: { request in try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["data": [:]]]]) }))
        do { _ = try await missing.tracks(in: qqChartCollection, limit: 100, cookies: qqCookies); Issue.record("Missing song list was accepted") }
        catch { #expect(error.localizedDescription == L10n.string("QQ 音乐响应格式已变化，请稍后重试或更新应用。")) }
    }

    // MARK: Playlist songs

    @Test func playlistSongsReadOneFirstPageAndSkipRowsWithoutIdentity() async throws {
        let methods = Mutex<[String]>([])
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            let rpc = try qqRPC(request), parameters = try qqParameters(request)
            methods.withLock { $0.append(rpc["method"] as? String ?? "") }
            #expect(rpc["module"] as? String == "music.srfDissInfo.aiDissInfo")
            #expect(parameters["disstid"] as? Int == 7_922_374_693)
            #expect(!(parameters["disstid"] is String))
            #expect(parameters["song_begin"] as? Int == 0)
            #expect(parameters["song_num"] as? Int == 3)
            #expect(parameters["userinfo"] as? Int == 1)
            #expect(parameters["tag"] as? Int == 1)
            #expect(parameters["orderlist"] as? Int == 1)
            #expect(parameters["onlysonglist"] as? Int == 1)
            #expect(parameters["enc_host_uin"] as? String == "")
            // A damaged row would trigger a detail request in the import path.
            return try qqReply(request, ["code": 0, "req_0": ["code": 0, "data": ["code": 0, "total_song_num": 511, "songlist": [
                qqSong("list1"), ["mid": "", "songid": 12345, "title": "Damaged"], "not a row", qqSong("list1"), qqSong("list2"), qqSong("list3"), qqSong("list4")
            ]]]])
        }))
        let tracks = try await provider.tracks(in: qqPlaylistCollection, limit: 3, cookies: qqCookies)
        #expect(tracks.map(\.id) == ["qq:list1", "qq:list2", "qq:list3"])
        #expect(methods.withLock { $0 } == ["uniform_get_Dissinfo"])
    }

    @Test func playlistSongFailuresKeepTheExistingMessages() async throws {
        let cases: [([String: Any], String)] = [
            (["code": 0, "req_0": ["code": 10006]], expectedQQRPCFailure(operation: L10n.string("读取歌单曲目"), code: 10006)),
            (["code": 0, "req_0": ["code": 0, "data": ["code": 4000]]], expectedQQRPCFailure(operation: L10n.string("读取歌单曲目"), code: 4000)),
            (["code": 0, "req_0": ["code": 0, "data": ["code": 0, "songlist": NSNull()]]], L10n.string("QQ 音乐响应格式已变化，请稍后重试或更新应用。"))
        ]
        for (root, message) in cases {
            let body = try JSONSerialization.data(withJSONObject: root)
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in qqResponse(request, body) }))
            do { _ = try await provider.tracks(in: qqPlaylistCollection, limit: 100, cookies: qqCookies); Issue.record("Failed playlist was accepted") }
            catch { #expect(error.localizedDescription == message) }
        }
    }

    // MARK: Rejections before any request

    @Test func albumsForeignSourcesAndInvalidIdentifiersNeverSendRequests() async throws {
        let requests = Mutex(0)
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            requests.withLock { $0 += 1 }; return try qqReply(request, ["code": 0])
        }))
        var cases: [(BrowseCollection, String)] = [
            (.init(source: .qq, kind: .album, remoteID: "003BhYeD0mahCv", title: "Album"), L10n.string("QQ 音乐暂不支持在此打开专辑。")),
            (.init(source: .netease, kind: .playlist, remoteID: "123", title: "Other"), L10n.string("不支持的音源类型")),
            (.init(source: .netease, kind: .chart, remoteID: "26", title: "Other"), L10n.string("不支持的音源类型"))
        ]
        for identifier in ["", "abc", "0", "-1", "+26", "26 ", "999999999999999999999999"] {
            cases.append((.init(source: .qq, kind: .chart, remoteID: identifier, title: "Chart"), L10n.string("QQ 音乐榜单标识无效，请刷新榜单。")))
            cases.append((.init(source: .qq, kind: .playlist, remoteID: identifier, title: "List"), L10n.string("QQ 音乐歌单标识无效，请刷新歌单列表。")))
        }
        for (collection, message) in cases {
            do { _ = try await provider.tracks(in: collection, limit: 100, cookies: qqCookies); Issue.record("Unsupported collection was accepted") }
            catch { #expect(error.localizedDescription == message) }
        }
        #expect(try await provider.tracks(in: qqChartCollection, limit: 0, cookies: qqCookies).isEmpty)
        #expect(try await provider.tracks(in: qqPlaylistCollection, limit: 0, cookies: qqCookies).isEmpty)
        #expect(requests.withLock { $0 } == 0)
    }

    @Test func browsingRequiresTheSignedInSession() async {
        let requests = Mutex(0)
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            requests.withLock { $0 += 1 }; return try qqReply(request, ["code": 0])
        }))
        let expected = L10n.string("请先在应用内登录 QQ 音乐，或重新登录已过期的账户。")
        for cookies in [[], [qqCookies[0]]] {
            do { _ = try await provider.charts(cookies: cookies); Issue.record("Signed-out charts were requested") }
            catch { #expect(error.localizedDescription == expected) }
            do { _ = try await provider.recommendations(cookies: cookies); Issue.record("Signed-out recommendations were requested") }
            catch { #expect(error.localizedDescription == expected) }
            do { _ = try await provider.tracks(in: qqChartCollection, limit: 100, cookies: cookies); Issue.record("Signed-out chart songs were requested") }
            catch { #expect(error.localizedDescription == expected) }
            do { _ = try await provider.tracks(in: qqPlaylistCollection, limit: 100, cookies: cookies); Issue.record("Signed-out playlist songs were requested") }
            catch { #expect(error.localizedDescription == expected) }
        }
        #expect(requests.withLock { $0 } == 0)
    }
}
