import Foundation
import Testing
@testable import AlpacaMusic

@Test @MainActor func lyricEmphasisSplitIsLosslessAcrossLanguagesAndUnicode() {
    let samples = [
        "  Don't follow the well-known road, take a golden-hour walk.  ",
        "把夜色，留给每一扇窗； 然后 we return。",
        "Cafe\u{301} \"moon\"\n\n👨‍👩‍👧‍👦 🌙  再见",
        "don't don’t rock’n’roll well-known non‑stop",
        " \t\n ", "", "你好世界"
    ]
    for text in samples {
        let pieces = LyricEmphasis.split(text)
        #expect(pieces.joined() == text)
        #expect(pieces == LyricEmphasis.split(text))
    }
    let joinedWords = LyricEmphasis.split(samples[0])
    #expect(joinedWords.contains("Don't"))
    #expect(joinedWords.contains("well-known"))
    #expect(joinedWords.contains("golden-hour"))
    #expect(joinedWords.contains { $0.allSatisfy(\.isWhitespace) })
    #expect(joinedWords.contains(","))
    let graphemes = LyricEmphasis.split(samples[2])
    #expect(graphemes.contains { $0.contains("👨‍👩‍👧‍👦") })
    #expect(graphemes.contains { $0.contains("e\u{301}") })
}

@Test @MainActor func lyricEmphasisLimitsWorkOnPathologicalInputWithoutLosingText() {
    let veryLong = String(repeating: "安静的夜色 ", count: 400)
    #expect(LyricEmphasis.split(veryLong) == [veryLong])
    let manyTokens = String(repeating: "moon,", count: 257)
    #expect(LyricEmphasis.split(manyTokens).joined() == manyTokens)
    #expect(LyricEmphasis.choices(texts: Array(repeating: "moon", count: 257),
                                line: .init(id: 0, text: manyTokens, start: 0, end: 8), suppliedWordTiming: false, seed: 0).isEmpty)
}

@Test @MainActor func lyricEmphasisExcludesFunctionWordsPunctuationAndWhitespace() {
    let texts = ["I", " ", "am", "the", "and", ",", "的", "我们", "在", "。", "night", "星光"]
    let line = LyricLine(id: 0, text: texts.joined(), start: 0, end: 8)
    for seed in 0..<30 {
        let choices = LyricEmphasis.choices(texts: texts, line: line, suppliedWordTiming: false, seed: UInt64(seed))
        #expect(Set(choices.keys) == Set([10, 11]))
        #expect(choices.values.allSatisfy { $0.reason == .estimatedWord && $0.window != nil })
    }
    let emptyContent = ["you", "for", "的", "了", " ", "!?", "123", "🌙"]
    #expect(LyricEmphasis.choices(texts: emptyContent, line: line, suppliedWordTiming: false, seed: 0).isEmpty)
}

@Test @MainActor func lyricEmphasisChoicesAreSparseReproducibleAndVaried() {
    let text = "We leave a little light beside the rain"
    let texts = LyricEmphasis.split(text)
    let line = LyricLine(id: 0, text: text, start: 3, end: 11)
    var kinds = Set<Int>()
    var selected: Set<String> = []
    for seed in 0..<40 {
        let first = LyricEmphasis.choices(texts: texts, line: line, suppliedWordTiming: false, seed: UInt64(seed))
        let replay = LyricEmphasis.choices(texts: texts, line: line, suppliedWordTiming: false, seed: UInt64(seed))
        #expect(first == replay)
        #expect(first.count <= 2)
        #expect(!first.isEmpty)
        #expect(first.values.allSatisfy { $0.reason == .estimatedWord && $0.delay == 0 })
        let ordered = first.sorted { $0.key < $1.key }
        let windows = ordered.compactMap { $0.value.window }
        #expect(windows.count == first.count)
        if windows.count == 2 { #expect(windows[0].endOffset <= windows[1].startOffset + 0.000_001) }
        #expect(first.values.allSatisfy { $0.direction == -1 || $0.direction == 1 })
        kinds.formUnion(first.values.map { $0.kind.rawValue })
        selected.formUnion(first.keys.map { texts[$0] })
    }
    #expect(kinds.count == LyricAccentKind.allCases.count)
    #expect(selected.count >= 4)
}

@Test @MainActor func lyricEmphasisUsesExplicitSustainAndPauseMetadata() {
    let line = LyricLine(id: 0, text: "Light rain returns", start: 2, end: 8, words: [
        .init(id: 0, text: "Light ", start: 2.2, end: 2.5),
        .init(id: 1, text: "rain ", start: 3.1, end: 3.4),
        .init(id: 2, text: "returns", start: 4, end: 6.2)
    ])
    #expect(LyricEmphasis.hasUsableWordTiming(line))
    let choices = LyricEmphasis.choices(texts: line.words.map(\.text), line: line, suppliedWordTiming: true, seed: 5)
    #expect(choices[2]?.reason == .sustain)
    #expect(choices[2]?.kind == .weight || choices[2]?.kind == .pulse)
    let pause = choices.filter { $0.value.reason == .pause }
    #expect(pause.count == 1)
    #expect(pause.values.allSatisfy { $0.kind == .ring || $0.kind == .box })
    #expect(choices.count == 2)
}

@Test @MainActor func lyricEmphasisTimingValidatorAcceptsLastCueAndMissingWordEnds() {
    let line = LyricLine(id: 0, text: "Light returns", start: 20, words: [
        .init(id: 0, text: "Light ", start: 20.2),
        .init(id: 1, text: "returns", start: 22.4)
    ])
    #expect(LyricEmphasis.hasUsableWordTiming(line))
    let choices = LyricEmphasis.choices(texts: line.words.map(\.text), line: line, suppliedWordTiming: true, seed: 3)
    #expect(choices.values.allSatisfy { $0.reason == .wordOnset })
    #expect(LyricEmphasis.state(choice: .init(kind: .ring, reason: .wordOnset), line: line,
                               unitIndex: 1, position: 22.5) != nil)
}

@Test @MainActor func lyricEmphasisInvalidTimingUsesOnlyClosedTextCompatibleEstimates() {
    let good = LyricLine(id: 0, text: "Light returns", start: 2, end: 7, words: [
        .init(id: 0, text: "Light ", start: 2.2, end: 3),
        .init(id: 1, text: "returns", start: 4, end: 6)
    ])
    var variants: [LyricLine] = []
    for badStart in [Double.nan, .infinity, -.infinity, 1, 7, 4] {
        var line = good; line.words[0].start = badStart; variants.append(line)
    }
    for badEnd in [Double.nan, .infinity, -.infinity, 2, 4.1, 9] {
        var line = good; line.words[0].end = badEnd; variants.append(line)
    }
    var noStart = good; noStart.start = nil; variants.append(noStart)
    var noWords = good; noWords.words = []; variants.append(noWords)
    var mismatch = good; mismatch.words[0].text = "Dark "; variants.append(mismatch)
    var reversed = good; reversed.words.reverse(); variants.append(reversed)
    var repeated = good; repeated.words[1].start = repeated.words[0].start; variants.append(repeated)
    var wrongCue = good; wrongCue.end = .nan; variants.append(wrongCue)
    for line in variants {
        #expect(!LyricEmphasis.hasUsableWordTiming(line))
        let choices = LyricEmphasis.choices(texts: ["Light", "returns"], line: line, suppliedWordTiming: true, seed: 0)
        #expect(choices.values.allSatisfy { $0.reason == .estimatedWord && $0.window != nil })
        #expect(LyricEmphasis.state(choice: .init(kind: .ring, reason: .wordOnset), line: line, unitIndex: 0, position: 2.5) == nil)
    }
    #expect(LyricEmphasis.choices(texts: ["Light", "returns"], line: good,
                                suppliedWordTiming: true, seed: 0).isEmpty)
}

@Test @MainActor func lyricEmphasisTimedPauseCompletesItsGestureAcrossTheNextWord() throws {
    let line = LyricLine(id: 0, text: "Light returns", start: 2, end: 8, words: [
        .init(id: 0, text: "Light ", start: 2.2, end: 2.6),
        .init(id: 1, text: "returns", start: 3.2, end: 4)
    ])
    let choice = LyricAccentChoice(kind: .box, reason: .pause)
    #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.19) == nil)
    #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.21) != nil)
    #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.55) != nil)
    #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.7) != nil)
    #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.93) != nil)
    let before = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 3.199))
    let after = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 3.201))
    #expect(abs(before.intensity - after.intensity) < 0.01)
    #expect(abs(before.scaleX - after.scaleX) < 0.002)
    #expect(after.progress == 1)
    #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 3.361) == nil)
    #expect(LyricEmphasis.state(choice: .init(kind: .weight, reason: .wordOnset), line: line, unitIndex: 1, position: 3.19) == nil)
    #expect(LyricEmphasis.state(choice: .init(kind: .weight, reason: .wordOnset), line: line, unitIndex: 1, position: 3.3) != nil)
}

@Test @MainActor func lyricEmphasisUntimedEventsUseVisualDelayThenLeaveReadingRestAndIgnoreAudio() {
    let line = LyricLine(id: 0, text: "Light returns quietly", start: 10, end: 16)
    let choice = LyricAccentChoice(kind: .ring, reason: .typography, delay: 0.4)
    var measured = VisualizationAudio(); measured.available = true; measured.beat = 1
    for position in [10.01, 10.14, 10.5, 10.9, 12.0, 15.9] {
        let first = LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: position)
        let later = LyricEmphasis.state(choice: choice, line: line, unitIndex: 5, position: position)
        #expect(first == later)
        #expect(first == LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: position, audio: measured))
    }
    #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 9.99) == nil)
    #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 10.39) == nil)
    #expect((LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 10.6)?.intensity ?? 0) > 0.5)
    #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 16) == nil)
    #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 12) == nil)
    #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 14) == nil)
}

@Test @MainActor func lyricEmphasisStatesAreFiniteBoundedAndReseekDeterministic() {
    let line = LyricLine(id: 0, text: "Light", start: 0, end: 8, words: [.init(id: 0, text: "Light", start: 1.25, end: 7)])
    for kind in LyricAccentKind.allCases {
        for reason in [LyricAccentReason.typography, .estimatedWord, .wordOnset, .sustain, .pause] {
            let choice = LyricAccentChoice(kind: kind, reason: reason)
            for beat in [Double.nan, .infinity, -.infinity, -1, 0, 0.5, 1, 2] {
                var audio = VisualizationAudio(); audio.available = true; audio.beat = beat
                for sample in 0...160 {
                    let position = Double(sample) * 0.05
                    let state = LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: position, audio: audio)
                    if let state {
                        #expect(state.intensity.isFinite && (0...1).contains(state.intensity))
                        #expect(state.progress.isFinite && (0...1).contains(state.progress))
                        #expect(state.weightBoost.isFinite && (0...1).contains(state.weightBoost))
                        #expect(state.offsetX.isFinite && (-0.06...0.06).contains(state.offsetX))
                        #expect(state.offsetY.isFinite && (-0.09...0.09).contains(state.offsetY))
                        #expect(state.scaleX.isFinite && (0.92...1.08).contains(state.scaleX))
                        #expect(state.scaleY.isFinite && (0.92...1.08).contains(state.scaleY))
                        #expect(state.rotation.isFinite && (-3...3).contains(state.rotation))
                        #expect(state.trail.isFinite && (0...1).contains(state.trail))
                    }
                    _ = LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 6.8, audio: audio)
                    #expect(state == LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: position, audio: audio))
                }
            }
            #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2, reduceMotion: true) == nil)
            for position in [Double.nan, .infinity, -.infinity] {
                #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: position) == nil)
            }
        }
    }
}

@Test @MainActor func lyricEmphasisAudioModulationRequiresMeasuredAvailableInput() {
    let line = LyricLine(id: 0, text: "Light", start: 0, end: 5, words: [.init(id: 0, text: "Light", start: 1, end: 4)])
    let choice = LyricAccentChoice(kind: .weight, reason: .sustain)
    var unavailable = VisualizationAudio(); unavailable.beat = 1
    var measured = unavailable; measured.available = true
    let baseline = LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2)
    #expect(baseline == LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2, audio: unavailable))
    #expect((LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2, audio: measured)?.intensity ?? 0) > (baseline?.intensity ?? 0))
    let recovery = LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 4.1)
    #expect(recovery != nil)
    #expect(recovery == LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 4.1, audio: measured))
    #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 4.6, audio: measured) == nil)
}

@Test @MainActor func lyricEmphasisFlashHasOneStrikeAndAQuieterReboundThenDisappears() {
    let line = LyricLine(id: 0, text: "Light", start: 0, end: 8)
    let choice = LyricAccentChoice(kind: .flash, reason: .typography)
    var maxima: [Double] = []
    let values = (0...800).map { index in
        LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: Double(index) / 100)?.intensity ?? 0
    }
    for index in 1..<(values.count - 1) where values[index] > values[index - 1] && values[index] >= values[index + 1] && values[index] > 0.1 {
        maxima.append(Double(index) / 100)
    }
    #expect(maxima.count == 2)
    if maxima.count == 2 {
        #expect(maxima[1] - maxima[0] > 0.28)
        #expect(values[Int(maxima[1] * 100)] < values[Int(maxima[0] * 100)] * 0.35)
    }
    #expect(values[100] == 0)
    #expect(values[300] == 0)
    #expect(values[700] == 0)
    #expect(values.max() ?? 0 <= 1)
}

@Test @MainActor func lyricEmphasisGesturesPrepareRecoilAndSettleWithDistinctDirections() throws {
    let line = LyricLine(id: 0, text: "Light", start: 0, end: 8)
    let ring = LyricAccentChoice(kind: .ring, reason: .typography)
    let preparation = try #require(LyricEmphasis.state(choice: ring, line: line, unitIndex: 0, position: 0.024))
    let strike = try #require(LyricEmphasis.state(choice: ring, line: line, unitIndex: 0, position: 0.184))
    let recoil = try #require(LyricEmphasis.state(choice: ring, line: line, unitIndex: 0, position: 0.36))
    let settle = try #require(LyricEmphasis.state(choice: ring, line: line, unitIndex: 0, position: 1.03))
    #expect(preparation.offsetY > 0)
    #expect(strike.offsetY < -0.05)
    #expect(recoil.offsetY > 0)
    #expect(abs(settle.offsetY) < 0.001)
    #expect(strike.trail == 0 && recoil.trail == 0)
    #expect(settle.trail > 0.8)
    let reverse = try #require(LyricEmphasis.state(choice: .init(kind: .ring, reason: .typography, direction: -1),
                                                   line: line, unitIndex: 0, position: 0.184))
    #expect(reverse.offsetX == -strike.offsetX)
    #expect(reverse.rotation == -strike.rotation)
    #expect(reverse.offsetY == strike.offsetY)
    let box = try #require(LyricEmphasis.state(choice: .init(kind: .box, reason: .typography),
                                               line: line, unitIndex: 0, position: 0.232))
    #expect(box.scaleX > 1.05)
    #expect(box.scaleY < 0.96)
    #expect(box.rotation < strike.rotation)
}

@Test @MainActor func lyricEmphasisDrawsFastFinishesSlowlyAndLimitsUnsuppliedEvents() throws {
    let line = LyricLine(id: 0, text: "Light", start: 5, end: 15)
    for kind in LyricAccentKind.allCases {
        let choice = LyricAccentChoice(kind: kind, reason: .typography, delay: 0.08)
        #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 5.07) == nil)
        let active = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 5.30))
        let later = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 5.72))
        #expect(active.progress > 0.7)
        #expect(later.progress > active.progress)
        #expect(later.progress <= 1)
        #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 6.4) == nil)
        #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 14) == nil)
    }
}

@Test @MainActor func lyricEmphasisTimedDelaysNeverShiftProviderOnsetsOrPauseTriggers() throws {
    let line = LyricLine(id: 9, text: "Light returns", start: 20, end: 26, words: [
        .init(id: 31, text: "Light ", start: 20.5, end: 21),
        .init(id: 32, text: "returns", start: 21.6, end: 24)
    ])
    let words = line.words
    let onTime = LyricAccentChoice(kind: .flash, reason: .wordOnset)
    let delayed = LyricAccentChoice(kind: .flash, reason: .wordOnset, delay: 1.4)
    #expect(LyricEmphasis.state(choice: delayed, line: line, unitIndex: 0, position: 20.49) == nil)
    let onset = try #require(LyricEmphasis.state(choice: delayed, line: line, unitIndex: 0, position: 20.6))
    #expect(onset == LyricEmphasis.state(choice: onTime, line: line, unitIndex: 0, position: 20.6))
    let pause = LyricAccentChoice(kind: .box, reason: .pause, delay: 1.4)
    #expect(LyricEmphasis.state(choice: pause, line: line, unitIndex: 0, position: 20.49) == nil)
    #expect(LyricEmphasis.state(choice: pause, line: line, unitIndex: 0, position: 20.55) != nil)
    #expect(LyricEmphasis.state(choice: pause, line: line, unitIndex: 0, position: 20.95) != nil)
    #expect(LyricEmphasis.state(choice: pause, line: line, unitIndex: 0, position: 21.6) != nil)
    #expect(LyricEmphasis.state(choice: pause, line: line, unitIndex: 0, position: 21.67) == nil)
    #expect(line.words == words)
    #expect(line.text == "Light returns")
    #expect(line.start == 20 && line.end == 26)
}

@Test @MainActor func lyricEmphasisMalformedVisualParametersCannotEscapeTransformBounds() {
    let line = LyricLine(id: 0, text: "Light", start: 0, end: 8)
    for delay in [Double.nan, .infinity, -.infinity, -4, 0, 12] {
        for direction in [Double.nan, .infinity, -.infinity, -4, 0, 12] {
            let choice = LyricAccentChoice(kind: .ring, reason: .typography, delay: delay, direction: direction)
            for position in [0.02, 0.2, 1.5, 1.7] {
                if let state = LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: position) {
                    #expect(state.offsetX.isFinite && (-0.06...0.06).contains(state.offsetX))
                    #expect(state.offsetY.isFinite && (-0.09...0.09).contains(state.offsetY))
                    #expect(state.rotation.isFinite && (-3...3).contains(state.rotation))
                    #expect(state.intensity.isFinite && (0...1).contains(state.intensity))
                }
            }
        }
    }
}

@Test @MainActor func lyricEmphasisSustainedWordUsesItsActualHoldAndRecoversContinuously() throws {
    let line = LyricLine(id: 0, text: "Light returns", start: 0, end: 8, words: [
        .init(id: 0, text: "Light ", start: 1, end: 5),
        .init(id: 1, text: "returns", start: 6, end: 7)
    ])
    let choice = LyricAccentChoice(kind: .pulse, reason: .sustain)
    let held = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 3))
    #expect(held.scaleX > 1.02)
    #expect(held.intensity > 0.3)
    let beforeEnd = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 4.999))
    let afterEnd = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 5.001))
    #expect(abs(beforeEnd.intensity - afterEnd.intensity) < 0.01)
    #expect(abs(beforeEnd.scaleX - afterEnd.scaleX) < 0.002)
    let recovered = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 5.339))
    #expect(recovered.intensity < 0.001)
    #expect(abs(recovered.scaleX - 1) < 0.001)
    #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 5.35) == nil)
    let unsupported = LyricLine(id: 0, text: "Light", start: 0, end: 8,
                                words: [.init(id: 0, text: "Light", start: 1)])
    #expect(LyricEmphasis.state(choice: choice, line: unsupported, unitIndex: 0, position: 3) == nil)
}

@Test @MainActor func lyricEmphasisManualChoicesKeepDefaultChoreographyWhileProductionUsesWordAllocation() throws {
    let manual = LyricAccentChoice(kind: .ring, reason: .typography)
    #expect(manual.delay == 0)
    #expect(manual.direction == 1)
    #expect(manual.window == nil)
    let text = "We return with a little golden light"
    let line = LyricLine(id: 0, text: text, start: 10, end: 30)
    for seed in 0..<40 {
        let choices = LyricEmphasis.choices(texts: LyricEmphasis.split(text), line: line,
                                          suppliedWordTiming: false, seed: UInt64(seed))
        #expect(choices.count == 2)
        for (index, choice) in choices {
            let window = try #require(choice.window)
            let onset = 10 + window.startOffset
            #expect(choice.reason == .estimatedWord)
            #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: index, position: onset - 0.001) == nil)
            #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: index, position: onset + 0.06) != nil)
            #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: index, position: onset + 1.5) == nil)
        }
    }
}

@Test @MainActor func lyricEstimatedAccentsFollowPronunciationIncludingFunctionWords() throws {
    let texts = ["The", " ", "light", " ", "returns"]
    let line = LyricLine(id: 1, text: texts.joined(), start: 12, end: 20)
    let choices = LyricEmphasis.choices(texts: texts, line: line, suppliedWordTiming: false, seed: 3)
    #expect(Set(choices.keys) == Set([2, 4]))
    let light = try #require(choices[2]?.window)
    let returns = try #require(choices[4]?.window)
    // The=1, light=1, returns=2 syllables: function words still occupy time.
    #expect(abs(light.startOffset - 0.55) < 0.000_001)
    #expect(abs(light.endOffset - 1.1) < 0.000_001)
    #expect(abs(returns.startOffset - 1.1) < 0.000_001)
    #expect(abs(returns.endOffset - 8) < 0.000_001)
    for (index, choice) in choices {
        let window = try #require(choice.window)
        let onset = 12 + window.startOffset
        #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: index, position: 12.1) == nil)
        #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: index, position: onset - 0.001) == nil)
        let attack = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: index, position: onset + 0.055))
        #expect(attack.intensity > 0.25)
        _ = LyricEmphasis.state(choice: choice, line: line, unitIndex: index, position: 19.8)
        #expect(attack == LyricEmphasis.state(choice: choice, line: line, unitIndex: index, position: onset + 0.055))
        #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: index, position: onset + 1.5) == nil)
    }
}

@Test @MainActor func lyricEstimatedAccentsUseCJKCharacterWeightsAndIgnoreWhitespaceEmoji() throws {
    let texts = ["的", "星光", "了", "回声"]
    let source = LyricLine(id: 2, text: texts.joined(), start: 5, end: 11)
    let plain = LyricEmphasis.choices(texts: texts, line: source, suppliedWordTiming: false, seed: 2)
    #expect(Set(plain.keys) == Set([1, 3]))
    let stars = try #require(plain[1]?.window)
    #expect(abs(stars.startOffset - 0.55) < 0.000_001 && abs(stars.endOffset - 1.65) < 0.000_001)
    #expect(plain[3]?.window == .init(startOffset: 2.2, endOffset: 6))
    let decoratedTexts = ["的", " \n👨‍👩‍👧‍👦 ", "星光", "了", "🌙\t", "回声"]
    let decorated = LyricLine(id: 3, text: decoratedTexts.joined(), start: 5, end: 11)
    let estimates = LyricEmphasis.choices(texts: decoratedTexts, line: decorated, suppliedWordTiming: false, seed: 2)
    #expect(estimates[2]?.window == plain[1]?.window)
    #expect(estimates[5]?.window == plain[3]?.window)
    let later = try #require(estimates[5]?.window)
    #expect(later.startOffset > 0)
}

@Test @MainActor func lyricEstimatedAccentsCountSyllablesAndCapPunctuationPauseBudget() throws {
    let plainTexts = ["love", " ", "beautiful"]
    let line = LyricLine(id: 0, text: plainTexts.joined(), start: 0, end: 4)
    let plain = LyricEmphasis.choices(texts: plainTexts, line: line, suppliedWordTiming: false, seed: 0)
    #expect(plain[0]?.window == .init(startOffset: 0, endOffset: 0.55))
    #expect(plain[2]?.window == .init(startOffset: 0.55, endOffset: 4))
    let punctuatedTexts = ["love", ",…!!!", " ", "beautiful"]
    let punctuated = LyricLine(id: 0, text: punctuatedTexts.joined(), start: 0, end: 4)
    let schedule = LyricEmphasis.choices(texts: punctuatedTexts, line: punctuated, suppliedWordTiming: false, seed: 0)
    let first = try #require(schedule[0]?.window), last = try #require(schedule[3]?.window)
    let gap = last.startOffset - first.endOffset
    #expect(gap > 0 && gap <= 4 * 0.14 + 0.000_001)
    #expect(last.startOffset > first.endOffset)
    #expect(last.endOffset <= 4)
    let longLine = LyricLine(id: 0, text: punctuated.text, start: 0, end: 60)
    let longSchedule = LyricEmphasis.choices(texts: punctuatedTexts, line: longLine, suppliedWordTiming: false, seed: 0)
    let longFirst = try #require(longSchedule[0]?.window), longLast = try #require(longSchedule[3]?.window)
    #expect(longLast.startOffset - longFirst.endOffset <= 0.9 + 0.000_001)
}

@Test @MainActor func lyricEstimatedAccentsAccountForDigitsAndPreserveRepeatedWordPositions() throws {
    let numericTexts = ["light", " ", "2026", " ", "rain"]
    let numeric = LyricLine(id: 0, text: numericTexts.joined(), start: 2, end: 8)
    let numberSchedule = LyricEmphasis.choices(texts: numericTexts, line: numeric, suppliedWordTiming: false, seed: 1)
    #expect(numberSchedule[0]?.window == .init(startOffset: 0, endOffset: 0.55))
    #expect(numberSchedule[4]?.window == .init(startOffset: 2.75, endOffset: 6))
    let texts = ["night", " ", "night"]
    let line = LyricLine(id: 0, text: texts.joined(), start: 12, end: 18)
    for seed in 0..<30 {
        let choices = LyricEmphasis.choices(texts: texts, line: line, suppliedWordTiming: false, seed: UInt64(seed))
        #expect(Set(choices.keys) == Set([0, 2]))
        let earlierWindow = try #require(choices[0]?.window)
        let laterWindow = try #require(choices[2]?.window)
        #expect(abs(earlierWindow.startOffset) < 0.000_001 && abs(earlierWindow.endOffset - 0.55) < 0.000_001)
        #expect(abs(laterWindow.startOffset - 0.55) < 0.000_001 && abs(laterWindow.endOffset - 6) < 0.000_001)
        let later = try #require(choices[2])
        #expect(LyricEmphasis.state(choice: later, line: line, unitIndex: 2, position: 12.1) == nil)
        #expect(LyricEmphasis.state(choice: later, line: line, unitIndex: 2, position: 12.61) != nil)
        let earlier = try #require(choices[0])
        #expect(LyricEmphasis.state(choice: earlier, line: line, unitIndex: 0, position: 15) == nil)
    }
}

@Test @MainActor func lyricEstimatedAccentsNeverInventWindowsForIncompleteOrUnboundedCues() {
    let text = "Light returns"
    let texts = LyricEmphasis.split(text)
    let variants: [LyricLine] = [
        .init(id: 0, text: text), .init(id: 0, text: text, start: 2),
        .init(id: 0, text: text, start: -1, end: 4), .init(id: 0, text: text, start: .nan, end: 4),
        .init(id: 0, text: text, start: 2, end: .nan), .init(id: 0, text: text, start: 2, end: .infinity),
        .init(id: 0, text: text, start: 2, end: 2), .init(id: 0, text: text, start: 2, end: 1),
        .init(id: 0, text: text, start: 2, end: 122.001)
    ]
    for line in variants {
        #expect(!LyricEmphasis.usesEstimatedTiming(line))
        #expect(LyricEmphasis.choices(texts: texts, line: line, suppliedWordTiming: false, seed: 0).isEmpty)
    }
    let bounded = LyricLine(id: 0, text: text, start: 2, end: 122)
    #expect(LyricEmphasis.usesEstimatedTiming(bounded))
    #expect(!LyricEmphasis.choices(texts: texts, line: bounded, suppliedWordTiming: false, seed: 0).isEmpty)
    #expect(LyricEmphasis.choices(texts: ["Wrong text"], line: bounded, suppliedWordTiming: false, seed: 0).isEmpty)
    let emoji = LyricLine(id: 0, text: "👨‍👩‍👧‍👦 🌙", start: 0, end: 5)
    #expect(!LyricEmphasis.usesEstimatedTiming(emoji))
    #expect(LyricEmphasis.choices(texts: LyricEmphasis.split(emoji.text), line: emoji, suppliedWordTiming: false, seed: 0).isEmpty)
}

@Test @MainActor func lyricEstimatedAccentsRejectMalformedWindowsAndRemainBoundedOnVeryShortCues() throws {
    let line = LyricLine(id: 0, text: "Light", start: 5, end: 8)
    let windows: [LyricAccentWindow?] = [nil,
        .init(startOffset: -.infinity, endOffset: 2), .init(startOffset: .nan, endOffset: 2),
        .init(startOffset: -1, endOffset: 2), .init(startOffset: 0, endOffset: .infinity),
        .init(startOffset: 0, endOffset: .nan), .init(startOffset: 0, endOffset: 3.001),
        .init(startOffset: 1, endOffset: 1), .init(startOffset: 2, endOffset: 1)
    ]
    for window in windows {
        let choice = LyricAccentChoice(kind: .ring, reason: .estimatedWord, window: window)
        #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 6) == nil)
    }
    let short = LyricLine(id: 0, text: "Light returns", start: 1, end: 1.03)
    let choices = LyricEmphasis.choices(texts: LyricEmphasis.split(short.text), line: short, suppliedWordTiming: false, seed: 0)
    #expect(choices.count == 1)
    for (index, choice) in choices {
        let window = try #require(choice.window)
        let position = 1 + (window.startOffset + window.endOffset) / 2
        let state = try #require(LyricEmphasis.state(choice: choice, line: short, unitIndex: index, position: position))
        #expect(state.intensity.isFinite && (0...1).contains(state.intensity))
        #expect((0.92...1.08).contains(state.scaleX))
        #expect((0.92...1.08).contains(state.scaleY))
        let interval = try #require(LyricEmphasis.eventInterval(choice: choice, line: short, unitIndex: index))
        #expect(interval.start < 1.03 && interval.end > 1.03)
        #expect(LyricEmphasis.state(choice: choice, line: short, unitIndex: index, position: 1.03) != nil)
        #expect(LyricEmphasis.state(choice: choice, line: short, unitIndex: index, position: interval.end) == nil)
        #expect(LyricEmphasis.state(choice: choice, line: short, unitIndex: index, position: position, reduceMotion: true) == nil)
    }
}

@Test @MainActor func lyricEmphasisRealTimingOverridesEstimatesAndSkipsSimultaneousZeroPrefixes() throws {
    let line = LyricLine(id: 4, text: "Light returns", start: 2, end: 8, words: [
        .init(id: 7, text: "Light ", start: 2.5, end: 2.5),
        .init(id: 9, text: "returns", start: 2.5, end: 6)
    ])
    let words = line.words
    #expect(LyricEmphasis.hasUsableWordTiming(line))
    #expect(!LyricEmphasis.usesEstimatedTiming(line))
    let choices = LyricEmphasis.choices(texts: line.words.map(\.text), line: line, suppliedWordTiming: true, seed: 0)
    #expect(Set(choices.keys) == Set([1]))
    #expect(choices[1]?.reason == .wordOnset)
    #expect(choices[1]?.window == nil)
    #expect(LyricEmphasis.state(choice: .init(kind: .ring, reason: .wordOnset), line: line, unitIndex: 0, position: 2.55) == nil)
    let actual = try #require(choices[1])
    #expect(LyricEmphasis.state(choice: actual, line: line, unitIndex: 1, position: 2.499) == nil)
    let attack = try #require(LyricEmphasis.state(choice: actual, line: line, unitIndex: 1, position: 2.555))
    #expect(attack.intensity > 0.3)
    #expect(line.words == words)
    let inferred = LyricAccentChoice(kind: .ring, reason: .estimatedWord, window: .init(startOffset: 1, endOffset: 2))
    #expect(LyricEmphasis.state(choice: inferred, line: line, unitIndex: 1, position: 3.1) == nil)
    var missingPrefixEnd = line; missingPrefixEnd.words[0].end = nil
    #expect(LyricEmphasis.hasUsableWordTiming(missingPrefixEnd))
    #expect(Set(LyricEmphasis.choices(texts: missingPrefixEnd.words.map(\.text), line: missingPrefixEnd,
                                    suppliedWordTiming: true, seed: 0).keys) == Set([1]))
}

@Test @MainActor func lyricEmphasisRealPauseAndLongSustainHaveImmediateWordAttack() throws {
    let line = LyricLine(id: 0, text: "Light returns", start: 0, end: 12, words: [
        .init(id: 0, text: "Light ", start: 1, end: 9),
        .init(id: 1, text: "returns", start: 10, end: 11)
    ])
    for reason in [LyricAccentReason.wordOnset, .sustain, .pause] {
        let choice = LyricAccentChoice(kind: reason == .pause ? .box : .weight, reason: reason)
        #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 0.999) == nil)
        let onset = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 1.065))
        #expect(onset.intensity > 0.3)
        #expect(abs(onset.offsetY) > 0.005 || abs(onset.scaleX - 1) > 0.02)
        #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 10) == nil)
    }
}

@Test @MainActor func lyricEstimatedAccentsDoNotClaimAudioTimingOrModifyOriginalLyrics() throws {
    let texts = ["The", " ", "light", " ", "returns"]
    let line = LyricLine(id: 41, text: texts.joined(), start: 4, end: 12)
    let snapshot = line
    let choices = LyricEmphasis.choices(texts: texts, line: line, suppliedWordTiming: false, seed: 9)
    var measured = VisualizationAudio(); measured.available = true; measured.beat = 1
    for (index, choice) in choices {
        let window = try #require(choice.window)
        let position = 4 + window.startOffset + 0.055
        let baseline = LyricEmphasis.state(choice: choice, line: line, unitIndex: index, position: position)
        #expect(baseline != nil)
        #expect(baseline == LyricEmphasis.state(choice: choice, line: line, unitIndex: index, position: position, audio: measured))
    }
    #expect(line == snapshot)
    #expect(line.words.isEmpty)
}

@Test @MainActor func lyricEmphasisTinyRealWordsKeepTheirFullGestureWithoutMovingTheTrigger() throws {
    let line = LyricLine(id: 5, text: "Light returns", start: 1, end: 7, words: [
        .init(id: 0, text: "Light ", start: 2, end: 2.04),
        .init(id: 1, text: "returns", start: 2.04, end: 5)
    ])
    let snapshot = line
    let durations: [LyricAccentKind: Double] = [.ring: 1.08, .box: 1.16, .flash: 0.84, .weight: 1.20, .pulse: 1.28, .triangle: 1.14]
    for kind in LyricAccentKind.allCases {
        for reason in [LyricAccentReason.wordOnset, .pause, .sustain] {
            let choice = LyricAccentChoice(kind: kind, reason: reason, delay: 1.4)
            #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 1.999) == nil)
            let beforeNext = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.039))
            let afterNext = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.041))
            #expect(abs(beforeNext.intensity - afterNext.intensity) < 0.06)
            #expect(abs(beforeNext.scaleX - afterNext.scaleX) < 0.01)
            let visible = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.065))
            #expect(visible.intensity > 0.3)
            #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.4) != nil)
            let duration = try #require(durations[kind])
            let settled = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0,
                                                         position: 2 + duration - 0.001))
            #expect(settled.intensity < 0.001)
            #expect(abs(settled.scaleX - 1) < 0.001)
            #expect(abs(settled.offsetY) < 0.001)
            #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2 + duration + 0.001) == nil)
            _ = LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 5.5)
            #expect(afterNext == LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.041))
            #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.4, reduceMotion: true) == nil)
        }
    }
    #expect(line == snapshot)
}

@Test @MainActor func lyricEstimatedTinyWordWindowOnlyControlsOnsetAndAllowsACompleteStroke() throws {
    let line = LyricLine(id: 6, text: "Light returns", start: 10, end: 16)
    let snapshot = line
    let durations: [LyricAccentKind: Double] = [.ring: 1.08, .box: 1.16, .flash: 0.84, .weight: 1.20, .pulse: 1.28, .triangle: 1.14]
    for kind in LyricAccentKind.allCases {
        let choice = LyricAccentChoice(kind: kind, reason: .estimatedWord,
                                      window: .init(startOffset: 1, endOffset: 1.04))
        #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 10.999) == nil)
        let before = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 11.039))
        let after = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 11.041))
        #expect(abs(before.intensity - after.intensity) < 0.06)
        let completed = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 11.32))
        #expect(completed.progress == 1)
        if kind == .ring || kind == .box || kind == .triangle { #expect(completed.intensity > 0.4) }
        #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 11.4) != nil)
        let duration = try #require(durations[kind])
        let recovered = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 11 + duration - 0.001))
        #expect(recovered.intensity < 0.001)
        #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 11 + duration + 0.001) == nil)
        _ = LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 15)
        #expect(after == LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 11.041))
    }
    #expect(line == snapshot)
    #expect(line.words.isEmpty)
}

@Test @MainActor func lyricEmphasisActualHoldRecoversBeyondTheImmediatelyFollowingWord() throws {
    let line = LyricLine(id: 7, text: "Light returns", start: 1, end: 7, words: [
        .init(id: 0, text: "Light ", start: 2, end: 5),
        .init(id: 1, text: "returns", start: 5, end: 6)
    ])
    for kind in [LyricAccentKind.weight, .pulse] {
        let choice = LyricAccentChoice(kind: kind, reason: .sustain)
        let before = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 4.999))
        let after = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 5.001))
        #expect(before.progress == 1 && after.progress == 1)
        #expect(abs(before.intensity - after.intensity) < 0.002)
        #expect(abs(before.scaleX - after.scaleX) < 0.001)
        let tail = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 5.339))
        #expect(tail.intensity < 0.001)
        #expect(abs(tail.scaleX - 1) < 0.001)
        #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 5.341) == nil)
    }
}

@Test @MainActor func lyricEmphasisLateWordsCompleteOneWholeCycleAcrossTheCueBoundary() throws {
    let line = LyricLine(id: 8, text: "Light returns", start: 1, end: 2.05, words: [
        .init(id: 0, text: "Light ", start: 2, end: 2.04),
        .init(id: 1, text: "returns", start: 2.04, end: 2.05)
    ])
    let original = line
    for kind in LyricAccentKind.allCases {
        for reason in [LyricAccentReason.wordOnset, .pause, .sustain] {
            let choice = LyricAccentChoice(kind: kind, reason: reason)
            let interval = try #require(LyricEmphasis.eventInterval(choice: choice, line: line, unitIndex: 0))
            #expect(interval.start == 2)
            #expect(interval.end > 2.8)
            #expect(interval.end - 2.05 <= LyricEmphasis.maximumTailDuration)
            #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 1.999) == nil)
            let before = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.049))
            let after = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.051))
            #expect(abs(before.intensity - after.intensity) < 0.04)
            #expect(abs(before.progress - after.progress) < 0.05)
            let complete = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.32))
            let presented = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.40))
            #expect(complete.progress == 1 && complete.trail == 0)
            #expect(presented.progress == 1 && presented.trail == 0)
            if [.ring, .box, .triangle].contains(kind) {
                #expect(complete.intensity > 0.4 && presented.intensity > 0.4)
            }
            let exiting = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0,
                                                         position: interval.start + (interval.end - interval.start) * 0.84))
            #expect(exiting.progress == 1 && exiting.trail > 0.5)
            let ended = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: interval.end - 0.001))
            #expect(ended.intensity < 0.001 && ended.trail > 0.999)
            #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: interval.end) == nil)
            _ = LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 20)
            #expect(after == LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.051))
            #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.40, reduceMotion: true) == nil)
        }
    }
    #expect(line == original)
}

@Test @MainActor func lyricEmphasisEstimatedFinalWordsCompleteWithoutInventingFutureOnsets() throws {
    let line = LyricLine(id: 9, text: "Light returns", start: 1, end: 2.05)
    let original = line
    for kind in LyricAccentKind.allCases {
        let choice = LyricAccentChoice(kind: kind, reason: .estimatedWord,
                                      window: .init(startOffset: 1, endOffset: line.end! - line.start!))
        let interval = try #require(LyricEmphasis.eventInterval(choice: choice, line: line, unitIndex: 0))
        #expect(interval.start == 2 && interval.end > 2.8)
        #expect(interval.end - 2.05 <= LyricEmphasis.maximumTailDuration)
        #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 1.999) == nil)
        let complete = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.32))
        #expect(complete.progress == 1 && complete.trail == 0)
        if [.ring, .box, .triangle].contains(kind) { #expect(complete.intensity > 0.4) }
        _ = LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 20)
        #expect(complete == LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 2.32))
        #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: interval.end) == nil)
        var invalid = choice; invalid.window = .init(startOffset: 1.05, endOffset: 1.06)
        #expect(LyricEmphasis.eventInterval(choice: invalid, line: line, unitIndex: 0) == nil)
        #expect(LyricEmphasis.state(choice: invalid, line: line, unitIndex: 0, position: 2.10) == nil)
        let delayed = LyricAccentChoice(kind: kind, reason: .typography, delay: 1.4)
        #expect(LyricEmphasis.eventInterval(choice: delayed, line: line, unitIndex: 0) == nil)
    }
    #expect(line == original && line.words.isEmpty)
}

@Test @MainActor func lyricEmphasisInkProgressAndExitNeverReverseOrEraseBeforeCompletion() throws {
    let line = LyricLine(id: 10, text: "Light", start: 1, end: 1.04,
                         words: [.init(id: 0, text: "Light", start: 1, end: 1.04)])
    for kind in LyricAccentKind.allCases {
        let choice = LyricAccentChoice(kind: kind, reason: .wordOnset)
        let interval = try #require(LyricEmphasis.eventInterval(choice: choice, line: line, unitIndex: 0))
        var precedingProgress = 0.0, precedingTrail = 0.0
        var sawCompleteHold = false, sawExit = false
        for sample in 0..<240 {
            let position = interval.start + (interval.end - interval.start) * Double(sample) / 240
            let state = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: position))
            #expect(state.progress >= precedingProgress && state.trail >= precedingTrail)
            if state.trail > 0 { #expect(state.progress == 1); sawExit = true }
            if state.progress == 1 && state.trail == 0 { sawCompleteHold = true }
            precedingProgress = state.progress; precedingTrail = state.trail
        }
        #expect(sawCompleteHold && sawExit)
    }
}

@Test @MainActor func lyricEmphasisRealSustainCompletesItsOwnReleaseAfterFinalCue() throws {
    let line = LyricLine(id: 11, text: "Light", start: 0, end: 4,
                         words: [.init(id: 0, text: "Light", start: 1, end: 4)])
    for kind in [LyricAccentKind.weight, .pulse] {
        let choice = LyricAccentChoice(kind: kind, reason: .sustain)
        let interval = try #require(LyricEmphasis.eventInterval(choice: choice, line: line, unitIndex: 0))
        #expect(interval.start == 1 && abs(interval.end - 4.34) < 0.000_001)
        #expect(interval.held)
        let before = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 3.999))
        let after = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 4.001))
        #expect(before.progress == 1 && before.trail == 0)
        #expect(after.progress == 1 && after.trail > 0)
        #expect(abs(before.intensity - after.intensity) < 0.01)
        let ended = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 4.339))
        #expect(ended.intensity < 0.001 && ended.trail > 0.999)
        #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 4.34) == nil)
    }
}

@Test @MainActor func lyricTriangleAccentAppendsWithoutChangingExistingKindsAndAppearsNaturally() {
    #expect(LyricAccentKind.ring.rawValue == 0)
    #expect(LyricAccentKind.box.rawValue == 1)
    #expect(LyricAccentKind.flash.rawValue == 2)
    #expect(LyricAccentKind.weight.rawValue == 3)
    #expect(LyricAccentKind.pulse.rawValue == 4)
    #expect(LyricAccentKind.triangle.rawValue == 5)
    let texts = ["The", " ", "light", " ", "returns"]
    let line = LyricLine(id: 12, text: texts.joined(), start: 2, end: 10)
    var triangleSeeds: [UInt64] = []
    for seed in 0..<64 {
        let choices = LyricEmphasis.choices(texts: texts, line: line, suppliedWordTiming: false, seed: UInt64(seed))
        #expect(choices.count <= 2)
        if choices.values.contains(where: { $0.kind == .triangle }) { triangleSeeds.append(UInt64(seed)) }
        #expect(choices == LyricEmphasis.choices(texts: texts, line: line, suppliedWordTiming: false, seed: UInt64(seed)))
    }
    #expect(!triangleSeeds.isEmpty)
    #expect(triangleSeeds.count < 64)
    #expect(line.words.isEmpty)
}

@Test @MainActor func lyricTriangleAccentStrikesOnTimeAndRecoversWithMirroredBoundedMotion() throws {
    let line = LyricLine(id: 13, text: "Light returns", start: 0, end: 4, words: [
        .init(id: 0, text: "Light ", start: 0.8, end: 0.84),
        .init(id: 1, text: "returns", start: 0.84, end: 3)
    ])
    let original = line
    let choice = LyricAccentChoice(kind: .triangle, reason: .wordOnset)
    let mirrored = LyricAccentChoice(kind: .triangle, reason: .wordOnset, direction: -1)
    #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 0.799) == nil)
    let strike = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 0.86))
    let reverse = try #require(LyricEmphasis.state(choice: mirrored, line: line, unitIndex: 0, position: 0.86))
    #expect(strike.intensity > 0.7)
    #expect(strike.offsetX > 0.03 && strike.offsetX <= 0.06)
    #expect(strike.offsetY < -0.04 && strike.offsetY >= -0.09)
    #expect(strike.scaleX > 1.05 && strike.scaleX <= 1.08)
    #expect(strike.scaleY > 1.025 && strike.scaleY <= 1.08)
    #expect(strike.rotation > 2 && strike.rotation <= 3)
    #expect(reverse.offsetX == -strike.offsetX)
    #expect(reverse.rotation == -strike.rotation)
    #expect(reverse.offsetY == strike.offsetY)
    #expect(reverse.scaleX == strike.scaleX)
    let drawn = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 1.12))
    #expect(drawn.progress == 1 && drawn.intensity > 0.4)
    let settled = try #require(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 1.939))
    #expect(settled.intensity < 0.001)
    #expect(abs(settled.scaleX - 1) < 0.001 && abs(settled.offsetY) < 0.001)
    #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 1.941) == nil)
    _ = LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 3.5)
    #expect(strike == LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 0.86))
    #expect(LyricEmphasis.state(choice: choice, line: line, unitIndex: 0, position: 0.86, reduceMotion: true) == nil)
    #expect(line == original)
}
