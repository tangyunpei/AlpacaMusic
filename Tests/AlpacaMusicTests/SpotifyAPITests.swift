import Foundation
import Testing
@testable import AlpacaMusic

@Suite struct SpotifyAPITests {
    @Test func profilePrefersStableAccountIDAndDoesNotRequireRemovedFields() async throws {
        let stub = SpotifyAPIStub([.init(json: #"{"account_id":"stableAccount","id":"legacyID","display_name":"Listener"}"#)])
        let client = SpotifyAPIClient(transport: { try await stub.respond($0) })
        let profile = try await client.profile(accessToken: "fixture-token")
        #expect(profile.id == "stableAccount" && profile.displayName == "Listener")
        let request = try #require(await stub.requests.first)
        #expect(request.url?.path == "/v1/me")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.httpShouldHandleCookies == false)
    }

    @Test func olderProfileStillWorksWithoutDisplayNameOrProduct() async throws {
        let client = SpotifyAPIClient(transport: { request in reply(request, json: #"{"id":"legacyAccount"}"#) })
        let profile = try await client.profile(accessToken: "fixture")
        #expect(profile.id == "legacyAccount" && profile.displayName == "legacyAccount")
    }

    @Test func searchAggregatesThreePagesOfTenWithoutUsingDeprecatedBulkFetch() async throws {
        let stub = SpotifyAPIStub((0..<3).map { page in
            let items = (0..<10).map { trackJSON("T\(page * 10 + $0)") }.joined(separator: ",")
            return .init(json: "{\"tracks\":{\"items\":[\(items)],\"offset\":\(page * 10),\"total\":100,\"next\":\"https://api.spotify.com/v1/search?offset=\((page + 1) * 10)\"}}")
        })
        let client = SpotifyAPIClient(transport: { try await stub.respond($0) })
        let tracks = try await client.search("特别的歌", accessToken: "fixture", limit: 100)
        #expect(tracks.count == 30)
        #expect(tracks.first?.sourceID == "T0" && tracks.last?.sourceID == "T29")
        #expect(tracks.allSatisfy { $0.source == .spotify && $0.url == nil })
        let requests = await stub.requests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.url?.path == "/v1/search" && query($0, "limit") == "10" && query($0, "q") == "特别的歌" })
        #expect(requests.map { query($0, "offset") } == ["0", "10", "20"])
    }

    @Test func playlistsUseNewCountFieldAndAcceptMetadataOnlyAndLegacyResponses() async throws {
        let stub = SpotifyAPIStub([
            .init(json: #"{"items":[{"id":"A","name":"Own","items":{"total":4},"images":[{"url":"https://i.scdn.co/a"}]}],"offset":0,"total":3,"next":"https://api.spotify.com/v1/me/playlists?offset=1&limit=50"}"#),
            .init(json: #"{"items":[{"id":"B","name":"Followed"},{"id":"C","name":"Legacy","tracks":{"total":6}}],"offset":1,"total":3,"next":null}"#)
        ])
        let client = SpotifyAPIClient(transport: { try await stub.respond($0) })
        let playlists = try await client.playlists(accessToken: "fixture")
        #expect(playlists.map(\.trackCount) == [4, 0, 6])
        #expect(playlists.first?.artworkURL?.host == "i.scdn.co")
        #expect(await stub.requests.count == 2)
    }

    @Test func renamedPlaylistItemsSkipNullLocalAndEpisodesWhileAcceptingLegacyTrack() async throws {
        let entries = ["{\"item\":\(trackJSON("New"))}", "{\"track\":\(trackJSON("Old"))}", "null", "{\"item\":null}",
                       "{\"is_local\":true,\"item\":\(trackJSON("Local"))}", #"{"item":{"id":"Episode","type":"episode","name":"Podcast"}}"#,
                       "{\"item\":\(trackJSON("Blocked", playable: false))}"]
        let stub = SpotifyAPIStub([.init(json: "{\"items\":[\(entries.joined(separator: ","))],\"offset\":0,\"total\":7,\"next\":null}")])
        let client = SpotifyAPIClient(transport: { try await stub.respond($0) })
        let tracks = try await client.tracks(in: playlist, accessToken: "fixture")
        #expect(tracks.map(\.sourceID) == ["New", "Old", "Blocked"])
        #expect(tracks.last?.unavailable == true)
        #expect(tracks.first?.duration == 123.456)
        #expect(tracks.first?.artist == "Artist")
        #expect(await stub.requests.first?.url?.path == "/v1/playlists/List123/items")
    }

    @Test func savedTracksStillUseCurrentReadEndpoint() async throws {
        let client = SpotifyAPIClient(transport: { request in
            #expect(request.url?.path == "/v1/me/tracks")
            return reply(request, json: "{\"items\":[{\"track\":\(trackJSON("Saved"))}],\"offset\":0,\"total\":1,\"next\":null}")
        })
        #expect(try await client.savedTracks(accessToken: "fixture").first?.sourceID == "Saved")
    }

    @Test(arguments: ["https://evil.example/v1/me/playlists?offset=1", "https://api.spotify.com.evil.example/v1/me/playlists?offset=1", "http://api.spotify.com/v1/me/playlists?offset=1", "https://api.spotify.com:8443/v1/me/playlists?offset=1", "https://api.spotify.com/v1/me?offset=1", "https://user@api.spotify.com/v1/me/playlists?offset=1"])
    func paginationRejectsUntrustedDestinationBeforeSendingBearer(_ next: String) async throws {
        let stub = SpotifyAPIStub([.init(json: "{\"items\":[{\"id\":\"A\",\"name\":\"A\"}],\"offset\":0,\"total\":2,\"next\":\"\(next)\"}")])
        let client = SpotifyAPIClient(transport: { try await stub.respond($0) })
        await #expect(throws: SpotifyAPIError.unsafeAddress) { try await client.playlists(accessToken: "fixture") }
        #expect(await stub.requests.count == 1)
    }

    @Test(arguments: ["null", "\"https://api.spotify.com/v1/me/playlists?limit=50&offset=0\"", "\"https://api.spotify.com/v1/me/playlists?offset=1&offset=2\""])
    func truncatedOrCyclingCollectionIsNeverReturnedAsComplete(_ next: String) async throws {
        let stub = SpotifyAPIStub([.init(json: "{\"items\":[{\"id\":\"A\",\"name\":\"A\"}],\"offset\":0,\"total\":2,\"next\":\(next)}")])
        let client = SpotifyAPIClient(transport: { try await stub.respond($0) })
        await #expect(throws: SpotifyAPIError.incompleteCollection) { try await client.playlists(accessToken: "fixture") }
        #expect(await stub.requests.count == 1)
    }

    @Test func playbackHandlesInactiveAndCurrentDeviceWithoutAudioURL() async throws {
        let device = #"{"id":"Device123","name":"Mac","type":"Computer","is_active":true,"is_restricted":false,"volume_percent":42,"supports_volume":true}"#
        let stub = SpotifyAPIStub([
            .init(json: "", status: 204),
            .init(json: "{\"is_playing\":true,\"progress_ms\":3210,\"device\":\(device),\"item\":\(trackJSON("Playing"))}"),
            .init(json: "{\"devices\":[\(device),{\"id\":null,\"name\":\"Restricted\",\"is_restricted\":true}]}")
        ])
        let client = SpotifyAPIClient(transport: { try await stub.respond($0) })
        #expect(try await client.playbackState(accessToken: "fixture") == nil)
        let state = try #require(try await client.playbackState(accessToken: "fixture"))
        #expect(state.isPlaying && state.progress == 3.21 && state.duration == 123.456)
        #expect(state.trackID == "Playing" && state.deviceID == "Device123" && state.deviceName == "Mac")
        #expect(state.volume == 0.42 && state.supportsVolume && state.item?.url == nil)
        let devices = try await client.devices(accessToken: "fixture")
        #expect(devices.count == 2 && devices[1].id == nil && devices[1].isRestricted)
    }

    @Test func playbackControlsTargetTheChosenDeviceAndUseMilliseconds() async throws {
        let stub = SpotifyAPIStub(Array(repeating: .init(json: "", status: 204), count: 5))
        let client = SpotifyAPIClient(transport: { try await stub.respond($0) })
        try await client.play(trackID: "Track123", deviceID: "Device123", position: 1.5, accessToken: "fixture")
        try await client.pause(deviceID: "Device123", accessToken: "fixture")
        try await client.seek(to: 9.125, deviceID: "Device123", accessToken: "fixture")
        try await client.setVolume(0.42, deviceID: "Device123", accessToken: "fixture")
        try await client.play(deviceID: "Device123", accessToken: "fixture")
        let requests = await stub.requests
        #expect(requests.allSatisfy { $0.httpMethod == "PUT" && query($0, "device_id") == "Device123" })
        let bodyData = try #require(requests[0].httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["uris"] as? [String] == ["spotify:track:Track123"] && body["position_ms"] as? Int == 1500)
        #expect(query(requests[2], "position_ms") == "9125")
        #expect(query(requests[3], "volume_percent") == "42")
        #expect(requests[4].httpBody == nil)
    }

    @Test(arguments: [(401, "登录已失效"), (403, "自己创建或参与协作"), (503, "HTTP 503")])
    func errorsAreContextualAndNeverExposeRawServerContent(_ status: Int, _ expected: String) async throws {
        let client = SpotifyAPIClient(transport: { request in reply(request, json: #"{"error":{"message":"secret token private-user@example.com"}}"#, status: status) })
        do {
            _ = try await client.tracks(in: playlist, accessToken: "fixture-private-token")
            Issue.record("HTTP failure unexpectedly succeeded")
        } catch {
            #expect(error.localizedDescription.contains(expected))
            #expect(!error.localizedDescription.contains("secret") && !error.localizedDescription.contains("private-"))
        }
    }

    @Test func missingPlayerHasSpecificActionableError() async throws {
        let client = SpotifyAPIClient(transport: { request in reply(request, json: "{}", status: 404) })
        await #expect(throws: SpotifyAPIError.noActiveDevice) { try await client.play(accessToken: "fixture") }
    }

    @Test func rateLimitWaitsWithoutAutomaticallyReplayingWrites() async throws {
        let stub = SpotifyAPIStub([.init(json: "{}", status: 429, headers: ["Retry-After": "120"])])
        let client = SpotifyAPIClient(transport: { try await stub.respond($0) })
        await #expect(throws: SpotifyAPIError.rateLimited(retryAfter: 120)) { try await client.play(trackID: "Track123", accessToken: "fixture") }
        do { try await client.pause(accessToken: "fixture"); Issue.record("Cooldown ignored") }
        catch let error as SpotifyAPIError {
            if case .rateLimited(let delay) = error { #expect(delay > 110) }
            else { Issue.record("Unexpected cooldown error") }
        }
        #expect(await stub.requests.count == 1)
    }

    @Test func julyQuotaResponseExplainsSharedDeveloperQuota() async throws {
        let stub = SpotifyAPIStub([.init(json: #"{"error":{"status":429,"reason":"QUOTA_EXCEEDED","message":"sensitive body"}}"#, status: 429, headers: ["Retry-After": "180"])])
        let client = SpotifyAPIClient(transport: { try await stub.respond($0) })
        await #expect(throws: SpotifyAPIError.quotaExceeded(retryAfter: 180)) { try await client.profile(accessToken: "fixture") }
        do { _ = try await client.playlists(accessToken: "fixture"); Issue.record("Quota cooldown ignored") }
        catch { #expect(error.localizedDescription.contains("共享调用配额")); #expect(!error.localizedDescription.contains("sensitive")) }
        #expect(await stub.requests.count == 1)
    }

    @Test func invalidInputsNeverReachTheNetwork() async throws {
        let stub = SpotifyAPIStub([])
        let client = SpotifyAPIClient(transport: { try await stub.respond($0) })
        await #expect(throws: SpotifyAPIError.invalidRequest) { try await client.play(trackID: "a/b", accessToken: "fixture") }
        await #expect(throws: SpotifyAPIError.invalidRequest) { try await client.seek(to: .infinity, accessToken: "fixture") }
        await #expect(throws: SpotifyAPIError.invalidRequest) { try await client.setVolume(.nan, accessToken: "fixture") }
        await #expect(throws: SpotifyAPIError.unauthorized) { try await client.profile(accessToken: "token\r\ninjected") }
        #expect(await stub.requests.isEmpty)
    }

    @Test func offOriginResponseAndCancellationRemainDistinctFromLoginFailure() async throws {
        let stub = SpotifyAPIStub([.init(json: "{}", status: 401, responseURL: "https://unrelated.example/v1/me")])
        let client = SpotifyAPIClient(transport: { try await stub.respond($0) })
        await #expect(throws: SpotifyAPIError.unsafeAddress) { try await client.profile(accessToken: "fixture") }
        let cancelled = SpotifyAPIClient(transport: { _ in throw CancellationError() })
        await #expect(throws: CancellationError.self) { try await cancelled.profile(accessToken: "fixture") }
    }

    private var playlist: RemoteMusicPlaylist { .init(id: "List123", name: "Test", trackCount: 0, source: .spotify) }
}

private struct SpotifyAPIStubReply: Sendable {
    let json: String
    var status: Int = 200
    var headers: [String: String]? = nil
    var responseURL: String? = nil
}
private actor SpotifyAPIStub {
    private var replies: [SpotifyAPIStubReply]
    private(set) var requests: [URLRequest] = []
    init(_ replies: [SpotifyAPIStubReply]) { self.replies = replies }
    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw SpotifyAPIError.network }
        let value = replies.removeFirst()
        return (Data(value.json.utf8), HTTPURLResponse(url: value.responseURL.flatMap(URL.init(string:)) ?? request.url!, statusCode: value.status, httpVersion: nil, headerFields: value.headers)!)
    }
}
private func reply(_ request: URLRequest, json: String, status: Int = 200) -> (Data, HTTPURLResponse) {
    (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}
private func query(_ request: URLRequest, _ key: String) -> String? {
    request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == key }?.value
}
private func trackJSON(_ id: String, playable: Bool = true) -> String {
    "{\"id\":\"\(id)\",\"name\":\"Song\",\"type\":\"track\",\"duration_ms\":123456,\"is_playable\":\(playable),\"artists\":[{\"name\":\"Artist\"}],\"album\":{\"name\":\"Album\",\"images\":[{\"url\":\"https://i.scdn.co/cover\"}]}}"
}
