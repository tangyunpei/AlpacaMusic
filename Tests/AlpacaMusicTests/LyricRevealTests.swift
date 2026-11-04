import Foundation
import Testing
@testable import AlpacaMusic

@Suite @MainActor struct LyricRevealTests {
    @Test func providerGraphemeWindowsRetainOnsetsEndsAndPauses() throws {
        let line = LyricLine(id: 1, text: "你 好", start: 1, end: 8, words: [
            .init(id: 0, text: "你", start: 2.2, end: 2.6),
            .init(id: 1, text: "好", start: 4.2, end: 4.8)
        ])
        let timeline = LyricReveal.timeline(for: line)
        #expect(timeline.isTimed && !timeline.isEstimated)
        #expect(timeline.units.map(\.text).joined() == line.text)
        let first = try #require(timeline.units.first)
        let second = try #require(timeline.units.last)
        #expect(first.start == 2.2 && first.end == 2.6)
        #expect(second.start == 4.2 && second.end == 4.8)
        #expect(first.opacity(at: 3) == 1 && second.opacity(at: 3) == 0)
        #expect(first.opacity(at: 2.19) == 0)
        #expect(first.opacity(at: 2.3) > 0 && first.opacity(at: 2.3) < 1)
        #expect(first.opacity(at: 2.2, reduceMotion: true) == 1)
    }

    @Test func providerWordsSubdivideInsideWindowsWithoutFillingGaps() throws {
        let line = LyricLine(id: 2, text: "hello 世界", start: 4, end: 11, words: [
            .init(id: 0, text: "hello ", start: 4.4, end: 6.4),
            .init(id: 1, text: "世界", start: 8, end: 10)
        ])
        let timeline = LyricReveal.timeline(for: line)
        #expect(timeline.isTimed && timeline.isEstimated)
        let fragments = timeline.fragments(["hello", " ", "世界"])
        #expect(fragments.count == 3)
        let hello = try #require(fragments.first)
        #expect(hello.count == 5)
        #expect(hello.first?.start == 4.4)
        #expect(hello.last?.end == 6.4)
        #expect(hello.allSatisfy { $0.start >= 4.4 && $0.end <= 6.4 })
        #expect(fragments[2].map(\.start) == [8, 8.55])
        #expect(fragments[2].allSatisfy { $0.opacity(at: 7.9) == 0 })
        #expect(Set(hello.map(\.start)).count == 5)
    }

    @Test func lineEstimatesFitDenseCuesAndKeepLongTailsOnTheLastCharacter() throws {
        let fast = LyricReveal.timeline(for: .init(id: 3, text: "你好世界", start: 10, end: 12))
        let slow = LyricReveal.timeline(for: .init(id: 4, text: "你好世界", start: 10, end: 18))
        #expect(fast.isEstimated && slow.isEstimated)
        #expect(fast.units.map(\.start) == [10, 10.5, 11, 11.5])
        #expect(slow.units.map(\.start) == [10, 10.55, 11.1, 11.65])
        #expect(slow.units.last?.end == 18)
        #expect(slow.units.allSatisfy { $0.opacity(at: 12) == 1 })
        let latin = LyricReveal.timeline(for: .init(id: 5, text: "I ocean", start: 0, end: 3))
        let ocean = try #require(latin.fragments(["I ", "ocean"]).last)
        #expect(abs((ocean.first?.start ?? -1) - 0.55) < 0.000_001)
    }

    @Test func estimatesShareEmphasisPronunciationAndPunctuationAllocation() throws {
        let line = LyricLine(id: 6, text: "夜色，golden light returns。", start: 2, end: 10)
        let texts = LyricEmphasis.split(line.text)
        let windows = try #require(LyricEmphasis.estimatedWindows(texts: texts, line: line))
        let reveal = LyricReveal.timeline(for: line)
        let pieces = reveal.fragments(texts)
        for (index, window) in windows {
            let spoken = pieces[index].filter { $0.end > $0.start }
            let first = try #require(spoken.first), last = try #require(spoken.last)
            #expect(abs(first.start - (2 + window.startOffset)) < 0.000_001)
            #expect(abs(last.end - (2 + window.endOffset)) < 0.000_001)
        }
        let comma = try #require(reveal.units.firstIndex { $0.text == "，" })
        #expect(reveal.units[comma + 1].start > reveal.units[comma - 1].end)
    }

    @Test func fragmentsUsePositionNotSubstringMatchingForRepeatedCharacters() {
        let line = LyricLine(id: 7, text: "啦啦 啦啦", start: 0, end: 5,
                             words: (0..<4).map { .init(id: $0, text: "啦", start: Double($0 + 1), end: Double($0 + 1) + 0.5) })
        let reveal = LyricReveal.timeline(for: line)
        let fragments = reveal.fragments(["啦\n啦", " 啦", "啦"])
        #expect(fragments.map { $0.map(\.text).joined() } == ["啦\n啦", " 啦", "啦"])
        #expect(fragments.flatMap { $0 }.filter { $0.text == "啦" }.map(\.start) == [1, 2, 3, 4])
        #expect(reveal.fragments(["啦啦啦"]).isEmpty)
        #expect(reveal.fragments(["啦啦嘿啦"]).isEmpty)
        #expect(reveal.fragments(["啦啦啦啦啦"]).isEmpty)
    }

    @Test func unicodeGraphemesRemainWholeAcrossTimelinesAndLayout() {
        let words = ["👨‍👩‍👧‍👦", "e\u{301}", "你", "한", "🇨🇦"]
        let line = LyricLine(id: 8, text: words.joined(), start: 0, end: 6,
                             words: words.enumerated().map { .init(id: $0.offset, text: $0.element, start: Double($0.offset), end: Double($0.offset) + 0.8) })
        let reveal = LyricReveal.timeline(for: line)
        #expect(reveal.units.map(\.text) == words)
        #expect(reveal.units.allSatisfy { $0.text.count == 1 })
        #expect(reveal.units[0].end == 0.8)
        #expect(!reveal.isEstimated)
        #expect(reveal.fragments([words[0], " ", words.dropFirst().joined()]).count == 3)
    }

    @Test func simultaneousAndZeroDurationTokensRevealAtTheirOnset() {
        let line = LyricLine(id: 9, text: "你我他", start: 0, end: 5, words: [
            .init(id: 0, text: "你", start: 1, end: 1),
            .init(id: 1, text: "我", start: 1, end: 1),
            .init(id: 2, text: "他", start: 3, end: 4)
        ])
        let reveal = LyricReveal.timeline(for: line)
        #expect(reveal.isTimed && !reveal.isEstimated)
        #expect(reveal.units[0].progress(at: 1) == 1)
        #expect(reveal.units[1].opacity(at: 1) == 1)
        #expect(reveal.units[2].opacity(at: 1) == 0)
        #expect(reveal.units[1].opacity(at: 0.99) == 0)
    }

    @Test func missingFinalEndUsesBoundedEstimateWithoutChangingSource() throws {
        let line = LyricLine(id: 10, text: "请把最后的光留给我", start: 20)
        let snapshot = line
        let reveal = LyricReveal.timeline(for: line)
        #expect(reveal.isTimed && reveal.isEstimated)
        #expect(reveal.units.first?.start == 20)
        let end = try #require(reveal.units.last?.end)
        #expect(end > 21 && end <= 32)
        #expect(line == snapshot)
        let words = LyricLine(id: 11, text: "月 光", start: 20, words: [
            .init(id: 0, text: "月", start: 20.5, end: 21),
            .init(id: 1, text: "光", start: 24)
        ])
        let supplied = LyricReveal.timeline(for: words)
        #expect(supplied.units.last?.start == 24)
        #expect(supplied.isEstimated)
        #expect((supplied.units.last?.end ?? 0) <= 26.4)
    }

    @Test func plainAndInvalidLinesStayReadable() {
        let plain = LyricReveal.timeline(for: .init(id: 12, text: "一直清晰可读"))
        #expect(!plain.isTimed && !plain.isEstimated)
        #expect(plain.units.allSatisfy { $0.opacity(at: -1) == 1 && $0.progress(at: 9) == 1 })
        for (start, end) in [(Double.nan, 4.0), (.infinity, 4), (-1, 4), (4, 2), (0, .nan), (0, 121)] {
            let line = LyricLine(id: 13, text: "时间错误", start: start, end: end)
            let timeline = LyricReveal.timeline(for: line)
            #expect(!timeline.isTimed)
            #expect(timeline.units.map(\.text).joined() == line.text)
        }
        let wrongWords = LyricLine(id: 14, text: "原句", start: 0, end: 4,
                                   words: [.init(id: 0, text: "不符", start: .nan)])
        let recovered = LyricReveal.timeline(for: wrongWords)
        #expect(recovered.isEstimated)
        #expect(recovered.units.allSatisfy { $0.start.isFinite && $0.end.isFinite })
        let oversized = LyricReveal.timeline(for: .init(id: 15, text: String(repeating: "啊", count: 1_025), start: 0, end: 20))
        #expect(!oversized.isTimed && oversized.units.isEmpty)
    }

    @Test func replayPauseAndBackwardSeekAreDeterministicAndBounded() {
        let line = LyricLine(id: 16, text: "日落以后 we return", start: 1, end: 8)
        let reveal = LyricReveal.timeline(for: line)
        for time in [6.0, 2.0, 6.0, 0.0, 9.0, 2.0] {
            let cached = LyricReveal.timeline(for: line)
            #expect(cached == reveal)
            #expect(cached.units.map { $0.opacity(at: time) } == reveal.units.map { $0.opacity(at: time) })
            #expect(reveal.units.allSatisfy { (0...1).contains($0.progress(at: time)) && (0...1).contains($0.opacity(at: time)) })
        }
        let invalid = LyricRevealUnit(text: "字", start: .nan, end: .infinity)
        #expect(invalid.progress(at: 2) == 0 && invalid.opacity(at: 2) == 0)
        #expect(reveal.units.allSatisfy { $0.opacity(at: .nan) == 0 && $0.progress(at: .infinity) == 0 })
    }
}
