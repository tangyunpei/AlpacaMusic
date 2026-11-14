import SwiftUI

/// What the results page shows above its songs.
enum SearchLayer: Equatable, Sendable {
    case none
    /// A singer card, beside or above the songs.
    case singer
    /// The line of singers credited in a song-title search.
    case singers
}

/// What decides the results page's layout: the area below the app header
/// and above the player bar, and what the page shows.
struct SearchLayoutInput: Equatable, Sendable {
    var width: CGFloat
    var height: CGFloat
    var songsOnly = false
    var layer: SearchLayer = .none
}

/// Where the singer stands.
enum SearchArrangement: Equatable, Sendable {
    /// Songs alone.
    case plain
    /// The singer in a band above the songs.
    case band
    /// A short window: the singer as one compact row above the songs.
    case compact
    /// A wide window: the songs stop at 960 and the singer stands beside them.
    case columns
}

struct SearchLayoutChoice: Equatable, Sendable {
    var arrangement: SearchArrangement
    /// The content is wide enough for the singer to stand beside a 960-point list.
    var wide: Bool
    /// The singers line of a song-title search shows above the songs.
    var singersLine: Bool
    /// The album column's width; none in a narrow list.
    var albumColumn: CGFloat

    var blend: SearchLayoutBlend {
        SearchLayoutBlend(wide: wide ? 1 : 0, band: arrangement == .band ? 1 : 0, compact: arrangement == .compact ? 1 : 0,
                          columns: arrangement == .columns ? 1 : 0, singersLine: singersLine ? 1 : 0, albumColumn: albumColumn)
    }
}

/// The page's choices as amounts. A resize feeds sizes straight in; when a
/// choice flips, these amounts travel on a spring and the parts glide.
struct SearchLayoutBlend: VectorArithmetic, Sendable {
    var wide: CGFloat = 0
    var band: CGFloat = 0
    var compact: CGFloat = 0
    var columns: CGFloat = 0
    var singersLine: CGFloat = 0
    var albumColumn: CGFloat = 0

    static var zero: SearchLayoutBlend { SearchLayoutBlend() }
    private func combined(_ other: SearchLayoutBlend, _ operation: (CGFloat, CGFloat) -> CGFloat) -> SearchLayoutBlend {
        SearchLayoutBlend(wide: operation(wide, other.wide), band: operation(band, other.band), compact: operation(compact, other.compact),
                          columns: operation(columns, other.columns), singersLine: operation(singersLine, other.singersLine),
                          albumColumn: operation(albumColumn, other.albumColumn))
    }
    static func + (lhs: SearchLayoutBlend, rhs: SearchLayoutBlend) -> SearchLayoutBlend { lhs.combined(rhs, +) }
    static func - (lhs: SearchLayoutBlend, rhs: SearchLayoutBlend) -> SearchLayoutBlend { lhs.combined(rhs, -) }
    mutating func scale(by factor: Double) { self = combined(self) { value, _ in value * CGFloat(factor) } }
    var magnitudeSquared: Double {
        let s = combined(self) { value, _ in value * value }
        // The column width is in points; weigh it like the other amounts.
        return Double(s.wide + s.band + s.compact + s.columns + s.singersLine + s.albumColumn / (220 * 220))
    }
}

/// The results page's sizes for one moment.
struct SearchMetrics: Equatable, Sendable {
    var contentWidth: CGFloat
    var listWidth: CGFloat
    /// The column beside the list in a wide window.
    var asideWidth: CGFloat
    var albumColumn: CGFloat
    /// The song and singer column, capped so a long list does not stretch it.
    var songColumn: CGFloat
}

/// The layout rules of the canvas's results frame (`Search.dc.html`).
enum SearchLayout {
    static let sidePadding: CGFloat = 34
    static let topPadding: CGFloat = 24
    /// From this much content the list stops at `listCap`.
    static let wideFrom: CGFloat = 1500
    static let listCap: CGFloat = 960
    static let asideGap: CGFloat = 40
    /// Under this viewport height the band folds to the compact row.
    static let compactBelow: CGFloat = 600
    static let bandHeight: CGFloat = 176
    static let compactHeight: CGFloat = 84
    static let singersLineHeight: CGFloat = 36
    static let rowHeight: CGFloat = 63
    static let cardWidth: CGFloat = 300
    static let compactCardWidth: CGFloat = 236
    /// Everything on a row but the song and album columns: padding, number,
    /// cover, sources, time, actions.
    static let rowFixed: CGFloat = 16 + 24 + 43 + 64 + 40 + 88

    static func contentWidth(_ width: CGFloat) -> CGFloat { max(0, width - 2 * sidePadding) }

    static func choice(for input: SearchLayoutInput) -> SearchLayoutChoice {
        let content = contentWidth(input.width)
        let wide = content >= wideFrom
        let shaped = !input.songsOnly
        let singer = shaped && input.layer == .singer
        let arrangement: SearchArrangement = !singer ? .plain : wide ? .columns : input.height < compactBelow ? .compact : .band
        let list = arrangement == .columns ? listCap : content
        return SearchLayoutChoice(arrangement: arrangement, wide: wide, singersLine: shaped && input.layer == .singers,
                                  albumColumn: albumColumn(forList: list))
    }

    static func albumColumn(forList list: CGFloat) -> CGFloat { list >= 900 ? 220 : list >= 700 ? 150 : 0 }

    static func metrics(width: CGFloat, blend: SearchLayoutBlend) -> SearchMetrics {
        let content = contentWidth(width)
        // The list stops at 960 only to make room for the singer beside it;
        // with nothing beside it, it fills the width (the owner's call, 14 November).
        let list = content + (min(listCap, content) - content) * blend.columns
        let aside = max(0, content - listCap - asideGap) * blend.columns
        let album = max(0, blend.albumColumn)
        // Gaps between the row's parts: six, or seven with the album column.
        let gaps: CGFloat = 72 + 12 * min(1, album / 150)
        let song = max(0, min(480, list - (rowFixed + album + gaps)))
        // Half points, so the frames at the end of a spring compare equal and are skipped.
        func snap(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
        return SearchMetrics(contentWidth: content, listWidth: snap(list), asideWidth: snap(aside), albumColumn: snap(album), songColumn: snap(song))
    }
}
