import AVFoundation
import Foundation
import Testing
@testable import AlpacaMusic

private actor AlignmentRunnerEvidence {
    var results: [(LyricAlignmentResult, Bool)] = []
    var statuses: [LyricAudioAlignmentStatus] = []
    func receive(_ value: LyricAlignmentResult, cached: Bool) { results.append((value, cached)) }
    func receive(_ status: LyricAudioAlignmentStatus) { statuses.append(status) }
}

@Suite(.serialized) struct LyricAlignmentRunnerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ALPACA_RUN_NATIVE_ALIGNMENT_QA"] == "1"))
    func completeBackgroundPipelineAnalyzesActualFileAndRestoresRecordingSpecificCache() async throws {
        // Use a physical temp root: /var and /tmp are macOS aliases, which the
        // cache deliberately refuses to traverse with O_NOFOLLOW.
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appending(path: "alpaca-lyric-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appending(path: "original.aiff")
        let phrase = "The quiet river shines beneath the moon."
        let say = Process(); say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-r", "135", "-o", audio.path, phrase]
        say.standardOutput = FileHandle.nullDevice; say.standardError = FileHandle.nullDevice
        try say.run(); say.waitUntilExit()
        #expect(say.terminationStatus == 0)
        let file = try AVAudioFile(forReading: audio)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let track = Track(id: "original-voice", title: "Original Voice", artist: "Test", album: "Studio", duration: duration, source: .local, url: audio)
        let document = LyricDocument(lines: [.init(id: 0, text: phrase, start: 0, end: duration)], timing: .line, sourceDescription: "Original test")
        let cache = LyricAlignmentCache(directory: directory), first = AlignmentRunnerEvidence(), second = AlignmentRunnerEvidence()
        let source = LyricAudioSource(session: UUID(), trackKey: LyricsIdentity.key(for: track), url: audio)
        await LyricAlignmentRunner.run(source: source, track: track, document: document, cache: cache, position: { 0 },
            progress: { await first.receive($0) }, publish: { await first.receive($0, cached: $1) })
        let measured = try #require(await first.results.first)
        #expect(measured.1 == false)
        #expect(measured.0.lines.first?.words.map(\.text).joined() == phrase)
        #expect(measured.0.lines.first?.words.count == 7)
        #expect(await first.statuses.last == .ready(1))
        await LyricAlignmentRunner.run(source: source, track: track, document: document, cache: cache, position: { 2 },
            progress: { await second.receive($0) }, publish: { await second.receive($0, cached: $1) })
        let restored = try #require(await second.results.first)
        #expect(restored.1 == true)
        #expect(restored.0 == measured.0)
        #expect(await second.results.count == 1)
        let files = try FileManager.default.contentsOfDirectory(at: directory.appending(path: "lyric-alignments"), includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let saved = try String(contentsOf: #require(files.first), encoding: .utf8)
        #expect(!saved.contains("quiet") && !saved.contains(phrase) && !saved.contains(audio.path))
    }
}
