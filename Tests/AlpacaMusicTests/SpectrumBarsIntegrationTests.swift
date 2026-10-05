import Foundation
import SwiftUI
import Testing
@testable import AlpacaMusic

@Suite struct SpectrumBarsIntegrationTests {
    private func input(_ value: Float = 0) -> AudioLevels {
        var audio = AudioLevels(available: true)
        audio.sampleRate = 44_100
        audio.spectrumBinWidth = 44_100 / 2_048
        audio.spectrum = Array(repeating: value, count: 1_024)
        return audio
    }

    @Test @MainActor func completeBarAndPeakPoseFreezesAndResumesWithoutCatchingUp() {
        let epoch = Date(timeIntervalSince1970: 0), clock = VisualizationClock()
        _ = clock.frame(at: epoch, animated: true, levels: input(), playing: true, spectrumBarsActive: true)
        _ = clock.frame(at: epoch.addingTimeInterval(0.04), animated: true, levels: input(0.9), playing: true, spectrumBarsActive: true)
        let response = clock.frame(at: epoch.addingTimeInterval(0.08), animated: true, levels: input(), playing: true, spectrumBarsActive: true)
        #expect(response.spectrumBars.levels.max()! > 0)
        #expect(response.spectrumBars.peaks[10] > response.spectrumBars.levels[10])
        let paused = clock.frame(at: epoch.addingTimeInterval(100), animated: false, levels: .init(), playing: false, spectrumBarsActive: true)
        #expect(paused.spectrumBars == response.spectrumBars)
        let reduced = clock.frame(at: epoch.addingTimeInterval(200), animated: false, levels: input(0.5), playing: true,
                                  captureStaticSignal: true, spectrumBarsActive: true)
        #expect(reduced.spectrumBars == response.spectrumBars)
        let resumed = clock.frame(at: epoch.addingTimeInterval(300), animated: true, levels: input(), playing: true, spectrumBarsActive: true)
        #expect(resumed.spectrumBars == response.spectrumBars && resumed.time == response.time)
        clock.resetSignal()
        let reset = clock.frame(at: epoch.addingTimeInterval(400), animated: false, levels: .init(), playing: false, spectrumBarsActive: true)
        #expect(reset.spectrumBars == .empty)
    }

    @Test @MainActor func freshReducedMotionSnapshotIsRealAndUnavailableInputClearsPeaks() {
        let epoch = Date(timeIntervalSince1970: 0), clock = VisualizationClock()
        let first = clock.frame(at: epoch, animated: false, levels: input(0.6), playing: true,
                                captureStaticSignal: true, spectrumBarsActive: true)
        #expect(first.spectrumBars.levels.max()! > 0.4)
        #expect(first.spectrumBars.levels == first.spectrumBars.peaks)
        let lost = clock.frame(at: epoch.addingTimeInterval(1), animated: false, levels: .init(), playing: true,
                               captureStaticSignal: true, spectrumBarsActive: true)
        #expect(lost.spectrumBars == .empty)
    }

    @Test @MainActor func segmentedSceneUsesMeasuredHeightsAndHeldPeaksAtBothSizes() throws {
        let epoch = Date(timeIntervalSince1970: 0), clock = VisualizationClock()
        _ = clock.frame(at: epoch, animated: true, levels: input(), playing: true, spectrumBarsActive: true)
        let bright = clock.frame(at: epoch.addingTimeInterval(0.05), animated: true, levels: input(0.7), playing: true, spectrumBarsActive: true)
        for size in [CGSize(width: 320, height: 180), CGSize(width: 960, height: 540)] {
            let waiting = try pixels(.init(time: 0, audio: .init()), size: size)
            let active = try pixels(bright, size: size)
            #expect(active != waiting)
            // Passing the same measured pose at another time cannot invent lights.
            var later = bright; later.time += 30
            let difference = TemporalDesignExport.difference(active, try pixels(later, size: size))
            // GPU blur can round a small number of edge pixels by one channel
            // level under concurrent offscreen draws. It must not move cells.
            #expect(difference.changedPixelFraction < 0.0001)
            #expect(difference.meanChannelDifference < 0.01)
            let geometry = SpectrumBarsRenderer.geometry(audio: bright.audio, size: size, presentation: bright.spectrumBars)
            #expect(geometry.bars.count == 72)
            #expect(geometry.bars.allSatisfy { $0.peakRect.minY >= geometry.plotRect.minY && $0.peakRect.maxX <= size.width })
        }
    }

    @MainActor private func pixels(_ frame: VisualizationFrame, size: CGSize) throws -> [UInt8] {
        let view = Canvas { context, canvasSize in
            SpectrumBarsRenderer.draw(in: &context, size: canvasSize, audio: frame.audio, time: frame.time,
                                      glow: true, presentation: frame.spectrumBars)
        }
        return try TemporalDesignExport.rgba(TemporalDesignExport.image(view, size: size))
    }
}
