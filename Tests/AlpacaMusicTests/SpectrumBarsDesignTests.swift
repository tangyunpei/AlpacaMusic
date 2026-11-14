import CoreGraphics
import Testing
@testable import AlpacaMusic

/// The Now stage's bars, drawn in the room as on the design canvas
/// ("Effects · Spectrum bars, the Now stage design in the room").
@Suite struct SpectrumBarsDesignTests {
    @Test func columnColoursAreFixedByPlaceAsOnTheCanvas() {
        let tints = (0..<96).map(SpectrumBarsRenderer.tint(column:))
        // The canvas's own columns: the same seeded rule picks these.
        #expect(tints.indices.filter { tints[$0] == .yellow } == [5, 22, 45, 54, 69, 73])
        #expect(tints.indices.filter { tints[$0] == .red } == [2, 34, 39, 66, 70, 85, 87])
        #expect((0..<96).map(SpectrumBarsRenderer.tint(column:)) == tints)
    }

    @Test func tallerColumnsAreBrighter() {
        #expect(SpectrumBarsRenderer.opacity(level: 0) == 0.35)
        #expect(SpectrumBarsRenderer.opacity(level: 1) == 1)
        let steps = stride(from: 0.0, through: 1, by: 0.1).map { SpectrumBarsRenderer.opacity(level: $0) }
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 < $1 })
        #expect(SpectrumBarsRenderer.opacity(level: .nan) == 0.35 && SpectrumBarsRenderer.opacity(level: 4) == 1)
        #expect(SpectrumBarsRenderer.mirrorShare == 0.38 && SpectrumBarsRenderer.mirrorOpacity == 0.16)
    }

    /// The room frame: a 1440 x 940 window gives the effect a 1440 x 676 scene.
    @Test func theRoomMatchesTheCanvasFrameAtTheDefaultWindow() {
        let layout = SpectrumBarsRenderer.layout(size: CGSize(width: 1440, height: 676), count: 96, place: .room)
        #expect(abs(layout.plot.width - 1051) < 2)
        #expect(abs(layout.plot.midX - 720) < 0.5)
        #expect(abs(layout.columnWidth - 6) < 0.1 && abs(layout.pitch - layout.columnWidth - 5) < 0.1)
        // Baseline at y 600 of the window and full columns 340 tall.
        #expect(abs(layout.plot.maxY - (600 - 108)) < 1.5 && abs(layout.plot.height - 340) < 1.5)
        // A 480 disc, centred, sitting on the baseline.
        #expect(abs(layout.disc.width - 480) < 1.5 && abs(layout.disc.midX - 720) < 0.5)
        #expect(abs(layout.disc.maxY - layout.plot.maxY) < 0.01)
        // The mirror stays inside the scene.
        #expect(layout.plot.maxY + layout.mirrorGap + layout.plot.height * SpectrumBarsRenderer.mirrorShare < 676)
    }

    @Test(arguments: [CGSize(width: 1040, height: 456), CGSize(width: 1080, height: 1656), CGSize(width: 2560, height: 1176),
                      CGSize(width: 576, height: 600)])
    func theRoomKeepsItsProportionsAtOtherWindows(_ size: CGSize) {
        let layout = SpectrumBarsRenderer.layout(size: size, count: 96, place: .room)
        #expect(layout.plot.minX >= 0 && layout.plot.maxX <= size.width)
        #expect(layout.disc.minX >= 0 && layout.disc.maxX <= size.width && layout.disc.minY >= 0)
        #expect(abs(layout.disc.maxY - layout.plot.maxY) < 0.001)
        // Proportions are the default window's, scaled: never stretched.
        #expect(abs(layout.disc.width / layout.plot.height - 0.71 / 0.503) < 0.001)
        #expect(layout.plot.maxY + 3 + layout.plot.height * 0.38 < size.height)
        #expect(abs(layout.columnWidth / layout.pitch - 6.0 / 11) < 0.001)
    }

    /// On the Now stage the columns run across the visual's width, 4 wide
    /// with 3 between, with the darker disc to the right; once the text sits
    /// below, the disc is centred and the baseline sits 40 pt above the text.
    @Test func theStageLayoutGlidesFromBesideToBelow() {
        let size = CGSize(width: 756, height: 420)
        let beside = SpectrumBarsRenderer.layout(size: size, count: 96, place: .stage(stacked: 0))
        #expect(beside.plot.minX == 0 && beside.plot.width == size.width)
        #expect(abs(beside.columnWidth / beside.pitch - 4.0 / 7) < 0.001)
        #expect(abs(beside.plot.maxY - 420 * 0.73) < 0.01)
        #expect(beside.disc.midX > size.width / 2 && beside.disc.maxY == beside.plot.maxY)
        let below = SpectrumBarsRenderer.layout(size: size, count: 96, place: .stage(stacked: 1))
        #expect(abs(below.plot.maxY - 380) < 0.01 && abs(below.disc.midX - size.width / 2) < 0.01)
        let halfway = SpectrumBarsRenderer.layout(size: size, count: 96, place: .stage(stacked: 0.5))
        #expect(halfway.plot.maxY > beside.plot.maxY && halfway.plot.maxY < below.plot.maxY)
        #expect(halfway.disc.midX < beside.disc.midX && halfway.disc.midX > below.disc.midX)
    }
}
