import AppKit
import Testing
@testable import AlpacaMusic

@Suite @MainActor struct NowConnectArtTests {
    @Test func theConnectCardShowsTheAlpacaOrFallsBackWithoutIt() throws {
        let brand = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/Brand/alpaca-disconnected.svg")
        let art = try #require(NowConnectArt.image(at: brand))
        // A square drawing, shown at 152 points a side.
        #expect(art.size.width > 0 && art.size.width == art.size.height)
        #expect(NowConnectArt.image(at: nil) == nil)
        #expect(NowConnectArt.image(at: brand.deletingLastPathComponent().appending(path: "missing.svg")) == nil)
    }
}
