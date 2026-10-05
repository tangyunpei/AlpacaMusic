import Foundation
import Testing
@testable import AlpacaMusic

@Test @MainActor func lyricPhrasingBalancesEveryRowOfLongChineseSentences() {
    let samples = [
        "我们沿着缓缓展开的地平线走向远处仍然亮着灯的一扇小小窗户",
        "我們沿著緩緩展開的地平線走向遠處仍然亮著燈的一扇小小窗戶",
        "把每一个安静的念头留在风中让明天的晨光慢慢经过我们的窗前"
    ]
    for text in samples {
        let result = LyricPhrasing.phrases(text, targetCount: 3, maximumUnits: 8)
        #expect(result.joined() == text)
        #expect(result.count >= 4)
        #expect(result.allSatisfy { LyricPhrasing.widthUnits($0) <= 8.000_001 })
        #expect(result.allSatisfy { LyricPhrasing.widthUnits($0) > 2 })
        #expect(result.dropLast().allSatisfy { !$0.hasSuffix("把") && !$0.hasSuffix("被") && !$0.hasSuffix("的") })
    }
}

@Test @MainActor func lyricPhrasingKeepsPunctuationAndSpacesWithTheirOriginalText() {
    let text = "让每一次停顿，都有呼吸的空间； 把风留在身后，慢慢向前。"
    let result = LyricPhrasing.phrases(text, targetCount: 3, maximumUnits: 9)
    #expect(result.joined() == text)
    #expect(result.contains { $0.hasSuffix("，") || $0.hasSuffix("； ") })
    #expect(result.contains { $0.hasSuffix("停顿，") })
    #expect(result.contains { $0.hasPrefix("都有呼吸") })
    let closing = Set<Character>("，。！？；：、）》」』】〉〕］｝’”.,!?;:%％…")
    #expect(result.dropFirst().allSatisfy { phrase in
        phrase.trimmingCharacters(in: .whitespacesAndNewlines).first.map { !closing.contains($0) } ?? true
    })
    #expect(result.allSatisfy { LyricPhrasing.widthUnits($0) <= 9.000_001 })
}

@Test @MainActor func lyricPhrasingPreservesEnglishWordsContractionsAndHyphens() {
    let text = "Don't let the well-known melody drift beyond the quiet room."
    let result = LyricPhrasing.phrases(text, targetCount: 3, maximumUnits: 8)
    #expect(result.joined() == text)
    #expect(result.contains { $0.contains("Don't") })
    #expect(result.contains { $0.contains("well-known") })
    #expect(result.allSatisfy { LyricPhrasing.widthUnits($0) <= 8.000_001 })
    #expect(result.dropLast().allSatisfy { !$0.hasSuffix("-") && !$0.hasSuffix("'") })
}

@Test @MainActor func lyricPhrasingTreatsMixedChineseEnglishAsOneLanguageAwareSentence() {
    let text = "这个夜晚 we keep a little light 然后沿着海边的小路慢慢回家"
    let result = LyricPhrasing.phrases(text, targetCount: 3, maximumUnits: 8)
    #expect(result.joined() == text)
    #expect(result.count >= 4)
    #expect(result.allSatisfy { LyricPhrasing.widthUnits($0) <= 8.000_001 })
    #expect(result.contains { $0.contains("little") })
    #expect(result.contains { $0.contains("light") })
    #expect(!(result.last?.contains("然后沿着海边的小路慢慢回家") ?? true))
}

@Test @MainActor func lyricPhrasingPreservesEmojiGraphemesCombiningMarksAndNewlines() {
    let text = "  🌙 把夜色留给 👨‍👩‍👧‍👦 每一扇窗\nCafe\u{301} beside the rain ✨\n\n让灯光慢慢落下  "
    let result = LyricPhrasing.phrases(text, targetCount: 4, maximumUnits: 8)
    #expect(result.joined() == text)
    #expect(result.contains { $0.contains("👨‍👩‍👧‍👦") })
    #expect(result.contains { $0.contains("e\u{301}") })
    #expect(result.filter { $0.contains("\n") }.count == 3)
    #expect(!result.contains { $0.contains("窗\nCafe") })
    #expect(result.first?.hasPrefix("  ") == true)
    #expect(result.last?.hasSuffix("  ") == true)
}

@Test @MainActor func lyricPhrasingAllowsOnlyIndivisibleLongTokensBeyondTheBudget() {
    let token = "Supercalifragilisticexpialidocious"
    let text = "A \(token) moment waits quietly"
    let result = LyricPhrasing.phrases(text, targetCount: 3, maximumUnits: 6)
    #expect(result.joined() == text)
    let overBudget = result.filter { LyricPhrasing.widthUnits($0) > 6.000_001 }
    #expect(overBudget.count == 1)
    #expect(overBudget.first?.trimmingCharacters(in: .whitespaces) == token)
}

@Test @MainActor func lyricPhrasingDefensiveLimitsStayDeterministicAndLossless() {
    let text = "每一次安静的停顿都能让我们看见更远的地方"
    #expect(LyricPhrasing.phrases(text, targetCount: Int.min, maximumUnits: .nan) == LyricPhrasing.phrases(text, targetCount: 1))
    #expect(LyricPhrasing.phrases(text, targetCount: Int.max, maximumUnits: -.infinity) == LyricPhrasing.phrases(text, targetCount: 6))
    #expect(LyricPhrasing.phrases("", targetCount: 3).isEmpty)
    #expect(LyricPhrasing.phrases(" \t\n ", targetCount: 3).joined() == " \t\n ")
    let extreme = String(repeating: "不改变任何一个原来的字", count: 300)
    #expect(LyricPhrasing.phrases(extreme, targetCount: 6, maximumUnits: 6) == [extreme])
    #expect(LyricPhrasing.widthUnits("abc") == 1.5)
    #expect(LyricPhrasing.widthUnits("ＡＢＣ") == 3)
    #expect(LyricPhrasing.widthUnits("夜色") == 2)
    #expect(LyricPhrasing.widthUnits("👨‍👩‍👧‍👦") == 1)
}

@Test @MainActor func lyricPhrasingRepresentativePartitionsForReview() {
    for text in [
        "我们沿着缓缓展开的地平线走向远处仍然亮着灯的一扇小小窗户",
        "让每一次停顿，都有呼吸的空间； 把风留在身后，慢慢向前。",
        "Don't let the well-known melody drift beyond the quiet room."
    ] {
        let result = LyricPhrasing.phrases(text, targetCount: 3, maximumUnits: 8)
        print("PHRASING_REVIEW: \(result)")
        #expect(result.joined() == text)
    }
}

@Test @MainActor func lyricPhrasingKeepsChineseNumeralsAndClassifiersTogether() {
    let samples: [(String, [String])] = [
        ("亮着灯的一扇小小窗户", ["一扇"]),
        ("让这一首歌走过两个夜晚然后留在每个安静的房间", ["一首", "两个", "每个"]),
        ("讓這一首歌走過兩個夜晚然後留在這扇安靜的窗前", ["一首", "兩個", "這扇"])
    ]
    for (text, atoms) in samples {
        for budget in [4.0, 6.0, 8.0] {
            let result = LyricPhrasing.phrases(text, targetCount: 3, maximumUnits: budget)
            #expect(result.joined() == text)
            for atom in atoms { #expect(result.contains { $0.contains(atom) }) }
        }
    }
}

@Test @MainActor func lyricPhrasingKeepsOpeningQuotesAndBracketsWithTheFollowingText() {
    let opening = Set<Character>("（([｛［《〈「『【〔“‘")
    for text in ["把这一句「轻轻的话」留给明天", "记得（每一阵晚风）经过窗前", "留下一句“安静的问候”然后回家", "看见（ 风中的树影）继续向前"] {
        let result = LyricPhrasing.phrases(text, targetCount: 3, maximumUnits: 6)
        #expect(result.joined() == text)
        #expect(result.dropLast().allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).last.map { !opening.contains($0) } ?? true
        })
    }
}

@Test @MainActor func lyricPhrasingPrefersOriginalChineseMusicalPhraseSpacesWithoutHardCuts() {
    let text = "别离开身边 拥有你 我的世界才能完美"
    let result = LyricPhrasing.phrases(text, targetCount: 3, maximumUnits: 8)
    #expect(result == ["别离开身边 ", "拥有你 ", "我的世界才能完美"])
    #expect(result.joined() == text)
    let tiny = "光 在风里 回家"
    let balanced = LyricPhrasing.phrases(tiny, targetCount: 3, maximumUnits: 8)
    #expect(balanced.joined() == tiny)
    #expect(!balanced.contains { $0.trimmingCharacters(in: .whitespaces) == "光" })
}
