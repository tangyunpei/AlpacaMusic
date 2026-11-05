import CoreGraphics
import Foundation
import Testing
@testable import AlpacaMusic

/// The menu bar lyrics' placement and cue rules. No panel or window is
/// created here.
@Suite @MainActor
struct MenuBarLyricsTests {
    /// A translated line, a blank interlude cue, then a second line.
    private func timedDocument() -> LyricDocument {
        LyricDocument(lines: [
            LyricLine(id: 0, text: "First light", start: 2, end: 5, translation: "Primera luz"),
            LyricLine(id: 1, text: "", start: 5, end: 6),
            LyricLine(id: 2, text: "Second wind", start: 6, end: 9)
        ], timing: .line, sourceDescription: "Fixture")
    }

    /// The menu bar cue while the player is playing at `position`.
    private func playing(_ document: LyricDocument?, at position: Double) -> MiniLyricCue? {
        MenuBarLyricsPresentation.cue(status: .playing, document: document, position: position)
    }

    @Test func thePanelIsCenteredJustBelowTheMenuBar() {
        #expect(MenuBarLyricsLayout.maximumWidth == 760)
        #expect(MenuBarLyricsLayout.height == 72)
        #expect(MenuBarLyricsLayout.topGap == 4)
        let visible: CGRect = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let frame: CGRect = MenuBarLyricsLayout.frame(visibleFrame: visible)
        let expected: CGRect = CGRect(x: 376, y: 869, width: 760, height: 72)
        #expect(frame == expected)
        #expect(frame.midX == visible.midX)
        #expect(frame.maxY == visible.maxY - MenuBarLyricsLayout.topGap)
    }

    @Test func aNarrowScreenKeepsASideMarginAndStaysCentered() {
        let visible: CGRect = CGRect(x: 0, y: 0, width: 600, height: 400)
        let frame: CGRect = MenuBarLyricsLayout.frame(visibleFrame: visible)
        let expected: CGRect = CGRect(x: 24, y: 324, width: 552, height: 72)
        #expect(frame == expected)
        #expect(frame.midX == visible.midX)
    }

    @Test func otherDisplaysKeepThePanelOnTheirOwnMenuBar() {
        let right: CGRect = CGRect(x: 1512, y: 0, width: 1920, height: 1050)
        let rightFrame: CGRect = MenuBarLyricsLayout.frame(visibleFrame: right)
        let rightExpected: CGRect = CGRect(x: 2092, y: 974, width: 760, height: 72)
        #expect(rightFrame == rightExpected)
        #expect(rightFrame.midX == right.midX)
        #expect(rightFrame.minX >= right.minX)
        #expect(rightFrame.maxX <= right.maxX)
        let left: CGRect = CGRect(x: -1440, y: 120, width: 1440, height: 875)
        let leftFrame: CGRect = MenuBarLyricsLayout.frame(visibleFrame: left)
        let leftExpected: CGRect = CGRect(x: -1100, y: 919, width: 760, height: 72)
        #expect(leftFrame == leftExpected)
        #expect(leftFrame.midX == left.midX)
    }

    @Test func emptyOrNonFiniteScreensHaveNoPanelFrame() {
        let nan: CGFloat = CGFloat.nan
        let infinity: CGFloat = CGFloat.infinity
        let zeroWidth: CGRect = CGRect(x: 0, y: 0, width: 0, height: 900)
        let zeroHeight: CGRect = CGRect(x: 0, y: 0, width: 1200, height: 0)
        let nanOrigin: CGRect = CGRect(x: nan, y: 0, width: 1200, height: 800)
        let nanHeight: CGRect = CGRect(x: 0, y: 0, width: 1200, height: nan)
        let infiniteWidth: CGRect = CGRect(x: 0, y: 0, width: infinity, height: 800)
        let infiniteOrigin: CGRect = CGRect(x: 0, y: -infinity, width: 1200, height: 800)
        let frames: [CGRect] = [
            CGRect.zero, CGRect.null, CGRect.infinite,
            zeroWidth, zeroHeight, nanOrigin, nanHeight, infiniteWidth, infiniteOrigin
        ]
        for visible in frames {
            #expect(MenuBarLyricsLayout.frame(visibleFrame: visible) == CGRect.zero)
        }
    }

    @Test func onlyPlayingShowsALyric() throws {
        let document: LyricDocument = timedDocument()
        let quiet: [PlaybackStatus] = [.idle, .loading, .paused, .failed]
        for status in quiet {
            #expect(MenuBarLyricsPresentation.cue(status: status, document: document, position: 3) == nil)
        }
        let cue: MiniLyricCue = try #require(playing(document, at: 3))
        #expect(cue.currentIndex == 0)
        #expect(cue.current?.text == "First light")
        #expect(cue.current?.translation == "Primera luz")
        #expect(cue.next?.text == "Second wind")
        let selection: MiniLyricCue = try #require(MiniLyricSelection.cue(in: document, at: 3))
        #expect(cue == selection)
    }

    @Test func theLyricFollowsPlaybackToTheNextLine() throws {
        let document: LyricDocument = timedDocument()
        let first: MiniLyricCue = try #require(playing(document, at: 2))
        #expect(first.currentIndex == 0)
        #expect(first.current?.text == "First light")
        let second: MiniLyricCue = try #require(playing(document, at: 6.5))
        #expect(second.currentIndex == 2)
        #expect(second.current?.text == "Second wind")
        #expect(second.current?.translation == nil)
        #expect(second.next == nil)
    }

    @Test func nothingShowsBeforeTheFirstLineInAnInterludeOrAfterTheEnd() {
        let document: LyricDocument = timedDocument()
        let positions: [Double] = [0, 1.5, 5, 5.5, 9, 30]
        for position in positions {
            #expect(playing(document, at: position) == nil)
        }
    }

    @Test func plainInstrumentalOrMissingLyricsShowNothing() {
        let plain = LyricDocument(lines: [LyricLine(id: 0, text: "Words without time")], timing: .plain,
                                  sourceDescription: "Fixture")
        let instrumental = LyricDocument(lines: [], timing: .plain, sourceDescription: "Fixture", isInstrumental: true)
        let flagged = LyricDocument(lines: [LyricLine(id: 0, text: "Hum", start: 0, end: 10)], timing: .line,
                                    sourceDescription: "Fixture", isInstrumental: true)
        #expect(playing(nil, at: 3) == nil)
        #expect(playing(plain, at: 3) == nil)
        #expect(playing(instrumental, at: 3) == nil)
        #expect(playing(flagged, at: 3) == nil)
    }

    @Test func unusablePositionsShowNothing() {
        let document: LyricDocument = timedDocument()
        let positions: [Double] = [Double.nan, Double.infinity, -Double.infinity]
        for position in positions {
            #expect(playing(document, at: position) == nil)
        }
    }

    @Test func theLyricsViewKeepsItsSharedInitializer() throws {
        let domain = "AlpacaMenuBarLyricsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = AppModel(directory: directory, preferences: defaults, ephemeralAccounts: true)
        defer { model.player.shutdown() }
        // Construction only: no panel, window or hosting view is created.
        _ = MenuBarLyricsView(model: model)
        #expect(model.showsMenuBarLyrics)
        #expect(MenuBarLyricsPresentation.cue(status: model.player.status, document: model.lyrics.document,
                                              position: model.player.position) == nil)
    }
}
