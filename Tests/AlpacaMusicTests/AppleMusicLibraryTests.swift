import Foundation
import MusicKit
import Testing
@testable import AlpacaMusic

@MainActor private final class LibraryFixtureTransport {
    var requests: [URLRequest] = []
    var replies: [Data]
    var failureAt: Int?
    var gate: CheckedContinuation<Void, Never>?
    var waits = false
    init(_ replies: [Data]) { self.replies = replies }
    func data(_ request: URLRequest) async throws -> Data {
        requests.append(request)
        if waits { await withCheckedContinuation { gate = $0 } }
        if failureAt == requests.count { throw URLError(.timedOut) }
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        return replies.removeFirst()
    }
}

private func librarySong(_ id: String, playable: Bool = true, type: String = "library-songs") -> [String: Any] {
    var attributes: [String: Any] = ["name": "Song \(id)", "artistName": "Artist", "albumName": "Album",
                                      "durationInMillis": 120_000, "genreNames": [], "trackNumber": 1, "discNumber": 1,
                                      "artwork": ["url": "https://is1-ssl.mzstatic.com/image/{w}x{h}bb.jpg", "width": 1200, "height": 1200]]
    if playable { attributes["playParams"] = ["id": id, "kind": "song", "isLibrary": type == "library-songs"] }
    return ["id": id, "type": type, "href": "/v1/me/library/songs/\(id)", "attributes": attributes]
}
private func libraryPage(_ items: [[String: Any]], next: String? = nil, total: Int? = nil) throws -> Data {
    var value: [String: Any] = ["data": items]
    if let next { value["next"] = next }
    if let total { value["meta"] = ["total": total] }
    return try JSONSerialization.data(withJSONObject: value)
}

@Suite(.serialized) @MainActor struct AppleMusicLibraryTests {
    @Test func allSongPagesPreserveLibraryIDsArtworkAndUnavailableItems() async throws {
        let fixture = try LibraryFixtureTransport([
            libraryPage([librarySong("i.first"), librarySong("i.uploaded", playable: false)], next: "/v1/me/library/songs?offset=2&limit=100", total: 3),
            libraryPage([librarySong("i.last")], total: 3)
        ])
        let client = AppleMusicLibraryClient(transport: fixture.data)
        let tracks = try await client.songs()
        #expect(tracks.map(\.sourceID) == ["i.first", "i.uploaded", "i.last"])
        #expect(tracks.map(\.id) == ["appleMusic:library:i.first", "appleMusic:library:i.uploaded", "appleMusic:library:i.last"])
        #expect(tracks[0].artworkURL?.absoluteString == "https://is1-ssl.mzstatic.com/image/640x640bb.jpg")
        #expect(tracks[0].duration == 120); #expect(!tracks[0].unavailable); #expect(tracks[1].unavailable)
        #expect(fixture.requests.count == 2)
        #expect(fixture.requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil && $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test func playlistPagesAndTracksKeepOriginalOrderIncludingDuplicates() async throws {
        let list = ["id": "p.one", "type": "library-playlists", "attributes": ["name": "Favorites"]] as [String: Any]
        let other = ["id": "p.two", "type": "library-playlists", "attributes": ["name": "Road"]] as [String: Any]
        let fixture = try LibraryFixtureTransport([
            libraryPage([list], next: "/v1/me/library/playlists?offset=1", total: 2), libraryPage([other], total: 2),
            libraryPage([librarySong("i.one"), librarySong("123", type: "songs")], next: "/v1/me/library/playlists/p.one/tracks?offset=2", total: 3),
            libraryPage([librarySong("i.one")], total: 3)
        ])
        let client = AppleMusicLibraryClient(transport: fixture.data)
        let playlists = try await client.playlists()
        #expect(playlists.map(\.id) == ["p.one", "p.two"])
        #expect(playlists[0].trackCount == nil)
        let tracks = try await client.tracks(in: playlists[0])
        #expect(tracks.map(\.sourceID) == ["i.one", "123", "i.one"])
    }

    @Test func laterPageFailureAndMissingRowsNeverReturnPartialSuccess() async throws {
        let first = try libraryPage([librarySong("i.one")], next: "/v1/me/library/songs?offset=1", total: 2)
        let fixture = LibraryFixtureTransport([first]); fixture.failureAt = 2
        do { _ = try await AppleMusicLibraryClient(transport: fixture.data).songs(); Issue.record("Returned truncated library") }
        catch {
            let context = L10n.string("读取\(L10n.string("个人歌曲"))第 \(2) 页（已读取 \(1) 条）")
            #expect(error.localizedDescription == L10n.string("\(context)：\(L10n.string("网络请求超时，请重试。"))"))
        }
        let missing = try LibraryFixtureTransport([libraryPage([librarySong("i.one")], total: 2)])
        await #expect(throws: MusicError.self) { try await AppleMusicLibraryClient(transport: missing.data).songs() }
    }

    @Test func rejectsForeignSkippedRepeatedAndCrossCollectionPagination() async throws {
        for next in ["https://example.com/v1/me/library/songs?offset=1", "/v1/me/library/playlists?offset=1",
                     "/v1/me/library/songs?offset=0", "/v1/me/library/songs?offset=2",
                     "https://user@api.music.apple.com/v1/me/library/songs?offset=1"] {
            let fixture = try LibraryFixtureTransport([libraryPage([librarySong("i.one")], next: next)])
            await #expect(throws: MusicError.self) { try await AppleMusicLibraryClient(transport: fixture.data).songs() }
            #expect(fixture.requests.count == 1)
        }
        let repeated = try LibraryFixtureTransport([
            libraryPage([librarySong("i.one")], next: "/v1/me/library/songs?offset=1"), libraryPage([librarySong("i.one")])
        ])
        await #expect(throws: MusicError.self) { try await AppleMusicLibraryClient(transport: repeated.data).songs() }
    }

    @Test func sizeLimitNeverClaimsACompleteLibrary() async throws {
        let fixture = try LibraryFixtureTransport([libraryPage([librarySong("i.one"), librarySong("i.two")], next: "/v1/me/library/songs?offset=2")])
        await #expect(throws: MusicError.self) { try await AppleMusicLibraryClient(maximumItems: 2, transport: fixture.data).songs() }
        #expect(fixture.requests.count == 1)
        let tooLarge = try LibraryFixtureTransport([libraryPage([], total: 10_001)])
        await #expect(throws: MusicError.self) { try await AppleMusicLibraryClient(transport: tooLarge.data).songs() }
    }

    @Test func unsupportedRowsFailInsteadOfSilentlyDisappearing() async throws {
        var video = librarySong("i.video"); video["type"] = "library-music-videos"
        let fixture = try LibraryFixtureTransport([libraryPage([librarySong("i.one"), video])])
        do { _ = try await AppleMusicLibraryClient(transport: fixture.data).songs(); Issue.record("Silently dropped video") }
        catch {
            let context = L10n.string("Apple Music 第 \(2) 首歌曲")
            #expect(error.localizedDescription == L10n.string("\(context)是当前不支持的非歌曲项目，本次未导入。"))
        }
    }

    @Test func cancelledOrInvalidatedReadCannotFetchAnotherPage() async throws {
        let fixture = try LibraryFixtureTransport([libraryPage([librarySong("i.one")], next: "/v1/me/library/songs?offset=1")])
        fixture.waits = true
        let client = AppleMusicLibraryClient(transport: fixture.data)
        let pending = Task { try await client.songs() }
        while fixture.gate == nil { await Task.yield() }
        pending.cancel(); fixture.gate?.resume()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(fixture.requests.count == 1)

        let invalidated = try LibraryFixtureTransport([libraryPage([librarySong("i.one")], next: "/v1/me/library/songs?offset=1")])
        var valid = true
        let second = AppleMusicLibraryClient { request in
            let result = try await invalidated.data(request); valid = false; return result
        }
        await #expect(throws: CancellationError.self) {
            try await second.songs { if !valid { throw CancellationError() } }
        }
        #expect(invalidated.requests.count == 1)
    }

    @Test func originalLibrarySongDecodesIntoMusicKitWithoutCatalogMapping() async throws {
        let fixture = try LibraryFixtureTransport([libraryPage([librarySong("i.uploaded")])])
        let song = try await AppleMusicLibraryClient(transport: fixture.data).playbackSong(libraryID: "i.uploaded")
        #expect(song.id.rawValue == "i.uploaded"); #expect(song.playParameters != nil)
        #expect(fixture.requests[0].url?.path == "/v1/me/library/songs/i.uploaded")

    }

    @Test func opaqueAndNumericLibraryIdentifiersKeepExplicitNamespacesForPlayback() async throws {
        let opaque = "opaqueID1234" // A fixture, not a real account or song identifier.
        #expect(opaque.count == 12); #expect(!opaque.hasPrefix("i."))
        let fixture = try LibraryFixtureTransport([
            libraryPage([librarySong(opaque), librarySong("123"), librarySong("123", type: "songs")]),
            libraryPage([librarySong(opaque)]), libraryPage([librarySong("123")])
        ])
        let client = AppleMusicLibraryClient(transport: fixture.data)
        let tracks = try await client.songs()
        #expect(tracks.map(\.sourceID) == [opaque, "123", "123"])
        #expect(tracks.map(\.appleMusicResourceKind) == [.librarySong, .librarySong, .catalogSong])
        #expect(tracks.map(\.id) == ["appleMusic:library:\(opaque)", "appleMusic:library:123", "appleMusic:123"])
        #expect(try tracks.map { try AppleMusicLibraryClient.playbackResource(for: $0) } == [.librarySong, .librarySong, .catalogSong])
        for track in tracks.prefix(2) {
            let song = try await client.playbackSong(libraryID: #require(track.sourceID))
            #expect(song.id.rawValue == track.sourceID); #expect(song.playParameters != nil)
        }
        #expect(fixture.requests[1].url?.path == "/v1/me/library/songs/\(opaque)")
        #expect(fixture.requests[2].url?.path == "/v1/me/library/songs/123")
    }

    @Test func legacyRecordsUseOnlyPreviouslySupportedRoutesAndNeverGuessNewOpaqueKind() throws {
        var track = Track(id: "appleMusic:123", title: "Legacy", artist: "", album: "", duration: 0, source: .appleMusic, sourceID: "123")
        #expect(try AppleMusicLibraryClient.playbackResource(for: track) == .catalogSong)
        track.sourceID = "i.previous"
        #expect(try AppleMusicLibraryClient.playbackResource(for: track) == .librarySong)
        track.sourceID = "opaqueID1234"
        #expect(throws: MusicError.self) { try AppleMusicLibraryClient.playbackResource(for: track) }
        track.appleMusicResourceKind = .librarySong
        #expect(try AppleMusicLibraryClient.playbackResource(for: track) == .librarySong)
        track.sourceID = "abc/../songs"
        #expect(throws: MusicError.self) { try AppleMusicLibraryClient.playbackResource(for: track) }
    }

    @Test func libraryPlaybackRejectsWrongIdentityMissingPermissionAndInvalidIDs() async throws {
        for resource in [librarySong("i.other"), librarySong("i.one", playable: false)] {
            let fixture = try LibraryFixtureTransport([libraryPage([resource])])
            await #expect(throws: MusicError.self) { try await AppleMusicLibraryClient(transport: fixture.data).playbackSong(libraryID: "i.one") }
        }
        let fixture = LibraryFixtureTransport([])
        for id in ["", "..", "i.abc/../../catalog", "i.abc?token=secret"] {
            await #expect(throws: MusicError.self) { try await AppleMusicLibraryClient(transport: fixture.data).playbackSong(libraryID: id) }
        }
        #expect(fixture.requests.isEmpty)
    }

    @Test(arguments: [MusicTokenRequestError.unknown, .permissionDenied, .userTokenRevoked, .userNotSignedIn,
                      .privacyAcknowledgementRequired, .developerTokenRequestFailed, .userTokenRequestFailed])
    func tokenErrorsHaveSafeDistinctReasonsAndPageContext(_ failure: MusicTokenRequestError) async throws {
        var count = 0
        let page = try libraryPage([librarySong("i.secretSongID")], next: "/v1/me/library/songs?offset=1")
        let client = AppleMusicLibraryClient { _ in
            count += 1
            if count == 1 { return page }
            throw failure
        }
        do { _ = try await client.songs(); Issue.record("Token error was swallowed") }
        catch {
            let description = error.localizedDescription
            #expect(description.contains(failure.rawValue))
            let context = L10n.string("读取\(L10n.string("个人歌曲"))第 \(2) 页（已读取 \(1) 条）")
            let expected: String
            switch failure {
            case .unknown: expected = L10n.string("系统未说明 Apple Music 认证失败的具体原因，请稍后重试（unknown）。")
            case .permissionDenied: expected = L10n.string("本应用未获 Apple Music 访问许可，请在系统设置检查媒体与 Apple Music 权限（permissionDenied）。")
            case .userTokenRevoked: expected = L10n.string("当前账户的 Apple Music 授权已失效，请在本应用重新连接（userTokenRevoked）。")
            case .userNotSignedIn: expected = L10n.string("Apple Music 尚未登录，请先在音乐 App 中登录订阅账户（userNotSignedIn）。")
            case .privacyAcknowledgementRequired: expected = L10n.string("Apple Music 需要确认隐私提示，请打开音乐 App 完成确认后重试（privacyAcknowledgementRequired）。")
            case .developerTokenRequestFailed: expected = L10n.string("系统未能获取本应用的 Apple Music 认证，请检查网络及 MusicKit 配置后重试（developerTokenRequestFailed）。")
            case .userTokenRequestFailed: expected = L10n.string("系统未能获取当前账户的 Apple Music 授权，请检查音乐 App 的登录及网络后重试（userTokenRequestFailed）。")
            @unknown default: expected = L10n.string("系统返回尚未识别的 Apple Music 认证错误，请稍后重试（unrecognizedMusicTokenError）。")
            }
            #expect(description == L10n.string("\(context)：\(expected)"))
            #expect(!description.contains("secretSongID")); #expect(!description.contains("https://"))
        }
        #expect(count == 2) // Do not retry authorization failures automatically.
    }

    @Test func missingArtistDoesNotDiscardAnIdentifiedSong() async throws {
        var item = librarySong("i.unnamedArtist", playable: false)
        var attributes = item["attributes"] as! [String: Any]; attributes.removeValue(forKey: "artistName")
        item["attributes"] = attributes
        let fixture = try LibraryFixtureTransport([libraryPage([item])])
        let tracks = try await AppleMusicLibraryClient(transport: fixture.data).songs()
        #expect(tracks.count == 1); #expect(tracks[0].sourceID == "i.unnamedArtist")
        #expect(tracks[0].artist.isEmpty); #expect(tracks[0].unavailable)
    }

    @Test func invalidRowsReportGlobalPositionAndStaticFieldDetailsWithoutValues() async throws {
        for problem in ["identity", "attributes", "name"] {
            var item = librarySong("i.privateIdentity")
            if problem == "identity" { item["id"] = "private invalid identity" }
            if problem == "attributes" { item.removeValue(forKey: "attributes") }
            if problem == "name" {
                var attributes = item["attributes"] as! [String: Any]; attributes["name"] = "  "
                item["attributes"] = attributes
            }
            let fixture = try LibraryFixtureTransport([
                libraryPage([librarySong("i.first")], next: "/v1/me/library/songs?offset=1"), libraryPage([item])
            ])
            do { _ = try await AppleMusicLibraryClient(transport: fixture.data).songs(); Issue.record("Invalid row was accepted") }
            catch {
                let description = error.localizedDescription
                let context = L10n.string("Apple Music 第 \(2) 首歌曲")
                let expected: String
                switch problem {
                case "identity":
                    let idLength = "private invalid identity".count
                    expected = L10n.string("\(context)标识不能作为安全的资源路径（曲库类型：\(L10n.string("是"))，长度：\(idLength)），本次未导入。")
                case "attributes": expected = L10n.string("\(context)缺少歌曲资料（attributes），本次未导入。")
                default: expected = L10n.string("\(context)缺少歌曲名称（name），本次未导入。")
                }
                #expect(description == expected)
                #expect(!description.contains("private"))
            }
        }
    }
}
