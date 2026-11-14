import CoreGraphics
import Foundation
import Testing
@testable import AlpacaMusic

/// The oscilloscope drawn on the room ("Rules · Oscilloscope and Spectral horizon").
@Suite struct OscilloscopeDesignTests {
    private func audio(_ swing: Double) -> VisualizationAudio {
        var levels = AudioLevels(available: true, waveform: [0, Float(swing), Float(-swing / 2), 0], sampleRate: 44_100)
        levels.waveformDuration = 3 / 44_100
        return VisualizationAudio(levels)
    }

    /// In a 1440 x 940 window the room's scene is 1440 x 676: full scale is
    /// 82% of the Harmonograph disc's radius, and the trace runs well past it.
    @Test func theTraceIsCentredOnTheRoomWithNoScreenOfItsOwn() {
        let layout = WaveformRenderer.layout(size: CGSize(width: 1440, height: 676))
        let harmonograph = HarmonographSongFigure.layout(size: CGSize(width: 1440, height: 676))
        #expect(abs(layout.plot.midX - 720) < 0.01 && abs(layout.plot.midY - 338) < 0.01)
        #expect(abs(layout.plot.width / 2 - 525.6) < 0.5)
        #expect(abs(layout.plot.height / 2 - 0.82 * harmonograph.disc.width / 2) < 0.01)
        #expect(layout.plot.minX > 0 && layout.plot.maxX + 22 < 1440)
        #expect(WaveformRenderer.stroke == 1.6)
    }

    @Test func theRedTicksHoldTheWidestRecentSwingAndFall() {
        var hold = OscilloscopePeakHold()
        #expect(hold.step(dt: 1.0 / 60, audio: audio(0.8)) == Double(Float(0.8)))
        // A smaller swing does not lower it at once; it falls by e every 1.2 s.
        let next = hold.step(dt: 1.2, audio: audio(0.1))
        #expect(abs(next - Double(Float(0.8)) / M_E) < 0.000_1)
        // A wider swing raises it at once.
        #expect(hold.step(dt: 1.0 / 60, audio: audio(0.9)) == Double(Float(0.9)))
        // A frozen frame neither raises nor lowers it ...
        #expect(hold.step(dt: 0, audio: audio(0.2)) == Double(Float(0.9)))
        // ... and losing the audio clears it.
        #expect(hold.step(dt: 1.0 / 60, audio: VisualizationAudio()) == 0)
    }

    @MainActor @Test func theClockCarriesTheHeldSwingAndAResetClearsIt() {
        let clock = VisualizationClock(), start = Date(timeIntervalSince1970: 0)
        var levels = AudioLevels(available: true, waveform: Array(repeating: 0.6, count: 64), sampleRate: 44_100)
        levels.waveformDuration = 63 / 44_100
        var peak = 0.0
        for step in 0..<30 {
            peak = clock.frame(at: start.addingTimeInterval(Double(step) / 60), animated: true, levels: levels, playing: true).scopePeak
        }
        #expect(peak > 0.5 && peak <= Double(Float(0.6)))
        clock.resetSignal()
        #expect(clock.frame(at: start.addingTimeInterval(2), animated: false, levels: levels, playing: true).scopePeak == 0)
    }
}
