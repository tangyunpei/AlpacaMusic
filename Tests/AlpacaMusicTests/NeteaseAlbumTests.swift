import Foundation
import Testing
@testable import AlpacaMusic

@Suite struct NeteaseAlbumTests {
    private var cookies: [MusicSessionCookie] {
        [.init(name: "MUSIC_U", value: "fixture-session", domain: ".music.163.com")]
    }
    private var profile: MusicAccountProfile { .init(id: "123", displayName: "Fixture") }
    private var album: RemoteMusicAlbum {
        .init(id: "42", name: "Saved album", artist: "Saved artist", trackCount: 3,
              artworkURL: URL(string: "https://p1.music.126.net/saved.jpg"), source: .netease)
    }
    private func provider(_ fixture: NEAlbumFixture) -> NeteaseDirectProvider {
        NeteaseDirectProvider(http: NativeMusicHTTP(transport: { request in try await fixture.respond(request) }))
    }

    @Test func collectionReadsEveryPageAndPreservesMetadata() async throws {
        let fixture = NEAlbumFixture([
            .init(path: "/weapi/album/sublist", json: #"{"code":200,"count":2,"hasMore":true,"data":[{"id":42,"name":"First album","artists":[{"name":"One"},{"name":"Two"}],"size":3,"picUrl":"https://p1.music.126.net/album.jpg"}]}"#),
            .init(path: "/weapi/album/sublist", json: #"{"code":200,"count":2,"hasMore":false,"data":[{"id":"43","name":"Second album","artist":{"name":"Three"},"songCount":6}]}"#)
        ])
        let albums = try await provider(fixture).albums(profile: profile, cookies: cookies)
        #expect(albums.map(\.id) == ["42", "43"])
        #expect(albums.map(\.artist) == ["One / Two", "Three"])
        #expect(albums.map(\.trackCount) == [3, 6])
        #expect(albums.first?.artworkURL?.absoluteString == "https://p1.music.126.net/album.jpg")
        #expect(albums.allSatisfy { $0.source == .netease })
        #expect(await fixture.count == 2)
        let requests = await fixture.requests
        #expect(requests.allSatisfy { $0.url?.host == "music.163.com" && $0.httpMethod == "POST" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "MUSIC_U=fixture-session" })
    }

    @Test func declaredCountContinuesAfterShortPagesWithoutHasMore() async throws {
        let fixture = NEAlbumFixture([
            .init(path: "/weapi/album/sublist", json: #"{"code":200,"count":2,"data":[{"id":1,"name":"First"}]}"#),
            .init(path: "/weapi/album/sublist", json: #"{"code":200,"count":2,"data":[{"id":2,"name":"Second"}]}"#)
        ])
        #expect(try await provider(fixture).albums(profile: profile, cookies: cookies).map(\.id) == ["1", "2"])
        #expect(await fixture.count == 2)
    }

    @Test func terminalRepeatedPageIsRejectedRatherThanSilentlyCompleting() async throws {
        let fixture = NEAlbumFixture([
            .init(path: "/weapi/album/sublist", json: #"{"code":200,"hasMore":true,"data":[{"id":1}]}"#),
            .init(path: "/weapi/album/sublist", json: #"{"code":200,"hasMore":false,"data":[{"id":1}]}"#)
        ])
        await #expect(throws: MusicError.self) { try await provider(fixture).albums(profile: profile, cookies: cookies) }
        #expect(await fixture.count == 2)
    }

    @Test func malformedAndContradictoryCollectionResponsesFail() async {
        let responses = [
            #"{"code":200,"count":0}"#,
            #"{"code":200,"count":2,"hasMore":false,"data":[{"id":1}]}"#,
            #"{"code":200,"count":1,"hasMore":true,"data":[{"id":1}]}"#,
            #"{"code":200,"count":2,"hasMore":true,"data":[]}"#,
            #"{"code":200,"count":-1,"data":[]}"#
        ]
        for json in responses {
            let fixture = NEAlbumFixture([.init(path: "/weapi/album/sublist", json: json)])
            await #expect(throws: MusicError.self) { try await provider(fixture).albums(profile: profile, cookies: cookies) }
            #expect(await fixture.count == 1)
        }
    }

    @Test func collectionChangingDuringPaginationDoesNotProducePartialSuccess() async {
        let fixture = NEAlbumFixture([
            .init(path: "/weapi/album/sublist", json: #"{"code":200,"count":3,"hasMore":true,"data":[{"id":1}]}"#),
            .init(path: "/weapi/album/sublist", json: #"{"code":200,"count":2,"hasMore":false,"data":[{"id":2}]}"#)
        ])
        await #expect(throws: MusicError.self) { try await provider(fixture).albums(profile: profile, cookies: cookies) }
    }

    @Test func emptyCollectionIsAValidCompleteResult() async throws {
        let fixture = NEAlbumFixture([.init(path: "/weapi/album/sublist", json: #"{"code":200,"count":0,"hasMore":false,"data":[]}"#)])
        #expect(try await provider(fixture).albums(profile: profile, cookies: cookies).isEmpty)
    }

    @Test func albumTracksKeepOrderUnavailableRowsAndMetadataFallbacks() async throws {
        let fixture = NEAlbumFixture([.init(path: "/weapi/v1/album/42", json: #"{"code":200,"album":{"id":42,"name":"Fresh album","size":3,"artist":{"name":"Album artist"},"picUrl":"https://p1.music.126.net/fresh.jpg"},"songs":[{"id":300,"name":"Opening","dt":125000,"ar":[{"name":"Track artist"}],"al":{"name":"Specific album","picUrl":"https://p1.music.126.net/track.jpg"}},{"id":100,"name":"Removed","st":-1},{"id":200,"name":"Closing","privilege":{"id":200,"st":-200}}]}"#)])
        let tracks = try await provider(fixture).tracks(in: album, cookies: cookies)
        #expect(tracks.map(\.sourceID) == ["300", "100", "200"])
        #expect(tracks.map(\.title) == ["Opening", "Removed", "Closing"])
        #expect(tracks.map(\.unavailable) == [false, true, true])
        #expect(tracks.map(\.artist) == ["Track artist", "Album artist", "Album artist"])
        #expect(tracks.map(\.album) == ["Specific album", "Fresh album", "Fresh album"])
        #expect(tracks[0].duration == 125)
        #expect(tracks[0].artworkURL?.lastPathComponent == "track.jpg")
        #expect(tracks[1].artworkURL?.lastPathComponent == "fresh.jpg")
        #expect(await fixture.count == 1)
    }

    @Test func freshAlbumCountSupersedesStaleSavedCount() async throws {
        let fixture = NEAlbumFixture([.init(path: "/weapi/v1/album/42", json: #"{"code":200,"album":{"id":42,"size":2},"songs":[{"id":300,"name":"One"},{"id":100,"name":"Two"}]}"#)])
        let tracks = try await provider(fixture).tracks(in: album, cookies: cookies)
        #expect(tracks.count == 2)
        #expect(tracks.allSatisfy { $0.album == "Saved album" && $0.artist == "Saved artist" })
        #expect(tracks.allSatisfy { $0.artworkURL?.lastPathComponent == "saved.jpg" })
    }

    @Test func absentTracksAreNotAssumedToBeDeleted() async {
        let fixture = NEAlbumFixture([.init(path: "/weapi/v1/album/42", json: #"{"code":200,"album":{"id":42,"size":3},"songs":[{"id":300,"name":"Only available row"}]}"#)])
        do {
            _ = try await provider(fixture).tracks(in: album, cookies: cookies)
            Issue.record("Expected incomplete album to fail")
        } catch {
            #expect(error.localizedDescription == L10n.string("网易云专辑标记有 \(String(3)) 首，但返回 \(String(1)) 首，无法确认完整曲目，本次未导入"))
        }
    }

    @Test func duplicateMismatchedAndMissingAlbumContentFail() async {
        let responses = [
            #"{"code":200,"album":{"id":42,"size":2},"songs":[{"id":1},{"id":1}]}"#,
            #"{"code":200,"album":{"id":99,"size":0},"songs":[]}"#,
            #"{"code":200,"album":{"id":42,"size":0}}"#,
            #"{"code":200,"songs":[]}"#
        ]
        for json in responses {
            let fixture = NEAlbumFixture([.init(path: "/weapi/v1/album/42", json: json)])
            await #expect(throws: MusicError.self) { try await provider(fixture).tracks(in: album, cookies: cookies) }
        }
    }

    @Test func invalidSourceAndIdentityDoNotSendRequests() async {
        let fixture = NEAlbumFixture([])
        var wrongSource = album
        wrongSource.source = .appleMusic
        var wrongID = album
        wrongID.id = "42/other"
        await #expect(throws: MusicError.self) { try await provider(fixture).tracks(in: wrongSource, cookies: cookies) }
        await #expect(throws: MusicError.self) { try await provider(fixture).tracks(in: wrongID, cookies: cookies) }
        #expect(await fixture.count == 0)
    }

    @Test func cancellationStaysCancellationForBothAlbumOperations() async {
        let value = NeteaseDirectProvider(http: NativeMusicHTTP(transport: { _ in throw CancellationError() }))
        await #expect(throws: CancellationError.self) { try await value.albums(profile: profile, cookies: cookies) }
        await #expect(throws: CancellationError.self) { try await value.tracks(in: album, cookies: cookies) }
    }
}

private actor NEAlbumFixture {
    struct Reply: Sendable { var path: String; var json: String }
    private let replies: [Reply]
    private(set) var requests: [URLRequest] = []
    var count: Int { requests.count }
    init(_ replies: [Reply]) { self.replies = replies }
    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let index = requests.count
        requests.append(request)
        guard index < replies.count, request.url?.path == replies[index].path, let url = request.url else {
            throw MusicError.message("Unexpected album fixture request")
        }
        return (Data(replies[index].json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
