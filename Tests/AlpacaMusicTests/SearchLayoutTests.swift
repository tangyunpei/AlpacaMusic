import CoreGraphics
import Testing
@testable import AlpacaMusic

/// A window the canvas draws, as the results page's area: the window less the
/// 220-point sidebar (when shown), and less the title strip, header and player bar.
private struct CanvasWindow: CustomTestStringConvertible, Sendable {
    var width: CGFloat
    var height: CGFloat
    var sidebar = true
    var arrangement: SearchArrangement
    var list: CGFloat
    var albumColumn: CGFloat
    var input: SearchLayoutInput {
        SearchLayoutInput(width: width - (sidebar ? 220 : 0), height: height - 209, layer: .singer)
    }
    var testDescription: String { "\(Int(width)) x \(Int(height))\(sidebar ? "" : ", no sidebar")" }

    static let all = [
        CanvasWindow(width: 1440, height: 940, arrangement: .band, list: 1152, albumColumn: 220),
        CanvasWindow(width: 1040, height: 720, arrangement: .compact, list: 752, albumColumn: 150),
        CanvasWindow(width: 1728, height: 904, sidebar: false, arrangement: .columns, list: 960, albumColumn: 220),
        CanvasWindow(width: 1728, height: 1117, arrangement: .band, list: 1440, albumColumn: 220),
        CanvasWindow(width: 1080, height: 1920, arrangement: .band, list: 792, albumColumn: 150),
    ]
}

@Suite struct SearchLayoutTests {
    @Test(arguments: CanvasWindow.all) fileprivate func settlesOnTheCanvasSizes(_ window: CanvasWindow) {
        let choice = SearchLayout.choice(for: window.input)
        let metrics = SearchLayout.metrics(width: window.input.width, blend: choice.blend)
        #expect(choice.arrangement == window.arrangement)
        #expect(metrics.listWidth == window.list)
        #expect(choice.albumColumn == window.albumColumn)
    }

    @Test func theListStopsAt960OnlyWhenTheSingerStandsBesideIt() {
        let below = SearchLayoutInput(width: 1499 + 68, height: 700, layer: .singer)
        let at = SearchLayoutInput(width: 1500 + 68, height: 700, layer: .singer)
        #expect(SearchLayout.choice(for: below).arrangement == .band)
        #expect(SearchLayout.choice(for: at).arrangement == .columns)
        #expect(SearchLayout.metrics(width: at.width, blend: SearchLayout.choice(for: at).blend).listWidth == 960)
        // Songs only, or no singer: the list fills the width.
        for input in [SearchLayoutInput(width: 1712 + 68, height: 700, songsOnly: true, layer: .singer),
                      SearchLayoutInput(width: 1712 + 68, height: 700, layer: .none),
                      SearchLayoutInput(width: 1712 + 68, height: 700, layer: .singers)] {
            let choice = SearchLayout.choice(for: input)
            let metrics = SearchLayout.metrics(width: input.width, blend: choice.blend)
            #expect(metrics.listWidth == 1712)
            #expect(metrics.asideWidth == 0)
            #expect(choice.albumColumn == 220)
        }
        // The singer stands beside the list in what is left, 40 points away.
        let singer = SearchLayoutInput(width: 1712 + 68, height: 700, layer: .singer)
        let metrics = SearchLayout.metrics(width: singer.width, blend: SearchLayout.choice(for: singer).blend)
        #expect(metrics.asideWidth == CGFloat(1712 - 960 - 40))
    }

    @Test func aShortWindowFoldsTheBandToOneRow() {
        #expect(SearchLayout.choice(for: SearchLayoutInput(width: 1220, height: 599, layer: .singer)).arrangement == .compact)
        #expect(SearchLayout.choice(for: SearchLayoutInput(width: 1220, height: 600, layer: .singer)).arrangement == .band)
    }

    @Test func songsOnlyAndASongTitleSearchHaveNoSingerArea() {
        let songsOnly = SearchLayout.choice(for: SearchLayoutInput(width: 1220, height: 731, songsOnly: true, layer: .singer))
        #expect(songsOnly.arrangement == .plain)
        #expect(!songsOnly.singersLine)
        let title = SearchLayout.choice(for: SearchLayoutInput(width: 1220, height: 731, layer: .singers))
        #expect(title.arrangement == .plain)
        #expect(title.singersLine)
    }

    @Test func theAlbumColumnNarrowsThenGoes() {
        #expect(SearchLayout.albumColumn(forList: 900) == 220)
        #expect(SearchLayout.albumColumn(forList: 899) == 150)
        #expect(SearchLayout.albumColumn(forList: 700) == 150)
        #expect(SearchLayout.albumColumn(forList: 699) == 0)
    }

    @Test func theSongColumnIsCappedAndFollowsTheCanvasSum() {
        // 1440 x 940: 1152 - (16 + 24 + 43 + 220 + 64 + 40 + 88 + 84) = 573, capped at 480.
        let wide = SearchLayout.metrics(width: 1152 + 68, blend: SearchLayout.choice(for: SearchLayoutInput(width: 1152 + 68, height: 731)).blend)
        #expect(wide.songColumn == 480)
        // With the queue open: 476 - (16 + 24 + 43 + 64 + 40 + 88 + 72) = 129.
        let narrow = SearchLayout.metrics(width: 476 + 68, blend: SearchLayout.choice(for: SearchLayoutInput(width: 476 + 68, height: 511)).blend)
        #expect(narrow.albumColumn == 0)
        #expect(narrow.songColumn == 129)
    }

    @Test func aFlipTravelsAsAmountsBetweenTheTwoLayouts() {
        let band = SearchLayout.choice(for: SearchLayoutInput(width: 1499 + 68, height: 731, layer: .singer)).blend
        let wide = SearchLayout.choice(for: SearchLayoutInput(width: 1500 + 68, height: 731, layer: .singer)).blend
        var halfway = band
        halfway += (wide - band).scaled(by: 0.5)
        let metrics = SearchLayout.metrics(width: 1500 + 68, blend: halfway)
        #expect(metrics.listWidth == 1230)
        #expect(halfway.band == 0.5 && halfway.columns == 0.5)
    }
}
