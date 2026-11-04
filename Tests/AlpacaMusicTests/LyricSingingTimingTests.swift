import Foundation
import Testing
@testable import AlpacaMusic

@Suite @MainActor struct LyricSingingTimingTests {
    @Test func longMandarinCueRevealsPhraseBeforeHeldTailWithoutChangingLyrics() throws {
        let line = LyricLine(id: 1, text: "亲爱的你别为我哭泣", start: 30, end: 45)
        let neighbors = [
            LyricLine(id: 0, text: "轻轻的我将离开你", start: 26, end: 30), line,
            LyricLine(id: 2, text: "在没有我的日子里", start: 45, end: 49),
            LyricLine(id: 3, text: "你要好好保重自己", start: 49, end: 53)
        ]
        let snapshot = neighbors
        let context = LyricSingingTiming.context(for: 1, in: neighbors)
        let cadence = try #require(context.secondsPerSyllable)
        #expect(cadence >= 0.3 && cadence <= 0.5)
        let timeline = LyricReveal.timeline(for: line, context: context)
        #expect(timeline.units.first?.start == 30)
        #expect((timeline.units.last?.start ?? 100) < 34)
        #expect(timeline.units.last?.end == 45)
        #expect(timeline.units.allSatisfy { $0.opacity(at: 34) == 1 })
        #expect(timeline.units.allSatisfy { $0.opacity(at: 29.99) == 0 })
        #expect(neighbors == snapshot)
        #expect(neighbors[2].start == 45)
    }

    @Test func finalInstrumentalGapAndIncreasingHoldNeverMoveEarlierOnsets() {
        let ordinary = LyricLine(id: 2, text: "月光照在我心里", start: 5, end: 10)
        var held = ordinary; held.end = 35
        let context = LyricTimingContext(secondsPerSyllable: 0.42)
        let a = LyricReveal.timeline(for: ordinary, context: context)
        let b = LyricReveal.timeline(for: held, context: context)
        #expect(a.units.map(\.start) == b.units.map(\.start))
        #expect(a.units.dropLast().map(\.end) == b.units.dropLast().map(\.end))
        #expect(b.units.last?.end == 35)
        #expect(b.units.allSatisfy { $0.opacity(at: 9) == 1 })
        #expect((b.units.last?.progress(at: 10) ?? 0) < 1)
    }

    @Test func fastDenseChineseKeepsAllOnsetsInsideCueAndMonotonic() throws {
        let line = LyricLine(id: 3, text: "只要你在我的身边每一秒都值得纪念", start: 9, end: 11)
        let timeline = LyricReveal.timeline(for: line, context: .init(secondsPerSyllable: 0.48))
        let last = try #require(timeline.units.last)
        #expect(last.start < 11 && last.end == 11)
        #expect(zip(timeline.units, timeline.units.dropFirst()).allSatisfy { $0.start < $1.start && $0.end <= $1.start })
        #expect(timeline.units.allSatisfy { $0.start >= 9 && $0.end <= 11 })
        #expect(timeline.units.allSatisfy { $0.opacity(at: 11) == 1 })
    }

    @Test func genuineSingleGlyphWordTimesRemainExactThroughLongSustainsAndContext() {
        let line = LyricLine(id: 4, text: "我爱你", start: 10, end: 25, words: [
            .init(id: 0, text: "我", start: 10.3, end: 10.7),
            .init(id: 1, text: "爱", start: 11.1, end: 11.6),
            .init(id: 2, text: "你", start: 12, end: 22)
        ])
        let timeline = LyricReveal.timeline(for: line, context: .init(secondsPerSyllable: 0.15))
        #expect(!timeline.isEstimated)
        #expect(timeline.units.map(\.start) == [10.3, 11.1, 12])
        #expect(timeline.units.map(\.end) == [10.7, 11.6, 22])
    }

    @Test func phraseTokensUseEstimatedInternalOnsetsButKeepProviderBoundariesAndPauses() {
        let line = LyricLine(id: 5, text: "亲爱的你 别为我哭泣", start: 10, end: 30, words: [
            .init(id: 0, text: "亲爱的你 ", start: 11, end: 18),
            .init(id: 1, text: "别为我哭泣", start: 20, end: 28)
        ])
        let timeline = LyricReveal.timeline(for: line, context: .init(secondsPerSyllable: 0.4))
        let fragments = timeline.fragments(["亲爱的你", " ", "别为我哭泣"])
        #expect(timeline.isEstimated)
        #expect(fragments[0].first?.start == 11 && fragments[0].last?.end == 18)
        #expect(fragments[2].first?.start == 20 && fragments[2].last?.end == 28)
        #expect((fragments[0].last?.start ?? 100) < 13)
        #expect((fragments[2].last?.start ?? 100) < 22)
        #expect(fragments[2].allSatisfy { $0.opacity(at: 19) == 0 })
    }

    @Test func contextChangesInvalidateTimelineCacheAndMalformedRatesUseFallback() {
        let line = LyricLine(id: 6, text: "夜色慢慢亮起", start: 1, end: 20)
        let fast = LyricReveal.timeline(for: line, context: .init(secondsPerSyllable: 0.24))
        let slow = LyricReveal.timeline(for: line, context: .init(secondsPerSyllable: 0.85))
        #expect(fast != slow)
        #expect(LyricReveal.timeline(for: line, context: .init(secondsPerSyllable: 0.24)) == fast)
        for rate in [Double.nan, .infinity, -1, 0, 10] {
            #expect(LyricReveal.timeline(for: line, context: .init(secondsPerSyllable: rate)) == LyricReveal.timeline(for: line))
        }
    }

    @Test func sparseNeighborTailsDoNotSlowTheLocalCadenceAndProviderOnsetsTakePriority() throws {
        let target = LyricLine(id: 1, text: "亲爱的你别为我哭泣", start: 20, end: 34)
        let rapid = LyricLine(id: 0, text: "请你把爱留给我", start: 10, end: 20, words:
                                Array("请你把爱留给我").enumerated().map {
            .init(id: $0.offset, text: String($0.element), start: 10 + Double($0.offset) * 0.3,
                  end: 10 + Double($0.offset) * 0.3 + 0.25)
        })
        let sparse = LyricLine(id: 2, text: "啊", start: 34, end: 64)
        let context = LyricSingingTiming.context(for: 1, in: [rapid, target, sparse])
        #expect(abs((try #require(context.secondsPerSyllable)) - 0.3) < 0.001)
        var slower = rapid
        for index in slower.words.indices {
            slower.words[index].start = 10 + Double(index) * 0.6
            slower.words[index].end = 10 + Double(index) * 0.6 + 0.55
        }
        #expect(abs((try #require(LyricSingingTiming.context(for: 1, in: [slower, target, sparse]).secondsPerSyllable)) - 0.6) < 0.001)
        #expect(LyricSingingTiming.context(for: 1, in: [rapid, target, sparse]) == context)
        var longerTarget = target; longerTarget.end = 54
        #expect(LyricSingingTiming.context(for: 1, in: [rapid, longerTarget, sparse]) == context)
        #expect(LyricSingingTiming.context(for: -1, in: [target]) == .init())
        #expect(LyricSingingTiming.context(for: 0, in: [target]) == .init())
    }

    @Test func localContextCacheFollowsNeighborEditsWithoutRetainingMalformedDocuments() throws {
        let target = LyricLine(id: 0, text: "亲爱的你别为我哭泣", start: 10, end: 24)
        let original = [target, LyricLine(id: 1, text: "月光照在我心里", start: 24, end: 28)]
        let before = LyricSingingTiming.context(for: 0, in: original)
        var faster = original; faster[1].end = 26
        let after = LyricSingingTiming.context(for: 0, in: faster)
        #expect(before != after)
        #expect(LyricSingingTiming.context(for: 0, in: original) == before)
        #expect(LyricSingingTiming.context(for: 0, in: faster) == after)
        var changedText = original; changedText[1].text = "月光照在我的心里你可知道我想你"
        #expect(LyricSingingTiming.context(for: 0, in: changedText) != before)
        var oversized = original; oversized[1].text = String(repeating: "啊", count: 1_025)
        #expect(LyricSingingTiming.context(for: 0, in: oversized) == .init())
        var oversizedWords = original
        oversizedWords[1].words = Array(repeating: .init(id: 0, text: "月", start: 24), count: 1_025)
        #expect(LyricSingingTiming.context(for: 0, in: oversizedWords) == .init())
        var invalid = original; invalid[1].end = .infinity
        #expect(LyricSingingTiming.context(for: 0, in: invalid) == .init())
        let reveal = LyricReveal.timeline(for: target, context: after)
        for time in [18.0, 10.4, 18, 9, 26, 10.4] {
            let replay = LyricReveal.timeline(for: target, context: after)
            #expect(replay == reveal)
            #expect(replay.units.map { $0.opacity(at: time) } == reveal.units.map { $0.opacity(at: time) })
            #expect(replay.units.allSatisfy { $0.opacity(at: time, reduceMotion: true) == (time >= $0.revealStart ? 1 : 0) })
        }
    }

    @Test func estimatedAccentsShareRevealOnsetsAfterPunctuationAndRepeatedLayoutFragments() throws {
        let line = LyricLine(id: 7, text: "夜色，夜色慢慢远去", start: 4, end: 24)
        let context = LyricTimingContext(secondsPerSyllable: 0.36)
        let texts = ["夜", "色", "，", "夜色", "慢慢", "远去"]
        let timeline = LyricReveal.timeline(for: line, context: context)
        let fragments = timeline.fragments(texts)
        let choices = LyricEmphasis.choices(texts: texts, line: line, suppliedWordTiming: false,
                                           seed: 12, context: context)
        #expect(!choices.isEmpty)
        for (index, choice) in choices {
            let event = try #require(LyricEmphasis.eventInterval(choice: choice, line: line, unitIndex: index))
            let first = try #require(fragments[index].first)
            #expect(abs(event.start - first.revealStart) < 0.000_001)
            #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: index, position: event.start - 0.001) == nil)
            #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: index, position: event.start + 0.06) != nil)
        }
        #expect((fragments[3].first?.start ?? 0) > (fragments[1].last?.end ?? 0))
        #expect(LyricSingingTiming.windows(texts: ["夜色，", "慢慢", "夜色", "远去"], line: line, context: context) == nil)
        let remapped = timeline.fragments(["夜色，夜", "\n色慢慢远去"])
        #expect(remapped.flatMap { $0 }.filter { !$0.text.allSatisfy(\.isWhitespace) }.map(\.start) == timeline.units.map(\.start))
    }

    @Test func closingPunctuationAppearsWithThePhraseInsteadOfWaitingForItsTail() throws {
        let line = LyricLine(id: 9, text: "你好。", start: 0, end: 20)
        let timeline = LyricReveal.timeline(for: line)
        let lastSpoken = try #require(timeline.units.first { $0.text == "好" })
        let period = try #require(timeline.units.last)
        #expect(lastSpoken.end == 20)
        #expect(period.start > lastSpoken.start && period.start < 2)
        #expect(period.opacity(at: 2) == 1)
        #expect(period.opacity(at: 0.5) == 0)
    }

    @Test func spanishAndEnglishAppearAsWordsWithoutWaitingForTheLongTail() throws {
        let line = LyricLine(id: 8, text: "Te quiero corazón, every quiet ocean", start: 2, end: 30)
        let timeline = LyricReveal.timeline(for: line, context: .init(secondsPerSyllable: 0.35))
        let texts = ["Te", " ", "quiero", " ", "corazón", ", ", "every", " ", "quiet", " ", "ocean"]
        let fragments = timeline.fragments(texts)
        for index in [0, 2, 4, 6, 8, 10] {
            let first = try #require(fragments[index].first)
            #expect(first.revealStart < 8)
            #expect(fragments[index].allSatisfy { $0.revealStart == first.revealStart })
            #expect(fragments[index].allSatisfy { $0.opacity(at: first.revealStart + 0.15) == 1 })
        }
        #expect(timeline.units.last?.end == 30)
    }
}
