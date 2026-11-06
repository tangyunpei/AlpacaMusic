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

    /// The panel frame for a screen whose menu bar is `menuBar` points tall
    /// and whose Dock takes `dock` points on the left.
    private func frame(screen: CGRect, menuBar: CGFloat, dock: CGFloat = 0, minimum: CGFloat = 24) -> CGRect {
        let visible = CGRect(x: screen.minX + dock, y: screen.minY,
                             width: screen.width - dock, height: screen.height - menuBar)
        return MenuBarLyricsLayout.frame(screenFrame: screen, visibleFrame: visible, minimumMenuBarHeight: minimum)
    }

    @Test func thePanelIsCenteredJustBelowTheMenuBar() {
        #expect(MenuBarLyricsLayout.maximumWidth == 760)
        #expect(MenuBarLyricsLayout.height == 72)
        #expect(MenuBarLyricsLayout.topGap == 4)
        let screen: CGRect = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let placed: CGRect = frame(screen: screen, menuBar: 37)
        let expected: CGRect = CGRect(x: 376, y: 869, width: 760, height: 72)
        #expect(placed == expected)
        #expect(placed.midX == screen.midX)
        #expect(placed.maxY == screen.maxY - 37 - MenuBarLyricsLayout.topGap)
    }

    @Test func aSideDockLeavesThePanelUnderTheMiddleOfTheMenuBar() {
        let screen: CGRect = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let placed: CGRect = frame(screen: screen, menuBar: 37, dock: 65)
        #expect(placed.midX == screen.midX)
        #expect(placed == CGRect(x: 376, y: 869, width: 760, height: 72))
    }

    @Test func anAutoHidingMenuBarStillKeepsThePanelBelowIt() {
        let screen: CGRect = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // While the menu bar hides itself the visible frame reaches the top.
        let notched: CGRect = frame(screen: screen, menuBar: 0, minimum: 37)
        #expect(notched.maxY == screen.maxY - 37 - MenuBarLyricsLayout.topGap)
        let plain: CGRect = frame(screen: screen, menuBar: 0, minimum: 24)
        #expect(plain.maxY == screen.maxY - 24 - MenuBarLyricsLayout.topGap)
        // A visible menu bar taller than the minimum wins.
        let shown: CGRect = frame(screen: screen, menuBar: 37, minimum: 24)
        #expect(shown.maxY == screen.maxY - 37 - MenuBarLyricsLayout.topGap)
        // Without a usable visible frame only the minimum applies.
        let unknown: CGRect = MenuBarLyricsLayout.frame(screenFrame: screen, visibleFrame: CGRect.null,
                                                        minimumMenuBarHeight: 24)
        #expect(unknown.maxY == screen.maxY - 24 - MenuBarLyricsLayout.topGap)
    }

    @Test func aNarrowScreenKeepsASideMarginAndStaysCentered() {
        let screen: CGRect = CGRect(x: 0, y: 0, width: 600, height: 424)
        let placed: CGRect = frame(screen: screen, menuBar: 24)
        let expected: CGRect = CGRect(x: 24, y: 324, width: 552, height: 72)
        #expect(placed == expected)
        #expect(placed.midX == screen.midX)
    }

    @Test func aFrameOnAnOffsetDisplayStaysWithinIt() {
        let right: CGRect = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let rightFrame: CGRect = frame(screen: right, menuBar: 30)
        let rightExpected: CGRect = CGRect(x: 2092, y: 974, width: 760, height: 72)
        #expect(rightFrame == rightExpected)
        #expect(rightFrame.midX == right.midX)
        #expect(rightFrame.minX >= right.minX)
        #expect(rightFrame.maxX <= right.maxX)
        let left: CGRect = CGRect(x: -1440, y: 120, width: 1440, height: 900)
        let leftFrame: CGRect = frame(screen: left, menuBar: 25)
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
        for screen in frames {
            #expect(MenuBarLyricsLayout.frame(screenFrame: screen, visibleFrame: screen, minimumMenuBarHeight: 24) == CGRect.zero)
        }
        // A non-finite minimum counts as none; the visible frame still decides.
        let screen: CGRect = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let visible: CGRect = CGRect(x: 0, y: 0, width: 1200, height: 770)
        for minimum in [nan, infinity, -infinity] {
            let placed: CGRect = MenuBarLyricsLayout.frame(screenFrame: screen, visibleFrame: visible,
                                                           minimumMenuBarHeight: minimum)
            #expect(placed.maxY == 770 - MenuBarLyricsLayout.topGap)
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
        // Construction only: no panel, window or hosting view is created,
        // and the view's body is never evaluated.
        _ = MenuBarLyricsView(model: model)
        #expect(model.showsMenuBarLyrics)
    }

    /// The default panel on a 1512 × 982 screen, and a 300 × 50 capsule
    /// centered in it, 4 points from its top (the panel's SwiftUI space).
    private let panel: CGRect = CGRect(x: 376, y: 869, width: 760, height: 72)
    private let capsule: CGRect = CGRect(x: 230, y: 4, width: 300, height: 50)

    @Test func theCapsuleMapsFromThePanelsTopLeftSpaceToTheScreen() {
        let onScreen: CGRect = MenuBarLyricsFade.screenRect(of: capsule, inPanel: panel)
        #expect(onScreen == CGRect(x: 606, y: 887, width: 300, height: 50))
        // The capsule's top edge sits 4 points under the panel's top edge.
        #expect(onScreen.maxY == panel.maxY - 4)
        #expect(onScreen.midX == panel.midX)
    }

    @Test func onlyAPointerOnOrNextToTheCapsuleFadesTheLyric() {
        func over(_ x: CGFloat, _ y: CGFloat, wasOver: Bool = false) -> Bool {
            MenuBarLyricsFade.isPointerOver(CGPoint(x: x, y: y), capsule: capsule, panelFrame: panel, wasOver: wasOver)
        }
        // On the capsule (screen x 606...906, y 887...937).
        #expect(over(756, 912))
        #expect(over(607, 888))
        // Within the small margin just outside its left edge.
        #expect(over(606 - MenuBarLyricsFade.enterMargin + 1, 912))
        // In the panel but well clear of a short capsule: nothing to hide.
        #expect(!over(400, 912))
        #expect(!over(1100, 912))
        // Above the panel, in the menu bar itself.
        #expect(!over(756, 960))
    }

    @Test func aFadedLyricWaitsForTheWiderMarginBeforeReturning() {
        let enter: CGFloat = MenuBarLyricsFade.enterMargin
        let exit: CGFloat = MenuBarLyricsFade.exitMargin
        #expect(exit > enter)
        // Between the two margins below the capsule (its bottom edge is y 887):
        // a pointer arriving there does not fade the lyric, but one that was
        // already over it keeps it faded, so an edge never makes it flicker.
        let between: CGPoint = CGPoint(x: 756, y: 887 - (enter + exit) / 2)
        #expect(!MenuBarLyricsFade.isPointerOver(between, capsule: capsule, panelFrame: panel, wasOver: false))
        #expect(MenuBarLyricsFade.isPointerOver(between, capsule: capsule, panelFrame: panel, wasOver: true))
        let beyond: CGPoint = CGPoint(x: 756, y: 887 - exit - 1)
        #expect(!MenuBarLyricsFade.isPointerOver(beyond, capsule: capsule, panelFrame: panel, wasOver: true))
    }

    @Test func withoutACapsuleOrWithUnusableGeometryNothingFades() {
        let center: CGPoint = CGPoint(x: 756, y: 912)
        let nan: CGFloat = CGFloat.nan
        #expect(!MenuBarLyricsFade.isPointerOver(center, capsule: nil, panelFrame: panel, wasOver: true))
        let capsules: [CGRect] = [
            CGRect.zero, CGRect.null, CGRect.infinite,
            CGRect(x: 230, y: 4, width: 0, height: 50),
            CGRect(x: nan, y: 4, width: 300, height: 50),
            CGRect(x: 230, y: 4, width: 300, height: CGFloat.infinity)
        ]
        for bad in capsules {
            #expect(!MenuBarLyricsFade.isPointerOver(center, capsule: bad, panelFrame: panel, wasOver: true))
        }
        for badPanel in [CGRect.zero, CGRect.null, CGRect(x: nan, y: 869, width: 760, height: 72)] {
            #expect(!MenuBarLyricsFade.isPointerOver(center, capsule: capsule, panelFrame: badPanel, wasOver: true))
        }
        for pointer in [CGPoint(x: nan, y: 912), CGPoint(x: 756, y: CGFloat.infinity)] {
            #expect(!MenuBarLyricsFade.isPointerOver(pointer, capsule: capsule, panelFrame: panel, wasOver: true))
        }
    }

    @Test func theFadeLeavesAFaintTraceOfTheLyric() {
        #expect(MenuBarLyricsFade.opacity > 0)
        #expect(MenuBarLyricsFade.opacity <= 0.25)
    }

    @Test func theHoverStateReportsOnlyRealChanges() {
        let hover = MenuBarLyricsHover()
        let line: UUID = UUID()
        var changes: Int = 0
        hover.capsuleChanged = { changes += 1 }
        #expect(hover.capsule == nil)
        #expect(!hover.isPointerOver)
        hover.setCapsule(capsule, from: line)
        hover.setCapsule(capsule, from: line)
        #expect(changes == 1)
        #expect(hover.capsule == capsule)
        hover.setCapsule(capsule.offsetBy(dx: 10, dy: 0), from: line)
        #expect(changes == 2)
        hover.clearCapsule(from: line)
        hover.clearCapsule(from: line)
        #expect(changes == 3)
        #expect(hover.capsule == nil)
        hover.setPointerOver(true)
        #expect(hover.isPointerOver)
        hover.setPointerOver(false)
        #expect(!hover.isPointerOver)
    }

    @Test func aCapsuleFadingOutCannotClearTheOneThatReplacedIt() {
        let hover = MenuBarLyricsHover()
        let old: UUID = UUID()
        let new: UUID = UUID()
        hover.setCapsule(capsule, from: old)
        // The next line's capsule appears while the old one is still leaving.
        let wider: CGRect = capsule.insetBy(dx: -40, dy: 0)
        hover.setCapsule(wider, from: new)
        hover.clearCapsule(from: old)
        #expect(hover.capsule == wider)
        hover.clearCapsule(from: new)
        #expect(hover.capsule == nil)
    }
}
