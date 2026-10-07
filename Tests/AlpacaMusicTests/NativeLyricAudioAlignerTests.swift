import AVFoundation
import Foundation
import Testing
@testable import AlpacaMusic

/// Explicitly enabled runtime QA uses original generated speech and synthesized
/// instrument-only audio, never private libraries/accounts. Ordinary CI exercises
/// the deterministic matcher and quality gates without downloading model assets.
@Suite(.serialized) struct NativeLyricAudioAlignerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ALPACA_RUN_NATIVE_ALIGNMENT_QA"] == "1"))
    func originalVoiceIsDetectedAndActuallyAlignedOnDevice() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alpaca-native-align-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("original-voice.aiff")
        let phrase = "The quiet river shines beneath the moon."
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-r", "135", "-o", audio.path, phrase]
        say.standardOutput = FileHandle.nullDevice; say.standardError = FileHandle.nullDevice
        try say.run(); say.waitUntilExit()
        #expect(say.terminationStatus == 0)
        let file = try AVAudioFile(forReading: audio)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let document = LyricDocument(lines: [.init(id: 0, text: phrase, start: 0, end: duration)],
                                     timing: .line, sourceDescription: "Original voice QA")
        let result = try await NativeLyricAudioAligner.align(fileURL: audio, document: document,
                                                           localeIdentifier: "en-US", allowAssetDownload: true)
        if let path = ProcessInfo.processInfo.environment["ALPACA_NATIVE_ALIGNMENT_REPORT"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        #expect(!result.vocalRegions.isEmpty)
        let aligned = try #require(result.lines.first)
        #expect(aligned.words.map(\.text).joined() == phrase)
        #expect(aligned.words.count >= 4)
        #expect(aligned.quality.meanConfidence >= 0.5)
        #expect(aligned.quality.vocalOverlap >= 0.65)
        #expect(aligned.words.allSatisfy { $0.start >= 0 && ($0.end ?? duration + 1) <= duration })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ALPACA_RUN_NATIVE_ALIGNMENT_QA"] == "1"))
    func originalMandarinPhraseRetainsAudioAnchorsBeforeLongSilentTail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alpaca-native-align-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("original-mandarin.aiff")
        let phrase = "亲爱的朋友请看天上的光"
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Tingting", "-r", "145", "-o", audio.path, phrase]
        say.standardOutput = FileHandle.nullDevice; say.standardError = FileHandle.nullDevice
        try say.run(); say.waitUntilExit()
        #expect(say.terminationStatus == 0)
        let file = try AVAudioFile(forReading: audio)
        let format = file.processingFormat
        let voiceDuration = Double(file.length) / format.sampleRate
        let voice = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: voice)
        let padding = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * 10)))
        padding.frameLength = padding.frameCapacity
        if let channels = padding.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                channels[channel].update(repeating: 0, count: Int(padding.frameLength))
            }
        }
        let held = directory.appendingPathComponent("mandarin-long-tail.wav")
        do {
            let output = try AVAudioFile(forWriting: held, settings: format.settings)
            try output.write(from: voice); try output.write(from: padding)
        }
        let shortDocument = LyricDocument(lines: [.init(id: 0, text: phrase, start: 0, end: voiceDuration)],
                                          timing: .line, sourceDescription: "Original Mandarin QA")
        var longDocument = shortDocument; longDocument.lines[0].end = voiceDuration + 10
        let original = try await NativeLyricAudioAligner.align(fileURL: audio, document: shortDocument,
                                                             localeIdentifier: "zh-CN", allowAssetDownload: true)
        let padded = try await NativeLyricAudioAligner.align(fileURL: held, document: longDocument,
                                                           localeIdentifier: "zh-CN", allowAssetDownload: true)
        if let path = ProcessInfo.processInfo.environment["ALPACA_NATIVE_ALIGNMENT_CHINESE_REPORT"] {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(["original": original, "longTail": padded])
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        let originalLine = try #require(original.lines.first)
        let heldLine = try #require(padded.lines.first)
        #expect(originalLine.words.map(\.text).joined() == phrase)
        #expect(heldLine.words.map(\.text).joined() == phrase)
        #expect(heldLine.quality.matchedUnitCount == phrase.count)
        #expect(heldLine.words.allSatisfy { $0.start < voiceDuration + 0.15 })
        #expect((heldLine.words.last?.end ?? 100) < voiceDuration + 0.3)
        #expect(originalLine.words.map(\.text) == heldLine.words.map(\.text))
        #expect(zip(originalLine.words, heldLine.words).allSatisfy { abs($0.start - $1.start) <= 0.2 })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ALPACA_RUN_NATIVE_ALIGNMENT_QA"] == "1"))
    func emptyAndInstrumentOnlyAudioCannotProduceLyricTiming() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("alpaca-native-align-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frames: AVAudioFrameCount = 48_000
        for instrument in [false, true] {
            let audio = directory.appendingPathComponent(instrument ? "instrument.wav" : "silence.wav")
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let data = try #require(buffer.floatChannelData?[0])
            for index in 0..<Int(frames) {
                let time = Double(index) / 16_000
                data[index] = instrument ? Float(0.2 * sin(2 * .pi * 440 * time) + 0.1 * sin(2 * .pi * 660 * time)) : 0
            }
            do {
                let output = try AVAudioFile(forWriting: audio, settings: format.settings)
                try output.write(from: buffer)
            }
            let document = LyricDocument(lines: [.init(id: 0, text: "The quiet river shines", start: 0, end: 3)],
                                         timing: .line, sourceDescription: "Synthetic instrument QA")
            let result = try await NativeLyricAudioAligner.align(fileURL: audio, document: document,
                                                               localeIdentifier: "en-US", allowAssetDownload: true)
            #expect(result.lines.isEmpty)
        }
    }
}
