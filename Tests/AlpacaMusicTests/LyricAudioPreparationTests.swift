import AVFoundation
import Foundation
import Testing
@testable import AlpacaMusic

@Suite struct LyricAudioPreparationTests {
    private func fixture(_ directory: URL, frequency: Double = 220) throws -> URL {
        let url = directory.appending(path: "original.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<48_000 { samples[index] = Float(sin(Double(index) / 16_000 * frequency * 2 * .pi) * 0.1) }
        let output = try AVAudioFile(forWriting: url, settings: format.settings)
        try output.write(from: buffer)
        return url
    }
    @Test func aheadWindowIsReadableWithoutPlayingAndRecordingBytesHaveDistinctDigests() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = LyricAudioSource(session: UUID(), trackKey: "local-fixture", url: try fixture(directory))
        let job = LyricAudioPreparation()
        let first = try await job.prepare(source)
        #expect(abs(first.duration - 3) < 0.001)
        #expect(first.contentDigest.count == 64)
        let window = try await job.window(start: 1, end: 2)
        let pcm = try AVAudioFile(forReading: window)
        #expect(pcm.length == 16_000)
        await job.cleanup()
        #expect(!FileManager.default.fileExists(atPath: window.path))
        _ = try fixture(directory, frequency: 330)
        let secondJob = LyricAudioPreparation()
        let second = try await secondJob.prepare(source)
        #expect(first.contentDigest != second.contentDigest)
        await secondJob.cleanup()
    }
    @Test func changedLocalRecordingIsRejectedBeforeAWindowCanBeUsed() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try fixture(directory), job = LyricAudioPreparation()
        _ = try await job.prepare(.init(session: UUID(), trackKey: "local", url: url))
        try Data([1, 2, 3]).write(to: url)
        await #expect(throws: LyricAudioPreparationError.self) { try await job.window(start: 0, end: 1) }
        await job.cleanup()
    }
    @Test func unsupportedLiveStreamsDoNotStartARequest() async throws {
        let job = LyricAudioPreparation()
        await #expect(throws: LyricAudioPreparationError.self) {
            try await job.prepare(.init(session: UUID(), trackKey: "stream", url: URL(string: "https://example.invalid/live.m3u8")!))
        }
        await job.cleanup()
    }
    @Test func seekingPrioritizesFutureCuesAndFreshResultsDoNotChangeCurrentPhrase() {
        let document = LyricDocument(lines: [
            .init(id: 0, text: "one", start: 0, end: 5),
            .init(id: 1, text: "two", start: 20, end: 25),
            .init(id: 2, text: "three", start: 70, end: 75)
        ], timing: .line, sourceDescription: "Fixture")
        #expect(LyricAnalysisWindow.next(document: document, duration: 90, position: 60, attempted: [])?.index == 2)
        #expect(LyricAnalysisWindow.next(document: document, duration: 90, position: 0, attempted: [0])?.index == 1)
        let quality = LyricAlignmentQuality(coverage: 1, meanConfidence: 0.9, maximumAnchorDrift: 0.1,
                                           vocalOverlap: 1, matchedUnitCount: 1, estimatedUnitCount: 0)
        let result = LyricAlignmentResult(lines: [
            .init(lineID: 1, words: [.init(id: 0, text: "two", start: 20.1, end: 24)], quality: quality),
            .init(lineID: 2, words: [.init(id: 0, text: "three", start: 70.1, end: 74)], quality: quality)
        ], vocalRegions: [.init(start: 20, end: 75)], engineVersion: "Fixture", localeIdentifier: "en-US")
        let fresh = LyricAnalysisWindow.merge(result, into: document, position: 21)
        #expect(fresh.lines[1].words.isEmpty)
        #expect(!fresh.lines[2].words.isEmpty)
        #expect(fresh.lines[2].wordTimingOrigin == .audioEstimate)
        let restored = LyricAnalysisWindow.merge(result, into: document, position: 21, includeCurrent: true)
        #expect(!restored.lines[1].words.isEmpty)
    }
    @Test @MainActor func audioDerivedTimingRemainsDisclosedAsEstimatedEvenForSingleCharacters() {
        let line = LyricLine(id: 0, text: "风光", start: 0, end: 2,
                             words: [.init(id: 0, text: "风", start: 0, end: 1), .init(id: 1, text: "光", start: 1, end: 2)],
                             wordTimingOrigin: .audioEstimate)
        #expect(LyricReveal.timeline(for: line).isEstimated)
        var provider = line; provider.wordTimingOrigin = nil
        #expect(!LyricReveal.timeline(for: provider).isEstimated)
    }
}
