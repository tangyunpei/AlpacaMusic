import Foundation
import Testing
@testable import AlpacaMusic

@MainActor struct SodaLivePlaybackTests {
    /// Opt-in checks the complete native AVPlayer path, beyond a successful
    /// metadata request or a CDN byte-range probe. Uses a public audition only.
    @Test func publicAuditionActuallyPlaysAndFeedsRealAudioAnalysis() async throws {
        guard ProcessInfo.processInfo.environment["ALPACA_LIVE_SODA"] == "1" else { return }
        let track = try #require(try await SodaShareClient().importShare("7079108541549643812").tracks.first)
        let domain = "AlpacaSodaPlaybackTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let player = PlayerController(sources: SourceService(), defaults: defaults)
        defer { player.shutdown() }
        player.setVolume(0.001)
        await player.play(track)
        let deadline = Date().addingTimeInterval(20)
        var observedPCM = false
        while Date() < deadline {
            let levels = player.readLevels()
            if player.status == .playing && player.position > 0.15 && levels.available && levels.waveform.contains(where: { $0 != 0 }) {
                observedPCM = true; break
            }
            if player.status == .failed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(observedPCM, "Official public audition: status=\(player.status), error=\(player.error ?? "none")")
        #expect(player.current?.sodaPlayback?.isPreview == true)
        #expect(player.duration > 0 && player.duration < 90)
        #expect(abs(player.duration - (player.current?.sodaPlayback?.duration ?? 0)) < 0.1, "Measured AAC duration should match the declared audition within encoder padding")
        if observedPCM {
            let prepared = try #require(player.current)
            let payload = try #require(try await SodaDirectProvider().lyrics(prepared, cookies: []))
            let document = try LyricsParser.parse(payload, sourceDescription: "汽水音乐")
            #expect(document.timing == .word && !document.lines.isEmpty)
            #expect(document.lines.allSatisfy { ($0.start ?? -1) >= 0 && ($0.end ?? 100000) <= (prepared.sodaPlayback?.duration ?? 0) })
        }
    }
}
