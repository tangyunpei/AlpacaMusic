import Foundation
import Synchronization
import Testing
@testable import AlpacaMusic

private func reply(_ request: URLRequest, _ value: [String: Any]) throws -> (Data, HTTPURLResponse) {
    (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}
private let neteaseCookies = [MusicSessionCookie(name: "MUSIC_U", value: "fixture-session", domain: ".music.163.com"),
                              MusicSessionCookie(name: "__csrf", value: "fixture-csrf", domain: ".music.163.com")]
private let qqCookies = [MusicSessionCookie(name: "uin", value: "o12345678", domain: ".y.qq.com"),
                         MusicSessionCookie(name: "qqmusic_key", value: "test-session-key", domain: ".y.qq.com")]

/// Shapes taken from the live replies of 14 November 2026, trimmed.
@Suite struct SingerLookupTests {
    @Test func neteaseReadsSingersAlbumsAndSongs() async throws {
        let paths = Mutex<[String]>([])
        let provider = NeteaseDirectProvider(http: NativeMusicHTTP(transport: { request in
            let path = request.url?.path ?? ""
            paths.withLock { $0.append(path) }
            switch path {
            case "/weapi/cloudsearch/pc":
                return try reply(request, ["code": 200, "result": ["artists": [
                    ["id": 6452, "name": "周杰伦", "alias": ["Jay Chou", "周董"], "picUrl": "http://p1.music.126.net/a.jpg", "albumSize": 45, "musicSize": 591],
                    ["id": 0, "name": "Broken"]]]])
            case "/weapi/artist/albums/6452":
                return try reply(request, ["code": 200, "more": true, "hotAlbums": [
                    ["id": 359251095, "name": "太阳之子", "publishTime": 1774281600000, "size": 13, "type": "专辑", "picUrl": "https://p2.music.126.net/c.jpg",
                     "artists": [["name": "周杰伦"]]]]])
            case "/weapi/v1/artist/songs":
                return try reply(request, ["code": 200, "more": false, "songs": [
                    ["id": 186016, "name": "晴天", "ar": [["name": "周杰伦"]], "al": ["name": "叶惠美", "picUrl": "https://p2.music.126.net/d.jpg"], "dt": 269000]]])
            default: throw MusicError.message("Unexpected \(path)")
            }
        }))
        let singers = try await provider.singers("周杰伦", cookies: neteaseCookies)
        #expect(singers.map(\.remoteID) == ["6452"])
        #expect(singers.first?.aliases == ["Jay Chou", "周董"])
        #expect(singers.first?.albumCount == 45)
        #expect(singers.first?.pictureURL?.scheme == "https")
        let albums = try await provider.singerAlbums("6452", offset: 0, cookies: neteaseCookies)
        #expect(albums.more)
        #expect(albums.items.first?.name == "太阳之子")
        #expect(albums.items.first?.date == ReleaseDate(year: 2026, month: 3, day: 24))
        #expect(albums.items.first?.trackCount == 13)
        #expect(albums.items.first?.artist == "周杰伦")
        let songs = try await provider.singerSongs("6452", offset: 0, cookies: neteaseCookies)
        #expect(songs.items.map(\.id) == ["netease:186016"])
        #expect(!songs.more)
        #expect(paths.withLock { $0 } == ["/weapi/cloudsearch/pc", "/weapi/artist/albums/6452", "/weapi/v1/artist/songs"])
        await #expect(throws: (any Error).self) { try await provider.singerAlbums("not-an-id", offset: 0, cookies: neteaseCookies) }
    }

    @Test func qqReadsSingersAlbumsSongsAndAnAlbum() async throws {
        let methods = Mutex<[String]>([])
        let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            let call = try #require(body["req_0"] as? [String: Any])
            let method = call["method"] as? String ?? ""
            let parameters = call["param"] as? [String: Any] ?? [:]
            methods.withLock { $0.append(method) }
            let data: [String: Any]
            switch method {
            case "DoSearchForQQMusicDesktop":
                #expect(parameters["search_type"] as? Int == 1)
                data = ["body": ["singer": ["list": [["singerMID": "0025NhlN2yWrP4", "singerName": "周杰伦", "singerPic": "https://y.gtimg.cn/s.jpg", "albumNum": 43, "songNum": 1013]]]]]
            case "GetAlbumList":
                data = ["total": 43, "albumList": [["albumMid": "0041WVfh2vtlJE", "albumName": "太阳之子", "publishDate": "2026-03-25", "albumType": "录音室专辑", "totalNum": 0, "singerName": "周杰伦"]]]
            case "GetSingerSongList":
                data = ["totalNum": 1013, "songList": [["songInfo": ["mid": "0039MnYb0qxYhV", "name": "晴天", "singer": [["name": "周杰伦"]], "album": ["mid": "000MkMni19ClKG", "name": "叶惠美"], "interval": 269]]]]
            case "GetAlbumSongList":
                data = ["totalNum": 1, "songList": [["songInfo": ["mid": "001AlbumSong1", "name": "太阳之子", "singer": [["name": "周杰伦"]], "album": ["mid": "0041WVfh2vtlJE", "name": "太阳之子"], "interval": 240]]]]
            default: throw MusicError.message("Unexpected \(method)")
            }
            return try reply(request, ["code": 0, "req_0": ["code": 0, "data": data]])
        }))
        let singers = try await provider.singers("周杰伦", cookies: qqCookies)
        #expect(singers.map(\.remoteID) == ["0025NhlN2yWrP4"])
        #expect(singers.first?.songCount == 1013)
        let albums = try await provider.singerAlbums("0025NhlN2yWrP4", offset: 0, cookies: qqCookies)
        #expect(albums.more)
        #expect(albums.items.first?.date == ReleaseDate(year: 2026, month: 3, day: 25))
        // QQ Music's list gives no song count: none is invented.
        #expect(albums.items.first?.trackCount == nil)
        #expect(albums.items.first?.artworkURL?.absoluteString.contains("0041WVfh2vtlJE") == true)
        let songs = try await provider.singerSongs("0025NhlN2yWrP4", offset: 0, cookies: qqCookies)
        #expect(songs.items.map(\.id) == ["qq:0039MnYb0qxYhV"])
        #expect(songs.more)
        let albumSongs = try await provider.albumSongs("0041WVfh2vtlJE", cookies: qqCookies)
        #expect(albumSongs.map(\.title) == ["太阳之子"])
        #expect(methods.withLock { $0 } == ["DoSearchForQQMusicDesktop", "GetAlbumList", "GetSingerSongList", "GetAlbumSongList"])
    }

    @Test func releaseDatesReadEachServicesForm() {
        #expect(ReleaseDate(text: "2025-06-06") == ReleaseDate(year: 2025, month: 6, day: 6))
        #expect(ReleaseDate(text: "2025") == ReleaseDate(year: 2025))
        #expect(ReleaseDate(text: "0000-00-00") == nil)
        // NetEase's milliseconds are read in China's time zone.
        #expect(ReleaseDate(milliseconds: 1774281600000) == ReleaseDate(year: 2026, month: 3, day: 24))
        #expect(ReleaseDate(year: 2025).shortText == "2025")
    }

    @Test func albumsAreNewestFirstWithCopiesTogetherAndYearOnlyAfterDated() {
        func album(_ name: String, _ source: MusicSource, _ date: ReleaseDate?) -> SingerAlbum {
            SingerAlbum(source: source, remoteID: "\(name)-\(source.rawValue)", name: name, artist: "谭米洛", date: date)
        }
        let input = [
            album("Old Radio", .appleMusic, ReleaseDate(year: 2019)),
            album("旧电台", .netease, ReleaseDate(year: 2019, month: 4, day: 2)),
            album("纸鹤电台", .qq, ReleaseDate(year: 2025)),
            album("Small Hours", .appleMusic, nil),
            album("纸鹤电台", .netease, ReleaseDate(year: 2025, month: 3, day: 1)),
            album("Paper Crane Radio", .appleMusic, ReleaseDate(year: 2025, month: 3, day: 1)),
            album("纸鹤电台（现场版）", .netease, ReleaseDate(year: 2025, month: 8, day: 9)),
        ]
        let sorted = AlbumOrder.sorted(input).map { "\($0.name)/\($0.source.rawValue)" }
        #expect(sorted == ["纸鹤电台（现场版）/netease",
                           // Same folded name: one group at its newest copy, services in the fixed order.
                           "纸鹤电台/netease", "纸鹤电台/qq",
                           "Paper Crane Radio/appleMusic",
                           "旧电台/netease", "Old Radio/appleMusic",
                           "Small Hours/appleMusic"])
        #expect(AlbumOrder.latest(input)?.name == "纸鹤电台（现场版）")
    }
}
