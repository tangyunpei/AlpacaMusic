import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import AlpacaMusic

/// Harmonograph, "song figure, measured swing" ("Rules · Harmonograph, decided and open").
@Suite struct HarmonographTests {
    private static let frame = 1.0 / 60

    private func levels(bass: Double = 0, mid: Double = 0, amplitude: Double? = nil, beat: Double = 0) -> VisualizationAudio {
        VisualizationAudio(AudioLevels(beat: Float(beat), available: true, amplitude: Float(amplitude ?? max(bass, mid)),
                                       bass: Float(bass), mid: Float(mid), sampleRate: 44_100))
    }

    private func hold(_ figure: inout HarmonographSongFigure, _ audio: VisualizationAudio, seconds: Double) {
        for _ in 0..<Int(seconds * 60) { figure.advance(dt: Self.frame, measured: audio) }
    }

    @Test func eachSongGetsItsOwnFigureFromItsSeed() {
        let first = HarmonographSongFigure(seed: 42), again = HarmonographSongFigure(seed: 42)
        #expect(first.figure == again.figure && first.phase == again.phase)
        let families = Set((0..<64).map { HarmonographSongFigure(seed: UInt64($0) &* 0x9E37_79B9).figure.points })
        #expect(families == Set(HarmonographSongFigure.figures.map(\.points)))
        let leans = Set((0..<16).map { HarmonographSongFigure(seed: UInt64($0) << 20).phase })
        #expect(leans.count > 8)
    }

    /// Width is the measured bass level and height the measured mid level, on
    /// square-root scales: full width at bass 1, full height at mid 0.6.
    @Test func widthFollowsTheBassAndHeightTheMids() {
        var figure = HarmonographSongFigure(seed: 7)
        hold(&figure, levels(bass: 0.49, mid: 0.15), seconds: 1)
        #expect(abs(figure.reachX - 0.7) < 0.01)
        #expect(abs(figure.reachY - (0.15 / 0.6).squareRoot()) < 0.01)
        // Music without low end keeps an open figure from the full-band level.
        var piano = HarmonographSongFigure(seed: 7)
        hold(&piano, levels(bass: 0, mid: 0.3, amplitude: 0.5), seconds: 1)
        #expect(abs(piano.reachX - (0.3 * 0.5).squareRoot()) < 0.01)
    }

    /// A hit throws the newest loop wide; as the level falls it steps back in
    /// and leaves a loop at each step, so the fan is the level falling.
    @Test func aHitThrowsTheLoopWideAndTheFallingLevelLeavesAFan() {
        var figure = HarmonographSongFigure(seed: 3)
        hold(&figure, levels(bass: 0.1, mid: 0.1), seconds: 0.5)
        let resting = figure.reachX
        hold(&figure, levels(bass: 0.8, mid: 0.2), seconds: 0.05)
        #expect(figure.reachX > resting * 2)
        #expect(figure.hitX > 0.5)
        #expect(figure.drawnKeptLoops == 0)
        var fan = 0
        for _ in 0..<18 {
            figure.advance(dt: Self.frame, measured: levels(bass: 0.08, mid: 0.1))
            fan = max(fan, figure.drawnKeptLoops)
        }
        #expect(fan >= 3)
        // The reach only fell as far as the level fell.
        #expect(figure.reachX >= (0.08).squareRoot() - 0.001)
        // Kept loops last about a second and then are gone.
        hold(&figure, levels(bass: 0.08, mid: 0.1), seconds: 1.6)
        #expect(figure.drawnKeptLoops == 0)
    }

    @Test func theRedTicksHoldTheFurthestRecentReach() {
        var figure = HarmonographSongFigure(seed: 3)
        hold(&figure, levels(bass: 0.81, mid: 0.2), seconds: 0.3)
        let reached = figure.holdX
        #expect(abs(reached - 0.9) < 0.02)
        hold(&figure, levels(bass: 0.1, mid: 0.2), seconds: 0.5)
        #expect(figure.holdX == reached)
        hold(&figure, levels(bass: 0.1, mid: 0.2), seconds: 1.5)
        #expect(figure.holdX < reached * 0.5)
    }

    /// Nothing moves on a paused or Reduce Motion frame.
    @Test func frozenFramesChangeNothing() {
        var figure = HarmonographSongFigure(seed: 9)
        hold(&figure, levels(bass: 0.6, mid: 0.3), seconds: 0.4)
        let before = (figure.reachX, figure.reachY, figure.holdX, figure.phase, figure.drawnKeptLoops)
        for _ in 0..<120 { figure.advance(dt: 0, measured: levels(bass: 0.05, mid: 0.9)) }
        let after = (figure.reachX, figure.reachY, figure.holdX, figure.phase, figure.drawnKeptLoops)
        #expect(before == after)
    }

    /// The small resting figure shows only before a song's first samples. Once
    /// the song has been heard, losing samples leaves an empty disc.
    @Test func theRestingFigureShowsOnlyBeforeTheFirstSamples() {
        var figure = HarmonographSongFigure(seed: 11)
        hold(&figure, VisualizationAudio(), seconds: 1)
        #expect(figure.idle == 1 && !figure.measured)
        hold(&figure, levels(bass: 0.4, mid: 0.2), seconds: 0.2)
        #expect(figure.idle == 0 && figure.live)
        hold(&figure, VisualizationAudio(), seconds: 2)
        #expect(figure.idle == 0 && !figure.live && !figure.swinging)
    }

    /// Reduce Motion from the first frame shows one real snapshot, still.
    @Test func reduceMotionShowsOneMeasuredStill() {
        var figure = HarmonographSongFigure(seed: 5)
        figure.advance(dt: 0, measured: levels(bass: 0.36, mid: 0.15))
        #expect(abs(figure.reachX - 0.6) < 0.001 && figure.swinging && figure.idle == 0)
    }

    @Test func aFullSwingReachesTheBarsWidthAndTheDiscHeight() {
        let layout = HarmonographSongFigure.layout(size: CGSize(width: 1440, height: 676))
        #expect(abs(layout.halfWidth - 525.6) < 0.01 && abs(layout.halfHeight - 270.4) < 0.01)
        #expect(abs(layout.disc.width - 540.8) < 0.01 && layout.centre == CGPoint(x: 720, y: 338))
    }

    /// The stage starts a new figure for a new song, on the measured levels.
    @MainActor @Test func theStageMakesANewFigureForEachSong() {
        let model = HarmonographStageModel(), start = Date(timeIntervalSince1970: 0)
        var loud = AudioLevels(available: true, amplitude: 0.7, bass: 0.64, mid: 0.2, sampleRate: 44_100)
        var figure = HarmonographSongFigure(seed: 0)
        for step in 0..<20 {
            figure = model.figure(at: start.addingTimeInterval(Double(step) / 60), trackID: "a", seed: 1, animated: true,
                                  levels: loud, playing: true, captureStaticSignal: false)
        }
        // Measured, not eased: the reach is there within a few frames.
        #expect(abs(figure.reachX - 0.8) < 0.02)
        loud.bass = 0.1
        let next = model.figure(at: start.addingTimeInterval(1), trackID: "b", seed: 99, animated: false,
                                levels: AudioLevels(), playing: true, captureStaticSignal: false)
        #expect(next.idle == 1 && next.reachX == 0 && next.figure == HarmonographSongFigure(seed: 99).figure)
    }

    @MainActor @Test func drawingIsFiniteAndStaysOnTheRoom() throws {
        var figure = HarmonographSongFigure(seed: 17)
        hold(&figure, levels(bass: 0.9, mid: 0.5), seconds: 0.1)
        hold(&figure, levels(bass: 0.2, mid: 0.3), seconds: 0.2)
        let drawn = figure
        let view = Canvas(opaque: false) { context, size in drawn.draw(in: &context, size: size, place: .room) }
        let pixels = try TemporalDesignExport.rgba(TemporalDesignExport.image(view, size: CGSize(width: 480, height: 240)))
        #expect(pixels.contains { $0 > 60 })
    }
}
