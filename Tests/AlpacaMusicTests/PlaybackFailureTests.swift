import Foundation
import Synchronization
import Testing
@testable import AlpacaMusic

private func failureTrack(_ id: String, source: MusicSource = .netease, unavailable: Bool = false) -> Track {
    Track(id: "\(source.rawValue):\(id)", title: "歌曲 \(id)", artist: "测试艺术家", album: "测试专辑",
          duration: 180, source: source, sourceID: id, unavailable: unavailable)
}

private struct FailureSavedQueue: Encodable {
    var tracks: [Track]
    var currentID: String
    var position: Double
}

@Suite(.serialized) @MainActor
struct PlaybackFailureTests {
    @Test func resolveFailureKeepsItsTrackAndRetriesWithoutAdvancingQueue() async throws {
        let suite = "AlpacaPlaybackFailure.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let requests = Mutex<[String]>([])
        let sources = SourceService(transport: { request in
            let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value ?? ""
            requests.withLock { $0.append(id) }
            throw SourceFailure(message: "平台拒绝了这首歌曲（状态 10006）", status: 10006)
        })
        let player = PlayerController(sources: sources, defaults: defaults)
        defer { player.shutdown() }
        player.sourceConfigurations = [.init(kind: .netease, endpoint: "https://fixture.invalid", enabled: true)]
        let first = failureTrack("111"), second = failureTrack("222")

        await player.play(first, context: [first, second])

        #expect(player.status == .failed)
        #expect(player.current?.id == first.id)
        #expect(player.failure?.track == first)
        #expect(player.failure?.stage == .resolving)
        #expect(player.error == "平台拒绝了这首歌曲（状态 10006）")
        #expect(requests.withLock { $0 } == ["111"])

        await player.retry()
        #expect(requests.withLock { $0 } == ["111", "111"])
        #expect(player.failure?.track == first)

        await player.next()
        #expect(requests.withLock { $0 } == ["111", "111", "222"])
        #expect(player.failure?.track == second)
    }

    @Test func unavailableAttemptPreservesCurrentTrackButRetryTargetsTheAttempt() async throws {
        let suite = "AlpacaUnavailableRetry.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prior = failureTrack("prior", source: .netease)
        defaults.set(try JSONEncoder().encode(FailureSavedQueue(tracks: [prior], currentID: prior.id, position: 42)),
                     forKey: "AlpacaMusic.NativePlayer.queue.v1")
        let requests = Mutex(0)
        let sources = SourceService(transport: { _ in
            requests.withLock { $0 += 1 }
            throw SourceFailure(message: "测试不应请求旧歌曲")
        })
        let player = PlayerController(sources: sources, defaults: defaults)
        defer { player.shutdown() }
        player.sourceConfigurations = [.init(kind: .netease, endpoint: "https://fixture.invalid", enabled: true)]
        player.restoreQueue([prior])
        let attempted = failureTrack("missing", source: .qq, unavailable: true)

        await player.play(attempted)
        await player.retry()

        #expect(player.current == prior)
        #expect(player.status == .paused)
        #expect(player.position == 42)
        #expect(player.failure?.track == attempted)
        #expect(player.failure?.stage == .preparing)
        #expect(player.error?.contains(MusicSource.qq.title) == true)
        #expect(player.error == L10n.string("\(MusicSource.qq.title)当前未提供这首歌曲的可播放资源，请在平台确认歌曲是否仍可播放。"))
        #expect(requests.withLock { $0 } == 0)
    }

    @Test(arguments: [MusicSource.netease, .qq, .appleMusic, .url])
    func unavailableOnlineTrackIsNotDescribedAsALocalFile(_ source: MusicSource) async throws {
        let suite = "AlpacaUnavailableSource.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlayerController(sources: SourceService(), defaults: defaults)
        defer { player.shutdown() }

        await player.play(failureTrack("missing", source: source, unavailable: true))

        #expect(player.current == nil)
        #expect(player.status == .idle)
        #expect(player.failure?.track.source == source)
        #expect(player.error?.contains(source.title) == true)
        #expect(player.error == L10n.string("\(source.title)当前未提供这首歌曲的可播放资源，请在平台确认歌曲是否仍可播放。"))
    }

    @Test func lateFailureFromCancelledTrackCannotReplaceTheNewFailure() async throws {
        let suite = "AlpacaFailureRace.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldStarted = Mutex(false)
        let sources = SourceService(transport: { request in
            let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
            if id == "old" {
                oldStarted.withLock { $0 = true }
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { continuation.resume() }
                }
                throw SourceFailure(message: "旧请求失败")
            }
            throw SourceFailure(message: "新请求失败")
        })
        let player = PlayerController(sources: sources, defaults: defaults)
        defer { player.shutdown() }
        player.sourceConfigurations = [.init(kind: .netease, endpoint: "https://fixture.invalid", enabled: true)]
        let old = failureTrack("old"), newest = failureTrack("new")
        let oldTask = Task { await player.play(old) }
        for _ in 0..<100 {
            if oldStarted.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(oldStarted.withLock { $0 })
        await player.play(newest)
        await oldTask.value

        #expect(player.status == .failed)
        #expect(player.current == newest)
        #expect(player.failure?.track == newest)
        #expect(player.error == "新请求失败")
    }
}
