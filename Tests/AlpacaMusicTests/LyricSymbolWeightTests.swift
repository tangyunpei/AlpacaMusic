import Foundation
import Testing
@testable import AlpacaMusic

/// Symbols nobody sings must not take a slot in a line-only estimate: adding
/// one leaves every later syllable where it was.
@Suite @MainActor struct LyricSymbolWeightTests {
    private let context = LyricTimingContext(secondsPerSyllable: 0.4)

    /// Total sung units, rounded so per-letter shares of a word add up exactly.
    private func weight(_ text: String) -> Double {
        ((LyricEmphasis.estimatedPronunciation(text)?.speech.reduce(0, +) ?? -1) * 1_000).rounded() / 1_000
    }
    /// Onsets of the graphemes whose base is a letter or digit, in order.
    private func sungOnsets(_ text: String, start: Double = 10, end: Double = 20) -> [Double] {
        let line = LyricLine(id: 0, text: text, start: start, end: end)
        return zip(Array(text), LyricReveal.timeline(for: line, context: context).units)
            .filter { character, _ in character.unicodeScalars.first.map { CharacterSet.alphanumerics.contains($0) } == true }
            .map { $0.1.start }
    }
    private func same(_ left: [Double], _ right: [Double]) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy { abs($0 - $1) < 0.000_1 }
    }

    @Test func silentMarksAndEmojiLeaveLaterSyllablesInPlace() {
        // The kana middle dot, emoji with a variation selector, and quotes.
        #expect(same(sungOnsets("ラ・ラ・ランド"), sungOnsets("ララランド")))
        #expect(weight("ラ・ラ・ランド") == 5)
        #expect(same(sungOnsets("我爱你❤️宝贝"), sungOnsets("我爱你宝贝")))
        #expect(same(sungOnsets("「ジョン・レノン」"), sungOnsets("ジョンレノン")))
        #expect(weight("♪ ✨ ❤️‍🔥 ※ 〜") == 0)
        // A line of only marks has nothing to sing and appears at its start.
        #expect(weight("「・・・ーーー・・・」") == 0)
        let morse = LyricReveal.timeline(for: LyricLine(id: 0, text: "「・・・ーーー・・・」", start: 4, end: 18), context: context)
        #expect(morse.units.allSatisfy { $0.start == 4 })
    }

    @Test func otherAlphabetsAreWeighedByWordNotByLetter() {
        #expect(same(sungOnsets("ＬＯＶＥ ＬＯＶＥ 我爱你"), sungOnsets("LOVE LOVE 我爱你")))
        #expect(weight("ＬＯＶＥ ｍｅ") == weight("LOVE me"))
        #expect(weight("Привет мир") == 3)
        #expect(weight("αγάπη μου") == 4)
        // Precomposed and decomposed Vietnamese spell the same words.
        let composed = "Việt Nam", decomposed = composed.decomposedStringWithCanonicalMapping
        #expect(weight(composed) == weight(decomposed))
        #expect(weight(composed) == 2)
        #expect(weight("dʼaccord") == weight("d'accord"))
        // Every Russian vowel letter is a syllable, and й is a consonant.
        #expect(weight("моя") == 2 && weight("район") == 2 && weight("её") == 2)
        // Modifier letters and emoji are not sung, even when Unicode calls them letters.
        #expect(weight("goinʼ") == weight("goin'") && weight("goin'") == 1)
        #expect(weight("ℹ️") == 0 && weight("™") == 0)
        #expect(weight("Hawaiʻi") == 3)
    }

    @Test func smallKanaAndHeldVowelsFollowMorae() throws {
        // きゃ is one mora: the small kana appears with the kana it follows.
        #expect(weight("しゃしん") == 3)
        #expect(weight("きゃりーぱみゅぱみゅ") == 7)
        let line = LyricLine(id: 0, text: "しゃしん", start: 10, end: 20)
        let units = LyricReveal.timeline(for: line, context: context).units
        #expect(units[0].start == units[1].start)
        let pace = units[2].start - 10
        #expect(pace > 0.2 && abs(units[3].start - 10 - 2 * pace) < 0.000_1)
        // ー holds a sung vowel, but not a dash run after a symbol.
        #expect(weight("ラーメン") == 4)
        #expect(weight("あーーー") == 4)
        #expect(weight("・ーー") == 0)
        // Small kana with nothing before it still takes its own mora.
        #expect(weight("ぁあ") == 2)
        // A provider word that starts with ー continues the word before it and
        // keeps its measured window.
        let held = LyricLine(id: 0, text: "ラー、メン", start: 10, end: 12.2, words: [
            .init(id: 0, text: "ラ", start: 10, end: 10.3), .init(id: 1, text: "ー、", start: 10.3, end: 11.5),
            .init(id: 2, text: "メ", start: 11.5, end: 11.8), .init(id: 3, text: "ン", start: 11.8, end: 12.2)
        ])
        let vowel = try #require(LyricReveal.timeline(for: held, context: context).units.first { $0.text == "ー" })
        #expect(vowel.start == 10.3 && vowel.end == 11.5)
    }

    @Test func digitsCountButSymbolKeycapsAndJamoDoNot() {
        #expect(weight("1️⃣2️⃣3") == 3)
        #expect(weight("#️⃣") == 0)
        #expect(weight("２０２４年") == 5)
        #expect(weight("二〇二四年") == 5)
        #expect(weight("ㅠㅠ 보고싶어") == 4)
    }

    @Test func aClosingMarkStaysVisibleWhenSingingFillsTheLine() throws {
        // Thirty syllables in four seconds: singing fills the whole cue, so the
        // period would otherwise appear exactly as the line stops being shown.
        let dense = String(repeating: "我", count: 30) + "。"
        for (start, end) in [(10.0, 14.0), (0.37, 4.37), (0.37, 2.21)] {
            let line = LyricLine(id: 0, text: dense, start: start, end: end)
            let units = LyricReveal.timeline(for: line, context: context).units
            let period = try #require(units.last), sung = units[units.count - 2]
            #expect(period.start > sung.start && period.start < end - 0.01, "\(start)-\(end)")
        }
        // With time to spare it still appears as the phrase ends, three
        // syllables in; a trailing mark costs no time of its own.
        let roomy = LyricReveal.timeline(for: LyricLine(id: 0, text: "我爱你。", start: 10, end: 20), context: context).units
        let pace = roomy[1].start - 10
        #expect(abs((roomy.last?.start ?? 0) - (10 + 3 * pace)) < 0.000_1)
    }
}
