import CoreGraphics
import Testing
@testable import AlpacaMusic

/// One frame of the Now page design canvas and the sizes its layout rules
/// give. The numbers come from evaluating the canvas's own rules for the
/// frame, not from this app's layout code. The canvas rounds to whole points;
/// the app keeps fractions so sizes move without steps, hence the tolerances.
private struct CanvasFrame: Sendable, CustomTestStringConvertible {
    let name: String
    let w: CGFloat, h: CGFloat
    let panel: Bool, idle: Bool, noSource: Bool
    let pageW: CGFloat, contentW: CGFloat
    let gutter: Bool
    let rowW: CGFloat
    let fit: Int
    let cardW: CGFloat, cardH: CGFloat
    let nextOn: Bool
    let firstBandH: CGFloat, stageH: CGFloat, titleSize: CGFloat, lyricSize: CGFloat, lyricNextSize: CGFloat
    let stacked: Bool
    let textH: CGFloat
    let nextItems: Int, cols: Int
    let placement: NowPanelPlacement

    init(_ name: String, w: CGFloat, h: CGFloat, panel: Bool, idle: Bool, noSource: Bool, pageW: CGFloat, contentW: CGFloat,
         gutter: Bool, rowW: CGFloat, fit: Int, cardW: CGFloat, cardH: CGFloat, nextOn: Bool, firstBandH: CGFloat, stageH: CGFloat,
         titleSize: CGFloat, lyricSize: CGFloat, lyricNextSize: CGFloat, stacked: Bool, textH: CGFloat, nextItems: Int, cols: Int,
         placement: NowPanelPlacement) {
        self.name = name; self.w = w; self.h = h; self.panel = panel; self.idle = idle; self.noSource = noSource
        self.pageW = pageW; self.contentW = contentW; self.gutter = gutter; self.rowW = rowW; self.fit = fit
        self.cardW = cardW; self.cardH = cardH; self.nextOn = nextOn; self.firstBandH = firstBandH; self.stageH = stageH
        self.titleSize = titleSize; self.lyricSize = lyricSize; self.lyricNextSize = lyricNextSize; self.stacked = stacked
        self.textH = textH; self.nextItems = nextItems; self.cols = cols; self.placement = placement
    }
    var testDescription: String { name }
    /// The page's area: the window without the 220pt sidebar and the 100pt player bar.
    var input: NowLayoutInput {
        NowLayoutInput(width: w - NowLayout.sidebarWidth, height: h - NowLayout.playerBarHeight, idle: idle, panelOpen: panel,
                       connect: noSource, action: idle, lyrics: !idle)
    }

    static let all: [CanvasFrame] = [
        CanvasFrame("Main", w: 1440, h: 940, panel: false, idle: false, noSource: false, pageW: 1220, contentW: 1152, gutter: true, rowW: 1004, fit: 4, cardW: 212, cardH: 283, nextOn: true, firstBandH: 327, stageH: 441, titleSize: 55, lyricSize: 23, lyricNextSize: 17, stacked: false, textH: 204, nextItems: 3, cols: 3, placement: .closed),
        CanvasFrame("ListOpen", w: 1440, h: 940, panel: true, idle: false, noSource: false, pageW: 880, contentW: 812, gutter: false, rowW: 812, fit: 3, cardW: 223, cardH: 297, nextOn: true, firstBandH: 385, stageH: 383, titleSize: 48, lyricSize: 20, lyricNextSize: 14, stacked: false, textH: 189, nextItems: 3, cols: 2, placement: .docked),
        // The whole scrolled page keeps the default window's first screen.
        CanvasFrame("FullPage", w: 1440, h: 940, panel: false, idle: false, noSource: false, pageW: 1220, contentW: 1152, gutter: true, rowW: 1004, fit: 4, cardW: 212, cardH: 283, nextOn: true, firstBandH: 327, stageH: 441, titleSize: 55, lyricSize: 23, lyricNextSize: 17, stacked: false, textH: 204, nextItems: 3, cols: 3, placement: .closed),
        CanvasFrame("Small", w: 1040, h: 720, panel: false, idle: false, noSource: false, pageW: 820, contentW: 752, gutter: false, rowW: 752, fit: 3, cardW: 205, cardH: 273, nextOn: false, firstBandH: 361, stageH: 260, titleSize: 34, lyricSize: 16, lyricNextSize: 13, stacked: false, textH: 167, nextItems: 2, cols: 2, placement: .closed),
        CanvasFrame("Portrait", w: 1080, h: 1920, panel: false, idle: false, noSource: false, pageW: 860, contentW: 792, gutter: false, rowW: 792, fit: 3, cardW: 217, cardH: 289, nextOn: true, firstBandH: 377, stageH: 720, titleSize: 76, lyricSize: 30, lyricNextSize: 22, stacked: true, textH: 243, nextItems: 3, cols: 2, placement: .closed),
        CanvasFrame("Big", w: 2560, h: 1440, panel: false, idle: false, noSource: false, pageW: 2340, contentW: 2272, gutter: true, rowW: 2124, fit: 7, cardW: 270, cardH: 360, nextOn: true, firstBandH: 404, stageH: 720, titleSize: 76, lyricSize: 30, lyricNextSize: 22, stacked: false, textH: 243, nextItems: 8, cols: 5, placement: .closed),
        CanvasFrame("StateIdle", w: 1440, h: 940, panel: false, idle: true, noSource: false, pageW: 1220, contentW: 1152, gutter: true, rowW: 1004, fit: 4, cardW: 212, cardH: 283, nextOn: false, firstBandH: 327, stageH: 260, titleSize: 34, lyricSize: 16, lyricNextSize: 13, stacked: false, textH: 167, nextItems: 3, cols: 3, placement: .closed),
        CanvasFrame("StateResume", w: 1440, h: 940, panel: false, idle: false, noSource: false, pageW: 1220, contentW: 1152, gutter: true, rowW: 1004, fit: 4, cardW: 212, cardH: 283, nextOn: true, firstBandH: 327, stageH: 441, titleSize: 55, lyricSize: 23, lyricNextSize: 17, stacked: false, textH: 204, nextItems: 3, cols: 3, placement: .closed),
        CanvasFrame("StateNoLyrics", w: 1440, h: 940, panel: false, idle: false, noSource: false, pageW: 1220, contentW: 1152, gutter: true, rowW: 1004, fit: 4, cardW: 212, cardH: 283, nextOn: true, firstBandH: 327, stageH: 441, titleSize: 55, lyricSize: 23, lyricNextSize: 17, stacked: false, textH: 204, nextItems: 3, cols: 3, placement: .closed),
        CanvasFrame("StateNoSignal", w: 1440, h: 940, panel: false, idle: false, noSource: false, pageW: 1220, contentW: 1152, gutter: true, rowW: 1004, fit: 4, cardW: 212, cardH: 283, nextOn: true, firstBandH: 327, stageH: 441, titleSize: 55, lyricSize: 23, lyricNextSize: 17, stacked: false, textH: 204, nextItems: 3, cols: 3, placement: .closed),
        CanvasFrame("StateLight", w: 1440, h: 940, panel: false, idle: false, noSource: false, pageW: 1220, contentW: 1152, gutter: true, rowW: 1004, fit: 4, cardW: 212, cardH: 283, nextOn: true, firstBandH: 327, stageH: 441, titleSize: 55, lyricSize: 23, lyricNextSize: 17, stacked: false, textH: 204, nextItems: 3, cols: 3, placement: .closed),
        // Under shuffle the canvas draws one song; the room the strip has is unchanged.
        CanvasFrame("StateShuffle", w: 1440, h: 940, panel: false, idle: false, noSource: false, pageW: 1220, contentW: 1152, gutter: true, rowW: 1004, fit: 4, cardW: 212, cardH: 283, nextOn: true, firstBandH: 327, stageH: 441, titleSize: 55, lyricSize: 23, lyricNextSize: 17, stacked: false, textH: 204, nextItems: 3, cols: 3, placement: .closed),
        CanvasFrame("StateNoSource", w: 1440, h: 940, panel: false, idle: false, noSource: true, pageW: 1220, contentW: 1152, gutter: true, rowW: 1004, fit: 4, cardW: 212, cardH: 283, nextOn: true, firstBandH: 224, stageH: 462, titleSize: 58, lyricSize: 24, lyricNextSize: 17, stacked: false, textH: 209, nextItems: 3, cols: 3, placement: .closed),
        CanvasFrame("StateDragStrip", w: 1440, h: 940, panel: false, idle: false, noSource: false, pageW: 1220, contentW: 1152, gutter: true, rowW: 1004, fit: 4, cardW: 212, cardH: 283, nextOn: true, firstBandH: 327, stageH: 441, titleSize: 55, lyricSize: 23, lyricNextSize: 17, stacked: false, textH: 204, nextItems: 3, cols: 3, placement: .closed),
        CanvasFrame("StatePanelSmall", w: 1040, h: 720, panel: true, idle: false, noSource: false, pageW: 820, contentW: 752, gutter: false, rowW: 752, fit: 3, cardW: 205, cardH: 273, nextOn: false, firstBandH: 361, stageH: 260, titleSize: 34, lyricSize: 16, lyricNextSize: 13, stacked: false, textH: 167, nextItems: 2, cols: 2, placement: .floating)
    ]
}

private func near(_ value: CGFloat, _ expected: CGFloat, within tolerance: CGFloat) -> Bool { abs(value - expected) <= tolerance }

/// A window as the page sees it: without the sidebar and the player bar.
private func page(_ windowWidth: CGFloat, _ windowHeight: CGFloat, panel: Bool = false, idle: Bool = false, connect: Bool = false) -> NowLayoutInput {
    NowLayoutInput(width: windowWidth - NowLayout.sidebarWidth, height: windowHeight - NowLayout.playerBarHeight, idle: idle,
                   panelOpen: panel, connect: connect, action: idle, lyrics: !idle)
}

@Suite struct NowLayoutTests {
    // MARK: The canvas

    @Test(arguments: CanvasFrame.all) fileprivate func settlesOnTheCanvasSizes(_ frame: CanvasFrame) {
        let choice = NowLayout.choice(for: frame.input)
        let metrics = NowLayout.settledMetrics(for: frame.input)
        #expect(choice.panel == frame.placement)
        #expect(choice.gutter == frame.gutter)
        #expect(choice.cardsPerRow == frame.fit)
        #expect(choice.nextStrip == frame.nextOn)
        #expect(choice.stacked == frame.stacked)
        #expect(choice.chartColumns == frame.cols)
        #expect(metrics.pageWidth == frame.pageW)
        #expect(metrics.contentWidth == frame.contentW)
        #expect(metrics.rowWidth == frame.rowW)
        #expect(near(metrics.cardWidth, frame.cardW, within: 0.5))
        #expect(near(metrics.cardHeight, frame.cardH, within: 1))
        #expect(near(metrics.todayHeight, frame.firstBandH, within: 1))
        #expect(near(metrics.stageHeight, frame.stageH, within: 1))
        #expect(near(metrics.titleSize, frame.titleSize, within: 0.5))
        #expect(near(metrics.lyricSize, frame.lyricSize, within: 0.5))
        #expect(near(metrics.lyricNextSize, frame.lyricNextSize, within: 0.5))
        #expect(metrics.nextStripHeight == (frame.nextOn ? 72 : 0))
        // The canvas draws at most the eight songs of its sample queue.
        #expect(min(8, NowLayout.nextItemCount(rowWidth: metrics.rowWidth)) == frame.nextItems)
        // The canvas's text height assumes lyric lines and no button.
        if !frame.idle { #expect(near(metrics.textHeight, frame.textH, within: 1.5)) }
    }

    // MARK: Content width

    @Test func theContentIsThePageLessItsPaddingAndADockedPanel() {
        // 1440 less the sidebar is 1220; less the two 34pt paddings, 1152; a docked panel takes 340 more.
        let open = NowLayout.settledMetrics(for: page(1440, 940))
        #expect(open.pageWidth == 1220)
        #expect(open.contentWidth == 1152)
        let docked = NowLayout.settledMetrics(for: page(1440, 940, panel: true))
        #expect(docked.pageWidth == 880)
        #expect(docked.contentWidth == 812)
        let floating = NowLayout.settledMetrics(for: page(1040, 720, panel: true))
        #expect(floating.pageWidth == 820)
    }

    // MARK: Gutter

    @Test func theLabelGutterAppearsOnceTheContentIsAThousandPointsWide() {
        // Content is the window less the sidebar (220) and the padding (68).
        let below = NowLayout.choice(for: page(999 + 288, 940)), at = NowLayout.choice(for: page(1000 + 288, 940))
        #expect(!below.gutter)
        #expect(at.gutter)
        let narrow = NowLayout.settledMetrics(for: page(999 + 288, 940)), wide = NowLayout.settledMetrics(for: page(1000 + 288, 940))
        #expect(narrow.rowInset == 0 && narrow.rowWidth == 999 && narrow.headHeight == 44)
        #expect(wide.rowInset == 148 && wide.rowWidth == 1000 - 148 && wide.headHeight == 0)
    }

    // MARK: Cards per row

    @Test func aRowShowsWholeCardsAndFourTenthsOfTheNext() {
        for windowWidth in stride(from: CGFloat(1040), through: 3200, by: 7) {
            for windowHeight in [CGFloat(720), 940, 1440] {
                let input = page(windowWidth, windowHeight)
                let choice = NowLayout.choice(for: input), metrics = NowLayout.settledMetrics(for: input)
                #expect(choice.cardsPerRow >= 2)
                #expect(NowLayout.cardWidthRange.contains(metrics.cardWidth))
                // Unless a limit on the card's width applies, the row is filled exactly.
                guard metrics.cardWidth > 180.01, metrics.cardWidth < 279.99 else { continue }
                let filled = CGFloat(choice.cardsPerRow) * (metrics.cardWidth + 18) + 0.4 * metrics.cardWidth
                #expect(near(filled, metrics.rowWidth, within: 0.01), "window \(windowWidth)×\(windowHeight)")
                #expect(near(metrics.cardHeight, metrics.cardWidth * 4 / 3, within: 0.001))
            }
        }
    }

    @Test func aWiderRowTakesACardAndAShortWindowUsesSmallerOnes() {
        // 1287 is the last width before the gutter; one point wider the row loses 148pt to it.
        #expect(NowLayout.choice(for: page(1286, 940)).cardsPerRow == 3)
        #expect(NowLayout.choice(for: page(1287, 940)).cardsPerRow == 4)
        #expect(NowLayout.choice(for: page(1288, 940)).cardsPerRow == 3)
        #expect(NowLayout.choice(for: page(1440, 940)).cardsPerRow == 4)
        #expect(NowLayout.choice(for: page(1728, 1117)).cardsPerRow == 5)
        // The same width fits one more card when the window is short.
        #expect(NowLayout.choice(for: page(1240, 940)).cardsPerRow == 3)
        #expect(NowLayout.choice(for: page(1240, 720)).cardsPerRow == 4)
    }

    // MARK: Stage height

    @Test func theStageTakesWhatTheFirstScreenLeaves() {
        let input = page(1440, 940)
        let metrics = NowLayout.settledMetrics(for: input)
        // Not at a limit here, so stage, Next strip and Today fill the page exactly.
        #expect(metrics.stageHeight > 260 && metrics.stageHeight < 0.55 * 840)
        #expect(near(metrics.stageHeight + metrics.nextStripHeight + metrics.todayHeight, input.height, within: 0.001))
    }

    @Test func theStageNeverGoesBelow260NorAbove720Or55Percent() {
        // The smallest window leaves less than 260.
        #expect(NowLayout.settledMetrics(for: page(1040, 720)).stageHeight == 260)
        // 55% of the available height is the limit in the default window with a short first band.
        #expect(near(NowLayout.settledMetrics(for: page(1440, 940, connect: true)).stageHeight, 0.55 * 840, within: 0.001))
        // 720 is the limit on tall screens.
        #expect(NowLayout.settledMetrics(for: page(1080, 1920)).stageHeight == 720)
        #expect(NowLayout.settledMetrics(for: page(2560, 1440)).stageHeight == 720)
        for windowWidth in stride(from: CGFloat(1040), through: 3000, by: 53) {
            for windowHeight in stride(from: CGFloat(720), through: 2200, by: 37) {
                let height = NowLayout.settledMetrics(for: page(windowWidth, windowHeight)).stageHeight
                #expect(height >= 260 && height <= min(720, max(260, 0.55 * (windowHeight - 100))) + 0.001)
            }
        }
    }

    @Test func anIdleStageIs260AndHasNoNextStrip() {
        for (width, height) in [(CGFloat(1440), CGFloat(940)), (1080, 1920), (2560, 1440), (1040, 720)] {
            let choice = NowLayout.choice(for: page(width, height, idle: true))
            let metrics = NowLayout.settledMetrics(for: page(width, height, idle: true))
            #expect(metrics.stageHeight == 260)
            #expect(!choice.nextStrip && metrics.nextStripHeight == 0)
            #expect(!choice.lyrics)
        }
    }

    @Test func aWindowUnder840DropsTheNextStripAndNotesTheNextSongOnTheStage() {
        let short = NowLayout.choice(for: page(1440, 839)), tall = NowLayout.choice(for: page(1440, 840))
        #expect(short.compact && !short.nextStrip && short.blend.compactNext == 1)
        #expect(!tall.compact && tall.nextStrip && tall.blend.compactNext == 0)
    }

    @Test func aTallNarrowStageStacksItsVisualOverItsText() {
        let portrait = NowLayout.settledMetrics(for: page(1080, 1920))
        #expect(portrait.stacked == 1)
        #expect(portrait.visualFrame.minX == 0 && portrait.visualFrame.width == portrait.pageWidth)
        #expect(near(portrait.visualFrame.maxY, portrait.stageHeight - portrait.textHeight, within: 0.001))
        let landscape = NowLayout.settledMetrics(for: page(1440, 940))
        #expect(landscape.stacked == 0)
        #expect(near(landscape.visualFrame.minX, landscape.pageWidth * 0.38, within: 0.001))
        #expect(landscape.visualFrame.maxX == landscape.pageWidth && landscape.visualFrame.height == landscape.stageHeight)
    }

    // MARK: Panel

    @Test func aPanelDocksWhileThePageKeepsItsSmallestWidthAndFloatsOtherwise() {
        #expect(NowLayout.choice(for: page(1440, 940)).panel == .closed)
        #expect(NowLayout.choice(for: page(1440, 940, panel: true)).panel == .docked)
        #expect(NowLayout.choice(for: page(1040, 720, panel: true)).panel == .floating)
        #expect(NowLayout.choice(for: page(1080, 1920, panel: true)).panel == .floating)
        // 820pt of page is what the smallest window has: 220 + 820 + 340 = 1380.
        #expect(NowLayout.choice(for: page(1380, 940, panel: true)).panel == .docked)
        #expect(NowLayout.choice(for: page(1379, 940, panel: true)).panel == .floating)
        // A floating panel takes nothing from the page.
        #expect(NowLayout.settledMetrics(for: page(1379, 940, panel: true)).pageWidth == 1159)
        #expect(NowLayout.settledMetrics(for: page(1380, 940, panel: true)).pageWidth == 820)
    }

    // MARK: Charts

    @Test func chartsStandInTwoThreeOrFiveColumns() {
        #expect(NowLayout.choice(for: page(1040, 720)).chartColumns == 2)
        #expect(NowLayout.choice(for: page(1440, 940)).chartColumns == 3)
        #expect(NowLayout.choice(for: page(2560, 1440)).chartColumns == 5)
        let metrics = NowLayout.settledMetrics(for: page(1440, 940))
        // Six cards in two rows of three, 14pt apart, 148pt tall: 2 × 148 + 14 = 310.
        let width = (metrics.rowWidth - 28) / 3
        #expect(NowLayout.chartFrame(index: 0, metrics: metrics) == CGRect(x: 0, y: 0, width: width, height: 148))
        #expect(NowLayout.chartFrame(index: 2, metrics: metrics).minX == 2 * (width + 14))
        #expect(NowLayout.chartFrame(index: 3, metrics: metrics).origin == CGPoint(x: 0, y: 162))
        #expect(NowLayout.chartGridHeight(count: 10, metrics: metrics) == 310)
        #expect(NowLayout.chartGridHeight(count: 2, metrics: metrics) == 148)
        #expect(NowLayout.chartOpacity(index: 5, metrics: metrics) == 1)
        #expect(NowLayout.chartOpacity(index: 6, metrics: metrics) == 0)
    }

    @Test func openingOutTheChartsShowsEveryRow() {
        var input = page(1440, 940)
        input.chartsExpanded = true
        let metrics = NowLayout.settledMetrics(for: input)
        // Ten charts in three columns are four rows: 4 × 148 + 3 × 14.
        #expect(NowLayout.chartGridHeight(count: 10, metrics: metrics) == 634)
        #expect(NowLayout.chartOpacity(index: 9, metrics: metrics) == 1)
    }

    // MARK: Motion

    /// With the choices held, a resize moves every size a little: nothing jumps.
    @Test func sizesFollowTheWindowWithoutSteps() {
        let blend = NowLayout.choice(for: page(1440, 940)).blend
        var previous = NowLayout.metrics(width: 900, height: 840, blend: blend)
        for width in stride(from: CGFloat(901), through: 2400, by: 1) {
            let metrics = NowLayout.metrics(width: width, height: 840, blend: blend)
            #expect(abs(metrics.cardWidth - previous.cardWidth) <= 1)
            #expect(abs(metrics.stageHeight - previous.stageHeight) <= 1.5)
            #expect(abs(metrics.rowWidth - previous.rowWidth) <= 1)
            #expect(abs(metrics.visualFrame.minX - previous.visualFrame.minX) <= 1)
            previous = metrics
        }
        previous = NowLayout.metrics(width: 1220, height: 560, blend: blend)
        for height in stride(from: CGFloat(561), through: 2000, by: 1) {
            let metrics = NowLayout.metrics(width: 1220, height: height, blend: blend)
            #expect(abs(metrics.stageHeight - previous.stageHeight) <= 1)
            #expect(abs(metrics.titleSize - previous.titleSize) <= 0.13)
            #expect(metrics.cardWidth == previous.cardWidth)
            previous = metrics
        }
    }

    /// A change of choice is a path between two settled layouts on which
    /// every size moves steadily from its old value to its new one.
    @Test func aChangeOfChoiceIsAGlideNotAJump() {
        let pairs: [(NowLayoutInput, NowLayoutInput)] = [
            (page(1440, 940), page(1440, 940, panel: true)),   // gutter, card count and stage height at once
            (page(1286, 940), page(1287, 940)),                 // a card joins
            (page(1287, 940), page(1288, 940)),                 // the gutter appears
            (page(1440, 839), page(1440, 840)),                 // the Next strip appears
            (page(1440, 940, idle: true), page(1440, 940)),     // playback starts
            (page(1040, 720), page(1040, 720, panel: true))     // a panel floats in
        ]
        let steps = 120
        for (from, to) in pairs {
            let start = NowLayout.choice(for: from).blend, end = NowLayout.choice(for: to).blend
            let first = NowLayout.metrics(width: to.width, height: to.height, blend: start)
            let last = NowLayout.metrics(width: to.width, height: to.height, blend: end)
            var previous = first
            var travelled = (card: CGFloat(0), stage: CGFloat(0), inset: CGFloat(0), page: CGFloat(0))
            for step in 1...steps {
                var delta = end - start
                delta.scale(by: Double(step) / Double(steps))
                let metrics = NowLayout.metrics(width: to.width, height: to.height, blend: start + delta)
                #expect(abs(metrics.cardWidth - previous.cardWidth) <= 2)
                #expect(abs(metrics.stageHeight - previous.stageHeight) <= 4)
                #expect(abs(metrics.pageWidth - previous.pageWidth) <= 340 / CGFloat(steps) + 0.001)
                travelled.card += abs(metrics.cardWidth - previous.cardWidth)
                travelled.stage += abs(metrics.stageHeight - previous.stageHeight)
                travelled.inset += abs(metrics.rowInset - previous.rowInset)
                travelled.page += abs(metrics.pageWidth - previous.pageWidth)
                previous = metrics
            }
            #expect(previous == last)
            // No detours on the way: the row's inset and the page's width go straight there.
            #expect(near(travelled.inset, abs(last.rowInset - first.rowInset), within: 0.01))
            #expect(near(travelled.page, abs(last.pageWidth - first.pageWidth), within: 0.01))
        }
    }

    /// While the grid changes its column count, each chart card travels in a
    /// straight line between its two cells; a card that joins fades in.
    @Test func chartCardsTravelBetweenTheirCells() {
        let two = NowLayout.choice(for: page(1040, 720)).blend
        var three = two
        three.columns2 = 0; three.columns3 = 1
        let rowWidth = NowLayout.metrics(width: 820, height: 620, blend: two).rowWidth
        for index in 0..<6 {
            let from = NowLayout.chartFrame(index: index, columns: 2, rowWidth: rowWidth)
            let to = NowLayout.chartFrame(index: index, columns: 3, rowWidth: rowWidth)
            for step in 0...10 {
                let amount = CGFloat(step) / 10
                var blend = two
                blend.columns2 = 1 - amount; blend.columns3 = amount
                let metrics = NowLayout.metrics(width: 820, height: 620, blend: blend)
                let frame = NowLayout.chartFrame(index: index, metrics: metrics)
                #expect(near(frame.minX, from.minX + (to.minX - from.minX) * amount, within: 0.001))
                #expect(near(frame.minY, from.minY + (to.minY - from.minY) * amount, within: 0.001))
                #expect(near(frame.width, from.width + (to.width - from.width) * amount, within: 0.001))
                // The first four are in both grids; the fifth and sixth join the three-column one.
                #expect(near(NowLayout.chartOpacity(index: index, metrics: metrics), index < 4 ? 1 : amount, within: 0.001))
            }
        }
    }

    @Test func settledAmountsAreWholeAndTheColumnWeightsSumToOne() {
        for frame in CanvasFrame.all {
            let blend = NowLayout.choice(for: frame.input).blend
            #expect(blend.columns2 + blend.columns3 + blend.columns5 == 1)
            for amount in [blend.gutter, blend.nextStrip, blend.compactNext, blend.idle, blend.stacked, blend.panel, blend.dock, blend.connect] {
                #expect(amount == 0 || amount == 1)
            }
            #expect(blend.cards == CGFloat(frame.fit))
        }
    }

    @Test func amountsAddSubtractAndScaleAsAVector() {
        let a = NowLayout.choice(for: page(1440, 940)).blend, b = NowLayout.choice(for: page(1040, 720, panel: true)).blend
        #expect((a + b) - b == a)
        #expect(a - a == .zero)
        var half = b - a
        half.scale(by: 0.5)
        let middle = a + half
        #expect(middle.cards == (a.cards + b.cards) / 2)
        #expect(middle.gutter == 0.5 && middle.panel == 0.5)
        #expect((b - a).magnitudeSquared > 0 && NowLayoutBlend.zero.magnitudeSquared == 0)
    }

    /// The spring may carry an amount a little past its end; sizes stay sane.
    @Test func overshootingAmountsKeepSizesInRange() {
        var blend = NowLayout.choice(for: page(1440, 940)).blend
        blend.gutter = 1.08; blend.panel = 1.1; blend.dock = 1.1; blend.nextStrip = -0.06; blend.idle = -0.05; blend.cards = 0.2
        let metrics = NowLayout.metrics(width: 1220, height: 840, blend: blend)
        #expect(metrics.headHeight >= 0 && metrics.nextStripHeight >= 0)
        #expect(metrics.pageWidth == 880)
        #expect(NowLayout.cardWidthRange.contains(metrics.cardWidth))
        #expect(metrics.stageHeight >= 260)
    }
}
