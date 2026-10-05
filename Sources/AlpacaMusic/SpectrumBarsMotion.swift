import CoreGraphics
import Foundation

/// Measured spectrum heights and their briefly retained peaks. Both arrays use
/// the renderer's fixed response curve, so a quiet source stays visibly quiet.
struct SpectrumBarsPresentation: Equatable, Sendable {
    var levels: [Double]
    var peaks: [Double]
    var state: WaveformGeometry.State

    static let barCount = 72
    static let empty = SpectrumBarsPresentation(levels: [], peaks: [], state: .waiting)
}

/// A per-scene envelope for real FFT data. It adds attack, release, and peak
/// retention, but does not generate energy from the clock, beat, or playback.
struct SpectrumBarsMotionClock: Sendable {
    private struct Format: Equatable, Sendable {
        var sampleRate: Double
        var binWidth: Double
        var spectrumCount: Int
    }

    private var format: Format?
    private var frame = SpectrumBarsPresentation.empty
    private var holdRemaining: [Double] = []
    private var fallVelocity: [Double] = []

    private static let attack = 0.022
    private static let release = 0.220
    private static let hold = 0.140
    private static let gravity = 2.8
    private static let silenceFloor = 0.0001

    mutating func reset() {
        format = nil
        frame = .empty
        holdRemaining.removeAll(keepingCapacity: true)
        fallVelocity.removeAll(keepingCapacity: true)
    }

    mutating func step(dt: Double, audio: VisualizationAudio,
                       resetInput: Bool = false) -> SpectrumBarsPresentation {
        let measured = SpectrumBarsRenderer.geometry(
            audio: audio, size: CGSize(width: 720, height: 400),
            barCount: SpectrumBarsPresentation.barCount)
        guard measured.state != .waiting else {
            reset()
            return .empty
        }
        let incomingFormat = Format(sampleRate: audio.sampleRate,
                                    binWidth: audio.spectrumBinWidth,
                                    spectrumCount: audio.spectrum.count)
        let targets = measured.bars.map { bar in
            let value = bar.magnitude.isFinite ? min(1, max(0, bar.magnitude)) : 0
            return pow(value, 1.55)
        }
        if resetInput || format != incomingFormat || frame.levels.count != targets.count {
            format = incomingFormat
            frame = .init(levels: targets, peaks: targets, state: measured.state)
            holdRemaining = targets.map { $0 > 0 ? Self.hold : 0 }
            fallVelocity = Array(repeating: 0, count: targets.count)
            return frame
        }

        // A paused/resumed scene passes zero elapsed time. Retain its complete
        // pose, including peak timers; a reset or changed format above still
        // accepts a fresh measured snapshot.
        let elapsed = dt.isFinite ? min(4, max(0, dt)) : 0
        guard elapsed > 0 else { return frame }
        for index in targets.indices {
            let target = targets[index]
            let previous = frame.levels[index]
            let tau = target > previous ? Self.attack : Self.release
            var level = target + (previous - target) * exp(-elapsed / tau)
            if target == 0 && level < Self.silenceFloor { level = 0 }
            frame.levels[index] = level

            if level >= frame.peaks[index] {
                frame.peaks[index] = level
                holdRemaining[index] = level > 0 ? Self.hold : 0
                fallVelocity[index] = 0
                continue
            }

            // Split a frame at the end of the hold. Integrating the remaining
            // fall analytically keeps the same shape at 30, 60, and 120 Hz.
            let held = min(elapsed, holdRemaining[index])
            holdRemaining[index] = max(0, holdRemaining[index] - elapsed)
            let falling = elapsed - held
            if falling > 0 {
                let distance = fallVelocity[index] * falling
                    + 0.5 * Self.gravity * falling * falling
                frame.peaks[index] -= distance
                fallVelocity[index] += Self.gravity * falling
            }
            if frame.peaks[index] <= level {
                frame.peaks[index] = level
                fallVelocity[index] = 0
            }
        }
        frame.state = frame.levels.contains(where: { $0 > 0 })
            || frame.peaks.contains(where: { $0 > 0 }) ? .signal : .silent
        return frame
    }
}
