import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import AlpacaMusic

@Suite struct SpectralHorizonTests {
    private static let size = CGSize(width: 480, height: 270)

    private func audio(peak frequency: Double? = 1_000, magnitude: Double = 1,
                       rate: Double = 44_100, count: Int = 1_024) -> VisualizationAudio {
        var result = VisualizationAudio()
        result.available = true
        result.sampleRate = rate
        result.spectrumBinWidth = rate / 2_048
        var spectrum = [Double](repeating: 0, count: count)
        if let frequency {
            let bin = Int((frequency / result.spectrumBinWidth).rounded())
            if bin >= 0, bin < count { spectrum[bin] = magnitude }
        }
        result.spectrum = spectrum
        return result
    }

    private var silence: VisualizationAudio { audio(peak: nil) }

    /// One immediate row, then exactly one more row per whole capture interval.
    private func filled(_ input: VisualizationAudio, captures: Int) -> SpectralHorizonHistory {
        var history = SpectralHorizonHistory()
        history.advance(dt: SpectralHorizonHistory.captureInterval, audio: input)
        for _ in 0..<captures { history.advance(dt: SpectralHorizonHistory.captureInterval, audio: input) }
        return history
    }

    private static func isFlat(_ ridge: SpectralHorizonRidge) -> Bool {
        ridge.points.allSatisfy { $0.y == ridge.baseY }
    }

    @Test func unavailableAudioShowsAStaticWaitingHorizon() {
        var history = SpectralHorizonHistory()
        let initial = SpectralHorizonRenderer.geometry(history: history, size: Self.size)
        #expect(initial.state == .waiting)
        #expect(initial.ridges.count == SpectralHorizonRenderer.waitingRowCount)
        #expect(initial.ridges.allSatisfy(Self.isFlat))
        var noPCM = VisualizationAudio()
        noPCM.energy = 1
        noPCM.beat = 1
        noPCM.bass = 1
        for _ in 0..<240 { history.advance(dt: 1.0 / 60, audio: noPCM) }
        #expect(history.rows.isEmpty)
        #expect(history.state == .waiting)
        #expect(SpectralHorizonRenderer.geometry(history: history, size: Self.size) == initial)
    }

    @Test func losingAudioClearsTheLandscapeInsteadOfHoldingAnInventedOne() {
        var history = filled(audio(), captures: 5)
        #expect(history.state == .signal)
        history.advance(dt: 0.02, audio: VisualizationAudio())
        #expect(history.rows.isEmpty)
        #expect(history.state == .waiting)
        var missingMetadata = audio()
        missingMetadata.spectrumBinWidth = 0
        var other = filled(audio(), captures: 2)
        other.advance(dt: 0.02, audio: missingMetadata)
        #expect(other.state == .waiting)
        #expect(SpectralHorizonHistory.measure(missingMetadata) == nil)
    }

    @Test func realSilenceShowsAStaticSilentComposition() {
        var history = filled(silence, captures: 3)
        #expect(history.state == .silent)
        #expect(history.rows.count == 1)
        #expect(history.rows.allSatisfy { row in row.allSatisfy { $0 == 0 } })
        let geometry = SpectralHorizonRenderer.geometry(history: history, size: Self.size)
        #expect(geometry.state == .silent)
        #expect(geometry.ridges.count == SpectralHorizonRenderer.waitingRowCount)
        #expect(geometry.ridges.allSatisfy(Self.isFlat))
        var frozen = history
        frozen.advance(dt: 0, audio: silence)
        #expect(frozen == history)
        for _ in 0..<120 { history.advance(dt: 1.0 / 60, audio: silence) }
        let later = SpectralHorizonRenderer.geometry(history: history, size: Self.size)
        #expect(later == geometry)

        // Music followed by silence recedes until every row is flat, then stops.
        var fading = filled(audio(), captures: 5)
        #expect(fading.state == .signal)
        fading.advance(dt: SpectralHorizonHistory.captureInterval, audio: silence)
        #expect(fading.rows.count == 7)
        for _ in 0..<(SpectralHorizonHistory.capacity + 2) {
            fading.advance(dt: SpectralHorizonHistory.captureInterval, audio: silence)
        }
        #expect(fading.state == .silent)
        let settled = fading
        fading.advance(dt: 0.03, audio: silence)
        #expect(fading == settled)
        #expect(SpectralHorizonRenderer.geometry(history: fading, size: Self.size) == geometry)
    }

    @Test func rowsAreCapturedAtAFixedRateAndBounded() {
        var history = SpectralHorizonHistory()
        history.advance(dt: 0.01, audio: audio())
        #expect(history.rows.count == 1)
        history.advance(dt: SpectralHorizonHistory.captureInterval * 0.5, audio: audio())
        #expect(history.rows.count == 1)
        history.advance(dt: SpectralHorizonHistory.captureInterval * 0.6, audio: audio())
        #expect(history.rows.count == 2)
        // Long hitches are bounded and can never exceed the capacity.
        for _ in 0..<200 { history.advance(dt: 5, audio: audio()) }
        #expect(history.rows.count == SpectralHorizonHistory.capacity)
        #expect(history.rows.allSatisfy { $0.count == SpectralHorizonHistory.columnCount })
        #expect(history.phase >= 0 && history.phase < 1)
        let geometry = SpectralHorizonRenderer.geometry(history: history, size: Self.size)
        #expect(geometry.ridges.count == SpectralHorizonHistory.capacity)
        #expect(geometry.ridges.allSatisfy { $0.points.count == SpectralHorizonHistory.columnCount })
    }

    @Test func frozenFramesNeverCaptureOrScroll() {
        let history = filled(audio(), captures: 6)
        let invalid: [Double] = [0, -1, .nan, .infinity, -.infinity]
        for dt in invalid {
            var frozen = history
            frozen.advance(dt: dt, audio: audio(peak: 4_000, magnitude: 0.4))
            #expect(frozen == history)
            frozen.advance(dt: dt, audio: VisualizationAudio())
            #expect(frozen == history)
        }
    }

    @Test func reducedMotionShowsOneRealSnapshotAndKeepsIt() {
        var history = SpectralHorizonHistory()
        history.captureSnapshot(audio: VisualizationAudio())
        #expect(history.state == .waiting)
        history.captureSnapshot(audio: audio())
        #expect(history.rows.count == 1)
        #expect(history.state == .signal)
        let snapshot = history
        history.captureSnapshot(audio: audio(peak: 6_000))
        #expect(history == snapshot)
        history.captureSnapshot(audio: VisualizationAudio())
        #expect(history == snapshot)
    }

    @Test func identicalInputsProduceIdenticalLandscapes() {
        func run() -> SpectralHorizonGeometry {
            var history = SpectralHorizonHistory()
            for frame in 0..<90 {
                let frequency = 200 * pow(2, Double(frame % 30) / 6)
                history.advance(dt: 1.0 / 60, audio: audio(peak: frequency, magnitude: 0.8))
            }
            return SpectralHorizonRenderer.geometry(history: history, size: Self.size)
        }
        let first = run()
        #expect(first.state == .signal)
        #expect(first == run())
    }

    @Test func columnsFollowMeasuredFrequenciesOnALogScaleWithFixedGain() throws {
        let columns = try #require(SpectralHorizonHistory.measure(audio(peak: 1_000)))
        #expect(columns.levels.count == SpectralHorizonHistory.columnCount)
        let peak = try #require(columns.levels.indices.max(by: { columns.levels[$0] < columns.levels[$1] }))
        let expected = Int(Double(SpectralHorizonHistory.columnCount) * log(1_000.0 / 30) / log(16_000.0 / 30))
        #expect(abs(peak - expected) <= 1)
        #expect(columns.levels[0] == 0)
        #expect(columns.levels[SpectralHorizonHistory.columnCount - 1] == 0)
        // Quiet audio stays quiet: there is no automatic gain.
        let quiet = try #require(SpectralHorizonHistory.measure(audio(peak: 1_000, magnitude: 0.2)))
        #expect(quiet.levels[peak] > 0)
        #expect(quiet.levels[peak] < columns.levels[peak] * 0.2)
    }

    @Test func productionAnalysisOfAToneLandsInItsColumn() throws {
        let levels = TemporalDesignFixture.tone(frequencies: [440], amplitude: 0.3)
        let columns = try #require(SpectralHorizonHistory.measure(VisualizationAudio(levels)))
        let peak = try #require(columns.levels.indices.max(by: { columns.levels[$0] < columns.levels[$1] }))
        let expected = Int(Double(SpectralHorizonHistory.columnCount) * log(440.0 / 30) / log(16_000.0 / 30))
        #expect(abs(peak - expected) <= 2)
    }

    @Test func formatChangesStartANewHistory() {
        var history = filled(audio(), captures: 8)
        history.advance(dt: 0.01, audio: audio(rate: 48_000))
        #expect(history.rows.count == 1)
        history = filled(audio(), captures: 8)
        history.advance(dt: 0.01, audio: audio(count: 2_048))
        #expect(history.rows.count == 1)
        var wider = audio()
        wider.spectrumBinWidth *= 2
        history = filled(audio(), captures: 8)
        history.advance(dt: 0.01, audio: wider)
        #expect(history.rows.count == 1)
        history.reset()
        #expect(history == SpectralHorizonHistory())
    }

    @Test func nearerRowsAreLowerWiderAndTaller() {
        #expect(SpectralHorizonRenderer.nearness(depth: 0) == 1)
        #expect(SpectralHorizonRenderer.nearness(depth: 1) == 0)
        #expect(SpectralHorizonRenderer.nearness(depth: .nan) == 0)
        let geometry = SpectralHorizonRenderer.geometry(history: filled(audio(), captures: 20), size: Self.size)
        #expect(abs(geometry.horizonY - Self.size.height * 0.38) < 0.001)
        let ridges = geometry.ridges
        #expect(ridges.count == 21)
        for (far, near) in zip(ridges, ridges.dropFirst()) {
            #expect(near.baseY > far.baseY)
            #expect(near.maxX - near.minX > far.maxX - far.minX)
            #expect(near.nearness > far.nearness)
            let farLift = far.baseY - (far.points.map(\.y).min() ?? far.baseY)
            let nearLift = near.baseY - (near.points.map(\.y).min() ?? near.baseY)
            #expect(nearLift > farLift)
        }
        #expect(ridges.allSatisfy { $0.baseY >= geometry.horizonY })
    }

    @Test func malformedInputStaysFiniteInsideTheCanvas() {
        var cases: [VisualizationAudio] = []
        var mixed = audio()
        let corrupt: [Double] = [.nan, .infinity, -.infinity, -4, 7, 0.5]
        mixed.spectrum = corrupt + [Double](repeating: 2, count: 2_000)
        cases.append(mixed)
        var huge = audio()
        huge.spectrum = [Double](repeating: 1, count: 300_000)
        cases.append(huge)
        let widths: [Double] = [1e-12, 1e-300, 1e12, .greatestFiniteMagnitude]
        for width in widths {
            var malformed = audio()
            malformed.spectrumBinWidth = width
            cases.append(malformed)
        }
        let rates: [Double] = [.nan, .infinity, 0, 41, 1e300]
        for rate in rates {
            var malformed = audio()
            malformed.sampleRate = rate
            cases.append(malformed)
        }
        var allNaN = audio()
        allNaN.spectrum = [Double](repeating: .nan, count: 64)
        cases.append(allNaN)
        var single = audio()
        single.spectrum = [1]
        cases.append(single)
        for size in [Self.size, CGSize(width: 1, height: 1), CGSize(width: 4_000, height: 30)] {
            for input in cases {
                var history = SpectralHorizonHistory()
                for _ in 0..<50 { history.advance(dt: 1.0 / 30, audio: input) }
                #expect(history.rows.count <= SpectralHorizonHistory.capacity)
                let geometry = SpectralHorizonRenderer.geometry(history: history, size: size)
                #expect(geometry.ridges.count <= SpectralHorizonHistory.capacity)
                var inside = true
                for ridge in geometry.ridges {
                    if ridge.points.count > SpectralHorizonHistory.columnCount { inside = false }
                    let corners = [CGPoint(x: ridge.minX, y: ridge.baseY), CGPoint(x: ridge.maxX, y: ridge.baseY)]
                    for point in ridge.points + corners {
                        let finite = point.x.isFinite && point.y.isFinite
                        let bounded = point.x >= 0 && point.x <= size.width && point.y >= 0 && point.y <= size.height
                        if !finite || !bounded { inside = false }
                    }
                }
                #expect(inside)
            }
        }
        let history = filled(audio(), captures: 3)
        for bad in [CGSize.zero, CGSize(width: -10, height: 20), CGSize(width: CGFloat.nan, height: 10),
                    CGSize(width: CGFloat.infinity, height: 10)] {
            #expect(SpectralHorizonRenderer.geometry(history: history, size: bad).ridges.isEmpty)
        }
    }

    @Test @MainActor func engineFreezesWhenPausedAndResetsOnTrackChange() {
        let engine = SpectralHorizonEngine()
        var spectrum = [Float](repeating: 0, count: 1_024)
        spectrum[46] = 1
        let levels = AudioLevels(spectrum: spectrum, available: true, sampleRate: 44_100, spectrumBinWidth: 44_100.0 / 2_048)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var history = SpectralHorizonHistory()
        for frame in 0..<30 {
            history = engine.frame(at: start.addingTimeInterval(Double(frame) / 30), trackID: "a", animated: true,
                                   levels: levels, playing: true, captureStaticSignal: false)
        }
        #expect(history.state == .signal)
        #expect(history.rows.count > 5)
        // Paused, inactive or reduced-motion frames neither capture nor scroll.
        for frame in 30..<120 {
            let frozen = engine.frame(at: start.addingTimeInterval(Double(frame) / 30), trackID: "a", animated: false,
                                      levels: levels, playing: false, captureStaticSignal: false)
            #expect(frozen == history)
        }
        let changed = engine.frame(at: start.addingTimeInterval(5), trackID: "b", animated: false,
                                   levels: levels, playing: true, captureStaticSignal: true)
        #expect(changed.rows.count == 1)
        #expect(changed.state == .signal)
        let unavailable = engine.frame(at: start.addingTimeInterval(6), trackID: "c", animated: false,
                                       levels: AudioLevels(), playing: true, captureStaticSignal: true)
        #expect(unavailable.state == .waiting)
    }

    /// The production renderer must not animate absent audio as time passes;
    /// only measured spectra change the landscape.
    @Test @MainActor func renderedLandscapeDependsOnMeasuredSpectraNotTime() throws {
        let size = CGSize(width: 320, height: 180)
        @MainActor func pixels(_ history: SpectralHorizonHistory, seed: UInt64, glow: Bool) throws -> [UInt8] {
            let view = Canvas(opaque: true, rendersAsynchronously: false) { context, canvasSize in
                SpectralHorizonRenderer.draw(in: &context, size: canvasSize, history: history, glow: glow, seed: seed)
            }
            return try TemporalDesignExport.rgba(TemporalDesignExport.image(view, size: size))
        }
        let waiting = try pixels(SpectralHorizonHistory(), seed: 7, glow: true)
        var stillWaiting = SpectralHorizonHistory()
        for _ in 0..<240 { stillWaiting.advance(dt: 1.0 / 60, audio: VisualizationAudio()) }
        let waitingLater = try pixels(stillWaiting, seed: 7, glow: true)
        #expect(waitingLater == waiting)

        var landscape = filled(audio(peak: 700, magnitude: 0.9), captures: 12)
        let measured = try pixels(landscape, seed: 7, glow: true)
        #expect(measured != waiting)
        let repeated = try pixels(landscape, seed: 7, glow: true)
        #expect(repeated == measured)
        landscape.advance(dt: 0, audio: audio(peak: 5_000))
        let frozen = try pixels(landscape, seed: 7, glow: true)
        #expect(frozen == measured)

        let silent = try pixels(filled(silence, captures: 12), seed: 7, glow: true)
        #expect(TemporalDesignExport.difference(silent, measured).changedPixelFraction > 0.001)
        let otherSeed = try pixels(landscape, seed: 99_999_999, glow: true)
        #expect(otherSeed != measured)

        // The glow setting is respected: the halo appears only when it is on.
        let unlit = try pixels(landscape, seed: 7, glow: false)
        #expect(unlit != measured)
        let waitingUnlit = try pixels(SpectralHorizonHistory(), seed: 7, glow: false)
        let waitingUnlitAgain = try pixels(SpectralHorizonHistory(), seed: 7, glow: false)
        #expect(waitingUnlitAgain == waitingUnlit)
    }
}
