import Foundation
import Testing
@testable import AlpacaMusic

/// Line-only cues: the cue's own length sets its pace, capped near the song's
/// pace, with a two-unit final hold. Constants were measured against word-timed
/// lyrics of 160 songs; these tests pin the rules, not the corpus.
@Suite(.serialized) @MainActor struct LyricCadenceTests {
    private func lines(_ texts: [String], starts: [Double]) -> [LyricLine] {
        texts.indices.map { .init(id: $0, text: texts[$0], start: starts[$0], end: starts[$0 + 1]) }
    }
    private func song() -> [LyricLine] {
        let texts = ["夜色慢慢靠近", "风把心事吹散", "你在远方等我", "灯火一盏一盏亮起", "我们终会相遇",
                     "雨落在旧街口", "歌声穿过人海", "让回声照亮远方", "天亮以前别走", "把今晚写成诗"]
        let starts = (0...texts.count).map { 10 + Double($0) * 3 }
        return lines(texts, starts: starts)
    }

    @Test func theSongPaceIsSharedByEveryLineAndFollowsDistantEdits() throws {
        let document = song()
        let contexts = document.indices.map { LyricSingingTiming.context(for: $0, in: document) }
        let first = try #require(contexts.first?.secondsPerSyllable)
        #expect(contexts.allSatisfy { $0.secondsPerSyllable == first })
        // Three seconds for six characters plus the two-unit hold.
        #expect(abs(first - 0.375) < 0.000_1)
        // A change far from the displayed line still reaches its pace.
        var edited = document
        for index in 5..<edited.count { edited[index].text += "啦啦啦" }
        #expect(LyricSingingTiming.context(for: 0, in: edited) != contexts[0])
        #expect(LyricSingingTiming.context(for: 0, in: document) == contexts[0])
        // Instrumental rests (very sparse cues) do not slow the song. With two
        // lines the lower median is the faster pace; any third, slower line that
        // counted would move it.
        let pair = lines(["夜色慢慢靠近心里", "风把心事吹散"], starts: [10, 13, 16])
        #expect(LyricSingingTiming.songCadence(pair) == 0.3)
        let rest = pair + [LyricLine(id: 2, text: "啊啊啊", start: 16, end: 46)]
        #expect(LyricSingingTiming.songCadence(rest) == 0.3)
        let slow = pair + [LyricLine(id: 2, text: "啊啊啊", start: 16, end: 19.6)]
        #expect(LyricSingingTiming.songCadence(slow) == 0.375)
        // The displayed line counts too: a single valid line sets its own pace.
        #expect(LyricSingingTiming.songCadence([pair[1]]) == 0.375)
    }

    @Test func aLongerTailNeverMovesAnEarlierOnsetLater() throws {
        let context = LyricTimingContext(secondsPerSyllable: 0.3)
        var previous: [Double]?
        for duration in stride(from: 1.0, through: 30, by: 0.25) {
            let line = LyricLine(id: 0, text: "亲爱的你别为我哭泣", start: 10, end: 10 + duration)
            let units = LyricReveal.timeline(for: line, context: context).units
            let onsets = units.map(\.start)
            #expect(zip(onsets, onsets.dropFirst()).allSatisfy { $0 <= $1 })
            #expect(units.allSatisfy { $0.start >= 10 && $0.end <= 10 + duration })
            #expect(units.last?.end == 10 + duration)
            if let previous { #expect(zip(previous, onsets).allSatisfy { $0 <= $1 + 0.000_001 }) }
            previous = onsets
        }
    }

    @Test func thePaceIsCappedNearTheSongSoInstrumentalTailsCannotSlowWords() throws {
        let context = LyricTimingContext(secondsPerSyllable: 0.3)
        let schedule = { (duration: Double) in
            try #require(LyricSingingTiming.schedule(text: "亲爱的你别为我哭泣", duration: duration, context: context))
        }
        // From 12 s on the cap binds: 1.2 × 0.3, pulled slightly toward 0.30.
        let capped = pow(0.30, 0.1) * pow(0.36, 0.9)
        for duration in [12.0, 20, 60] {
            let value = try schedule(duration)
            #expect(abs((value.characters[1]?.startOffset ?? 0) - capped) < 0.000_1)
            #expect(value.articulationEnd <= duration)
        }
        // A tight cue never sings past its end.
        let tight = try schedule(1.5)
        #expect(tight.articulationEnd <= 1.5)
        #expect(tight.characters.compactMap { $0 }.allSatisfy { $0.startOffset <= 1.5 && $0.endOffset <= 1.5 })
    }

    @Test func aLastLineWithoutAnEndLastsItsUnitsAtTheSongPace() throws {
        var document = song()
        document[document.count - 1].end = nil
        let index = document.count - 1
        let context = LyricSingingTiming.context(for: index, in: document)
        let pace = try #require(context.secondsPerSyllable)
        let timeline = LyricReveal.timeline(for: document[index], context: context)
        // 把今晚写成诗: six units plus the two-unit hold.
        let start = try #require(document[index].start)
        #expect(abs((timeline.units.last?.end ?? 0) - (start + 8 * pace)) < 0.000_1)
        // Without any pace to learn from it falls back to a typical 0.30 s.
        let alone = LyricReveal.timeline(for: .init(id: 0, text: "我爱你", start: 5), context: .init())
        #expect(abs((alone.units.last?.end ?? 0) - (5 + 5 * 0.30)) < 0.000_1)
        #expect(LyricSingingTiming.openCueDuration("・・・", context: .init()) == 1.2)
    }

    @Test func japaneseKanjiAreLongerOnlyInJapaneseLines() throws {
        let japanese = try #require(LyricEmphasis.cadenceAllocation("君の名前を呼ぶ"))
        #expect(japanese.speech == [1.5, 1, 1.5, 1.5, 1, 1.5, 1])
        // One stray の does not make a Chinese line Japanese.
        let chinese = try #require(LyricEmphasis.cadenceAllocation("我の世界很美丽"))
        #expect(chinese.speech.allSatisfy { $0 == 1 })
        // Plain pronunciation weights, used for word-timed lyrics, are unchanged.
        #expect(LyricEmphasis.estimatedPronunciation("君の名前を呼ぶ")?.speech.allSatisfy { $0 == 1 } == true)
    }

    @Test func phraseBreaksComeFromPunctuationAndSpacesBetweenPhrases() throws {
        let spaced = try #require(LyricEmphasis.cadenceAllocation("亲爱的 别哭泣"))
        #expect(spaced.breaks == [0, 0, 0, 2, 0, 0, 0])
        let punctuated = try #require(LyricEmphasis.cadenceAllocation("夜色，夜色慢慢远去…!!"))
        #expect(punctuated.breaks.reduce(0, +) == 4)
        // Characters spaced one by one, Latin words and Hangul are not phrase breaks.
        for text in ["我 爱 你 中 国", "Hello 你好", "보고 싶어", "love you"] {
            #expect(try #require(LyricEmphasis.cadenceAllocation(text)).breaks.allSatisfy { $0 == 0 }, "\(text)")
        }
        // A break inside the line spends two units of its pace before the next phrase.
        let schedule = try #require(LyricSingingTiming.schedule(text: "亲爱的 别哭泣", duration: 6, context: .init(secondsPerSyllable: 0.3)))
        let pace = try #require(schedule.characters[1]?.startOffset)
        #expect(abs((schedule.characters[4]?.startOffset ?? 0) - 5 * pace) < 0.000_1)
    }
}
