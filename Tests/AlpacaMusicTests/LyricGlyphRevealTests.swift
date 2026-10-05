import AppKit
import SwiftUI
import Testing
@testable import AlpacaMusic

@Test @MainActor func kineticRevealCoversEveryCompositionAndPreservesCompleteText() throws {
    let line = LyricLine(id: 24, text: "让夜色慢慢经过那扇小窗", start: 2, end: 10)
    for scene in LyricScene.allCases {
        let pieces = LyricTypography.layout(line: line, index: scene.rawValue,
                                            in: CGSize(width: 960, height: 540), position: 2.15, reduceMotion: false)
        #expect(pieces.map(\.text).joined() == line.text)
        #expect(pieces.flatMap(\.revealUnits).map(\.text).joined() == line.text)
        let early = pieces.flatMap { LyricGlyphRenderer.samples(for: $0, position: 2.15) }
        let complete = pieces.flatMap { LyricGlyphRenderer.samples(for: $0, position: 10) }
        #expect(early.contains { $0.opacity == 0 })
        #expect(early.contains { $0.opacity > 0 })
        #expect(complete.allSatisfy { $0.opacity == 1 && $0.lift == 0 })
        #expect(pieces.flatMap { LyricGlyphRenderer.samples(for: $0, position: 1.9) }.allSatisfy { $0.opacity == 0 })
    }
}

@Test @MainActor func kineticEchoesCannotExposeFutureCharacters() throws {
    let lines = (0..<16).map { index in
        let start = Double(index) * 10
        return LyricLine(id: index, text: "Every quiet beginning has a place", start: start, end: start + 8)
    }
    let document = LyricDocument(lines: lines, timing: .line, sourceDescription: "Fixture")
    var observedDecorations = Set<Int>()
    // The director uses the cue's position in its document, not line.id. Keep
    // the real preceding cues so these samples exercise distinct directions.
    for index in lines.indices {
        let position = (lines[index].start ?? 0) + 0.1
        let direction = LyricTypography.director(line: lines[index], index: index)
        let frame = LyricTypography.frame(document: document, position: position,
                                          in: CGSize(width: 960, height: 540), reduceMotion: false)
        let echoes = frame.fragments.filter { $0.role == .echo }
        if direction.decoration != .quiet {
            #expect(!echoes.isEmpty)
            observedDecorations.insert(direction.decoration.rawValue)
        }
        for echo in echoes {
            #expect(echo.revealUnits.count == echo.text.count)
            let samples = LyricGlyphRenderer.samples(for: echo, position: position)
            for (sample, unit) in zip(samples, echo.revealUnits) where unit.revealStart > position {
                #expect(sample.opacity == 0)
            }
        }
    }
    #expect(observedDecorations.count == 3)
}

@Test @MainActor func reducedMotionRetainsSingingClockWithoutCharacterMovement() throws {
    let line = LyricLine(id: 0, text: "夜色慢慢亮起", start: 1, end: 7)
    let pieces = LyricTypography.layout(line: line, index: 1, in: CGSize(width: 960, height: 540),
                                        position: 1.5, reduceMotion: true)
    #expect(pieces.allSatisfy { $0.reduceRevealMotion })
    let early = pieces.flatMap { LyricGlyphRenderer.samples(for: $0, position: 1.5) }
    let late = pieces.flatMap { LyricGlyphRenderer.samples(for: $0, position: 6.99) }
    #expect(early.contains { $0.opacity == 0 })
    #expect(early.contains { $0.opacity == 1 })
    #expect(early.allSatisfy { $0.lift == 0 && ($0.opacity == 0 || $0.opacity == 1) })
    #expect(late.allSatisfy { $0.opacity == 1 && $0.lift == 0 })
}

@Test @MainActor func shapedRevealRegionsRetainGraphemesLigaturesAndBidiPositions() throws {
    for text in ["office", "夜色", "e\u{301}clair", "👩🏽‍🚀✨", "مرحبا", "abc שלום"] {
        let line = LyricLine(id: 0, text: text, start: 0, end: 8)
        let units = LyricReveal.timeline(for: line).units
        let piece = LyricTypeFragment(id: 0, text: text, center: .zero, size: CGSize(width: 800, height: 100),
                                      fontSize: 100, weight: .regular, revealUnits: units)
        let regions = LyricGlyphRenderer.regions(for: piece)
        #expect(regions.count == text.count)
        #expect(regions.allSatisfy { $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite })
        for (character, region) in zip(text, regions) where !character.isWhitespace {
            #expect(region.width > 0)
        }
        let original = regions
        _ = LyricGlyphRenderer.samples(for: piece, position: 0.15)
        _ = LyricGlyphRenderer.samples(for: piece, position: 7.9)
        #expect(LyricGlyphRenderer.regions(for: piece) == original)
    }
}

@Test @MainActor func kineticAccentClockMatchesFirstSpokenCharacterAndTailCompletes() throws {
    for line in [LyricLine(id: 0, text: "让夜色折成一封信", start: 1, end: 9),
                 LyricLine(id: 1, text: "There is light beside the river", start: 1, end: 9)] {
        let pieces = LyricTypography.layout(line: line, index: 0, in: CGSize(width: 960, height: 540),
                                            position: 1, reduceMotion: false)
        let texts = pieces.map(\.text)
        let choices = LyricEmphasis.choices(texts: texts, line: line, suppliedWordTiming: false, seed: 42)
        #expect(!choices.isEmpty)
        for (index, choice) in choices {
            let event = try #require(LyricEmphasis.eventInterval(choice: choice, line: line, unitIndex: index))
            let spoken = try #require(pieces[index].revealUnits.first {
                $0.text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
            })
            #expect(abs(event.start - spoken.start) < 0.000_001)
            #expect(spoken.opacity(at: event.start - 0.001) == 0)
        }
    }
    let line = LyricLine(id: 7, text: "light", start: 1, end: 1.1,
                         words: [.init(id: 0, text: "light", start: 1.06, end: 1.1)])
    let document = LyricDocument(lines: [line, .init(id: 8, text: "morning", start: 1.1, end: 4)],
                                timing: .word, sourceDescription: "Fixture")
    let tail = LyricTypography.frame(document: document, position: 1.5,
                                     in: CGSize(width: 960, height: 540), reduceMotion: false)
    let owner = try #require(tail.fragments.first { $0.role == .completingAccent && $0.lineID == 7 })
    #expect(owner.accent != nil)
    #expect(owner.revealUnits.count == line.text.count)
    #expect(LyricGlyphRenderer.samples(for: owner, position: 1.5).allSatisfy { $0.opacity == 1 && $0.lift == 0 })
}
