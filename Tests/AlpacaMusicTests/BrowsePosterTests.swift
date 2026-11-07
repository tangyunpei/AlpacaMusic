import Testing
@testable import AlpacaMusic

@Suite struct BrowsePosterTests {
    /// A square image whose rows run top to bottom: `top` above, `bottom` in the last rows.
    private func pixels(size: Int = 32, top: [UInt8], bottom: [UInt8], bottomRows: Int = 4) -> ArtworkPixels {
        var rgba: [UInt8] = []
        for row in 0..<size { for _ in 0..<size { rgba += row >= size - bottomRows ? bottom : top } }
        return ArtworkPixels(width: size, height: size, rgba: rgba)
    }

    @Test func theCardColourComesFromTheCoversLowerEdge() throws {
        let colors = try #require(PosterColors.edge(pixels(top: [255, 255, 255, 255], bottom: [200, 40, 20, 255])))
        #expect(abs(colors.background.red - 200.0 / 255) < 0.001)
        #expect(abs(colors.background.green - 40.0 / 255) < 0.001)
        #expect(abs(colors.background.blue - 20.0 / 255) < 0.001)
        // Text colours are left to the card, which picks light or dark ink.
        #expect(colors.primary == nil && colors.secondary == nil)
    }

    @Test func transparentAndPremultipliedPixelsKeepTheirTrueColour() throws {
        // Half-transparent red stored premultiplied reads as full red.
        let half = try #require(PosterColors.edge(pixels(top: [0, 0, 0, 255], bottom: [100, 0, 0, 128])))
        #expect(half.background.red > 0.75 && half.background.green < 0.01)
        // A fully transparent edge gives no colour rather than black.
        #expect(PosterColors.edge(pixels(top: [0, 0, 0, 255], bottom: [0, 0, 0, 0])) == nil)
        #expect(PosterColors.edge(ArtworkPixels(width: 4, height: 4, rgba: [])) == nil)
    }

    @Test func lightAndDarkCardsAreToldApart() {
        #expect(BrowseColor(red: 0.95, green: 0.93, blue: 0.9).luminance > 0.6)
        #expect(BrowseColor(red: 0.2, green: 0.25, blue: 0.4).luminance < 0.6)
    }
}
