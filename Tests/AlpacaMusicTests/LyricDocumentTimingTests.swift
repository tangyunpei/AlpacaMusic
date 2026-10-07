import Foundation
import SwiftUI
import Testing
@testable import AlpacaMusic

@Suite @MainActor struct LyricDocumentTimingTests {
    // Anonymous QQ LRC intervals for the user's reported recording. Neighbor
    // text is replaced with equal-length original placeholders; only the
    // user-provided target phrase is retained, not the song's complete lyrics.
    private func winterLines() -> [LyricLine] {
        let starts = [10.09, 13.46, 16.17, 19.62, 22.68, 26.54, 29.16, 32.47, 35.68, 39.59]
        let lengths = [6, 8, 8, 10, 9, 9, 9, 10, 9]
        return lengths.indices.map { index in
            .init(id: 40 + index * 7,
                  text: index == 4 ? "亲爱的你别为我哭泣" : String(repeating: "啦", count: lengths[index]),
                  start: starts[index], end: starts[index + 1])
        }
    }

    @Test func reportedQQCueUsesDocumentCadenceForGlyphsAndAccentEvents() throws {
        let lines = winterLines(), index = 4, line = lines[index]
        let document = LyricDocument(lines: lines, timing: .line, sourceDescription: "Fixture")
        let context = LyricSingingTiming.context(for: index, in: lines)
        let timeline = LyricReveal.timeline(for: line, context: context)
        let final = try #require(timeline.units.last)
        #expect(abs(final.start - 25.008) < 0.002)
        #expect(final.end == 26.54)
        // The old equal distribution held the last syllable until 26.11.
        #expect(final.start < 22.68 + (26.54 - 22.68) * 8 / 9 - 0.9)
        let frame = LyricTypography.frame(document: document, position: 25.2,
                                         in: CGSize(width: 960, height: 540), reduceMotion: false)
        let primary = frame.fragments.filter { $0.role == .primary }
        #expect(primary.map(\.text).joined() == line.text)
        #expect(primary.flatMap(\.revealUnits).map(\.start) == timeline.units.map(\.start))
        #expect(primary.flatMap { LyricGlyphRenderer.samples(for: $0, position: 25.2) }.allSatisfy { $0.opacity == 1 })
        for piece in primary {
            let first = try #require(piece.revealUnits.first)
            let before = LyricTypography.frame(document: document, position: first.revealStart - 0.001,
                                              in: CGSize(width: 960, height: 540), reduceMotion: false)
            #expect(before.fragments.first { $0.role == .primary && $0.id == piece.id }?.accent == nil)
        }
    }

    @Test func stageCacheSeparatesNeighborCadencesAndSeeksReconstructTheSameClock() throws {
        let target = LyricLine(id: 10, text: "夜色慢慢靠近心里的光", start: 20, end: 35)
        func document(rate: Double) -> LyricDocument {
            .init(lines: [
                .init(id: 3, text: "每一阵风都有归处", start: 10, end: 10 + rate * 8), target,
                .init(id: 90, text: "让回声照亮远方", start: 35, end: 35 + rate * 7)
            ], timing: .line, sourceDescription: "Fixture")
        }
        func frame(_ document: LyricDocument, at time: Double) -> [LyricTypeFragment] {
            LyricTypography.frame(document: document, position: time, in: CGSize(width: 960, height: 540),
                                  reduceMotion: false).fragments.filter { $0.role == .primary }
        }
        let fast = document(rate: 0.3), slow = document(rate: 0.9)
        let before = frame(fast, at: 21.5)
        let slower = frame(slow, at: 21.5)
        #expect(before.flatMap(\.revealUnits).map(\.start) != slower.flatMap(\.revealUnits).map(\.start))
        _ = frame(fast, at: 34.5)
        let repeated = frame(fast, at: 21.5)
        #expect(before.flatMap(\.revealUnits) == repeated.flatMap(\.revealUnits))
        #expect(before.map(\.center) == repeated.map(\.center))
        #expect(before.map(\.accent) == repeated.map(\.accent))
    }
}
