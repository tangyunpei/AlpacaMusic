import Foundation
import Testing
@testable import AlpacaMusic

private func song(_ id: String, unavailable: Bool = false) -> Track {
    Track(id: id, title: id, artist: "Artist", album: "Album", duration: 28, source: .url, url: URL(string: "https://audio.example/\(id).wav"), unavailable: unavailable)
}
struct PlayerQueueTests {
    @Test func queueDeduplicatesAndMoves() {
        var queue = PlaybackQueue(); queue.select(song("a"), context: [song("a"), song("b"), song("a"), song("c")]); queue.enqueue(song("a"))
        #expect(queue.tracks.map(\.id) == ["a", "b", "c"])
        queue.move("c", direction: -1); #expect(queue.tracks.map(\.id) == ["a", "c", "b"])
        queue.move("a", direction: -1); #expect(queue.tracks.first?.id == "a")
    }
    @Test func skipsMissingAndStopsAtEnd() {
        var queue = PlaybackQueue(); queue.select(song("a"), context: [song("a"), song("missing", unavailable: true), song("b")])
        #expect(queue.next(shuffle: false, repeatMode: .off)?.id == "b")
        #expect(queue.next(shuffle: false, repeatMode: .off) == nil)
        #expect(queue.currentID == "b")
    }
    @Test func repeatAllWrapsAndManualNextDoesNotRepeatOne() {
        var queue = PlaybackQueue(); queue.select(song("b"), context: [song("a"), song("b")])
        #expect(queue.next(shuffle: false, repeatMode: .all)?.id == "a")
        #expect(queue.next(shuffle: false, repeatMode: .one)?.id == "b")
    }
    @Test func shuffleVisitsEachSongOnceAndPreviousUsesHistory() {
        var queue = PlaybackQueue(); queue.select(song("a"), context: [song("a"), song("b"), song("c")])
        #expect(queue.next(shuffle: true, repeatMode: .off, randomUnit: 0.99)?.id == "c")
        #expect(queue.next(shuffle: true, repeatMode: .off, randomUnit: 0.99)?.id == "b")
        #expect(queue.next(shuffle: true, repeatMode: .off) == nil)
        #expect(queue.previous(repeatMode: .off)?.id == "c")
        #expect(queue.previous(repeatMode: .off)?.id == "a")
    }
    @Test func explicitPlayNextOverridesShuffle() {
        var queue = PlaybackQueue(); queue.select(song("a"), context: [song("a"), song("b"), song("c"), song("d")]); queue.playNext(song("b"))
        #expect(queue.next(shuffle: true, repeatMode: .off, randomUnit: 0.99)?.id == "b")
    }
    @Test func removingCurrentSelectsSuccessorAndCleansHistory() {
        var queue = PlaybackQueue(); queue.select(song("a"), context: [song("a"), song("b"), song("c")]); _ = queue.next(shuffle: false, repeatMode: .off)
        #expect(queue.remove("b")?.id == "c")
        #expect(queue.history == ["a"])
        _ = queue.remove("a"); #expect(queue.previous(repeatMode: .off) == nil)
        #expect(queue.remove("c") == nil); #expect(queue.currentID == nil)
    }
    @Test func unavailableQueueCannotStartAndSingleRepeatIsStable() {
        var queue = PlaybackQueue(); queue.select(song("missing", unavailable: true))
        #expect(queue.next(shuffle: true, repeatMode: .all) == nil)
        queue.select(song("a"), context: [song("a")]); #expect(queue.next(shuffle: true, repeatMode: .all)?.id == "a")
    }
}
struct AudioAnalyzerTests {
    @Test func detectsActualFrequencyAndSilenceExpires() async throws {
        let analyzer = AudioAnalyzer()
        let rate = 44100.0, bin = 4, frequency = rate / 2048 * Double(bin)
        let samples = (0..<4096).map { Float(sin(2 * Double.pi * frequency * Double($0) / rate) * 0.35) }
        analyzer.ingest(samples: samples, sampleRate: rate)
        try await Task.sleep(for: .milliseconds(180))
        let levels = analyzer.levels()
        #expect(levels.available)
        #expect(levels.energy > 0)
        #expect(levels.spectrum.count == 1024)
        let peak = levels.spectrum.enumerated().max { $0.element < $1.element }?.offset
        #expect(peak == bin)
        try await Task.sleep(for: .milliseconds(500))
        #expect(!analyzer.levels().available)
        #expect(analyzer.levels().energy == 0)
    }
    @Test func resetDiscardsOldAudioAndInvalidSamples() async throws {
        let analyzer = AudioAnalyzer(); analyzer.ingest(samples: [Float](repeating: .nan, count: 2048), sampleRate: 44100)
        try await Task.sleep(for: .milliseconds(100)); let levels = analyzer.levels()
        #expect(levels.energy == 0); #expect(levels.spectrum.allSatisfy { $0.isFinite })
        analyzer.reset(); #expect(!analyzer.levels().available)
    }
}
struct OriginalAudioTests {
    @Test func demoWAVHasCorrectHeaderDurationAndRealSignal() {
        let data = DemoLibrary.synthesize(root: 130.8128, seed: 731, progression: [0, 5, 9, 7])
        #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
        #expect(data.count == 44 + 22050 * 28 * 2)
        data.withUnsafeBytes { raw in
            #expect(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 24, as: UInt32.self)) == 22050)
            var energy = 0.0, peak = 0.0, count = 0
            for offset in stride(from: 44, to: data.count, by: 202) {
                let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768
                energy += sample * sample; peak = max(peak, abs(sample)); count += 1
            }
            #expect(sqrt(energy / Double(count)) > 0.03); #expect(peak < 0.98)
        }
    }
    @Test func generatedLibraryPersistsOriginalPlayableFilesAndArt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AlpacaDemoTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tracks = try await DemoLibrary.tracks(in: directory)
        #expect(tracks.count == 3); #expect(Set(tracks.map(\.id)).count == 3)
        #expect(tracks.allSatisfy { $0.source == .demo && $0.duration == 28 && $0.artworkData != nil })
        #expect(tracks.allSatisfy { FileManager.default.fileExists(atPath: $0.url!.path) })
        let again = try await DemoLibrary.tracks(in: directory)
        #expect(tracks.map(\.url) == again.map(\.url))
    }
}

import Network
import Synchronization

private final class AudioHTTPFixture: @unchecked Sendable {
    let listener: NWListener
    let content: Data
    private let queue = DispatchQueue(label: "AlpacaMusic.audio-fixture")
    init(content: Data) throws { self.content = content; listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let completed = Mutex(false)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = self?.listener.port, !completed.withLock({ value in let old = value; value = true; return old }) else { return }
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/original.wav")!)
                case .failed(let error):
                    guard !completed.withLock({ value in let old = value; value = true; return old }) else { return }; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in guard let self else { connection.cancel(); return }; connection.start(queue: queue); receive(connection, accumulated: Data()) }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, ended, error in
            guard let self else { connection.cancel(); return }
            var requestData = accumulated; if let data { requestData.append(data) }
            guard let request = String(data: requestData, encoding: .utf8), request.contains("\r\n\r\n") else {
                if ended || error != nil { connection.cancel() } else { receive(connection, accumulated: requestData) }; return
            }
            let rangeLine = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range: bytes=") }
            var start = 0, end = content.count - 1
            if let rangeLine {
                let bounds = rangeLine.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
                start = Int(bounds.first ?? "0") ?? 0
                if bounds.count > 1, let upper = Int(bounds[1]) { end = min(upper, end) }
            }
            guard start >= 0, start <= end, end < content.count else { connection.cancel(); return }
            let body = content.subdata(in: start..<(end + 1))
            let code = rangeLine == nil ? "200 OK" : "206 Partial Content"
            let range = rangeLine == nil ? "" : "Content-Range: bytes \(start)-\(end)/\(content.count)\r\n"
            let header = "HTTP/1.1 \(code)\r\nContent-Type: audio/wav\r\nAccept-Ranges: bytes\r\nContent-Length: \(body.count)\r\n\(range)Connection: close\r\n\r\n"
            var response = Data(header.utf8); if !request.hasPrefix("HEAD ") { response.append(body) }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@Suite(.serialized)
@MainActor struct NativePlaybackTests {
    private func waitFor(_ predicate: @MainActor () -> Bool, seconds: Double = 8) async throws -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { if predicate() { return true }; try await Task.sleep(for: .milliseconds(100)) }
        return predicate()
    }
    @Test func actualLocalPlaybackSpectrumSeekPauseMuteAndRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AlpacaPlayback-\(UUID().uuidString)")
        let suite = "AlpacaPlaybackTests.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        var track = try await DemoLibrary.tracks(in: directory)[0]
        track.source = .local; track.bookmark = try track.url!.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        let player = PlayerController(sources: SourceService(), defaults: defaults); defer { player.shutdown() }
        player.setVolume(0.001) // An audible-engine test at 0.1% volume, only until PCM is observed.
        await player.play(track)
        let played = try await waitFor {
            let levels = player.readLevels()
            return player.status == .playing && player.position > 0.15 && levels.available && levels.spectrum.contains { $0 > 0 }
                && levels.waveform.count == 1024 && levels.waveform.contains { $0 != 0 }
        }
        #expect(played, "AVPlayer status=\(player.status), error=\(player.error ?? "none"), position=\(player.position)")
        #expect(player.readLevels().spectrum.contains { $0 > 0 })
        let analyzed = player.readLevels(), waveform = analyzed.waveform
        #expect(waveform.contains { $0 > 0 }); #expect(waveform.contains { $0 < 0 }); #expect(waveform.allSatisfy { $0.isFinite })
        #expect([analyzed.bassWaveform, analyzed.midWaveform, analyzed.trebleWaveform].allSatisfy { $0.count == 1024 && $0.allSatisfy { $0.isFinite } })
        #expect(analyzed.bassWaveform.contains { $0 != 0 })
        #expect(analyzed.sampleRate > 0 && analyzed.spectrumBinWidth == analyzed.sampleRate / 2048)
        player.toggleMute(); #expect(player.readLevels().bassWaveform.isEmpty && player.readLevels().midWaveform.isEmpty && player.readLevels().trebleWaveform.isEmpty); #expect(player.readLevels().energy == 0); #expect(player.readLevels().spectrum.isEmpty); #expect(player.readLevels().waveform.isEmpty); #expect(player.readLevels().amplitude == 0)
        player.seek(to: 4); let sought = try await waitFor { player.position >= 4 && player.position < 5 }; #expect(sought)
        player.pause(); let stoppedAt = player.position; try await Task.sleep(for: .milliseconds(220)); #expect(player.status == .paused); #expect(abs(player.position - stoppedAt) < 0.2)
        player.cycleRepeat(); player.toggleShuffle(); player.setVolume(0.23); #expect(!player.muted); player.toggleMute(); player.shutdown()
        let restored = PlayerController(sources: SourceService(), defaults: defaults); defer { restored.shutdown() }; restored.restoreQueue([track])
        #expect(restored.current?.id == track.id); #expect(restored.status == .paused); #expect(restored.volume == 0.23); #expect(restored.muted); #expect(restored.shuffle); #expect(restored.repeatMode == .all)
    }
    @Test func actualHTTPAudioPlaysAndQueueCancellationCannotReviveOldItem() async throws {
        let content = DemoLibrary.synthesize(root: 110, seed: 1729, progression: [0, 3, 8, 5])
        let fixture = try AudioHTTPFixture(content: content); let url = try await fixture.start(); defer { fixture.stop() }
        let suite = "AlpacaHTTPTests.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlayerController(sources: SourceService(), defaults: defaults); defer { player.shutdown() }
        player.setVolume(0.001)
        let track = Track(id: "http-original", title: "HTTP test", artist: "Alpaca Sessions", album: "Test", duration: 28, source: .url, url: url)
        await player.play(track)
        let played = try await waitFor {
            let levels = player.readLevels()
            return player.status == .playing && player.position > 0.15 && levels.available && levels.spectrum.contains { $0 > 0 }
                && levels.waveform.count == 1024 && levels.waveform.contains { $0 != 0 }
        }
        #expect(played, "HTTP AVPlayer status=\(player.status), error=\(player.error ?? "none")")
        let analyzed = player.readLevels(), waveform = analyzed.waveform
        #expect(waveform.contains { $0 > 0 }); #expect(waveform.contains { $0 < 0 }); #expect(waveform.allSatisfy { $0.isFinite })
        #expect([analyzed.bassWaveform, analyzed.midWaveform, analyzed.trebleWaveform].allSatisfy { $0.count == 1024 && $0.allSatisfy { $0.isFinite } })
        #expect(analyzed.bassWaveform.contains { $0 != 0 })
        #expect(analyzed.sampleRate > 0 && analyzed.spectrumBinWidth == analyzed.sampleRate / 2048)
        player.pause(); player.clearQueue(); #expect(player.status == .idle); #expect(player.current == nil); #expect(player.readLevels().waveform.isEmpty)
        let pending = Task { await player.play(track) }; await Task.yield(); player.clearQueue(); await pending.value
        #expect(player.status == .idle); #expect(player.current == nil); #expect(player.readLevels().waveform.isEmpty)
    }
    @Test func missingSourceConfigurationFailsWithoutPretendingToPlay() async {
        let suite = "AlpacaFailureTests.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlayerController(sources: SourceService(), defaults: defaults); defer { player.shutdown() }
        let track = Track(id: "netease:123", title: "Not configured", artist: "Artist", album: "Album", duration: 0, source: .netease, sourceID: "123")
        await player.play(track)
        #expect(player.status == .failed); #expect(player.error != nil); #expect(!player.readLevels().available)
        player.seek(to: .infinity); #expect(player.position == 0)
    }
    @Test func volumeSliderUnmutesAndRejectsNonfiniteValues() {
        let suite = "AlpacaVolumeTests.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlayerController(sources: SourceService(), defaults: defaults); defer { player.shutdown() }
        player.toggleMute(); #expect(player.muted)
        player.setVolume(0.3); #expect(!player.muted); #expect(player.volume == 0.3)
        player.setVolume(.nan); #expect(player.volume == 0.3)
        player.setVolume(-1); #expect(player.volume == 0)
        player.setVolume(2); #expect(player.volume == 1)
    }
    @Test func aResolverThatFinishesAfterCancellationCannotRevivePlayback() async throws {
        let suite = "AlpacaResolveRaceTests.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let requested = Mutex(false)
        let service = SourceService(transport: { request in
            requested.withLock { $0 = true }
            // Model a service that delivers a late success even after the caller cancels.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { continuation.resume() }
            }
            let data = Data(#"{"code":200,"data":[{"id":123,"url":"http://127.0.0.1:9/never.wav"}]}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let player = PlayerController(sources: service, defaults: defaults); defer { player.shutdown() }
        player.sourceConfigurations = [.init(kind: .netease, endpoint: "http://127.0.0.1:9", enabled: true)]
        let track = Track(id: "netease:123", title: "Delayed", artist: "Artist", album: "Album", duration: 0, source: .netease, sourceID: "123")
        let task = Task { await player.play(track) }
        let began = try await waitFor { requested.withLock { $0 } }; #expect(began)
        player.clearQueue(); await task.value
        #expect(player.status == .idle); #expect(player.current == nil); #expect(player.queue.isEmpty); #expect(player.error == nil)
    }

}
