import Foundation
import Synchronization
import Testing
@testable import AlpacaMusic

/// A signed-in platform that returns fixed search results and lyrics.
private actor WordLyricsProvider: DirectMusicProvider {
    nonisolated let source: MusicSource
    private let results: [Track]
    private let payloads: [String: LyricsPayload]
    private let slowSearch: Bool
    private(set) var searches: [String] = []
    private(set) var lyricRequests = 0
    init(_ source: MusicSource, results: [Track] = [], payloads: [String: LyricsPayload] = [:], slowSearch: Bool = false) {
        self.source = source; self.results = results; self.payloads = payloads; self.slowSearch = slowSearch
    }
    func profile(cookies: [MusicSessionCookie]) async throws -> MusicAccountProfile { .init(id: "fixture", displayName: "Fixture") }
    func search(_ query: String, cookies: [MusicSessionCookie]) async throws -> [Track] {
        searches.append(query)
        if slowSearch { try await Task.sleep(for: .seconds(30)) }
        return results
    }
    func playlists(profile: MusicAccountProfile, cookies: [MusicSessionCookie]) async throws -> [RemoteMusicPlaylist] { [] }
    func tracks(in playlist: RemoteMusicPlaylist, cookies: [MusicSessionCookie]) async throws -> [Track] { [] }
    func resolve(_ track: Track, cookies: [MusicSessionCookie]) async throws -> URL { throw MusicError.message("Fixture has no audio") }
    func lyrics(_ track: Track, cookies: [MusicSessionCookie]) async throws -> LyricsPayload? {
        lyricRequests += 1
        return payloads[track.sourceID ?? ""]
    }
}

/// Counts LRCLIB requests across the transport's concurrent closure.
private final class LRCLIBCalls: Sendable {
    private let count = Mutex(0)
    func record() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

@Suite(.serialized) @MainActor struct AppleMusicWordLyricsTests {
    private func song(title: String = "手绘黑卡", artist: String = "冯允谦", album: String = "手绘黑卡 - Single",
                      duration: Double = 241.005) -> Track {
        .init(id: "appleMusic:library:\(title)", title: title, artist: artist, album: album, duration: duration,
              source: .appleMusic, sourceID: "i.\(title)", appleMusicResourceKind: .librarySong)
    }
    private func candidate(_ source: MusicSource = .netease, id: String = "1", title: String = "手绘黑卡",
                           artist: String = "冯允谦", album: String = "手绘黑卡", duration: Double = 241) -> Track {
        .init(id: "\(source.rawValue):\(id)", title: title, artist: artist, album: album, duration: duration, source: source, sourceID: id)
    }
    /// Three lines, each sung as two measured words.
    private static func wordDocument() -> LyricDocument {
        let lines = (0..<3).map { index -> LyricLine in
            let start = Double(index * 4 + 1)
            return LyricLine(id: index, text: "第\(index)句歌词", start: start, end: start + 3, words: [
                LyricWord(id: 0, text: "第\(index)句", start: start, end: start + 1.5),
                LyricWord(id: 1, text: "歌词", start: start + 1.5, end: start + 3)
            ])
        }
        return LyricDocument(lines: lines, timing: .word, sourceDescription: "")
    }
    private static let wordTimed = LyricsPayload(text: "", document: wordDocument())
    private static let lineTimed = LyricsPayload(text: "[00:01.00]第0句歌词\n[00:05.00]第1句歌词")
    private func directory() -> URL { .temporaryDirectory.appending(path: "AppleWordLyrics-\(UUID().uuidString)") }
    private func signedIn(_ providers: [WordLyricsProvider]) async throws -> NativeMusicClient {
        let client = NativeMusicClient(providers: providers, credentials: MemoryMusicCredentialStore())
        for provider in providers { try await signIn(provider.source, client) }
        return client
    }
    private func signIn(_ source: MusicSource, _ client: NativeMusicClient) async throws {
        let cookie: MusicSessionCookie = source == .qq ? .init(name: "qqmusic_key", value: "fixture", domain: ".qq.com")
            : .init(name: "MUSIC_U", value: "fixture", domain: ".music.163.com")
        _ = try await client.connect(source, cookies: [cookie])
    }
    /// LRCLIB answers `/api/get` with one line-timed song and counts requests.
    nonisolated private static func lrclib(_ calls: LRCLIBCalls) -> LRCLIBClient {
        LRCLIBClient(transport: { request in
            calls.record()
            let data = try JSONSerialization.data(withJSONObject: [
                "trackName": "手绘黑卡", "artistName": "冯允谦", "albumName": "手绘黑卡 - Single", "duration": 241.005,
                "instrumental": false, "syncedLyrics": "[00:01.00]第0句歌词\n[00:05.00]第1句歌词"])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
    }
    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    /// Apple Music and the platforms credit the same recording differently.
    @Test func theSameRecordingMatchesAcrossCreditStyles() {
        let live = song(title: "爱错(feat. 单依纯) [with 单依纯] [Live]", artist: "王力宏", album: "王力宏 Live", duration: 252.94)
        let liveCandidate = candidate(title: "爱错 (Live)", artist: "王力宏 / 单依纯", album: "演唱会", duration: 254)
        #expect(PlatformLyricMatch.matches(for: live, in: [liveCandidate]) == [liveCandidate])
        #expect(PlatformLyricMatch.query(for: live) == "爱错 王力宏")

        let mixed = candidate(.qq, title: "On a SunnyDay", artist: "姜涛", album: "On a SunnyDay", duration: 200)
        #expect(PlatformLyricMatch.matches(for: song(title: "On a SunnyDay", artist: "Keung To 姜涛", album: "On a SunnyDay - Single",
                                                     duration: 200.4), in: [mixed]) == [mixed])
        let duet = candidate(title: "为你揭晓", artist: "林俊杰 / 张艺兴", album: "为你揭晓", duration: 245)
        #expect(PlatformLyricMatch.matches(for: song(title: "为你揭晓", artist: "张艺兴 & 林俊杰", duration: 245.3), in: [duet]) == [duet])
        let traditional = candidate(title: "手繪黑卡", artist: "馮允謙")
        #expect(PlatformLyricMatch.matches(for: song(), in: [traditional]) == [traditional])
    }

    /// Real search results: Apple Music credits "Jay Chou" where QQ Music has
    /// 周杰伦, and NetEase, which lacks his catalog, offers covers and
    /// re-uploads with copied durations under other names.
    @Test func englishCreditsMatchOnlyThePlatformsTopRecording() {
        let anhao = song(title: "暗號", artist: "Jay Chou", album: "七里香", duration: 269.76)
        let qq = [candidate(.qq, id: "q1", title: "暗号", artist: "周杰伦", album: "七里香", duration: 271),
                  candidate(.qq, id: "q2", title: "暗号 (Live)", artist: "周杰伦", album: "2004 无与伦比 演唱会", duration: 287)]
        #expect(PlatformLyricMatch.matches(for: anhao, in: qq).map(\.sourceID) == ["q1"])
        let back = song(title: "爸我回來了", artist: "Jay Chou", album: "范特西", duration: 235.64)
        #expect(PlatformLyricMatch.matches(for: back, in: [candidate(.qq, id: "q3", title: "爸，我回来了", artist: "周杰伦", duration: 235)])
            .map(\.sourceID) == ["q3"])

        let reupload = [candidate(id: "n1", title: "爸 我回来了", artist: "DJ-PPT", duration: 229),
                        candidate(id: "n2", title: "爸我回来了", artist: "麻辣热可可", duration: 97),
                        candidate(id: "n3", title: "爸我回来了", artist: "不知名的猫", duration: 235.759)]
        #expect(PlatformLyricMatch.matches(for: back, in: reupload).isEmpty)
        // Too far apart without an artist to confirm it.
        #expect(PlatformLyricMatch.matches(for: anhao, in: [candidate(.qq, title: "暗号", artist: "周杰伦", duration: 271.5)]).isEmpty)
        // A Latin credit is compared by name, never waved through.
        #expect(PlatformLyricMatch.matches(for: anhao, in: [candidate(title: "暗号", artist: "Yuri", duration: 269.8)]).isEmpty)
        // Covers say so in the title.
        let chantey = song(title: "Chantey", artist: "AKMU", album: "SAILING", duration: 138.1)
        #expect(PlatformLyricMatch.matches(for: chantey, in: [candidate(title: "Chantey（翻自 AKMU）", artist: "小爱吖", duration: 138.32)]).isEmpty)
        let cover = song(title: "Lemon（Cover：米津玄師）", artist: "Akie秋绘", album: "Lemon", duration: 164.2)
        let coverCandidate = candidate(title: "Lemon（翻自 米津玄師）", artist: "Akie秋绘", duration: 164.612)
        #expect(PlatformLyricMatch.matches(for: cover, in: [coverCandidate]) == [coverCandidate])
        let bass = song(title: "빠졌죠", artist: "J.Bass/윤음/타코", album: "빠졌죠", duration: 187.2)
        let bassCandidate = candidate(title: "빠졌죠", artist: "정바스 (J.BASS)", duration: 187.504)
        #expect(PlatformLyricMatch.matches(for: bass, in: [bassCandidate]) == [bassCandidate])
        let dotted = candidate(title: "狂流", artist: "羽·泉", duration: 340.48)
        #expect(PlatformLyricMatch.matches(for: song(title: "狂流", artist: "羽泉", duration: 340.2), in: [dotted]) == [dotted])
    }

    @Test func anotherRecordingOrArtistNeverMatches() {
        let apple = song()
        #expect(PlatformLyricMatch.matches(for: apple, in: [candidate(duration: 243.5)]).isEmpty)
        #expect(PlatformLyricMatch.matches(for: apple, in: [candidate(artist: "冯允")]).isEmpty)
        #expect(PlatformLyricMatch.matches(for: apple, in: [candidate(title: "手绘黑卡 2")]).isEmpty)
        #expect(PlatformLyricMatch.matches(for: apple, in: [candidate(title: "手绘黑卡 (Live)")]).isEmpty)
        #expect(PlatformLyricMatch.matches(for: apple, in: [candidate(album: "手绘黑卡 (Remix)")]).isEmpty)
        #expect(PlatformLyricMatch.matches(for: apple, in: [candidate(duration: 0)]).isEmpty)
        #expect(PlatformLyricMatch.matches(for: song(artist: ""), in: [candidate()]).isEmpty)

        let far = candidate(id: "far", duration: 242.9), near = candidate(id: "near", duration: 241.2)
        #expect(PlatformLyricMatch.matches(for: apple, in: [far, near]).map(\.sourceID) == ["near", "far"])
    }

    @Test func onlyWordTimedLyricsWithinTheSongAreUsable() throws {
        #expect(PlatformLyricMatch.isUsable(Self.wordDocument(), for: song()))
        #expect(!PlatformLyricMatch.isUsable(Self.wordDocument(), for: song(duration: 6)))
        var lines = Self.wordDocument(); lines.timing = .line
        #expect(!PlatformLyricMatch.isUsable(lines, for: song()))
        var sparse = Self.wordDocument()
        for index in sparse.lines.indices.dropFirst() { sparse.lines[index].words = [] }
        #expect(!PlatformLyricMatch.isUsable(sparse, for: song()))
    }

    @Test func appleMusicSongUsesNetEaseWordTimingInsteadOfLRCLIB() async throws {
        let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
        let netease = WordLyricsProvider(.netease, results: [candidate()], payloads: ["1": Self.wordTimed])
        let calls = LRCLIBCalls()
        let controller = LyricsController(client: try await signedIn([netease]), directory: location, online: Self.lrclib(calls))
        await controller.load(track: song())
        #expect(controller.status == .ready && controller.document?.timing == .word)
        #expect(controller.document?.sourceDescription == PlatformLyricMatch.sourceDescription(.netease))
        #expect(controller.document?.lines.first?.words.count == 2)
        #expect(calls.value == 0)
        #expect(await netease.searches == ["手绘黑卡 冯允谦"])
        // A replay in the same session reads the result from memory.
        await controller.load(track: nil); await controller.load(track: song())
        #expect(await netease.searches.count == 1)
        #expect(controller.document?.timing == .word)
        // Signed-in results never reach the disk cache shared with LRCLIB.
        #expect(await LyricsStorage(directory: location).cachedOnline(for: song()) == nil)
    }

    @Test func lineTimedPlatformLyricsFallBackToLRCLIBOnce() async throws {
        let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
        let netease = WordLyricsProvider(.netease, results: [candidate()], payloads: ["1": Self.lineTimed])
        let calls = LRCLIBCalls()
        let controller = LyricsController(client: try await signedIn([netease]), directory: location, online: Self.lrclib(calls))
        await controller.load(track: song())
        #expect(controller.document?.sourceDescription == "LRCLIB" && calls.value == 1)
        await controller.load(track: nil); await controller.load(track: song())
        #expect(await netease.searches.count == 1)
        #expect(controller.document?.sourceDescription == "LRCLIB")
    }

    @Test func qqIsTriedWhenNetEaseHasNoMatch() async throws {
        let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
        let netease = WordLyricsProvider(.netease, results: [candidate(artist: "Someone Else")])
        let qq = WordLyricsProvider(.qq, results: [candidate(.qq, id: "q1")], payloads: ["q1": Self.wordTimed])
        let calls = LRCLIBCalls()
        let controller = LyricsController(client: try await signedIn([netease, qq]), directory: location, online: Self.lrclib(calls))
        await controller.load(track: song())
        #expect(controller.document?.sourceDescription == PlatformLyricMatch.sourceDescription(.qq))
        #expect(await netease.lyricRequests == 0)
        #expect(calls.value == 0)
    }

    @Test func turnedOffOrSignedOutPlatformsAreNeverSearched() async throws {
        let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
        let netease = WordLyricsProvider(.netease, results: [candidate()], payloads: ["1": Self.wordTimed])
        let calls = LRCLIBCalls()
        let off = LyricsController(client: try await signedIn([netease]), directory: location, online: Self.lrclib(calls),
                                   platformWordLyrics: false)
        await off.load(track: song())
        #expect(off.document?.sourceDescription == "LRCLIB")
        #expect(await netease.searches.isEmpty)
        let signedOut = WordLyricsProvider(.netease, results: [candidate()], payloads: ["1": Self.wordTimed])
        let client = NativeMusicClient(providers: [signedOut], credentials: MemoryMusicCredentialStore())
        let controller = LyricsController(client: client, directory: location, online: Self.lrclib(calls))
        await controller.load(track: song())
        #expect(controller.document?.sourceDescription == "LRCLIB")
        #expect(await signedOut.searches.isEmpty)
        // Other sources never search platforms on Apple Music's behalf.
        var local = song(); local.source = .url
        await LyricsController(client: try await signedIn([netease]), directory: location, online: Self.lrclib(calls)).load(track: local)
        #expect(await netease.searches.isEmpty)
    }

    @Test func signingInUpgradesAndSigningOutDropsPlatformLyrics() async throws {
        let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
        let netease = WordLyricsProvider(.netease, results: [candidate()], payloads: ["1": Self.wordTimed])
        let client = NativeMusicClient(providers: [netease], credentials: MemoryMusicCredentialStore())
        let calls = LRCLIBCalls()
        let controller = LyricsController(client: client, directory: location, online: Self.lrclib(calls))
        await controller.load(track: song())
        #expect(controller.document?.sourceDescription == "LRCLIB")
        try await signIn(.netease, client)
        try await waitFor { controller.document?.timing == .word }
        try await client.disconnect(.netease)
        try await waitFor { controller.document?.sourceDescription == "LRCLIB" }
        // The setting switches the current song without a restart.
        try await signIn(.netease, client)
        try await waitFor { controller.document?.timing == .word }
        await controller.setPlatformWordLyrics(false)
        #expect(controller.document?.sourceDescription == "LRCLIB")
        await controller.setPlatformWordLyrics(true)
        #expect(controller.document?.timing == .word)
    }

    @Test func aSlowPlatformFallsBackToLRCLIBAndIsRetriedLater() async throws {
        let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
        let netease = WordLyricsProvider(.netease, results: [candidate()], payloads: ["1": Self.wordTimed], slowSearch: true)
        let calls = LRCLIBCalls()
        let controller = LyricsController(client: try await signedIn([netease]), directory: location, online: Self.lrclib(calls),
                                          platformLookupDeadline: .milliseconds(50))
        let clock = ContinuousClock(), started = clock.now
        await controller.load(track: song())
        #expect(clock.now - started < .seconds(10))
        #expect(controller.document?.sourceDescription == "LRCLIB")
        await controller.load(track: nil); await controller.load(track: song())
        #expect(await netease.searches.count == 2)
    }
}
