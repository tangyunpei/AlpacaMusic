import Foundation
import Synchronization
import Testing
@testable import AlpacaMusic

private func onlineTrack(_ id: String = "fixture") -> Track {
    .init(id: "appleMusic:library:\(id)", title: "Fixture Song", artist: "Fixture Artist", album: "Fixture Album", duration: 123, source: .appleMusic, sourceID: id, appleMusicResourceKind: .librarySong)
}
private func onlineResponse(_ request: URLRequest, status: Int = 200, headers: [String: String] = [:], changes: [String: Any] = [:]) throws -> (Data, HTTPURLResponse) {
    var object: [String: Any] = ["trackName": "Fixture Song", "artistName": "Fixture Artist", "albumName": "Fixture Album", "duration": 123, "instrumental": false, "syncedLyrics": "[00:01]Original fixture line", "plainLyrics": "Original fixture line"]
    for (key, value) in changes { object[key] = value }
    return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
}
private actor OnlineFixtureGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private func clientSearchResponse(_ request: URLRequest, candidates: [[String: Any]]) throws -> (Data, HTTPURLResponse) {
    let objects = try candidates.map { changes in
        let (data, _) = try onlineResponse(request, changes: changes)
        return try JSONSerialization.jsonObject(with: data)
    }
    return (try JSONSerialization.data(withJSONObject: objects), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}

struct LRCLIBTests {
    @Test func exactGetCarriesOnlyMetadataAndCachesSuccessfulSignature() async throws {
        let requests = Mutex<[URLRequest]>([])
        let client = LRCLIBClient(transport: { request in
            requests.withLock { $0.append(request) }
            return try onlineResponse(request)
        })
        let first = try await client.lookup(onlineTrack())
        #expect(first?.sourceDescription == "LRCLIB")
        #expect(first?.timing == .line)
        #expect(first?.lines.first?.text == "Original fixture line")
        _ = try await client.lookup(onlineTrack("same-metadata-other-resource"))
        let sent = requests.withLock { $0 }
        #expect(sent.count == 1)
        let request = try #require(sent.first)
        #expect(request.url?.host == "lrclib.net"); #expect(request.url?.path() == "/api/get")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(Set(query.map(\.name)) == ["track_name", "artist_name", "album_name", "duration"])
        #expect(query.first { $0.name == "track_name" }?.value == "Fixture Song")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("https://byalpaca.dev") == true)
        #expect(!request.httpShouldHandleCookies)
    }
    @Test(arguments: ["trackName", "artistName", "duration"])
    func searchNeverRelaxesTitleArtistOrTwoSecondDurationTolerance(_ field: String) async throws {
        let client = LRCLIBClient(transport: { request in
            let changes: [String: Any] = field == "duration" ? [field: 125.01] : [field: "Different fixture"]
            return request.url?.path() == "/api/search"
                ? try clientSearchResponse(request, candidates: [changes]) : try onlineResponse(request, changes: changes)
        })
        #expect(try await client.lookup(onlineTrack()) == nil)
    }
    @Test func currentAppleMetadataFindsExactDurationAfterGetReturnsAnOutOfToleranceRecord() async throws {
        var track = onlineTrack()
        track.title = "爱爱爱"; track.artist = "方大同"; track.album = "爱爱爱"; track.duration = 213.267
        let calls = Mutex<[URLRequest]>([])
        let client = LRCLIBClient(transport: { request in
            calls.withLock { $0.append(request) }
            let common: [String: Any] = ["trackName": "爱爱爱", "artistName": "方大同", "albumName": "爱爱爱"]
            func record(_ duration: Double, album: String = "爱爱爱", text: String) -> [String: Any] {
                common.merging(["duration": duration, "albumName": album, "syncedLyrics": text]) { _, new in new }
            }
            if request.url?.path() == "/api/get" {
                // Real observed metadata for LRCLIB record 19184253. The lyric
                // content below is original test text, never the song's lyrics.
                return try onlineResponse(request, changes: record(211.24, text: "[00:01]Rejected duration fixture"))
            }
            let candidates = [
                record(211.24, text: "[00:01]Rejected duration fixture"),
                record(213, album: "this love", text: "[00:01]Album alias fixture"),
                record(214, album: "timeless concert live 2009", text: "[00:01]Live fixture"),
                // Real observed metadata for 23159207; delta is 0.000333s.
                record(213.266667, text: "[00:01]Exact recording fixture")
            ] + Array(repeating: record(180, text: "[00:01]Different duration fixture"), count: 16)
            return try clientSearchResponse(request, candidates: candidates)
        })
        let found = try await client.lookup(track)
        #expect(found?.lines.first?.text == "Exact recording fixture")
        let requests = calls.withLock { $0 }
        #expect(requests.map { $0.url!.path() } == ["/api/get", "/api/search"])
        let search = try #require(requests.last)
        let items = URLComponents(url: search.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(Set(items.map(\.name)) == ["track_name", "artist_name"])
        #expect(search.value(forHTTPHeaderField: "Cookie") == nil && search.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(!search.httpShouldHandleCookies)
    }
    @Test func simplifiedTraditionalFormsAndWidthAreEquivalentWithoutRemovingVersionLabels() async throws {
        var track = onlineTrack()
        track.title = "爱与风 （Live）"; track.artist = "歌手陈"; track.album = "现场录音"
        let exact = LRCLIBClient(transport: { request in
            try onlineResponse(request, changes: ["trackName": "愛與風 (live)", "artistName": "歌手陳", "albumName": "現場錄音"])
        })
        #expect(try await exact.lookup(track)?.sourceDescription == "LRCLIB")
        let missingVersion = LRCLIBClient(transport: { request in
            let value: [String: Any] = ["trackName": "愛與風", "artistName": "歌手陳", "albumName": "現場錄音"]
            if request.url?.path() == "/api/get" { return try onlineResponse(request, changes: value) }
            return try clientSearchResponse(request, candidates: [value])
        })
        #expect(try await missingVersion.lookup(track) == nil)
    }
    @Test func traditionalSearchVariantIsBoundedAndCanFindEquivalentMetadata() async throws {
        var track = onlineTrack(); track.title = "纸上的海"; track.artist = "陈先生"; track.album = "夜间书信"
        let requests = Mutex<[URLRequest]>([])
        let client = LRCLIBClient(transport: { request in
            requests.withLock { $0.append(request) }
            if request.url?.path() == "/api/get" { return try onlineResponse(request, status: 404) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if query.first(where: { $0.name == "track_name" })?.value == "紙上的海" {
                return try clientSearchResponse(request, candidates: [["trackName": "紙上的海", "artistName": "陳先生", "albumName": "夜間書信"]])
            }
            return try clientSearchResponse(request, candidates: [])
        })
        #expect(try await client.lookup(track)?.sourceDescription == "LRCLIB")
        #expect(requests.withLock { $0.count } == 3)
    }
    @Test func uniqueAlbumAliasCanMatchButAmbiguousCandidatesCannot() async throws {
        let unique = LRCLIBClient(transport: { request in
            if request.url?.path() == "/api/get" { return try onlineResponse(request, status: 404) }
            return try clientSearchResponse(request, candidates: [["albumName": "Regional Album Name"]])
        })
        #expect(try await unique.lookup(onlineTrack())?.sourceDescription == "LRCLIB")
        for sameAlbum in [true, false] {
            let ambiguous = LRCLIBClient(transport: { request in
                if request.url?.path() == "/api/get" { return try onlineResponse(request, status: 404) }
                return try clientSearchResponse(request, candidates: [
                    ["albumName": sameAlbum ? "Fixture Album" : "Album A", "duration": 123],
                    ["albumName": sameAlbum ? "Fixture Album" : "Album B", "duration": 123.1]
                ])
            })
            #expect(try await ambiguous.lookup(onlineTrack()) == nil)
        }
    }
    @Test func fullSearchPageCannotEstablishAUniqueAlbumAlias() async throws {
        let client = LRCLIBClient(transport: { request in
            if request.url?.path() == "/api/get" { return try onlineResponse(request, status: 404) }
            let values: [[String: Any]] = [["albumName": "Regional Album Name"]] + Array(repeating: ["trackName": "Different Fixture"], count: 19)
            return try clientSearchResponse(request, candidates: values)
        })
        #expect(try await client.lookup(onlineTrack()) == nil)
    }
    @Test(arguments: ["Live", "Remix", "Acoustic", "现场", "演唱會", "Remastered"])
    func albumFallbackCannotEraseRecordingEdition(_ edition: String) async throws {
        let client = LRCLIBClient(transport: { request in
            if request.url?.path() == "/api/get" { return try onlineResponse(request, status: 404) }
            return try clientSearchResponse(request, candidates: [["albumName": "Fixture Album (\(edition))"]])
        })
        #expect(try await client.lookup(onlineTrack()) == nil)
    }
    @Test func durationToleranceAndPlainLyricsNeverInventSynchronization() async throws {
        let client = LRCLIBClient(transport: { request in
            try onlineResponse(request, changes: ["trackName": " fixture song ", "duration": 125, "syncedLyrics": NSNull()])
        })
        let value = try await client.lookup(onlineTrack())
        #expect(value?.timing == .plain)
        #expect(value?.activeIndex(at: 100) == nil)
        let instrumental = LRCLIBClient(transport: { request in try onlineResponse(request, changes: ["instrumental": true]) })
        #expect(try await instrumental.lookup(onlineTrack())?.isInstrumental == true)
    }
    @Test func missingMetadataSendsNothingAndNotFoundUsesOnlyBoundedStructuredSearch() async throws {
        let calls = Mutex(0)
        let client = LRCLIBClient(transport: { request in
            calls.withLock { $0 += 1 }; return try onlineResponse(request, status: 404)
        })
        var missing = onlineTrack(); missing.artist = " "
        await #expect(throws: MusicError.self) { try await client.lookup(missing) }
        #expect(calls.withLock { $0 } == 0)
        #expect(try await client.lookup(onlineTrack()) == nil)
        #expect(calls.withLock { $0 } == 2)
    }
    @Test(arguments: [429, 503])
    func retryAfterOnNonJSONResponsePreventsAnotherRequest(_ status: Int) async throws {
        let calls = Mutex(0)
        let client = LRCLIBClient(transport: { request in
            calls.withLock { $0 += 1 }
            return (Data("edge unavailable".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "60"])!)
        })
        await #expect(throws: MusicError.self) { try await client.lookup(onlineTrack()) }
        await #expect(throws: MusicError.self) { try await client.lookup(onlineTrack()) }
        #expect(calls.withLock { $0 } == 1)
    }
    @Test func cancelledSongUnwindsBeforeNextSongQueriesWithoutABusyFailure() async throws {
        let gate = OnlineFixtureGate(), starts = Mutex<[ContinuousClock.Instant]>([])
        let client = LRCLIBClient(transport: { request in
            let first = starts.withLock { values in values.append(ContinuousClock.now); return values.count == 1 }
            if first { await gate.wait() }
            let title = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "track_name" }!.value!
            return try onlineResponse(request, changes: ["trackName": title])
        })
        let pending = Task { try await client.lookup(onlineTrack()) }
        for _ in 0..<100 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.entered)
        var second = onlineTrack("second"); second.title = "Second Fixture Song"
        let next = Task { try await client.lookup(second) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(starts.withLock { $0.count } == 1)
        pending.cancel()
        let released = ContinuousClock.now
        await gate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(try await next.value?.sourceDescription == "LRCLIB")
        let observed = starts.withLock { $0 }
        #expect(observed.count == 2)
        #expect(released.duration(to: observed[1]) >= .milliseconds(250))
    }
    @Test func cancellingAQueuedSongSendsNoRequest() async throws {
        let gate = OnlineFixtureGate(), calls = Mutex(0)
        let client = LRCLIBClient(transport: { request in
            calls.withLock { $0 += 1 }; await gate.wait(); return try onlineResponse(request)
        })
        let first = Task { try await client.lookup(onlineTrack()) }
        for _ in 0..<100 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(5)) }
        let queued = Task { try await client.lookup(onlineTrack("queued")) }
        try await Task.sleep(for: .milliseconds(35)); queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        await gate.release(); _ = try await first.value
        #expect(calls.withLock { $0 } == 1)
    }
    @Test func fallbackRequestsRemainThrottledAndSearchRetryAfterStopsFurtherRequests() async throws {
        let starts = Mutex<[ContinuousClock.Instant]>([])
        let client = LRCLIBClient(transport: { request in
            starts.withLock { $0.append(ContinuousClock.now) }
            if request.url?.path() == "/api/get" { return try onlineResponse(request, status: 404) }
            return (Data("rate limited".utf8), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "60"])!)
        })
        await #expect(throws: MusicError.self) { try await client.lookup(onlineTrack()) }
        await #expect(throws: MusicError.self) { try await client.lookup(onlineTrack("second")) }
        let observed = starts.withLock { $0 }
        #expect(observed.count == 2)
        #expect(observed[0].duration(to: observed[1]) >= .milliseconds(250))
    }
    @Test func cancellationAndUnexpectedResponseHostDoNotPublishLyrics() async throws {
        let gate = OnlineFixtureGate()
        let client = LRCLIBClient(transport: { request in await gate.wait(); return try onlineResponse(request) })
        let pending = Task { try await client.lookup(onlineTrack()) }
        for _ in 0..<100 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(5)) }
        pending.cancel(); await gate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        let unexpected = LRCLIBClient(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "https://example.com/api/get")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: MusicError.self) { try await unexpected.lookup(onlineTrack()) }
    }
    @Test func searchCannotRedirectEvenToTheSameHostDifferentEndpoint() async throws {
        let client = LRCLIBClient(transport: { request in
            if request.url?.path() == "/api/get" { return try onlineResponse(request, status: 404) }
            return (Data(), HTTPURLResponse(url: URL(string: "https://lrclib.net/api/get")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: MusicError.self) { try await client.lookup(onlineTrack()) }
    }
}
