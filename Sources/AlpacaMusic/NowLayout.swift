import SwiftUI

/// Where the opened list or the queue sits beside the Now page.
enum NowPanelPlacement: Equatable, Sendable { case closed, docked, floating }

/// What decides the Now page's layout: the room it has and what it shows.
struct NowLayoutInput: Equatable, Sendable {
    /// The page's own width: the window without the sidebar.
    var width: CGFloat
    /// From the window's top edge down to the player bar.
    var height: CGFloat
    /// Nothing is playing.
    var idle = false
    /// A list or the queue is open beside the page.
    var panelOpen = false
    /// No source is connected, so a prompt replaces Today's cards.
    var connect = false
    /// The stage offers a button: play when idle, resume when paused.
    var action = false
    /// The stage shows the current and the next lyric line.
    var lyrics = true
    /// The stage says its visual has no live audio to draw.
    var notice = false
    /// This week shows every chart instead of two rows.
    var chartsExpanded = false
}

/// The layout the page settles on for one window and state: every either-or
/// the design makes. Sizes follow from it and the page's size.
struct NowLayoutChoice: Equatable, Sendable {
    /// Section names stand in a column at the left of each section.
    var gutter: Bool
    /// Whole cards in a row, before the part of the next one that shows.
    var cardsPerRow: Int
    /// The window is too short for the Next strip.
    var compact: Bool
    var nextStrip: Bool
    var idle: Bool
    /// The stage is tall for its width: the visual spans it and the text
    /// sits below, instead of side by side.
    var stacked: Bool
    var chartColumns: Int
    var panel: NowPanelPlacement
    /// A panel opened at this width would dock.
    var docks: Bool
    var connect: Bool
    var action: Bool
    var lyrics: Bool
    var notice: Bool
    var chartsExpanded: Bool

    /// The same choices as amounts, the form in which they move.
    var blend: NowLayoutBlend {
        NowLayoutBlend(gutter: gutter ? 1 : 0, cards: CGFloat(cardsPerRow), nextStrip: nextStrip ? 1 : 0,
                       compactNext: compact && !idle ? 1 : 0, idle: idle ? 1 : 0, stacked: stacked ? 1 : 0,
                       columns2: chartColumns == 2 ? 1 : 0, columns3: chartColumns == 3 ? 1 : 0, columns5: chartColumns == 5 ? 1 : 0,
                       panel: panel == .closed ? 0 : 1, dock: docks ? 1 : 0, connect: connect ? 1 : 0,
                       action: action ? 1 : 0, lyrics: lyrics ? 1 : 0, notice: notice ? 1 : 0, expanded: chartsExpanded ? 1 : 0)
    }
}

/// Each choice as an amount. A window resize feeds sizes straight into the
/// layout; when a choice flips, only these amounts travel on a spring, so the
/// page's parts glide to their new places while still following the window.
struct NowLayoutBlend: VectorArithmetic, Sendable {
    var gutter: CGFloat = 0
    /// Cards per row as a real number, so a card joins or leaves gradually.
    var cards: CGFloat = 4
    var nextStrip: CGFloat = 0
    /// The one-line "next" note the stage shows when the strip has no room.
    var compactNext: CGFloat = 0
    var idle: CGFloat = 0
    var stacked: CGFloat = 0
    /// How much of each chart grid is showing; they sum to one.
    var columns2: CGFloat = 0
    var columns3: CGFloat = 1
    var columns5: CGFloat = 0
    var panel: CGFloat = 0
    var dock: CGFloat = 0
    var connect: CGFloat = 0
    var action: CGFloat = 0
    var lyrics: CGFloat = 0
    var notice: CGFloat = 0
    var expanded: CGFloat = 0

    static var zero: NowLayoutBlend {
        NowLayoutBlend(gutter: 0, cards: 0, nextStrip: 0, compactNext: 0, idle: 0, stacked: 0, columns2: 0, columns3: 0, columns5: 0,
                       panel: 0, dock: 0, connect: 0, action: 0, lyrics: 0, notice: 0, expanded: 0)
    }
    private func combined(_ other: NowLayoutBlend, _ operation: (CGFloat, CGFloat) -> CGFloat) -> NowLayoutBlend {
        NowLayoutBlend(gutter: operation(gutter, other.gutter), cards: operation(cards, other.cards),
                       nextStrip: operation(nextStrip, other.nextStrip), compactNext: operation(compactNext, other.compactNext),
                       idle: operation(idle, other.idle), stacked: operation(stacked, other.stacked),
                       columns2: operation(columns2, other.columns2), columns3: operation(columns3, other.columns3),
                       columns5: operation(columns5, other.columns5), panel: operation(panel, other.panel),
                       dock: operation(dock, other.dock), connect: operation(connect, other.connect),
                       action: operation(action, other.action), lyrics: operation(lyrics, other.lyrics),
                       notice: operation(notice, other.notice), expanded: operation(expanded, other.expanded))
    }
    static func + (lhs: NowLayoutBlend, rhs: NowLayoutBlend) -> NowLayoutBlend { lhs.combined(rhs, +) }
    static func - (lhs: NowLayoutBlend, rhs: NowLayoutBlend) -> NowLayoutBlend { lhs.combined(rhs, -) }
    mutating func scale(by factor: Double) { self = combined(self) { value, _ in value * CGFloat(factor) } }
    var magnitudeSquared: Double {
        let squares = combined(self) { value, _ in value * value }
        return Double(squares.gutter + squares.cards + squares.nextStrip + squares.compactNext + squares.idle + squares.stacked
                      + squares.columns2 + squares.columns3 + squares.columns5 + squares.panel + squares.dock + squares.connect
                      + squares.action + squares.lyrics + squares.notice + squares.expanded)
    }
}

/// The Now page's sizes for one moment: the page's area and the amounts.
struct NowMetrics: Equatable, Sendable {
    /// The whole area: the page and, when one is docked, the panel.
    var width: CGFloat
    var height: CGFloat
    /// The page beside a docked panel.
    var pageWidth: CGFloat
    var contentWidth: CGFloat
    var gutter: CGFloat
    /// From the content's left edge to where a section's row starts.
    var rowInset: CGFloat
    var rowWidth: CGFloat
    var cardWidth: CGFloat
    var cardHeight: CGFloat
    /// The line that names a section above its row when there is no gutter.
    var headHeight: CGFloat
    var todayRowHeight: CGFloat
    var todayHeight: CGFloat
    var nextStrip: CGFloat
    var nextStripHeight: CGFloat
    var compactNext: CGFloat
    var idle: CGFloat
    var stageHeight: CGFloat
    var titleSize: CGFloat
    var lyricSize: CGFloat
    var lyricNextSize: CGFloat
    /// From the stage's bottom edge to the top of its text.
    var textHeight: CGFloat
    var stacked: CGFloat
    /// The visual's place on the stage.
    var visualFrame: CGRect
    var action: CGFloat
    var lyrics: CGFloat
    var notice: CGFloat
    var connect: CGFloat
    var panel: CGFloat
    var dock: CGFloat
    var columns: NowChartColumns
    var expanded: CGFloat
}

/// What a section below the stage needs to place its heading and its row.
/// A part that takes only this is left alone by changes it does not show,
/// such as the stage growing with the window's height.
struct NowRowMetrics: Equatable, Sendable {
    var contentWidth: CGFloat
    var gutter: CGFloat
    var rowInset: CGFloat
    var rowWidth: CGFloat
    var headHeight: CGFloat
}

/// What the stage needs.
struct NowStageMetrics: Equatable, Sendable {
    var pageWidth: CGFloat
    var contentWidth: CGFloat
    var height: CGFloat
    var gutter: CGFloat
    var rowInset: CGFloat
    var titleSize: CGFloat
    var lyricSize: CGFloat
    var lyricNextSize: CGFloat
    var textHeight: CGFloat
    var stacked: CGFloat
    var visualFrame: CGRect
    var action: CGFloat
    var lyrics: CGFloat
    var notice: CGFloat
    var compactNext: CGFloat
}

extension NowMetrics {
    var row: NowRowMetrics {
        NowRowMetrics(contentWidth: contentWidth, gutter: gutter, rowInset: rowInset, rowWidth: rowWidth, headHeight: headHeight)
    }
    var stage: NowStageMetrics {
        NowStageMetrics(pageWidth: pageWidth, contentWidth: contentWidth, height: stageHeight, gutter: gutter, rowInset: rowInset,
                        titleSize: titleSize, lyricSize: lyricSize, lyricNextSize: lyricNextSize, textHeight: textHeight,
                        stacked: stacked, visualFrame: visualFrame, action: action, lyrics: lyrics, notice: notice, compactNext: compactNext)
    }
    var cardSize: CGSize { CGSize(width: cardWidth, height: cardHeight) }
}

/// How much of each chart grid shows while the page changes between them.
struct NowChartColumns: Equatable, Sendable {
    var two: CGFloat
    var three: CGFloat
    var five: CGFloat
}

enum NowLayout {
    static let sidebarWidth: CGFloat = 220
    static let playerBarHeight: CGFloat = 100
    /// The strip at the window's top that drags it.
    static let stripHeight: CGFloat = 52
    static let sidePadding: CGFloat = 34
    static let panelWidth: CGFloat = 340
    /// The page keeps at least the width it has in the smallest window, so a
    /// panel docks only where that still fits and floats elsewhere.
    static let minimumPageWidth: CGFloat = 820
    static let gutterThreshold: CGFloat = 1000
    static let gutterWidth: CGFloat = 130
    static let gutterGap: CGFloat = 18
    static var gutterSpan: CGFloat { gutterWidth + gutterGap }
    static let headHeight: CGFloat = 44
    static let cardGap: CGFloat = 18
    /// The part of the next card that shows at the end of a row.
    static let cardPeek: CGFloat = 0.4
    static let cardWidthRange: ClosedRange<CGFloat> = 180...280
    static let connectHeight: CGFloat = 180
    static let nextStripHeight: CGFloat = 72
    static let nextItemWidth: CGFloat = 222
    /// A page shorter than this (a window under 840pt) drops the Next strip.
    static let compactHeight: CGFloat = 740
    static let stageFloor: CGFloat = 260
    static let stageCeiling: CGFloat = 720
    static let stageShare: CGFloat = 0.55
    static let todayPadding = (top: CGFloat(24), bottom: CGFloat(20))
    static let weekPadding = (top: CGFloat(28), bottom: CGFloat(28))
    static let latelyPadding = (top: CGFloat(28), bottom: CGFloat(36))
    static let chartCardHeight: CGFloat = 148
    static let chartGap: CGFloat = 14
    static let chartRows = 2
    static let tileWidth: CGFloat = 132

    // MARK: Choices

    static func choice(for input: NowLayoutInput) -> NowLayoutChoice {
        let docks = input.width - panelWidth >= minimumPageWidth
        let panel: NowPanelPlacement = !input.panelOpen ? .closed : docks ? .docked : .floating
        let pageWidth = input.width - (panel == .docked ? panelWidth : 0)
        let contentWidth = pageWidth - 2 * sidePadding
        let gutter = contentWidth >= gutterThreshold
        let rowWidth = contentWidth - (gutter ? gutterSpan : 0)
        let compact = input.height < compactHeight
        let base: CGFloat = contentWidth >= 1700 ? 264 : compact ? 196 : 240
        let cards = max(2, roundHalfUp((rowWidth - cardPeek * base) / (base + cardGap)))
        let nextStrip = !compact && !input.idle
        var choice = NowLayoutChoice(gutter: gutter, cardsPerRow: cards, compact: compact, nextStrip: nextStrip, idle: input.idle,
                                     stacked: false, chartColumns: rowWidth >= 1700 ? 5 : rowWidth >= 940 ? 3 : 2,
                                     panel: panel, docks: docks, connect: input.connect, action: input.action,
                                     lyrics: input.lyrics && !input.idle, notice: input.notice && !input.idle,
                                     chartsExpanded: input.chartsExpanded)
        let settled = metrics(width: input.width, height: input.height, blend: choice.blend)
        choice.stacked = settled.pageWidth / settled.stageHeight < 1.6
        return choice
    }

    // MARK: Sizes

    static func metrics(width: CGFloat, height: CGFloat, blend: NowLayoutBlend) -> NowMetrics {
        let panel = share(blend.panel), dock = share(blend.dock)
        let pageWidth = pixel(max(320, width - panelWidth * panel * dock))
        let contentWidth = pageWidth - 2 * sidePadding
        let gutter = share(blend.gutter)
        // The inset may overshoot with the spring; sizes that cannot go negative use the bounded amount.
        let rowInset = pixel(gutterSpan * blend.gutter)
        let rowWidth = max(120, contentWidth - rowInset)
        let cards = max(1, blend.cards)
        // Whole points, as on the canvas. A card then keeps its size over several
        // steps of a resize, and a step that leaves it alone costs it nothing.
        let cardWidth = clamp(((rowWidth - cardGap * cards) / (cards + cardPeek)).rounded(), cardWidthRange.lowerBound, cardWidthRange.upperBound)
        let cardHeight = (cardWidth * 4 / 3).rounded()
        let headHeight = pixel(Self.headHeight * (1 - gutter))
        let connect = share(blend.connect)
        let todayRowHeight = pixel(cardHeight + (connectHeight - cardHeight) * connect)
        let todayHeight = todayPadding.top + headHeight + todayRowHeight + todayPadding.bottom
        let nextStrip = share(blend.nextStrip)
        let nextStripHeight = pixel(Self.nextStripHeight * nextStrip)
        let idle = share(blend.idle)
        let ceiling = max(stageFloor, min(stageCeiling, height * stageShare))
        let playing = clamp(height - nextStripHeight - todayHeight, stageFloor, ceiling)
        let stageHeight = pixel(playing + (stageFloor - playing) * idle)
        // Type in whole points, as on the canvas: a size in between is set and drawn afresh at every step.
        let titleSize = clamp((stageHeight * 0.125).rounded(), 34, 76)
        let lyricSize = clamp((stageHeight * 0.052).rounded(), 16, 30)
        let lyricNextSize = max(13, (lyricSize * 0.72).rounded())
        let action = share(blend.action), lyrics = share(blend.lyrics)
        let textHeight = pixel(73 + titleSize * 1.08 + action * 55 + lyrics * (20 + lyricSize * 1.3 + lyricNextSize * 1.3))
        let stacked = share(blend.stacked)
        let visualLeft = pixel(pageWidth * 0.38 * (1 - stacked))
        let visualFrame = CGRect(x: visualLeft, y: 0, width: pageWidth - visualLeft, height: pixel(max(1, stageHeight - stacked * textHeight)))
        return NowMetrics(width: width, height: height, pageWidth: pageWidth, contentWidth: contentWidth, gutter: gutter,
                          rowInset: rowInset, rowWidth: rowWidth, cardWidth: cardWidth, cardHeight: cardHeight,
                          headHeight: headHeight, todayRowHeight: todayRowHeight, todayHeight: todayHeight,
                          nextStrip: nextStrip, nextStripHeight: nextStripHeight, compactNext: share(blend.compactNext),
                          idle: idle, stageHeight: stageHeight, titleSize: titleSize, lyricSize: lyricSize,
                          lyricNextSize: lyricNextSize, textHeight: textHeight, stacked: stacked, visualFrame: visualFrame,
                          action: action, lyrics: lyrics, notice: share(blend.notice), connect: connect, panel: panel, dock: dock,
                          columns: NowChartColumns(two: fine(blend.columns2), three: fine(blend.columns3), five: fine(blend.columns5)),
                          expanded: share(blend.expanded))
    }

    /// A length on the half-point grid: a whole pixel on a Retina display.
    static func pixel(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
    /// An amount in steps too fine to see. The last stretch of a glide, where
    /// nothing visibly moves any more, then gives the same sizes frame after
    /// frame, and a frame with the same sizes redraws nothing.
    static func fine(_ value: CGFloat) -> CGFloat { (value * 1024).rounded() / 1024 }
    /// A fine amount between nothing and all.
    static func share(_ value: CGFloat) -> CGFloat { fine(unit(value)) }

    /// The sizes the page rests at for a window and state.
    static func settledMetrics(for input: NowLayoutInput) -> NowMetrics {
        metrics(width: input.width, height: input.height, blend: choice(for: input).blend)
    }

    // MARK: Rows

    /// Songs the Next strip has room for beside its label and the queue button.
    static func nextItemCount(rowWidth: CGFloat) -> Int {
        max(1, Int(((rowWidth - 120) / nextItemWidth).rounded(.down)))
    }

    // MARK: Chart grid

    static let chartColumnOptions = [2, 3, 5]

    static func chartCardWidth(columns: Int, rowWidth: CGFloat) -> CGFloat {
        max(1, (rowWidth - chartGap * CGFloat(columns - 1)) / CGFloat(columns))
    }


    /// A chart card's place in a grid of `columns`, rows running on below the
    /// ones shown, so a card that is about to join glides up from there.
    static func chartFrame(index: Int, columns: Int, rowWidth: CGFloat) -> CGRect {
        let width = chartCardWidth(columns: columns, rowWidth: rowWidth)
        return CGRect(x: CGFloat(index % columns) * (width + chartGap), y: CGFloat(index / columns) * (chartCardHeight + chartGap),
                      width: width, height: chartCardHeight)
    }

    /// Rows a grid of `columns` shows for `count` charts.
    static func chartRowCount(count: Int, columns: Int, expanded: CGFloat) -> CGFloat {
        let all = CGFloat((count + columns - 1) / columns), folded = min(all, CGFloat(chartRows))
        return folded + (all - folded) * expanded
    }

    static func chartFrame(index: Int, metrics: NowMetrics) -> CGRect {
        chartFrame(index: index, columns: metrics.columns, rowWidth: metrics.rowWidth)
    }
    static func chartFrame(index: Int, columns: NowChartColumns, rowWidth: CGFloat) -> CGRect {
        blended(columns) { chartFrame(index: index, columns: $0, rowWidth: rowWidth) }
    }

    static func chartGridHeight(count: Int, metrics: NowMetrics) -> CGFloat {
        chartGridHeight(count: count, columns: metrics.columns, expanded: metrics.expanded)
    }
    static func chartGridHeight(count: Int, columns: NowChartColumns, expanded: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let height = zip(chartColumnOptions, columns.weights).reduce(CGFloat(0)) { total, pair in
            let rows = chartRowCount(count: count, columns: pair.0, expanded: expanded)
            return total + pair.1 * (rows * chartCardHeight + max(0, rows - 1) * chartGap)
        }
        return max(0, height)
    }

    /// How visible chart `index` is: fully in the rows a grid shows, and
    /// fading in below them as the list opens out.
    static func chartOpacity(index: Int, metrics: NowMetrics) -> CGFloat {
        chartOpacity(index: index, columns: metrics.columns, expanded: metrics.expanded)
    }
    static func chartOpacity(index: Int, columns: NowChartColumns, expanded: CGFloat) -> CGFloat {
        let value = zip(chartColumnOptions, columns.weights).reduce(CGFloat(0)) { total, pair in
            total + pair.1 * (index < pair.0 * chartRows ? 1 : expanded)
        }
        return unit(value)
    }

    private static func blended(_ columns: NowChartColumns, _ frame: (Int) -> CGRect) -> CGRect {
        var x: CGFloat = 0, y: CGFloat = 0, width: CGFloat = 0, height: CGFloat = 0
        for (option, weight) in zip(chartColumnOptions, columns.weights) {
            let rect = frame(option)
            x += weight * rect.minX; y += weight * rect.minY; width += weight * rect.width; height += weight * rect.height
        }
        return CGRect(x: x, y: y, width: max(1, width), height: max(1, height))
    }

    // MARK: Arithmetic

    static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { max(low, min(high, value)) }
    static func unit(_ value: CGFloat) -> CGFloat { value.isFinite ? max(0, min(1, value)) : 0 }
    /// Halves round up, as on the design canvas.
    static func roundHalfUp(_ value: CGFloat) -> Int { Int((value + 0.5).rounded(.down)) }
}

extension NowChartColumns {
    var weights: [CGFloat] { [two, three, five] }
}
