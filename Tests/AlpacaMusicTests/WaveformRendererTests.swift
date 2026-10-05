import CoreGraphics
import SwiftUI
import Testing
@testable import AlpacaMusic

@Suite struct WaveformRendererTests {
    @Test func unavailableAndMissingPCMWaitWithoutInventingASignal() {
        let size = CGSize(width: 320, height: 180)
        for input in [([0.6, -0.8], false), ([], true), ([Double.nan, .infinity], true)] {
            let geometry = WaveformRenderer.geometry(samples: input.0, available: input.1, size: size)
            #expect(geometry.state == .waiting)
            #expect(geometry.points.count == 2)
            #expect(geometry.points.allSatisfy { abs($0.y - size.height / 2) < 0.000_001 })
        }
        let silence = WaveformRenderer.geometry(samples: Array(repeating: 0, count: 256), available: true, size: size)
        #expect(silence.state == .silent)
        #expect(silence.points.allSatisfy { abs($0.y - size.height / 2) < 0.000_001 })
    }

    @Test func gainIsFixedAndSignedPCMRetainsItsPolarity() {
        let size = CGSize(width: 960, height: 540)
        let quiet = WaveformRenderer.geometry(samples: [0, 0.1, -0.1, 0], available: true, size: size)
        let loud = WaveformRenderer.geometry(samples: [0, 0.8, -0.8, 0], available: true, size: size)
        #expect(quiet.points[1].y < quiet.centerY && quiet.points[2].y > quiet.centerY)
        let quietHeight = quiet.centerY - quiet.points[1].y
        let loudHeight = loud.centerY - loud.points[1].y
        #expect(abs(loudHeight / quietHeight - 8) < 0.000_001)
        #expect(quiet.plotRect == loud.plotRect)
    }

    @Test func narrowWindowsPreserveOneSamplePeaksAndTheirOrder() {
        var samples = Array(repeating: 0.0, count: 4_096)
        samples[1_771] = 1
        samples[1_772] = -1
        let geometry = WaveformRenderer.geometry(samples: samples, available: true, size: .init(width: 140, height: 90))
        #expect(geometry.points.count < samples.count / 8)
        let positive = geometry.points.firstIndex { abs($0.y - geometry.plotRect.minY) < 0.000_001 }
        let negative = geometry.points.firstIndex { abs($0.y - geometry.plotRect.maxY) < 0.000_001 }
        #expect(positive != nil && negative != nil)
        if let positive, let negative {
            #expect(positive < negative)
            #expect(geometry.points[positive].x < geometry.points[negative].x)
        }
        #expect(zip(geometry.points, geometry.points.dropFirst()).allSatisfy { pair in pair.0.x < pair.1.x })
    }

    @Test func fullScaleAndMalformedPCMStayFiniteInsideTheStage() {
        for size in [CGSize(width: 72, height: 44), .init(width: 320, height: 180), .init(width: 1_280, height: 720)] {
            let geometry = WaveformRenderer.geometry(samples: [0, 1, -1, .nan, .infinity, -4, 4, 0], available: true, size: size)
            #expect(geometry.points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
            #expect(geometry.points.allSatisfy { $0.x > 0 && $0.x < size.width && $0.y > 0 && $0.y < size.height })
            let bounds = WaveformRenderer.path(for: geometry).boundingRect
            // SwiftUI Path stores float coordinates; allow subpixel float rounding.
            #expect(bounds.minY >= geometry.plotRect.minY - 0.000_1)
            #expect(bounds.maxY <= geometry.plotRect.maxY + 0.000_1)
        }
        #expect(WaveformRenderer.geometry(samples: [1], available: true, size: .zero).points.isEmpty)
    }

    @Test func oneSampleDCSignalIsAStableOffsetNotAnOscillation() {
        let geometry = WaveformRenderer.geometry(samples: [0.25], available: true, size: .init(width: 320, height: 180))
        #expect(geometry.state == .signal)
        #expect(geometry.points.count == 2)
        #expect(geometry.points[0].y == geometry.points[1].y)
        #expect(geometry.points[0].y < geometry.centerY)
    }

    /// The production renderer must not animate absent audio as time advances.
    @Test @MainActor func renderedWaveformDependsOnPCMInsteadOfAnimationTime() throws {
        let size = CGSize(width: 320, height: 180)
        var signal = VisualizationAudio()
        signal.available = true
        signal.waveform = [0, 0.1, -0.08, 0.9, -0.6, 0.2, 0, 0]
        @MainActor func pixels(_ audio: VisualizationAudio, at time: Double) throws -> [UInt8] {
            let view = Canvas { context, canvasSize in
                WaveformRenderer.draw(in: &context, size: canvasSize, audio: audio, time: time, glow: true)
            }
            return try TemporalDesignExport.rgba(TemporalDesignExport.image(view, size: size))
        }
        let waiting = try pixels(VisualizationAudio(), at: 0)
        let waitingLater = try pixels(VisualizationAudio(), at: 20)
        #expect(waiting == waitingLater)
        let first = try pixels(signal, at: 0)
        let later = try pixels(signal, at: 20)
        #expect(first == later)
        #expect(first != waiting)
    }
}
