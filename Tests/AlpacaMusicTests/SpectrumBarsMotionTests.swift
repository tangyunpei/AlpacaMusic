import Foundation
import Testing
@testable import AlpacaMusic

@Suite struct SpectrumBarsMotionTests {
    private func audio(_ magnitude: Double, rate: Double = 44_100,
                       count: Int = 1_024) -> VisualizationAudio {
        var result = VisualizationAudio()
        result.available = true
        result.sampleRate = rate
        result.spectrumBinWidth = rate / 2_048
        result.spectrum = Array(repeating: magnitude, count: count)
        return result
    }

    @Test func initialSnapshotUsesActualFixedGainHeights() {
        var clock = SpectrumBarsMotionClock()
        let frame = clock.step(dt: 0, audio: audio(0.4))
        #expect(frame.levels.count == 72 && frame.peaks.count == 72)
        #expect(frame.state == .signal)
        #expect(frame.levels.allSatisfy { abs($0 - pow(0.4, 1.55)) < 0.000_001 })
        #expect(frame.levels == frame.peaks)
    }

    @Test func attackFollowsRapidOnsetsAndReleaseRetainsMovement() {
        var clock = SpectrumBarsMotionClock()
        _ = clock.step(dt: 0, audio: audio(0))
        let rise = clock.step(dt: 0.022, audio: audio(1))
        #expect(abs(rise.levels[0] - (1 - exp(-1))) < 0.000_001)
        let fall = clock.step(dt: 0.022, audio: audio(0))
        #expect(abs(fall.levels[0] - rise.levels[0] * exp(-0.1)) < 0.000_001)
        #expect(fall.levels[0] > rise.levels[0] * 0.90)
        #expect(fall.peaks[0] == rise.peaks[0])
    }

    @Test func peaksHoldThenFallWithAnAcceleratingTrajectory() {
        var clock = SpectrumBarsMotionClock()
        let first = clock.step(dt: 0, audio: audio(1))
        let held = clock.step(dt: 0.10, audio: audio(0))
        #expect(held.peaks == first.peaks)
        let slightFall = clock.step(dt: 0.10, audio: audio(0))
        #expect(abs(slightFall.peaks[0] - (1 - 1.4 * 0.06 * 0.06)) < 0.000_001)
        let nextFall = clock.step(dt: 0.10, audio: audio(0))
        #expect(abs(nextFall.peaks[0] - (1 - 1.4 * 0.16 * 0.16)) < 0.000_001)
        #expect(slightFall.peaks[0] - nextFall.peaks[0] > held.peaks[0] - slightFall.peaks[0])
    }

    @Test func strongerOnsetsRenewPeakHoldWithoutDroppingBelowLiveBars() {
        var clock = SpectrumBarsMotionClock()
        _ = clock.step(dt: 0, audio: audio(0.4))
        _ = clock.step(dt: 0.4, audio: audio(0))
        let onset = clock.step(dt: 0.1, audio: audio(0.9))
        let held = clock.step(dt: 0.1, audio: audio(0))
        #expect(onset.peaks == onset.levels)
        #expect(held.peaks == onset.peaks)
        for index in held.levels.indices { #expect(held.peaks[index] >= held.levels[index]) }
    }

    @Test func silenceSettlesExactlyAndNeverCreatesClockEnergy() {
        var clock = SpectrumBarsMotionClock()
        _ = clock.step(dt: 0, audio: audio(1))
        let fading = clock.step(dt: 0.15, audio: audio(0))
        #expect(fading.state == .signal)
        #expect(fading.levels[0] > 0 && fading.peaks[0] > 0)
        let silent = clock.step(dt: 3, audio: audio(0))
        #expect(silent.state == .silent)
        #expect(silent.levels.allSatisfy { $0 == 0 })
        #expect(silent.peaks.allSatisfy { $0 == 0 })
        var arbitrary = audio(0)
        arbitrary.beat = 1; arbitrary.energy = 1
        arbitrary.bass = 1; arbitrary.mid = 1; arbitrary.treble = 1
        #expect(clock.step(dt: 0.5, audio: arbitrary) == silent)
    }

    @Test func quietAndLoudInputKeepTheirAbsoluteDifference() {
        var quiet = SpectrumBarsMotionClock(), loud = SpectrumBarsMotionClock()
        let quietFrame = quiet.step(dt: 0, audio: audio(0.2))
        let loudFrame = loud.step(dt: 0, audio: audio(0.8))
        #expect(loudFrame.levels[0] > quietFrame.levels[0] * 8)
        #expect(loudFrame.peaks[0] > quietFrame.peaks[0] * 8)
    }

    @Test func elapsedTimeIsConsistentAcrossRefreshRates() {
        func frame(rate: Int) -> SpectrumBarsPresentation {
            var clock = SpectrumBarsMotionClock()
            _ = clock.step(dt: 0, audio: audio(0))
            for _ in 0..<(rate / 5) { _ = clock.step(dt: 1 / Double(rate), audio: audio(1)) }
            var result = SpectrumBarsPresentation.empty
            for _ in 0..<(rate * 3 / 5) { result = clock.step(dt: 1 / Double(rate), audio: audio(0)) }
            return result
        }
        let frames = [30, 60, 120].map(frame)
        for candidate in frames.dropFirst() {
            for index in candidate.levels.indices {
                #expect(abs(candidate.levels[index] - frames[0].levels[index]) < 0.000_001)
                #expect(abs(candidate.peaks[index] - frames[0].peaks[index]) < 0.000_001)
            }
        }
    }

    @Test func zeroTimePreservesTheEntirePoseAndPeakTimer() {
        var frozen = SpectrumBarsMotionClock(), reference = SpectrumBarsMotionClock()
        _ = frozen.step(dt: 0, audio: audio(1))
        _ = reference.step(dt: 0, audio: audio(1))
        let before = frozen.step(dt: 0.10, audio: audio(0))
        _ = reference.step(dt: 0.10, audio: audio(0))
        #expect(frozen.step(dt: 0, audio: audio(0.2)) == before)
        #expect(frozen.step(dt: 0, audio: audio(0.9)) == before)
        #expect(frozen.step(dt: 0.10, audio: audio(0)) == reference.step(dt: 0.10, audio: audio(0)))
    }

    @Test func resetAndChangedFormatStartFromARealSnapshot() {
        var clock = SpectrumBarsMotionClock()
        _ = clock.step(dt: 0, audio: audio(1))
        let reset = clock.step(dt: 0, audio: audio(0.2), resetInput: true)
        #expect(reset.levels == reset.peaks)
        #expect(abs(reset.levels[0] - pow(0.2, 1.55)) < 0.000_001)
        let changedRate = clock.step(dt: 0, audio: audio(0.3, rate: 48_000))
        #expect(abs(changedRate.levels[0] - pow(0.3, 1.55)) < 0.000_001)
        #expect(changedRate.levels == changedRate.peaks)
        var changedSpacing = audio(0.1, rate: 48_000)
        changedSpacing.spectrumBinWidth *= 2
        let spacingFrame = clock.step(dt: 0, audio: changedSpacing)
        #expect(abs(spacingFrame.levels[0] - pow(0.1, 1.55)) < 0.000_001)
        #expect(spacingFrame.levels == spacingFrame.peaks)
        let countFrame = clock.step(dt: 0, audio: audio(0.4, rate: 48_000, count: 2_048))
        #expect(abs(countFrame.levels[0] - pow(0.4, 1.55)) < 0.000_001)
        #expect(countFrame.levels == countFrame.peaks)
    }

    @Test func unavailableAndInvalidMetadataClearResidualPeaks() {
        var clock = SpectrumBarsMotionClock()
        _ = clock.step(dt: 0, audio: audio(1))
        #expect(clock.step(dt: 0, audio: .init()) == .empty)
        for badValue in [0.0, -1, .nan, .infinity] {
            _ = clock.step(dt: 0, audio: audio(1))
            var malformed = audio(0.5)
            malformed.spectrumBinWidth = badValue
            #expect(clock.step(dt: 0, audio: malformed) == .empty)
        }
        for badValue in [40.0, 0, -1, .nan, .infinity] {
            _ = clock.step(dt: 0, audio: audio(1))
            var malformed = audio(0.5)
            malformed.sampleRate = badValue
            #expect(clock.step(dt: 0, audio: malformed) == .empty)
        }
        let reconnect = clock.step(dt: 0, audio: audio(0.2))
        #expect(abs(reconnect.levels[0] - pow(0.2, 1.55)) < 0.000_001)
    }

    @Test func malformedBinsAreSanitizedAndAllAbsentBinsWait() {
        var clock = SpectrumBarsMotionClock()
        var mixed = audio(0)
        mixed.spectrum[8] = .nan; mixed.spectrum[16] = .infinity
        mixed.spectrum[32] = -1; mixed.spectrum[64] = 2
        let frame = clock.step(dt: 0, audio: mixed)
        #expect(frame.levels.count == 72)
        #expect(frame.levels.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        #expect(frame.peaks.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        var absent = audio(.nan)
        #expect(clock.step(dt: 0.1, audio: absent) == .empty)
        absent.spectrum = []
        #expect(clock.step(dt: 0.1, audio: absent) == .empty)
    }

    @Test func invalidElapsedTimeCannotAdvanceOrPoisonAnEnvelope() {
        var clock = SpectrumBarsMotionClock()
        let initial = clock.step(dt: 0, audio: audio(0.6))
        for elapsed in [-1.0, .nan, .infinity, -.infinity] {
            #expect(clock.step(dt: elapsed, audio: audio(0)) == initial)
        }
        let settled = clock.step(dt: Double.greatestFiniteMagnitude, audio: audio(0))
        #expect(settled.state == .silent)
        #expect(settled.levels.allSatisfy { $0 == 0 })
        #expect(settled.peaks.allSatisfy { $0 == 0 })
    }

    @Test func explicitResetDropsOldTimersAndAllowsInitialSnapshot() {
        var clock = SpectrumBarsMotionClock()
        _ = clock.step(dt: 0, audio: audio(1))
        _ = clock.step(dt: 0.3, audio: audio(0))
        clock.reset()
        let result = clock.step(dt: 0, audio: audio(0.25))
        #expect(result.levels == result.peaks)
        #expect(abs(result.levels[0] - pow(0.25, 1.55)) < 0.000_001)
    }

    @Test func independentColumnsFollowOnlyTheirMeasuredFrequencyEnergy() {
        var clock = SpectrumBarsMotionClock()
        _ = clock.step(dt: 0, audio: audio(0))
        var narrow = audio(0)
        narrow.spectrum[46] = 0.85
        let first = clock.step(dt: 0.1, audio: narrow)
        let strongest = first.levels.indices.max { first.levels[$0] < first.levels[$1] }!
        #expect(first.levels[strongest] > 0.7)
        #expect(first.levels.prefix(12).allSatisfy { $0 == 0 })
        #expect(first.levels.suffix(12).allSatisfy { $0 == 0 })
        for magnitude in [0.0, 0.9, 0.1, 1, 0, 0.4, 0] {
            narrow.spectrum[46] = magnitude
            let frame = clock.step(dt: 1 / 30, audio: narrow)
            for index in frame.levels.indices {
                #expect(frame.levels[index].isFinite && frame.levels[index] >= 0 && frame.levels[index] <= 1)
                #expect(frame.peaks[index].isFinite && frame.peaks[index] >= frame.levels[index] && frame.peaks[index] <= 1)
            }
            #expect(frame.levels.prefix(12).allSatisfy { $0 == 0 })
            #expect(frame.levels.suffix(12).allSatisfy { $0 == 0 })
        }
    }
}
