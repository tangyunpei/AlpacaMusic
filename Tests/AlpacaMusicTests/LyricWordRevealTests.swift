import Foundation
import SwiftUI
import Testing
@testable import AlpacaMusic

@Suite @MainActor struct LyricWordRevealTests {
    private static func word(_ text: String, in line: LyricLine) throws -> [LyricRevealUnit] {
        let range = try #require(line.text.range(of: text))
        let first = line.text.distance(from: line.text.startIndex, to: range.lowerBound)
        let last = line.text.distance(from: line.text.startIndex, to: range.upperBound)
        return Array(LyricReveal.timeline(for: line).units[first..<last])
    }

    private static func expectAtomic(_ units: [LyricRevealUnit]) throws {
        let first = try #require(units.first)
        #expect(units.allSatisfy { $0.revealStart == first.revealStart && $0.revealEnd == first.revealEnd })
        for position in [first.revealStart - 0.01, first.revealStart,
                         first.revealStart + 0.025, first.revealStart + 0.08, first.revealEnd + 0.1] {
            #expect(units.allSatisfy { $0.opacity(at: position) == first.opacity(at: position) })
            #expect(units.allSatisfy { $0.opacity(at: position, reduceMotion: true) == first.opacity(at: position, reduceMotion: true) })
        }
        #expect(units.allSatisfy { $0.opacity(at: first.revealStart - 0.001) == 0 })
        #expect(units.allSatisfy { $0.opacity(at: first.revealEnd + 0.1) == 1 })
    }

    @Test func englishAndSpanishRevealAsWholeWordsWithSeparateOnsets() throws {
        for (text, words) in [
            ("Every quiet ocean returns", ["Every", "quiet", "ocean", "returns"]),
            ("¿Cómo estás, corazón?", ["Cómo", "estás", "corazón"])
        ] {
            let line = LyricLine(id: 100, text: text, start: 2, end: 10)
            var previous: Double?
            for text in words {
                let units = try Self.word(text, in: line)
                try Self.expectAtomic(units)
                let first = try #require(units.first)
                if let previous { #expect(first.revealStart > previous) }
                previous = first.revealStart
            }
            #expect(LyricReveal.timeline(for: line).units.map(\.text).joined() == text)
        }
    }

    @Test func accentsCombiningMarksAndCasedAlphabetsKeepWholeWords() throws {
        let words = ["cafe\u{301}", "pingüino", "mañana", "đường", "Νύχτα", "Привет"]
        let line = LyricLine(id: 101, text: words.joined(separator: " "), start: 0, end: 16)
        for text in words {
            let units = try Self.word(text, in: line)
            try Self.expectAtomic(units)
            #expect(units.count == text.count)
            #expect(units.allSatisfy { $0.text.count == 1 })
            #expect(units.map(\.text).joined() == text)
        }
        #expect(try Self.word("cafe\u{301}", in: line).last?.text == "e\u{301}")
    }

    @Test func internalApostrophesAndHyphensDoNotTypeSeparately() throws {
        let words = ["don't", "don’t", "l’amour", "rock’n’roll", "dʼaccord", "well-known", "non‑stop", "re‐enter", "B2B"]
        let line = LyricLine(id: 102, text: words.joined(separator: " "), start: 1, end: 20)
        for text in words { try Self.expectAtomic(Self.word(text, in: line)) }
    }

    @Test func whitespacePunctuationAndEmojiCannotMergeAdjacentWords() throws {
        let line = LyricLine(id: 103, text: "'Hola'—mundo,hello\nworld 👩🏽‍🚀light", start: 0, end: 12)
        var onsets: [Double] = []
        for text in ["Hola", "mundo", "hello", "world", "light"] {
            let units = try Self.word(text, in: line)
            try Self.expectAtomic(units)
            onsets.append(try #require(units.first?.revealStart))
        }
        #expect(zip(onsets, onsets.dropFirst()).allSatisfy { $0 < $1 })
        let timeline = LyricReveal.timeline(for: line)
        #expect(timeline.units.map(\.text).joined() == line.text)
        #expect(timeline.units.filter { $0.text == "👩🏽‍🚀" }.count == 1)
    }

    @Test func mixedChineseLatinAndNumbersRetainTheirOwnGranularity() throws {
        let line = LyricLine(id: 104, text: "我love你mañana好 123", start: 0, end: 12)
        try Self.expectAtomic(Self.word("love", in: line))
        try Self.expectAtomic(Self.word("mañana", in: line))
        let timeline = LyricReveal.timeline(for: line)
        for unit in timeline.units where ["我", "你", "好", "1", "2", "3"].contains(unit.text) {
            #expect(unit.revealStart == unit.start && unit.revealEnd == unit.end)
        }
        let chinese = timeline.units.filter { ["我", "你", "好"].contains($0.text) }
        #expect(Set(chinese.map(\.revealStart)).count == 3)
        let digits = try Self.word("123", in: line)
        #expect(Set(digits.map(\.revealStart)).count == 3)
        #expect(timeline.units.map(\.text).joined() == line.text)
    }

    @Test func providerWholeWordsKeepTheSingingWindowAndPause() throws {
        let line = LyricLine(id: 105, text: "hello mundo", start: 0, end: 7, words: [
            .init(id: 0, text: "hello ", start: 1.2, end: 2.4),
            .init(id: 1, text: "mundo", start: 4.2, end: 6)
        ])
        let hello = try Self.word("hello", in: line)
        let mundo = try Self.word("mundo", in: line)
        try Self.expectAtomic(hello)
        try Self.expectAtomic(mundo)
        #expect(hello.allSatisfy { abs($0.revealStart - 1.2) < 0.000_001 && abs($0.revealEnd - 2.4) < 0.000_001 })
        #expect(mundo.allSatisfy { abs($0.revealStart - 4.2) < 0.000_001 && abs($0.revealEnd - 6) < 0.000_001 })
        #expect(hello.allSatisfy { $0.opacity(at: 3.5) == 1 })
        #expect(mundo.allSatisfy { $0.opacity(at: 3.5) == 0 })
        #expect(Set(hello.map(\.start)).count > 1)
    }

    @Test func providerLettersAndSyllablesJoinOnlyInTheRevealClock() throws {
        let line = LyricLine(id: 106, text: "hello mundo", start: 0, end: 6, words: [
            .init(id: 0, text: "h", start: 0.4, end: 0.6),
            .init(id: 1, text: "e", start: 0.7, end: 0.9),
            .init(id: 2, text: "l", start: 1, end: 1.2),
            .init(id: 3, text: "l", start: 1.3, end: 1.5),
            .init(id: 4, text: "o ", start: 1.6, end: 1.9),
            .init(id: 5, text: "mun", start: 3, end: 3.6),
            .init(id: 6, text: "do", start: 3.9, end: 4.8)
        ])
        let snapshot = line
        let hello = try Self.word("hello", in: line)
        let mundo = try Self.word("mundo", in: line)
        try Self.expectAtomic(hello)
        try Self.expectAtomic(mundo)
        #expect(hello.map(\.start) == [0.4, 0.7, 1, 1.3, 1.6])
        #expect(hello.allSatisfy { $0.revealStart == 0.4 && $0.revealEnd == 1.9 })
        #expect(mundo.allSatisfy { $0.revealStart == 3 && abs($0.revealEnd - 4.8) < 0.000_001 })
        let last = try #require(hello.last)
        #expect(last.progress(at: 0.55) == 0 && last.opacity(at: 0.55) == 1)
        #expect(line == snapshot)
    }

    @Test func longWordCueLeavesATailWithoutDelayingEveryWordAndSeeksWithoutHistory() throws {
        let fast = LyricLine(id: 107, text: "quiet ocean returns", start: 10, end: 13)
        let slow = LyricLine(id: 108, text: fast.text, start: 10, end: 22)
        for text in ["quiet", "ocean", "returns"] {
            let a = try #require(Self.word(text, in: fast).first)
            let b = try #require(Self.word(text, in: slow).first)
            #expect(b.revealStart <= a.revealStart + 0.5)
            #expect(b.revealStart < 13)
        }
        #expect(try Self.word("returns", in: slow).last?.revealEnd == 22)
        let timeline = LyricReveal.timeline(for: slow)
        for position in [20.0, 11, 20, 9, 24, 11] {
            let again = LyricReveal.timeline(for: slow)
            #expect(again == timeline)
            #expect(again.units.map { $0.opacity(at: position) } == timeline.units.map { $0.opacity(at: position) })
        }
        let ocean = try Self.word("ocean", in: slow)
        let onset = try #require(ocean.first?.revealStart)
        #expect(ocean.allSatisfy { $0.opacity(at: onset, reduceMotion: true) == 1 })
        #expect(ocean.allSatisfy { $0.opacity(at: onset - 0.001, reduceMotion: true) == 0 })
    }

    @Test func manyShortWordsDoNotFallBackToOneSentenceReveal() throws {
        let line = LyricLine(id: 109, text: Array(repeating: "la", count: 300).joined(separator: " "), start: 0, end: 60)
        let timeline = LyricReveal.timeline(for: line)
        #expect(timeline.isTimed)
        let letters = timeline.units.filter { !$0.text.allSatisfy(\.isWhitespace) }
        try #require(letters.count == 600)
        #expect(Set(letters.map(\.revealStart)).count == 300)
        for index in stride(from: 0, to: letters.count, by: 2) {
            #expect(letters[index].revealStart == letters[index + 1].revealStart)
            #expect(letters[index].revealEnd == letters[index + 1].revealEnd)
            if index > 0 { #expect(letters[index].revealStart > letters[index - 1].revealStart) }
        }
    }

    @Test func layoutRemappingPreservesAtomicWordsAndGraphemeGeometry() throws {
        let line = LyricLine(id: 110, text: "hello mundo", start: 0, end: 6)
        let timeline = LyricReveal.timeline(for: line)
        let fragments = timeline.fragments(["hel", "lo\n", "mundo"])
        #expect(fragments.map { $0.map(\.text).joined() } == ["hel", "lo\n", "mundo"])
        let hello = Array(fragments.prefix(2).flatMap { $0 }.filter { !$0.text.allSatisfy(\.isWhitespace) })
        try Self.expectAtomic(hello)
        #expect(hello.map(\.text).joined() == "hello")
        #expect(timeline.fragments(["hello world"]).isEmpty)
    }

    @Test func everyKineticCompositionRevealsTheWholeWordTogether() throws {
        let line = LyricLine(id: 111, text: "Hello mundo 夜色", start: 1, end: 9)
        let timeline = LyricReveal.timeline(for: line)
        let first = try #require(timeline.units.first)
        let second = try #require(Self.word("mundo", in: line).first)
        for scene in LyricScene.allCases {
            for position in [first.revealStart - 0.01, first.revealStart + 0.04,
                             second.revealStart - 0.01, second.revealStart + 0.04, 9] {
                let pieces = LyricTypography.layout(line: line, index: scene.rawValue,
                                                    in: CGSize(width: 960, height: 540), position: position,
                                                    reduceMotion: false)
                let samples = pieces.flatMap { LyricGlyphRenderer.samples(for: $0, position: position) }
                #expect(samples.map(\.text).joined() == line.text)
                try #require(samples.count == line.text.count)
                #expect(pieces.flatMap { LyricGlyphRenderer.regions(for: $0) }.count == line.text.count)
                let helloSamples = Array(samples[0..<5])
                let mundoSamples = Array(samples[6..<11])
                #expect(helloSamples.allSatisfy { $0.opacity == first.opacity(at: position) })
                #expect(mundoSamples.allSatisfy { $0.opacity == second.opacity(at: position) })
                if position < second.revealStart { #expect(mundoSamples.allSatisfy { $0.opacity == 0 }) }
            }
        }
    }
}
