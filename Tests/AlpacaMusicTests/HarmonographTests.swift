import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import AlpacaMusic

@Suite struct HarmonographTests {
    private func audio(bass: [Double], mid: [Double], full: [Double] = []) -> VisualizationAudio {
        var result = VisualizationAudio()
        result.available = true
        result.bassWaveform = bass
        result.midWaveform = mid
        result.waveform = full
        return result
    }

    @Test func unavailableOrMissingPCMWaitsWithoutInventingACurve() {
        let unavailable = HarmonographRenderer.trace(bass: [0.5, -0.5], mid: [0.2, 0.4], full: [0.3], available: false)
        #expect(unavailable == .waiting)
        #expect(HarmonographRenderer.trace(bass: [], mid: [], full: [], available: true) == .waiting)
        #expect(HarmonographRenderer.trace(bass: [.nan, .infinity], mid: [.nan, -.infinity], full: [], available: true) == .waiting)
        var history = HarmonographHistory()
        let frame = history.step(dt: 0.05, audio: VisualizationAudio())
        #expect(frame == .waiting)
    }

    @Test func silenceIsASteadyCenteredDot() {
        let silent = HarmonographRenderer.trace(bass: Array(repeating: 0, count: 1_024),
                                                mid: Array(repeating: 0, count: 1_024), full: [], available: true)
        #expect(silent.state == .silent)
        #expect(silent.points == [.zero])
        let size = CGSize(width: 320, height: 180)
        let canvas = HarmonographRenderer.points(for: silent, size: size)
        #expect(canvas.count == 1)
        #expect(abs(canvas[0].x - size.width / 2) < 0.000_001 && abs(canvas[0].y - size.height / 2) < 0.000_001)
    }

    @Test func curveExtentMeasuresTheFigureForTheSilenceDotHandoff() {
        #expect(HarmonographRenderer.extent(of: []) == 0)
        #expect(HarmonographRenderer.extent(of: [CGPoint(x: 2, y: 2)]) == 0)
        #expect(abs(HarmonographRenderer.extent(of: [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 1), CGPoint(x: 1, y: 4)]) - 5) < 0.000_001)
        #expect(HarmonographRenderer.extent(of: [CGPoint(x: 0, y: 0), CGPoint(x: CGFloat.infinity, y: 1)]) == 0)
    }

    @Test func bandsMapToAFixedGainPhasePortrait() {
        let quiet = HarmonographRenderer.trace(bass: [0, 0.1, -0.1], mid: [0, -0.1, 0.05], full: [0.9, 0.9, 0.9], available: true)
        let loud = HarmonographRenderer.trace(bass: [0, 0.8, -0.8], mid: [0, -0.8, 0.4], full: [], available: true)
        #expect(quiet.state == .signal && loud.state == .signal)
        // The full waveform is ignored while both band traces are present.
        #expect(abs(quiet.points[1].x - 0.1) < 0.000_001 && abs(quiet.points[1].y + 0.1) < 0.000_001)
        #expect(abs(loud.points[1].x / quiet.points[1].x - 8) < 0.000_001)
        #expect(abs(loud.points[2].y / quiet.points[2].y - 8) < 0.000_001)
        let size = CGSize(width: 400, height: 300)
        let plot = HarmonographRenderer.plotRect(size: size)
        let point = HarmonographRenderer.points(for: loud, size: size)[1]
        #expect(point.x > plot.midX && point.y > plot.midY)
    }

    @Test func fullWaveformFallsBackToAShortDelayEmbedding() {
        let full = (0..<48).map { Double($0) / 48 }
        let curve = HarmonographRenderer.trace(bass: [], mid: [0.5, 0.5], full: full, available: true)
        #expect(curve.state == .signal)
        #expect(curve.points.count == 46)
        #expect(curve.points[5] == CGPoint(x: full[5], y: full[7]))
        #expect(curve.points[45] == CGPoint(x: full[45], y: full[47]))
    }

    @Test func malformedAndHugeInputsStayFiniteBoundedAndInsideThePlot() {
        let malformed = HarmonographRenderer.trace(bass: [.nan, .infinity, -4, 4, 0.5], mid: [.infinity, .nan, 3, -3, -0.5],
                                                   full: [], available: true)
        #expect(malformed.points.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1 && abs($0.y) <= 1 })
        let huge = (0..<200_000).map { sin(Double($0) * 0.013) }
        let hugeCurve = HarmonographRenderer.trace(bass: huge, mid: Array(huge.reversed()), full: [], available: true)
        #expect(hugeCurve.points.count <= HarmonographRenderer.maximumPoints)
        #expect(HarmonographRenderer.trace(bass: [], mid: [], full: huge, available: true).points.count <= HarmonographRenderer.maximumPoints)
        for size in [CGSize(width: 44, height: 72), .init(width: 320, height: 180), .init(width: 1_280, height: 720)] {
            let plot = HarmonographRenderer.plotRect(size: size)
            for curve in [malformed, hugeCurve] {
                let points = HarmonographRenderer.points(for: curve, size: size)
                #expect(points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
                #expect(points.allSatisfy { $0.x >= plot.minX - 0.000_1 && $0.x <= plot.maxX + 0.000_1 })
                #expect(points.allSatisfy { $0.y >= plot.minY - 0.000_1 && $0.y <= plot.maxY + 0.000_1 })
                #expect(points.allSatisfy { $0.x > 0 && $0.x < size.width && $0.y > 0 && $0.y < size.height })
                let bounds = HarmonographRenderer.path(points).boundingRect
                #expect(bounds.minX >= plot.minX - 0.000_1 && bounds.maxX <= plot.maxX + 0.000_1)
                #expect(bounds.minY >= plot.minY - 0.000_1 && bounds.maxY <= plot.maxY + 0.000_1)
            }
        }
        #expect(HarmonographRenderer.plotRect(size: .zero) == .zero)
        #expect(HarmonographRenderer.curve(bass: [0.5, -0.5], mid: [0.5, 0.5], full: [], size: .zero).isEmpty)
        #expect(HarmonographRenderer.curve(bass: [0.5, -0.5], mid: [0.5, 0.5], full: [],
                                           size: .init(width: CGFloat.nan, height: 100)).isEmpty)
    }

    @Test func frozenFramesNeitherAppendNorAgeTrails() {
        var history = HarmonographHistory()
        let signal = audio(bass: [0, 0.5, -0.5], mid: [0.2, -0.2, 0.4])
        let first = history.step(dt: 0, audio: signal)
        #expect(first.current.state == .signal && first.trails.isEmpty)
        let second = history.step(dt: 0.05, audio: signal)
        #expect(second.trails.count == 1 && second.trails[0].age == 0.05)
        for dt in [0, Double.nan, -1] {
            let frozen = history.step(dt: dt, audio: signal)
            #expect(frozen == second)
        }
        // A frozen frame without audio hides trails but keeps the history.
        let frozenWaiting = history.step(dt: 0, audio: VisualizationAudio())
        #expect(frozenWaiting == .waiting)
        #expect(history.trails.count == 1)
        // Animating without audio clears them instead of fading on time alone.
        _ = history.step(dt: 0.05, audio: VisualizationAudio())
        #expect(history.trails.isEmpty)
    }

    @Test func trailsFadeByAnimationTimeAndStayBounded() {
        var history = HarmonographHistory()
        let signal = audio(bass: [0, 0.5, -0.5], mid: [0.2, -0.2, 0.4])
        _ = history.step(dt: 0, audio: signal)
        var frame = HarmonographPresentation.waiting
        for _ in 0..<5 { frame = history.step(dt: 0.05, audio: signal) }
        #expect(frame.trails.count == 3)
        #expect(frame.trails.allSatisfy { $0.age < HarmonographHistory.lifetime && $0.fade > 0 })
        #expect(zip(frame.trails, frame.trails.dropFirst()).allSatisfy { $0.0.age > $0.1.age })
        for _ in 0..<50 { frame = history.step(dt: 0.001, audio: signal) }
        #expect(frame.trails.count == HarmonographHistory.capacity)
        // Real silence lets the measured trails expire into a steady dot.
        let silence = audio(bass: [0, 0, 0], mid: [0, 0, 0])
        for _ in 0..<10 { frame = history.step(dt: 0.05, audio: silence) }
        #expect(frame.current.state == .silent && frame.trails.isEmpty)
        let steady = history.step(dt: 0.05, audio: silence)
        #expect(steady == frame)
        history.reset()
        #expect(history.presentation == .waiting && history.trails.isEmpty)
    }

    @Test func identicalInputsProduceIdenticalHistories() {
        var first = HarmonographHistory(), second = HarmonographHistory()
        // Explicit types keep the nested closures cheap for the type checker.
        var frames: [VisualizationAudio] = []
        for index in 0..<24 {
            let bass: [Double] = (0..<256).map { (sample: Int) -> Double in sin(Double(sample + index) * 0.07) * 0.6 }
            let mid: [Double] = (0..<256).map { (sample: Int) -> Double in cos(Double(sample * 2 + index) * 0.05) * 0.4 }
            frames.append(audio(bass: bass, mid: mid))
        }
        for (index, input) in frames.enumerated() {
            let dt = index == 0 ? 0 : 1.0 / 60
            let left = first.step(dt: dt, audio: input)
            let right = second.step(dt: dt, audio: input)
            #expect(left == right)
        }
    }
}

@Suite @MainActor struct HarmonographStageTests {
    private let start = Date(timeIntervalSince1970: 0)
    private var levels: AudioLevels {
        AudioLevels(available: true, waveformDuration: 1_024.0 / 44_100,
                    bassWaveform: (0..<1_024).map { Float(0.6 * sin(Double($0) * 2 * Double.pi * 3 / 1_024)) },
                    midWaveform: (0..<1_024).map { Float(0.5 * sin(Double($0) * 2 * Double.pi * 4 / 1_024 + 0.4)) },
                    sampleRate: 44_100)
    }

    @Test func stageExposesTheSharedContract() {
        let stage = HarmonographStage(isPlaying: false, isActive: true, reduceMotion: false, lowPower: false, glow: true,
                                      seed: 7, trackID: nil, signal: { AudioLevels() })
        #expect(stage.seed == 7 && stage.trackID == nil && !stage.isPlaying)
    }

    @Test func unavailableAudioIsStaticAsTimeAdvances() {
        let model = HarmonographStageModel()
        let first = model.presentation(at: start, animated: true, levels: AudioLevels(), playing: true, captureStaticSignal: false)
        #expect(first == .waiting)
        for frame in 1...600 {
            let later = model.presentation(at: start.addingTimeInterval(Double(frame) / 60), animated: true,
                                           levels: AudioLevels(), playing: true, captureStaticSignal: false)
            #expect(later == first)
        }
    }

    @Test func pausedFramesFreezeAndResetClearsHistory() {
        let model = HarmonographStageModel()
        var moving = HarmonographPresentation.waiting
        for frame in 0..<30 {
            moving = model.presentation(at: start.addingTimeInterval(Double(frame) / 60), animated: true,
                                        levels: levels, playing: true, captureStaticSignal: false)
        }
        #expect(moving.current.state == .signal)
        #expect(!moving.trails.isEmpty && moving.trails.count <= HarmonographHistory.capacity)
        for offset in [10.0, 100.0] {
            let frozen = model.presentation(at: start.addingTimeInterval(offset), animated: false,
                                            levels: AudioLevels(), playing: false, captureStaticSignal: false)
            #expect(frozen == moving)
        }
        // The first resumed frame has no elapsed animation time.
        let resumed = model.presentation(at: start.addingTimeInterval(200), animated: true,
                                         levels: levels, playing: true, captureStaticSignal: false)
        #expect(resumed.trails == moving.trails)
        model.reset()
        let cleared = model.presentation(at: start.addingTimeInterval(201), animated: false,
                                         levels: AudioLevels(), playing: false, captureStaticSignal: false)
        #expect(cleared == .waiting)
    }

    @Test func reducedMotionShowsOneRealStaticSnapshot() {
        let model = HarmonographStageModel()
        let snapshot = model.presentation(at: start, animated: false, levels: levels, playing: true, captureStaticSignal: true)
        #expect(snapshot.current.state == .signal && snapshot.trails.isEmpty)
        // Later, different real audio must not replace the one captured snapshot.
        let laterLevels = AudioLevels(available: true, waveformDuration: 1_024.0 / 44_100,
                                      bassWaveform: (0..<1_024).map { Float(0.2 * sin(Double($0) * 0.05)) },
                                      midWaveform: (0..<1_024).map { Float(-0.3 * cos(Double($0) * 0.09)) },
                                      sampleRate: 44_100)
        let later = model.presentation(at: start.addingTimeInterval(30), animated: false, levels: laterLevels,
                                       playing: true, captureStaticSignal: true)
        #expect(later == snapshot)
        let paused = model.presentation(at: start.addingTimeInterval(60), animated: false, levels: laterLevels,
                                        playing: false, captureStaticSignal: false)
        #expect(paused == snapshot)
    }

    /// Only measured audio changes the rendered portrait; time alone does not.
    @Test func renderedPortraitDependsOnAudioInsteadOfTime() throws {
        let size = CGSize(width: 240, height: 180)
        @MainActor func pixels(_ presentation: HarmonographPresentation, glow: Bool) throws -> [UInt8] {
            let view = Canvas { context, canvasSize in
                HarmonographRenderer.draw(in: &context, size: canvasSize, presentation: presentation, glow: glow)
            }
            return try TemporalDesignExport.rgba(TemporalDesignExport.image(view, size: size))
        }
        let idle = HarmonographStageModel()
        let waiting = idle.presentation(at: start, animated: true, levels: AudioLevels(), playing: true, captureStaticSignal: false)
        var waitingLater = waiting
        for frame in 1...240 {
            waitingLater = idle.presentation(at: start.addingTimeInterval(Double(frame) / 60), animated: true,
                                             levels: AudioLevels(), playing: true, captureStaticSignal: false)
        }
        let waitingPixels = try pixels(waiting, glow: true)
        let waitingLaterPixels = try pixels(waitingLater, glow: true)
        #expect(waitingPixels == waitingLaterPixels)

        let live = HarmonographStageModel()
        var playing = HarmonographPresentation.waiting
        for frame in 0..<30 {
            playing = live.presentation(at: start.addingTimeInterval(Double(frame) / 60), animated: true,
                                        levels: levels, playing: true, captureStaticSignal: false)
        }
        let playingPixels = try pixels(playing, glow: true)
        #expect(playingPixels != waitingPixels)
        let frozen = live.presentation(at: start.addingTimeInterval(60), animated: false, levels: AudioLevels(),
                                       playing: false, captureStaticSignal: false)
        let frozenPixels = try pixels(frozen, glow: true)
        #expect(frozenPixels == playingPixels)
        let plainPixels = try pixels(playing, glow: false)
        #expect(plainPixels != playingPixels)
    }
}
