import Foundation
import Synchronization
import Testing
@testable import AlpacaMusic

@Suite @MainActor struct AppleMusicLyricsTests {
    private func track(_ id: String = "one", title: String = "Original Fixture") -> Track {
        .init(id: "appleMusic:library:\(id)", title: title, artist: "Fixture Author", album: "Fixture Album", duration: 123,
              source: .appleMusic, sourceID: id, appleMusicResourceKind: .librarySong)
    }
    private func directory() -> URL { .temporaryDirectory.appending(path: "AppleLyricsTest-\(UUID().uuidString)") }
    private func native() -> NativeMusicClient { NativeMusicClient(providers: [], credentials: MemoryMusicCredentialStore()) }
    nonisolated private static func response(_ request: URLRequest, title: String = "Original Fixture") throws -> (Data, HTTPURLResponse) {
        let data = try JSONSerialization.data(withJSONObject: ["trackName": title, "artistName": "Fixture Author", "albumName": "Fixture Album", "duration": 123,
            "instrumental": false, "syncedLyrics": "[00:01]An original test phrase\n[00:03]A second test phrase"])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    @Test func automaticLookupRestoresSyncedLyricsAfterSwitchAndRestartWithoutNetwork() async throws {
        let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
        let calls = Mutex(0)
        let online = LRCLIBClient(transport: { request in calls.withLock { $0 += 1 }; return try Self.response(request) })
        let controller = LyricsController(client: native(), directory: location, online: online)
        await controller.load(track: track())
        #expect(controller.status == .ready && controller.document?.timing == .line)
        #expect(controller.document?.sourceDescription == "LRCLIB")
        #expect(controller.document?.activeIndex(at: 3.1) == 1)
        await controller.load(track: nil)
        await controller.load(track: track())
        #expect(calls.withLock { $0 } == 1)
        let restored = LyricsController(client: native(), directory: location, online: LRCLIBClient(transport: { _ in
            Issue.record("A valid disk cache must not query the network"); throw URLError(.notConnectedToInternet)
        }))
        await restored.load(track: track())
        #expect(restored.document == controller.document)
    }
    @Test func disabledAutomaticLookupAndOtherSourcesDoNotSendMetadataButExplicitLookupWorks() async throws {
        let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
        let calls = Mutex(0)
        let online = LRCLIBClient(transport: { request in calls.withLock { $0 += 1 }; return try Self.response(request) })
        let controller = LyricsController(client: native(), directory: location, online: online, automaticAppleMusicLookup: false)
        await controller.load(track: track())
        #expect(calls.withLock { $0 } == 0 && controller.status == .unavailable)
        var local = track(); local.source = .url
        await controller.load(track: local)
        #expect(calls.withLock { $0 } == 0)
        await controller.load(track: track())
        await controller.lookupOnline(for: track())
        #expect(controller.status == .ready && calls.withLock { $0 } == 1)
        await controller.lookupOnline(for: track("other"))
        #expect(calls.withLock { $0 } == 1)
    }
    @Test func songChangeAndDisabledPreferenceDiscardLateResult() async throws {
        let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
        let gate = AppleLyricsGate()
        let online = LRCLIBClient(transport: { request in await gate.wait(); return try Self.response(request) })
        let controller = LyricsController(client: native(), directory: location, online: online)
        let loading = Task { await controller.load(track: track()) }
        for _ in 0..<100 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await gate.entered)
        await controller.setAutomaticAppleMusicLookup(false)
        await gate.release(); await loading.value
        #expect(controller.status == .unavailable && controller.document == nil)
        let storage = LyricsStorage(directory: location)
        #expect(await storage.cachedOnline(for: track()) == nil)
    }
    @Test func slowEarlierSongCannotReplaceNewSelection() async throws {
        let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
        let gate = AppleLyricsGate()
        let online = LRCLIBClient(transport: { request in await gate.wait(); return try Self.response(request) })
        let controller = LyricsController(client: native(), directory: location, online: online)
        let old = Task { await controller.load(track: track()) }
        for _ in 0..<100 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(5)) }
        var other = track("two"); other.source = .url
        await controller.load(track: other)
        await gate.release(); await old.value
        #expect(controller.status == .unavailable && controller.document == nil)
    }
    @Test func importedLyricsWinAndCacheRequiresSameTrackMetadataAndFreshAge() async throws {
        let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        let storage = LyricsStorage(directory: location)
        let doc = try LyricsParser.parse("[00:01]Online fixture", sourceDescription: "LRCLIB")
        try await storage.cacheOnline(doc, for: track())
        #expect(await storage.cachedOnline(for: track("another")) == nil)
        #expect(await storage.cachedOnline(for: track(title: "Different version")) == nil)
        #expect(await storage.cachedOnline(for: track(), now: Date().addingTimeInterval(31 * 24 * 3600)) == nil)
        let file = location.appending(path: "imported.lrc")
        try Data("[00:01]Manual fixture wins".utf8).write(to: file)
        _ = try await storage.importFile(file, for: track())
        let controller = LyricsController(client: native(), directory: location, online: LRCLIBClient(transport: { _ in
            Issue.record("Manual import must not query online"); throw URLError(.notConnectedToInternet)
        }))
        await controller.load(track: track())
        #expect(controller.document?.sourceDescription == L10n.string("手动导入"))
        #expect(controller.document?.lines.first?.text == "Manual fixture wins")
    }
    @Test func damagedOnlineCacheRefetchesWithoutTouchingManualImports() async throws {
        let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
        let storage = LyricsStorage(directory: location)
        try await storage.cacheOnline(LyricsParser.parse("[00:01]Cache fixture", sourceDescription: "LRCLIB"), for: track())
        let folder = location.appending(path: "lyrics/online")
        let file = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        try Data("damaged".utf8).write(to: file)
        let controller = LyricsController(client: native(), directory: location, online: LRCLIBClient(transport: { request in try Self.response(request) }))
        await controller.load(track: track())
        #expect(controller.status == .ready)
        #expect(await storage.cachedOnline(for: track()) != nil)
    }
    @Test func semanticallyDamagedCacheIsIgnored() async throws {
        let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
        let storage = LyricsStorage(directory: location)
        let original = try LyricsParser.parse("[00:01]Valid fixture", sourceDescription: "LRCLIB")
        try await storage.cacheOnline(original, for: track())
        let folder = location.appending(path: "lyrics/online")
        let file = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        let saved = try Data(contentsOf: file)
        let invalid = [
            LyricDocument(lines: [], timing: .line, sourceDescription: "LRCLIB"),
            LyricDocument(lines: [.init(id: 0, text: "A", start: 2), .init(id: 0, text: "B", start: 3)], timing: .line, sourceDescription: "LRCLIB"),
            LyricDocument(lines: [.init(id: 0, text: "A", start: 2), .init(id: 1, text: "B", start: 1)], timing: .line, sourceDescription: "LRCLIB")
        ]
        for doc in invalid {
            var record = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
            record["document"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(doc))
            try JSONSerialization.data(withJSONObject: record).write(to: file)
            #expect(await storage.cachedOnline(for: track()) == nil)
        }
    }
    @Test func networkFailureExplainsCauseWithoutBlockingPlaybackModel() async {
        let location = directory(); defer { try? FileManager.default.removeItem(at: location) }
        let controller = LyricsController(client: native(), directory: location, online: LRCLIBClient(transport: { _ in throw URLError(.timedOut) }))
        await controller.load(track: track())
        #expect(controller.status == .failed)
        #expect(controller.error == L10n.string("LRCLIB 查询超时，请稍后重试。"))
        #expect(controller.document == nil)
    }
}

private actor AppleLyricsGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
