import CoreGraphics
import Testing
@testable import AlpacaMusic

@Suite struct OrbitScopeTests {
    private func signal(_ sample: Float = 0.5, rate: Double = 44_100) -> AudioLevels {
        var result = AudioLevels(available: true)
        result.bassWaveform = Array(repeating: sample, count: 1_024)
        result.midWaveform = Array(repeating: -sample * 0.5, count: 1_024)
        result.trebleWaveform = Array(repeating: sample * 0.25, count: 1_024)
        result.sampleRate = rate
        result.spectrumBinWidth = rate / 2_048
        result.waveformDuration = 1_023 / rate
        return result
    }

    @Test @MainActor func GPUWavePacketsRetainEverySignedSampleAndStayAtFourKiB() {
        var samples = Array(repeating: Float(0), count: 1_024)
        samples[77] = 0.85; samples[397] = -0.7
        let packet = ParticleFieldPipeline.scopeWaveform(samples, available: true)
        #expect(packet == samples)
        #expect(packet.count * MemoryLayout<Float>.stride == 4_096)
        #expect(ParticleFieldPipeline.scopeWaveform(samples, available: false).allSatisfy { $0 == 0 })
        samples[100] = .nan; samples[500] = .infinity
        let clean = ParticleFieldPipeline.scopeWaveform(samples, available: true)
        #expect(clean.allSatisfy { $0.isFinite })
        #expect(clean[77] == 0.85 && clean[397] == -0.7 && clean[100] == 0 && clean[500] == 0)
        var oversized = Array(repeating: Float(0), count: 8_192)
        oversized[4_013] = 1; oversized[4_014] = -1
        let reduced = ParticleFieldPipeline.scopeWaveform(oversized, available: true)
        #expect(reduced.count == 1_024)
        #expect(reduced.contains(1) && reduced.contains(-1))
    }

    @Test func motionClockCarriesAllBandPCMAndFreezesTheCompletePose() {
        var input = signal()
        input.bassWaveform[77] = 0.91
        var clock = ParticleFieldMotionClock()
        let active = clock.frame(at: 0, animated: true, levels: input)
        #expect(active.audio.bassWaveform == input.bassWaveform)
        #expect(active.audio.midWaveform == input.midWaveform)
        #expect(active.audio.trebleWaveform == input.trebleWaveform)
        #expect(active.audio.sampleRate == 44_100 && active.audio.waveformDuration == input.waveformDuration)
        let frozen = clock.frame(at: 100, animated: false, levels: .init())
        #expect(frozen.time == active.time)
        #expect(frozen.audio.bassWaveform == active.audio.bassWaveform)
        #expect(frozen.audio.midWaveform == active.audio.midWaveform)
        #expect(frozen.audio.trebleWaveform == active.audio.trebleWaveform)
        let resumed = clock.frame(at: 200, animated: true, levels: input)
        #expect(resumed.time == active.time && resumed.audio.bassWaveform == active.audio.bassWaveform)
    }

    @Test func signedTraceSmoothingTreatsBothPolaritiesSymmetrically() {
        func run(_ first: Float) -> [Float] {
            var clock = ParticleFieldMotionClock()
            _ = clock.frame(at: 0, animated: true, levels: signal(first))
            return clock.frame(at: 0.05, animated: true, levels: signal(-first)).audio.bassWaveform
        }
        let falling = run(0.5), rising = run(-0.5)
        #expect(falling.count == 1_024 && falling[0] < 0 && rising[0] > 0)
        #expect(zip(falling, rising).allSatisfy { abs($0 + $1) < 0.000_001 })
    }

    @Test func playingSourceLossClearsMeasuredPCMAndFormatChangeStartsFresh() {
        var clock = ParticleFieldMotionClock()
        _ = clock.frame(at: 0, animated: true, levels: signal())
        let newRate = signal(-0.5, rate: 48_000)
        let reformatted = clock.frame(at: 0.01, animated: true, levels: newRate)
        #expect(reformatted.audio.bassWaveform == newRate.bassWaveform)
        #expect(reformatted.audio.sampleRate == 48_000)
        #expect(reformatted.audio.waveformDuration == newRate.waveformDuration)
        let lost = clock.frame(at: 0.02, animated: true, levels: .init())
        #expect(lost.time > reformatted.time)
        #expect(lost.audio.bassWaveform.isEmpty && lost.audio.midWaveform.isEmpty && lost.audio.trebleWaveform.isEmpty)
        #expect(lost.audio.sampleRate == 0 && lost.audio.spectrumBinWidth == 0 && lost.audio.waveformDuration == 0)
    }

    @Test func reducedMotionTakesOneRealSnapshotAndClearsItOnPlayingSourceLoss() {
        var clock = ParticleFieldMotionClock()
        let initial = clock.frame(at: 0, animated: false, levels: signal(), captureStaticSignal: true)
        #expect(initial.audio.bassWaveform == signal().bassWaveform)
        let unchanged = clock.frame(at: 1, animated: false, levels: signal(-0.5), captureStaticSignal: true)
        #expect(unchanged.time == initial.time && unchanged.audio.bassWaveform == initial.audio.bassWaveform)
        let reformatted = clock.frame(at: 2, animated: false, levels: signal(-0.5, rate: 48_000), captureStaticSignal: true)
        #expect(reformatted.audio.sampleRate == 48_000 && reformatted.audio.bassWaveform[0] == -0.5)
        let lost = clock.frame(at: 3, animated: false, levels: .init(), captureStaticSignal: true)
        #expect(lost.time == initial.time)
        #expect(!lost.audio.available && lost.audio.bassWaveform.isEmpty && lost.audio.midWaveform.isEmpty && lost.audio.trebleWaveform.isEmpty)
        #expect(lost.audio.sampleRate == 0 && lost.audio.waveformDuration == 0)
    }

    @Test @MainActor func eachGPUOrbitRespondsToItsOwnBandWithoutScalarImitation() throws {
        let baseline = try pixels(.init())
        let scalarOnly = AudioLevels(energy: 0.9, beat: 1, available: true, amplitude: 0.8, bass: 1, mid: 1, treble: 1)
        #expect(try pixels(scalarOnly) == baseline)
        let silence = signal(0)
        #expect(try pixels(silence) == baseline)
        var outputs: [[UInt8]] = []
        let samples = (0..<1_024).map { Float(sin(Double($0) * .pi * 2 / 48)) * 0.6 }
        for band in 0..<3 {
            var audio = AudioLevels(available: true)
            switch band {
            case 0: audio.bassWaveform = samples
            case 1: audio.midWaveform = samples
            default: audio.trebleWaveform = samples
            }
            let frame = try pixels(audio)
            #expect(frame != baseline)
            outputs.append(frame)
        }
        #expect(outputs[0] != outputs[1] && outputs[1] != outputs[2] && outputs[0] != outputs[2])
    }

    @Test @MainActor func GPUShowsNarrowPeaksAndTheirPolarityBetweenBaselineColumns() throws {
        for lowPower in [false, true] {
            let baseline = try pixels(.init(), lowPower: lowPower)
            for index in [77, 397] {
                for band in 0..<3 {
                    func input(_ value: Float) -> AudioLevels {
                        var audio = AudioLevels(available: true)
                        var samples = Array(repeating: Float(0), count: 1_024)
                        samples[index] = value
                        switch band {
                        case 0: audio.bassWaveform = samples
                        case 1: audio.midWaveform = samples
                        default: audio.trebleWaveform = samples
                        }
                        return audio
                    }
                    let positive = try pixels(input(1), lowPower: lowPower)
                    let negative = try pixels(input(-1), lowPower: lowPower)
                    #expect(positive != baseline && negative != baseline && positive != negative)
                }
            }
        }
    }

    @MainActor private func pixels(_ audio: AudioLevels, lowPower: Bool = false) throws -> [UInt8] {
        let image = try ParticleFieldOffscreen.image(mode: .spectrumRing, time: 3, audio: audio,
                                                    size: .init(width: 960, height: 540), seed: 0xA17ACA,
                                                    glow: true, lowPower: lowPower)
        return try TemporalDesignExport.rgba(image)
    }
}
