import Foundation
import Synchronization
import Testing
@testable import AlpacaMusic

struct LyricsParserTests {
    @Test func lrcOffsetsRepeatedTimestampsAndSeekAreDeterministic() throws {
        let document = try LyricsParser.parse("[ti:Fixture]\n[ar:Author]\n[offset:500]\n[00:02.00][00:08.50]Repeated\n[00:04.000]Middle")
        #expect(document.timing == .line)
        #expect(document.lines.map(\.start) == [1.5, 3.5, 8])
        #expect(document.title == "Fixture"); #expect(document.artist == "Author")
        #expect(document.activeIndex(at: 1) == nil)
        #expect(document.activeIndex(at: 8.4) == 2)
        #expect(document.activeIndex(at: 2) == 0)
        #expect(document.activeIndex(at: 3.5) == 1)
        #expect(document.activeIndex(at: .nan) == nil)
    }
    @Test func enhancedWordsKeepAbsoluteTimingAndRepeatedLineShift() throws {
        let document = try LyricsParser.parse("[00:02][00:12]<00:02.00>One <00:02.50>two<00:03.00>\n[00:20]End")
        #expect(document.timing == .word)
        #expect(document.lines[0].text == "One two")
        #expect(document.lines[0].words.map(\.start) == [2, 2.5])
        #expect(document.lines[0].words.map(\.end) == [2.5, 3])
        #expect(document.lines[1].words.map(\.start) == [12, 12.5])
        #expect(document.activeWordIndex(in: 0, at: 2.75) == 1)
        #expect(document.activeWordIndex(in: 0, at: 3.1) == nil)
        #expect(throws: MusicError.self) { try LyricsParser.parse("[00:01]<00:03>later<00:02>earlier") }
    }
    @Test func srtKeepsExplicitGapsAndMultilineCues() throws {
        let document = try LyricsParser.parse("1\r\n00:00:01,250 --> 00:00:02,500\r\nFirst\r\nSecond\r\n\r\n2\r\n00:00:04,000 --> 00:00:06,000\r\nLast", format: .srt)
        #expect(document.lines[0].text == "First\nSecond")
        #expect(document.activeIndex(at: 1.25) == 0)
        #expect(document.activeIndex(at: 2.5) == nil)
        #expect(document.activeIndex(at: 4) == 1)
        #expect(document.activeIndex(at: 6) == nil)
        #expect(throws: MusicError.self) { try LyricsParser.parse("1\n00:00:04,000 --> 00:00:02,000\nInvalid", format: .srt) }
    }
    @Test func plainLyricsNeverFabricateTimingAndOversizedTextIsRejected() throws {
        let document = try LyricsParser.parse("A plain fixture\nAnother line", format: .plain)
        #expect(document.timing == .plain)
        #expect(document.lines.allSatisfy { $0.start == nil && $0.end == nil && $0.words.isEmpty })
        #expect(document.activeIndex(at: 500) == nil)
        #expect(throws: MusicError.self) { try LyricsParser.parse(String(repeating: "x", count: LyricsParser.maximumBytes + 1)) }
        #expect(throws: MusicError.self) { try LyricsParser.parse(String(repeating: "[00:01]", count: 100) + String(repeating: "x", count: 22_000)) }
    }
    @Test func translationUsesMatchingTimestampsAndInstrumentalHasNoInventedText() throws {
        let document = try LyricsParser.parse(LyricsPayload(text: "[00:01]One\n[00:02]Two", translation: "[00:01]译文\n[00:10]Unrelated"), sourceDescription: "Fixture")
        #expect(document.lines[0].translation == "译文")
        #expect(document.lines[1].translation == nil)
        let instrumental = try LyricsParser.parse(LyricsPayload(text: "", isInstrumental: true), sourceDescription: "Fixture")
        #expect(instrumental.isInstrumental); #expect(instrumental.lines.isEmpty)
        #expect(instrumental.activeIndex(at: 0) == nil)
    }
}

private actor LyricsFixtureProvider: DirectMusicProvider {
    nonisolated let source = MusicSource.netease
    private var waitIDs = Set<String>()
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var calls: [String: Int] = [:]
    func hold(_ id: String) { waitIDs.insert(id) }
    func waiting(_ id: String) -> Bool { continuations[id] != nil }
    func release(_ id: String) { continuations.removeValue(forKey: id)?.resume(); waitIDs.remove(id) }
    func profile(cookies: [MusicSessionCookie]) async throws -> MusicAccountProfile {
        .init(id: cookies.first?.value ?? "fixture", displayName: "Fixture")
    }
    func search(_ query: String, cookies: [MusicSessionCookie]) async throws -> [Track] { [] }
    func playlists(profile: MusicAccountProfile, cookies: [MusicSessionCookie]) async throws -> [RemoteMusicPlaylist] { [] }
    func tracks(in playlist: RemoteMusicPlaylist, cookies: [MusicSessionCookie]) async throws -> [Track] { [] }
    func resolve(_ track: Track, cookies: [MusicSessionCookie]) async throws -> URL { throw MusicError.message("Fixture has no audio") }
    func lyrics(_ track: Track, cookies: [MusicSessionCookie]) async throws -> LyricsPayload? {
        let id = track.sourceID ?? track.id
        calls[id, default: 0] += 1
        let account = cookies.first?.value ?? "fixture"
        if waitIDs.contains(id) { await withCheckedContinuation { continuations[id] = $0 } }
        return .init(text: "[00:01]Fixture \(id) \(account)")
    }
}
private func lyricTrack(_ id: String, source: MusicSource = .netease) -> Track {
    .init(id: "\(source.rawValue):\(id)", title: "Fixture", artist: "", album: "", duration: 100, source: source, sourceID: id)
}
private func lyricCookies(_ value: String) -> [MusicSessionCookie] { [.init(name: "MUSIC_U", value: value, domain: ".music.163.com")] }

@Suite(.serialized) @MainActor struct LyricsControllerTests {
    private func directory() throws -> URL {
        let value = URL.temporaryDirectory.appending(path: "Alpaca 歌词 Test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
    private func waitFor(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 { if await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await condition())
    }
    @Test func oldSongCompletionCannotReplaceTheNewSong() async throws {
        let location = try directory(); defer { try? FileManager.default.removeItem(at: location) }
        let provider = LyricsFixtureProvider(), client = NativeMusicClient(providers: [provider], credentials: MemoryMusicCredentialStore())
        _ = try await client.connect(.netease, cookies: lyricCookies("account-A"))
        let controller = LyricsController(client: client, directory: location)
        await provider.hold("1")
        let old = Task { await controller.load(track: lyricTrack("1")) }
        try await waitFor { await provider.waiting("1") }
        await controller.load(track: lyricTrack("2"))
        #expect(controller.document?.lines.first?.text == "Fixture 2 account-A")
        await provider.release("1"); await old.value
        #expect(controller.document?.lines.first?.text == "Fixture 2 account-A")
    }
    @Test func accountChangesInvalidateCacheAndAutomaticallyRecoverAfterLogin() async throws {
        let location = try directory(); defer { try? FileManager.default.removeItem(at: location) }
        let provider = LyricsFixtureProvider(), client = NativeMusicClient(providers: [provider], credentials: MemoryMusicCredentialStore())
        let controller = LyricsController(client: client, directory: location)
        await controller.load(track: lyricTrack("1"))
        #expect(controller.status == .failed)
        _ = try await client.connect(.netease, cookies: lyricCookies("account-A"))
        try await waitFor { controller.document?.lines.first?.text == "Fixture 1 account-A" }
        let before = await provider.calls["1"]
        await controller.load(track: lyricTrack("2")); await controller.load(track: lyricTrack("1"))
        #expect(await provider.calls["1"] == before)
        _ = try await client.connect(.netease, cookies: lyricCookies("account-B"))
        try await waitFor { controller.document?.lines.first?.text == "Fixture 1 account-B" }
        try await client.disconnect(.netease)
        try await waitFor { controller.document == nil && controller.status != .loading }
    }
    @Test func staleAccountResponseCannotSurviveReconnect() async throws {
        let provider = LyricsFixtureProvider(), client = NativeMusicClient(providers: [provider], credentials: MemoryMusicCredentialStore())
        _ = try await client.connect(.netease, cookies: lyricCookies("account-A"))
        let scope = try await client.lyricsScope(for: .netease)
        await provider.hold("1")
        let pending = Task { try await client.lyrics(lyricTrack("1"), scope: scope) }
        try await waitFor { await provider.waiting("1") }
        _ = try await client.connect(.netease, cookies: lyricCookies("account-B"))
        await provider.release("1")
        await #expect(throws: CancellationError.self) { try await pending.value }
        await #expect(throws: CancellationError.self) { try await client.lyrics(lyricTrack("1"), scope: scope) }
    }
    @Test func importedLyricsPersistForTheirTargetWithoutReplacingAnotherPlayingSong() async throws {
        let location = try directory(); defer { try? FileManager.default.removeItem(at: location) }
        let file = location.appending(path: "fixture.lrc")
        try Data("[00:01]User fixture".utf8).write(to: file)
        let client = NativeMusicClient(providers: [], credentials: MemoryMusicCredentialStore())
        let controller = LyricsController(client: client, directory: location)
        let first = lyricTrack("first", source: .appleMusic), second = lyricTrack("second", source: .appleMusic)
        await controller.load(track: second)
        try await controller.importFile(url: file, for: first)
        #expect(controller.document == nil)
        await controller.load(track: first)
        #expect(controller.document?.sourceDescription == "手动导入")
        #expect(controller.document?.lines.first?.text == "User fixture")
        let restored = LyricsController(client: client, directory: location)
        await restored.load(track: first)
        #expect(restored.document == controller.document)
        await restored.load(track: second); #expect(restored.document == nil)
        let importedDirectory = location.appending(path: "lyrics")
        let records = try FileManager.default.contentsOfDirectory(at: importedDirectory, includingPropertiesForKeys: nil)
        #expect(records.count == 1)
        try Data("corrupt".utf8).write(to: records[0])
        await restored.load(track: first)
        #expect(restored.document == nil); #expect(restored.status == .failed)
        #expect(FileManager.default.fileExists(atPath: records[0].path(percentEncoded: false)))
    }
    @Test func bookmarkedLocalTrackFindsOnlyItsOwnNonSymlinkSidecar() async throws {
        let location = try directory(); defer { try? FileManager.default.removeItem(at: location) }
        let audio = location.appending(path: "sound.wav"), lyrics = location.appending(path: "sound.lrc")
        try Data().write(to: audio); try Data("[00:01]Sidecar fixture".utf8).write(to: lyrics)
        var track = lyricTrack("local", source: .local)
        track.url = audio
        track.bookmark = try audio.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
        let storage = LyricsStorage(directory: location)
        #expect(try await storage.sidecar(for: track)?.lines.first?.text == "Sidecar fixture")
        try FileManager.default.removeItem(at: lyrics)
        let other = location.appending(path: "unrelated.lrc"); try Data("Other fixture".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: lyrics, withDestinationURL: other)
        #expect(try await storage.sidecar(for: track) == nil)
    }
}

struct LyricsProviderTests {
    @Test func neteaseLyricsUseExistingScopedSessionAndRespectNoLyricFlag() async throws {
        let requests = Mutex<[URLRequest]>([])
        let provider = NeteaseDirectProvider(http: NativeMusicHTTP(transport: { request in
            requests.withLock { $0.append(request) }
            let body = #"{"code":200,"lrc":{"lyric":"[00:01]Fixture"},"tlyric":{"lyric":"[00:01]译文"}}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }))
        let value = try await provider.lyrics(lyricTrack("1"), cookies: lyricCookies("fixture-session"))
        #expect(value?.text == "[00:01]Fixture"); #expect(value?.translation == "[00:01]译文")
        let request = try #require(requests.withLock { $0.first })
        #expect(request.url?.host == "music.163.com"); #expect(request.url?.path == "/weapi/song/lyric")
        #expect(request.httpMethod == "POST")
        let instrumental = NeteaseDirectProvider(http: NativeMusicHTTP(transport: { request in
            (Data(#"{"code":200,"nolyric":true}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }))
        #expect(try await instrumental.lyrics(lyricTrack("1"), cookies: lyricCookies("fixture"))?.isInstrumental == true)
    }
    @Test func qqLyricsDecodeBase64OnlyAndDoNotTreatMalformedTextAsLyrics() async throws {
        let cookies = [MusicSessionCookie(name: "uin", value: "o12345678", domain: ".y.qq.com"), MusicSessionCookie(name: "qqmusic_key", value: "fixture", domain: ".y.qq.com")]
        for malformed in [false, true] {
            let provider = QQDirectProvider(http: NativeMusicHTTP(transport: { request in
                #expect(request.url?.host == "c.y.qq.com")
                #expect(request.url?.path == "/lyric/fcgi-bin/fcg_query_lyric_new.fcg")
                #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "songmid" && $0.value == "fixtureMID" } == true)
                let value: [String: Any] = ["code": 0, "lyric": malformed ? "not-base64!" : Data("[00:01]Fixture".utf8).base64EncodedString(), "trans": ""]
                return (try JSONSerialization.data(withJSONObject: value), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }))
            if malformed {
                await #expect(throws: MusicError.self) { try await provider.lyrics(lyricTrack("fixtureMID", source: .qq), cookies: cookies) }
            } else { #expect(try await provider.lyrics(lyricTrack("fixtureMID", source: .qq), cookies: cookies)?.text == "[00:01]Fixture") }
        }
    }
}
