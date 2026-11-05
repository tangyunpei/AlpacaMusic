import Foundation
import SwiftUI
import Testing
@testable import AlpacaMusic

@Suite @MainActor
struct CompactLyricsTests {
    /// "One", a blank interlude, "Two" and "Three". The parser keeps the blank
    /// LRC line as a timed cue of its own.
    private func lrcDocument() throws -> LyricDocument {
        let document = try LyricsParser.parse("[00:01.00]One\n[00:03.00]\n[00:04.00]Two\n[00:06.00]Three", format: .lrc)
        try #require(document.timing == .line)
        try #require(document.lines.map(\.text) == ["One", "", "Two", "Three"])
        return document
    }

    /// Explicit SRT-style ends leave unhighlighted gaps between the cues.
    private func gappedDocument() -> LyricDocument {
        LyricDocument(lines: [
            LyricLine(id: 0, text: "First", start: 1, end: 2),
            LyricLine(id: 1, text: "Second", start: 4, end: 6)
        ], timing: .line, sourceDescription: "Fixture")
    }

    @Test func onlyTimedLyricsProduceACue() throws {
        #expect(MiniLyricSelection.cue(in: nil, at: 2) == nil)
        let plain = try LyricsParser.parse("One\nTwo", format: .plain)
        #expect(plain.timing == .plain)
        #expect(MiniLyricSelection.cue(in: plain, at: 2) == nil)
        let instrumental = LyricDocument(lines: [], timing: .plain, sourceDescription: "Fixture", isInstrumental: true)
        #expect(MiniLyricSelection.cue(in: instrumental, at: 2) == nil)
        let flagged = LyricDocument(lines: [LyricLine(id: 0, text: "Hum", start: 0, end: 10)], timing: .line,
                                    sourceDescription: "Fixture", isInstrumental: true)
        #expect(MiniLyricSelection.cue(in: flagged, at: 2) == nil)
        let empty = LyricDocument(lines: [], timing: .line, sourceDescription: "Fixture")
        #expect(MiniLyricSelection.cue(in: empty, at: 2) == nil)
    }

    @Test func nonFinitePositionsHaveNoCue() throws {
        let document = try lrcDocument()
        #expect(MiniLyricSelection.cue(in: document, at: Double.nan) == nil)
        #expect(MiniLyricSelection.cue(in: document, at: Double.infinity) == nil)
        #expect(MiniLyricSelection.cue(in: document, at: -Double.infinity) == nil)
    }

    @Test func beforeTheFirstLineItIsTheUpcomingLine() throws {
        let document = try lrcDocument()
        let positions: [Double] = [0, 0.5, -3]
        for position in positions {
            let cue = try #require(MiniLyricSelection.cue(in: document, at: position))
            #expect(cue.currentIndex == nil)
            #expect(cue.current == nil)
            #expect(cue.next?.text == "One")
        }
    }

    @Test func insideALineTheNextLineSkipsBlankCues() throws {
        let document = try lrcDocument()
        let first = try #require(MiniLyricSelection.cue(in: document, at: 2))
        #expect(first.currentIndex == 0)
        #expect(first.current?.text == "One")
        #expect(first.next?.text == "Two")
        let second = try #require(MiniLyricSelection.cue(in: document, at: 5))
        #expect(second.currentIndex == 2)
        #expect(second.current?.text == "Two")
        #expect(second.next?.text == "Three")
    }

    @Test func aBlankLineKeepsItsIndexWithoutCurrentText() throws {
        let document = try lrcDocument()
        let cue = try #require(MiniLyricSelection.cue(in: document, at: 3.5))
        #expect(cue.currentIndex == 1)
        #expect(cue.current == nil)
        #expect(cue.next?.text == "Two")
    }

    @Test func whitespaceOnlyLinesCountAsBlank() throws {
        let document = LyricDocument(lines: [
            LyricLine(id: 0, text: "Opening", start: 0, end: 2),
            LyricLine(id: 1, text: " \u{3000}\n", start: 2, end: 3),
            LyricLine(id: 2, text: "\t", start: 3, end: 4),
            LyricLine(id: 3, text: "Closing", start: 4, end: 6)
        ], timing: .line, sourceDescription: "Fixture")
        let opening = try #require(MiniLyricSelection.cue(in: document, at: 1))
        #expect(opening.current?.text == "Opening")
        #expect(opening.next?.text == "Closing")
        let interlude = try #require(MiniLyricSelection.cue(in: document, at: 2.5))
        #expect(interlude.currentIndex == 1)
        #expect(interlude.current == nil)
        #expect(interlude.next?.text == "Closing")
    }

    @Test func afterTheLastLineNothingIsUpcoming() throws {
        let document = try lrcDocument()
        let cue = try #require(MiniLyricSelection.cue(in: document, at: 100))
        #expect(cue.currentIndex == 3)
        #expect(cue.current?.text == "Three")
        #expect(cue.next == nil)
    }

    @Test func explicitGapsHaveNoCurrentLine() throws {
        let document = gappedDocument()
        let inside = try #require(MiniLyricSelection.cue(in: document, at: 1.5))
        #expect(inside.currentIndex == 0)
        #expect(inside.current?.text == "First")
        #expect(inside.next?.text == "Second")
        let gap = try #require(MiniLyricSelection.cue(in: document, at: 3))
        #expect(gap == MiniLyricCue(currentIndex: nil, current: nil, next: document.lines[1]))
        let ended = try #require(MiniLyricSelection.cue(in: document, at: 7))
        #expect(ended == MiniLyricCue(currentIndex: nil, current: nil, next: nil))
    }

    @Test func untimedLinesAreNeverUpcoming() throws {
        let document = LyricDocument(lines: [
            LyricLine(id: 0, text: "Credits"),
            LyricLine(id: 1, text: "One", start: 2, end: 4)
        ], timing: .line, sourceDescription: "Fixture")
        let cue = try #require(MiniLyricSelection.cue(in: document, at: 1))
        #expect(cue.currentIndex == nil)
        #expect(cue.current == nil)
        #expect(cue.next?.text == "One")
    }

    @Test func batterySaverOnlySlowsLyricsInLowPowerMode() {
        var settings = VisualSettings.standard
        settings.batterySaver = false
        #expect(!CompactLyricsMotion.lowPower(settings, systemLowPower: false))
        #expect(!CompactLyricsMotion.lowPower(settings, systemLowPower: true))
        settings.batterySaver = true
        #expect(!CompactLyricsMotion.lowPower(settings, systemLowPower: false))
        #expect(CompactLyricsMotion.lowPower(settings, systemLowPower: true))
    }

    @Test func compactViewsKeepTheirSharedInitializers() throws {
        let domain = "AlpacaCompactLyricsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = AppModel(directory: directory, preferences: defaults, ephemeralAccounts: true)
        defer { model.player.shutdown() }
        // Construction only: nothing is rendered or hosted in a window.
        _ = CompactLyricLines(model: model)
        _ = CompactLyricLines(model: model, primarySize: 20, secondarySize: 13, showsNextLine: false,
                              alignment: .center, fallback: .hidden)
        _ = ProjectedLyricTime(position: 1, isPlaying: false, cueEnd: nil, animates: false, lowPower: false) { (time: Double) in
            Text(verbatim: "\(time)")
        }
    }
}
