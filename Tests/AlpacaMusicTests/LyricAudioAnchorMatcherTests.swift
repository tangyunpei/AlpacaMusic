import Foundation
import Testing
@testable import AlpacaMusic

@Suite struct LyricAudioAnchorMatcherTests {
    private func align(_ line: LyricLine, anchors: [LyricAudioAnchor],
                       regions: [LyricVocalRegion] = [.init(start: 10, end: 18)]) -> LyricAlignmentResult {
        LyricAudioAnchorMatcher.align(document: .init(lines: [line], timing: .line, sourceDescription: "Original test"),
                                      anchors: anchors, vocalRegions: regions, audioRange: 10..<20,
                                      engineVersion: "test-v1", localeIdentifier: "zh-CN")
    }

    @Test func measuredChineseGroupsRetainTheirBoundariesAndOriginalText() throws {
        let line = LyricLine(id: 3, text: "月光，轻轻落下。", start: 10, end: 19)
        let anchors: [LyricAudioAnchor] = [
            .init(text: "月光", start: 10.2, end: 10.9, confidence: 0.95),
            .init(text: "轻轻", start: 11.1, end: 11.9, confidence: 0.9),
            .init(text: "落下", start: 12.3, end: 13.6, confidence: 0.94)
        ]
        let result = align(line, anchors: anchors)
        let aligned = try #require(result.lines.first)
        #expect(aligned.lineID == 3)
        #expect(aligned.words.map(\.text).joined() == line.text)
        #expect(aligned.words.map(\.text) == ["月光，", "轻轻", "落下。"])
        #expect(aligned.words.map(\.start) == [10.2, 11.1, 12.3])
        #expect(aligned.words.map(\.end) == [10.9, 11.9, 13.6])
        #expect(aligned.quality.estimatedUnitCount == 3)
        #expect(aligned.quality.matchedUnitCount == 6)
        #expect(aligned.quality.coverage == 1)
        #expect(line.words.isEmpty)
    }

    @Test func latinWordsStayWholeAndPunctuationNeverChanges() throws {
        let line = LyricLine(id: 7, text: "Hello, bright world!", start: 10, end: 18)
        let result = align(line, anchors: [
            .init(text: "hello", start: 10.3, end: 10.8, confidence: 0.9),
            .init(text: "bright", start: 11.4, end: 12.1, confidence: 0.92),
            .init(text: "world", start: 12.7, end: 13.9, confidence: 0.93)
        ])
        let aligned = try #require(result.lines.first)
        #expect(aligned.words.map(\.text) == ["Hello, ", "bright ", "world!"])
        #expect(aligned.quality.estimatedUnitCount == 0)
        #expect(aligned.words.map(\.start) == [10.3, 11.4, 12.7])
    }

    @Test func mismatchMissingWordAndWrongOrderCannotGenerateAlignment() {
        let line = LyricLine(id: 1, text: "bright quiet river", start: 10, end: 18)
        for texts in [["bright", "river"], ["bright", "loud", "river"], ["river", "quiet", "bright"]] {
            let anchors = texts.enumerated().map {
                LyricAudioAnchor(text: $0.element, start: 10.1 + Double($0.offset),
                                 end: 10.8 + Double($0.offset), confidence: 0.98)
            }
            #expect(align(line, anchors: anchors).lines.isEmpty)
        }
    }

    @Test func exactHallucinatedTextWithoutDetectedVoiceIsRejected() {
        let line = LyricLine(id: 0, text: "quiet river", start: 10, end: 18)
        let anchors: [LyricAudioAnchor] = [.init(text: "quiet", start: 10.1, end: 10.8, confidence: 0.99),
                                          .init(text: "river", start: 11, end: 11.8, confidence: 0.99)]
        #expect(align(line, anchors: anchors, regions: []).lines.isEmpty)
        #expect(align(line, anchors: anchors, regions: [.init(start: 10, end: 10.2)]).lines.isEmpty)
    }

    @Test func lowConfidenceAndLargeCueDriftCannotOverwriteEstimatedLyrics() {
        let line = LyricLine(id: 0, text: "quiet river", start: 10, end: 18)
        #expect(align(line, anchors: [.init(text: "quiet river", start: 10.1, end: 12, confidence: 0.4)]).lines.isEmpty)
        #expect(align(line, anchors: [.init(text: "quiet river", start: 13, end: 15, confidence: 0.99)]).lines.isEmpty)
    }

    @Test func authoritativeProviderWordsNeverChangeAndPartialASRRunIsRejected() {
        let anchors: [LyricAudioAnchor] = [.init(text: "quiet river", start: 10.1, end: 11.8, confidence: 0.99)]
        let exact = LyricLine(id: 2, text: "quiet river", start: 10, end: 18,
                              words: [.init(id: 0, text: "quiet ", start: 10.6, end: 11),
                                      .init(id: 1, text: "river", start: 11.7, end: 12.1)])
        #expect(align(exact, anchors: anchors).lines.isEmpty)
        let partial = LyricLine(id: 2, text: "quiet river", start: 10, end: 18)
        #expect(align(partial, anchors: [.init(text: "unrelated quiet river unrelated", start: 10.1,
                                             end: 17.8, confidence: 0.99)]).lines.isEmpty)
    }

    @Test func offsetRangeAndRepeatedCuesDoNotReuseOtherPhraseAnchors() throws {
        let document = LyricDocument(lines: [
            .init(id: 0, text: "quiet river", start: 1, end: 4),
            .init(id: 1, text: "quiet river", start: 10, end: 18)
        ], timing: .line, sourceDescription: "Original test")
        let result = LyricAudioAnchorMatcher.align(document: document,
                                                  anchors: [.init(text: "quiet river", start: 1.1, end: 3.2, confidence: 0.99),
                                                            .init(text: "quiet river", start: 10.4, end: 12, confidence: 0.96)],
                                                  vocalRegions: [.init(start: 10, end: 14)], audioRange: 10..<20,
                                                  engineVersion: "test", localeIdentifier: "en-US")
        #expect(result.lines.count == 1)
        #expect(result.lines.first?.lineID == 1)
        #expect(try #require(result.lines.first?.words.first).start == 10.4)
    }

    @Test func detectorRegionsAreClippedMergedAndCannotInflateOverlap() {
        let regions = LyricAudioAnchorMatcher.mergedVocalRegions([
            .init(start: 9, end: 11), .init(start: 10.5, end: 12),
            .init(start: 11, end: 11.8), .init(start: 12.01, end: 13),
            .init(start: 17, end: 30), .init(start: .nan, end: 15), .init(start: 18, end: 17)
        ], within: 10..<20)
        #expect(regions == [.init(start: 10, end: 13), .init(start: 17, end: 20)])
    }

    @Test func groupedASRTextMayContainPunctuationButNeverInventOnsetsInsideTheGroup() throws {
        let line = LyricLine(id: 1, text: "星光落在心里", start: 10, end: 18)
        let result = align(line, anchors: [.init(text: "星光落在心里。", start: 10.2, end: 14, confidence: 0.9)])
        let aligned = try #require(result.lines.first)
        #expect(aligned.words.count == 1)
        #expect(aligned.words.first?.text == line.text)
        #expect(aligned.words.first?.start == 10.2)
        #expect(aligned.words.first?.end == 14)
        #expect(aligned.quality.estimatedUnitCount == 5)
    }

    @Test func voiceClassifierAcceptsOnlyRealVoiceClassesAtSufficientConfidence() {
        #expect(NativeLyricVocalDetector.qualifies(identifier: "singing", confidence: 0.8))
        #expect(NativeLyricVocalDetector.qualifies(identifier: "speech", confidence: 0.75))
        #expect(!NativeLyricVocalDetector.qualifies(identifier: "music", confidence: 0.99))
        #expect(!NativeLyricVocalDetector.qualifies(identifier: "piano", confidence: 0.99))
        #expect(!NativeLyricVocalDetector.qualifies(identifier: "singing", confidence: 0.49))
        #expect(!NativeLyricVocalDetector.qualifies(identifier: "speech", confidence: .nan))
    }

    @Test func localeSelectionUsesLyricLanguageRatherThanInterfaceLanguage() {
        let chinese = LyricDocument(lines: [.init(id: 0, text: "月光轻轻落下，星光留在我的心里")], timing: .plain, sourceDescription: "test")
        let english = LyricDocument(lines: [.init(id: 0, text: "The quiet river shines beneath the moon")], timing: .plain, sourceDescription: "test")
        #expect(NativeLyricAudioAligner.preferredLocaleIdentifier(for: chinese) == "zh-CN")
        #expect(NativeLyricAudioAligner.preferredLocaleIdentifier(for: english) == "en-US")
    }
}
