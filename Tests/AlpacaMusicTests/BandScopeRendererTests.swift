import CoreGraphics
import SwiftUI
import Testing
@testable import AlpacaMusic

@Suite struct BandScopeRendererTests {
    @Test func spectralBarsPlaceRealHzPeaksAtTheirLogarithmicPositions() {
        for frequency in [80.0, 1_000.0, 8_000.0] {
            var audio = VisualizationAudio()
            audio.available = true
            audio.sampleRate = 44_100
            audio.spectrumBinWidth = 44_100 / 2_048
            audio.spectrum = Array(repeating: 0, count: 1_024)
            let bin = Int((frequency / audio.spectrumBinWidth).rounded())
            audio.spectrum[bin] = 0.85
            let geometry = SpectrumBarsRenderer.geometry(audio: audio, size: .init(width: 960, height: 540), barCount: 60)
            let strongest = geometry.bars.max { $0.magnitude < $1.magnitude }!
            let measuredFrequency = Double(bin) * audio.spectrumBinWidth
            #expect(strongest.lowerFrequency <= measuredFrequency && strongest.upperFrequency >= measuredFrequency)
            #expect(abs(strongest.magnitude - 0.85) < 0.000_001)
            let expectedPosition = log(measuredFrequency / 20) / log(20_000 / 20)
            let actualPosition = (strongest.rect.midX - geometry.plotRect.minX) / geometry.plotRect.width
            #expect(abs(Double(actualPosition) - expectedPosition) < 1.0 / 60)
        }
    }

    @Test func barsWaitForRealFrequencyMetadataAndStayFinite() {
        var audio = VisualizationAudio()
        audio.available = true
        audio.spectrum = [0.7, .nan, .infinity, 0.8]
        let size = CGSize(width: 320, height: 180)
        let absent = SpectrumBarsRenderer.geometry(audio: audio, size: size)
        #expect(absent.state == .waiting)
        #expect(absent.bars.allSatisfy { $0.rect.height == 0 })
        audio.sampleRate = 44_100
        audio.spectrumBinWidth = 21.533_203_125
        let valid = SpectrumBarsRenderer.geometry(audio: audio, size: size)
        #expect(valid.state == .signal)
        #expect(valid.bars.allSatisfy { $0.rect.minX.isFinite && $0.rect.minY.isFinite && $0.rect.maxX <= size.width && $0.rect.minY >= valid.plotRect.minY })
        audio.spectrumBinWidth = Double.leastNonzeroMagnitude
        #expect(SpectrumBarsRenderer.geometry(audio: audio, size: size).bars.allSatisfy { $0.rect.height == 0 })
        audio.spectrumBinWidth = .nan
        #expect(SpectrumBarsRenderer.geometry(audio: audio, size: size).state == .waiting)
    }

    @Test func barsDoNotNormalizeQuietAndLoudAudioToTheSameHeight() {
        func geometry(_ magnitude: Double) -> SpectrumBarsGeometry {
            var audio = VisualizationAudio()
            audio.available = true
            audio.sampleRate = 44_100
            audio.spectrumBinWidth = 44_100 / 2_048
            audio.spectrum = Array(repeating: magnitude, count: 1_024)
            return SpectrumBarsRenderer.geometry(audio: audio, size: .init(width: 960, height: 540))
        }
        let quiet = geometry(0.2), loud = geometry(0.8), silence = geometry(0)
        #expect(loud.bars[0].rect.height > quiet.bars[0].rect.height * 4)
        #expect(silence.state == .silent)
        #expect(silence.bars.allSatisfy { $0.rect.height == 0 })
        #expect(loud.bars[0].rect.height <= loud.plotRect.height)
    }

    @Test func barDensityStaysBoundedForVerySmallAndLargeFiniteSizes() {
        for width in [0.25, 72, 960, Double.greatestFiniteMagnitude] {
            let geometry = SpectrumBarsRenderer.geometry(audio: .init(), size: .init(width: width, height: 180))
            #expect(geometry.bars.count >= 8 && geometry.bars.count <= 96)
            #expect(geometry.bars.allSatisfy { $0.rect.minX.isFinite && $0.rect.maxX.isFinite && $0.rect.minX >= 0 && $0.rect.maxX <= width })
        }
    }

    @Test @MainActor func barsUseAudioInsteadOfAnimationTime() throws {
        let size = CGSize(width: 320, height: 180)
        var signal = VisualizationAudio()
        signal.available = true
        signal.sampleRate = 44_100
        signal.spectrumBinWidth = 44_100 / 2_048
        signal.spectrum = (0..<1_024).map { Double($0) / 1_024 * 0.65 }
        @MainActor func pixels(_ audio: VisualizationAudio, at time: Double) throws -> [UInt8] {
            let view = Canvas { context, canvasSize in
                SpectrumBarsRenderer.draw(in: &context, size: canvasSize, audio: audio, time: time, glow: true)
            }
            return try TemporalDesignExport.rgba(TemporalDesignExport.image(view, size: size))
        }
        let waiting = try pixels(.init(), at: 0)
        #expect(waiting == (try pixels(.init(), at: 20)))
        let active = try pixels(signal, at: 0)
        #expect(active == (try pixels(signal, at: 20)))
        #expect(active != waiting)
    }
}
