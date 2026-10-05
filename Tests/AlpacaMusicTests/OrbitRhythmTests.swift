import Foundation
import Testing
@testable import AlpacaMusic

@Suite struct OrbitRhythmTests {
    private func signal(_ amplitude: Float, band: Int = 0, count: Int = 1_024,
                        rate: Double = 44_100) -> AudioLevels {
        var result = AudioLevels(available: true, sampleRate: rate)
        let samples = (0..<count).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
        result.bassWaveform = Array(repeating: 0, count: count)
        result.midWaveform = Array(repeating: 0, count: count)
        result.trebleWaveform = Array(repeating: 0, count: count)
        switch band {
        case 0: result.bassWaveform = samples
        case 1: result.midWaveform = samples
        default: result.trebleWaveform = samples
        }
        return result
    }

    @Test func usesIndependentSignedPCMAndIgnoresPlayerScalars() {
        for activeBand in 0..<3 {
            var clock = OrbitRhythmClock()
            _ = clock.step(dt: 0, levels: signal(0))
            var frame = OrbitRhythmFrame.zero
            for _ in 0..<5 { frame = clock.step(dt: 1 / 60, levels: signal(0.4, band: activeBand)) }
            #expect(frame.energy[activeBand] > 0.5)
            #expect(frame.pulse[activeBand] > 0.35)
            for otherBand in 0..<3 where otherBand != activeBand {
                #expect(frame.energy[otherBand] == 0 && frame.pulse[otherBand] == 0)
            }
        }
        var clock = OrbitRhythmClock()
        let scalars = AudioLevels(energy: 1, beat: 1, available: true, amplitude: 1,
                                 bass: 1, mid: 1, treble: 1)
        for _ in 0..<180 {
            let frame = clock.step(dt: 1 / 60, levels: scalars)
            #expect(frame.energy == .zero && frame.pulse == .zero)
        }
    }

    @Test func firstBlockAndFormatChangesSeedWithoutInventingAnOnset() {
        var clock = OrbitRhythmClock()
        let initial = clock.step(dt: 1 / 60, levels: signal(0.4))
        #expect(initial.energy.x > 0.9 && initial.pulse == .zero)
        _ = clock.step(dt: 1 / 60, levels: signal(0))
        let reset = clock.step(dt: 1 / 60, levels: signal(0.8), resetInput: true)
        #expect(reset.energy.x == 1 && reset.pulse == .zero)
        let rateChange = clock.step(dt: 1 / 60, levels: signal(0.9, rate: 48_000))
        #expect(rateChange.pulse == .zero)
        let countChange = clock.step(dt: 1 / 60, levels: signal(1, count: 512, rate: 48_000))
        #expect(countChange.energy.x == 1 && countChange.pulse == .zero)
        let staticCapture = clock.step(dt: 0, levels: signal(0.1, rate: 48_000))
        #expect(abs(staticCapture.energy.x - pow(0.25, 0.8)) < 0.000_001)
        #expect(staticCapture.pulse == .zero)
    }

    @Test func sustainedToneHasNoRepeatedRhythmPulse() {
        for fps in [30.0, 60.0, 120.0] {
            var clock = OrbitRhythmClock()
            _ = clock.step(dt: 0, levels: signal(0))
            var peaks = 0
            var previous: Float = 0
            var wasRising = false
            for _ in 0..<Int(fps * 3) {
                let value = clock.step(dt: 1 / fps, levels: signal(0.4)).pulse.x
                let rising = value > previous
                if wasRising && !rising && previous > 0.25 { peaks += 1 }
                wasRising = rising
                previous = value
            }
            #expect(peaks == 1)
            #expect(previous == 0)
        }
    }

    @Test func quietSignalIsNotAmplifiedIntoRhythm() {
        var clock = OrbitRhythmClock()
        _ = clock.step(dt: 0, levels: signal(0))
        for index in 0..<240 {
            let frame = clock.step(dt: 1 / 60, levels: signal(index.isMultiple(of: 15) ? 0.002 : 0))
            #expect(frame.pulse == .zero)
            #expect(frame.energy.x < 0.02)
        }
    }

    @Test func aSteadyLowToneDoesNotBecomeACycleOfInventedBeats() {
        for fps in [30.0, 60.0, 120.0] {
            func tone(at time: Double) -> AudioLevels {
                var result = signal(0)
                // The bass window is shorter than one 20 Hz cycle, so its block RMS
                // varies with phase even though the actual tone never changes volume.
                result.bassWaveform = (0..<1_024).map {
                    Float(0.4 * sin(2 * .pi * 20 * (time + Double($0) / 44_100)))
                }
                return result
            }
            var clock = OrbitRhythmClock()
            _ = clock.step(dt: 0, levels: tone(at: 0))
            for index in 1...Int(fps * 2) {
                let frame = clock.step(dt: 1 / fps, levels: tone(at: Double(index) / fps))
                #expect(frame.pulse == .zero)
            }
        }
    }

    @Test func repeatedDrumBurstsProduceSeparateCompleteMeasuredResponses() {
        var clock = OrbitRhythmClock()
        _ = clock.step(dt: 0, levels: signal(0))
        var peaks: [Float] = []
        var values: [Float] = []
        for index in 0..<180 {
            let time = Double(index) / 60
            let sinceBeat = time - floor(time / 0.75) * 0.75
            let amplitude = sinceBeat < 0.12 ? Float(0.5 * exp(-sinceBeat / 0.04)) : 0
            values.append(clock.step(dt: 1 / 60, levels: signal(amplitude)).pulse.x)
        }
        for start in stride(from: 0, to: values.count, by: 45) {
            let segment = values[start..<min(values.count, start + 45)]
            peaks.append(segment.max() ?? 0)
            #expect((segment.last ?? 1) == 0)
            #expect(segment.dropFirst(5).prefix(14).contains { $0 > 0.1 })
        }
        #expect(peaks.count == 4 && peaks.allSatisfy { $0 > 0.4 })
    }

    @Test func lossReleasesTheExistingBeatAndReconnectionCannotInventOne() {
        var clock = OrbitRhythmClock()
        _ = clock.step(dt: 0, levels: signal(0))
        var hit = OrbitRhythmFrame.zero
        for _ in 0..<4 { hit = clock.step(dt: 1 / 60, levels: signal(0.4)) }
        #expect(hit.pulse.x > 0.4)
        let release = clock.step(dt: 1 / 60, levels: .init())
        #expect(release.pulse.x > 0.2 && release.energy.x > 0)
        var final = release
        for _ in 0..<48 { final = clock.step(dt: 1 / 60, levels: .init()) }
        #expect(final.pulse == .zero && final.energy.x < 0.01)
        let reconnected = clock.step(dt: 1 / 60, levels: signal(0.8))
        #expect(reconnected.energy.x == 1 && reconnected.pulse == .zero)
    }

    @Test func overlappingHitsPreserveTheEarlierRelease() {
        var clock = OrbitRhythmClock()
        _ = clock.step(dt: 0, levels: signal(0))
        var first = OrbitRhythmFrame.zero
        for _ in 0..<3 { first = clock.step(dt: 1 / 60, levels: signal(0.5)) }
        #expect(first.pulse.x > 0.4)
        for _ in 0..<8 { _ = clock.step(dt: 1 / 60, levels: signal(0)) }
        let before = clock.step(dt: 1 / 60, levels: signal(0)).pulse.x
        let after = clock.step(dt: 1 / 60, levels: signal(0.5)).pulse.x
        #expect(before > 0.2)
        #expect(after > before)
    }

    @Test func zeroTimeWithoutPCMFreezesAndBriefLossDoesNotCutOffARelease() {
        var clock = OrbitRhythmClock()
        _ = clock.step(dt: 0, levels: signal(0))
        var active = OrbitRhythmFrame.zero
        for _ in 0..<4 { active = clock.step(dt: 1 / 60, levels: signal(0.4)) }
        let unchanged = clock.step(dt: 0, levels: .init())
        #expect(unchanged == active)
        let recovered = clock.step(dt: 1 / 60, levels: signal(0.4))
        #expect(recovered.pulse.x > 0.2 && recovered.pulse.x < active.pulse.x)
    }

    @Test func responseIsTimeBasedAcrossDisplayRates() {
        func response(fps: Double) -> (integral: Double, peak: Float, last: Float) {
            var clock = OrbitRhythmClock()
            _ = clock.step(dt: 0, levels: signal(0))
            var integral = 0.0
            var peak: Float = 0
            var final: Float = 0
            for index in 0..<Int(fps) {
                let time = Double(index) / fps
                let frame = clock.step(dt: 1 / fps, levels: signal(time < 0.10 ? 0.5 : 0))
                integral += Double(frame.pulse.x) / fps
                peak = max(peak, frame.pulse.x)
                final = frame.pulse.x
            }
            return (integral, peak, final)
        }
        let slow = response(fps: 30), regular = response(fps: 60), fast = response(fps: 120)
        #expect(abs(slow.integral - fast.integral) < 0.035)
        #expect(abs(regular.integral - fast.integral) < 0.025)
        #expect(abs(slow.peak - fast.peak) < 0.14)
        #expect(abs(regular.peak - fast.peak) < 0.10)
        #expect(slow.last == 0 && regular.last == 0 && fast.last == 0)
    }

    @Test func nonfinitePCMAndTimeRemainBoundedAndResetClearsEveryBand() {
        var clock = OrbitRhythmClock()
        var malformed = signal(0)
        malformed.bassWaveform = [.nan, .infinity, -.infinity, 2, -2]
        malformed.midWaveform = [.nan]
        malformed.sampleRate = .nan
        for dt in [0.0, .nan, .infinity, -1, 0.01, 10] {
            let frame = clock.step(dt: dt, levels: malformed)
            for band in 0..<3 {
                #expect(frame.energy[band].isFinite && frame.energy[band] >= 0 && frame.energy[band] <= 1)
                #expect(frame.pulse[band].isFinite && frame.pulse[band] >= 0 && frame.pulse[band] <= 1)
            }
        }
        clock.reset()
        let clear = clock.step(dt: 1 / 60, levels: .init())
        #expect(clear.energy == .zero && clear.pulse == .zero)
    }
}
