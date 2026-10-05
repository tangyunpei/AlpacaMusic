import CoreGraphics
import Foundation
import Testing
@testable import AlpacaMusic

/// These tests check the production GPU output, including the visible identity
/// of each ribbon. A changed whole-frame hash alone cannot prove band isolation.
@Suite(.serialized) @MainActor struct RibbonBandRenderingTests {
    private let size = CGSize(width: 960, height: 540)

    @Test func eachSignedPCMTraceMovesItsOwnColoredRibbonInBothDensities() throws {
        for lowPower in [false, true] {
            let resting = try pixels(.init(), lowPower: lowPower)
            for selected in 0..<3 {
                let positive = bandSignal(selected, samples: wave(amplitude: 0.6))
                let negative = bandSignal(selected, samples: wave(amplitude: -0.6))
                let rising = try pixels(positive, lowPower: lowPower)
                let falling = try pixels(negative, lowPower: lowPower)
                expectOwnRibbonChanged(resting, rising, selected: selected)
                expectOwnRibbonChanged(resting, falling, selected: selected)
                // Inverting measured PCM must preserve its sign in the geometry,
                // rather than converting the trace to an unsigned loudness value.
                expectOwnRibbonChanged(rising, falling, selected: selected)
            }
        }
    }

    @Test func eachMeasuredAttackAccentsItsOwnRibbonWithoutMovingTheOthers() throws {
        for lowPower in [false, true] {
            let resting = try pixels(.init(), lowPower: lowPower)
            for selected in 0..<3 {
                var response = OrbitRhythmFrame.zero
                response.energy[selected] = 0.55
                response.pulse[selected] = 0.90
                let accented = try pixels(.init(), rhythm: response, lowPower: lowPower)
                expectOwnRibbonChanged(resting, accented, selected: selected)
                // A measured attack should also read as light, beyond displacement.
                let before = bandLight(resting)[selected]
                let after = bandLight(accented)[selected]
                #expect(after > before * 1.10)
            }
        }
    }

    @Test(arguments: [80.0, 1_000.0, 8_000.0])
    func productionFilterTonesDriveTheCorrespondingVisibleRibbon(_ frequency: Double) throws {
        let samples = (0..<8_192).map {
            Float(0.4 * sin(2 * Double.pi * frequency * Double($0) / 44_100))
        }
        let levels = AudioBandAnalysis.analyze(samples: samples, sampleRate: 44_100)
        try #require(levels.available, "The production filters must analyze the supplied PCM.")
        let selected = frequency == 80 ? 0 : frequency == 1_000 ? 1 : 2
        let traces = [levels.bassWaveform, levels.midWaveform, levels.trebleWaveform]
        try #require(traces.allSatisfy { $0.count == 1_024 })
        let measured = traces.map(rms)
        #expect(measured[selected] > 0.20)
        #expect(measured.enumerated().filter { $0.offset != selected }.allSatisfy { $0.element < 0.02 })

        // Use the same measured onset/envelope chain as the live motion clock.
        var clock = OrbitRhythmClock()
        _ = clock.step(dt: 0, levels: bandSignal(0, samples: Array(repeating: 0, count: 1_024)))
        var response = OrbitRhythmFrame.zero
        for _ in 0..<5 { response = clock.step(dt: 1 / 60, levels: levels) }
        print("Filtered ribbon tone \(frequency) Hz: RMS=\(measured), energy=\(response.energy), pulse=\(response.pulse)")
        #expect(response.energy[selected] > 0.4 && response.pulse[selected] > 0.1)
        for lowPower in [false, true] {
            let resting = try pixels(.init(), lowPower: lowPower)
            let active = try pixels(levels, rhythm: response, lowPower: lowPower)
            // Crossover filters retain real neighboring-band PCM (8 kHz leaves
            // about 4.4% mid-band RMS), and pleats/edge ruffles have different
            // geometric gains. Do not mistake that legitimate measured response
            // for crosstalk. The intended ribbon must contribute the majority of
            // the visible change; synthetic isolated-band tests above separately
            // enforce that an absent band cannot respond to another band.
            let changes = changesByBand(resting, active)
            print("Filtered ribbon visible changes: selected=\(selected), changes=\(changes)")
            #expect(changes[selected] > 1_000)
            #expect(changes[selected] > changes.enumerated().filter { $0.offset != selected }.reduce(0) { $0 + $1.element })
        }
    }

    @Test func scalarsUnavailablePCMAndSilenceCannotInventBandMotion() throws {
        let resting = try pixels(.init())
        let scalars = AudioLevels(energy: 1, beat: 1, available: true, amplitude: 1,
                                 bass: 1, mid: 1, treble: 1)
        #expect(try pixels(scalars) == resting)
        #expect(try pixels(bandSignal(0, samples: Array(repeating: 0, count: 1_024))) == resting)
        var unavailable = bandSignal(0, samples: wave(amplitude: 0.8))
        unavailable.available = false
        #expect(try pixels(unavailable) == resting)
        var clock = OrbitRhythmClock()
        for _ in 0..<240 {
            #expect(clock.step(dt: 1 / 60, levels: scalars) == .zero)
            #expect(clock.step(dt: 1 / 60, levels: unavailable) == .zero)
        }
        // The ambient silk still flows with time; this is not a claimed audio
        // response, so compare scalar and missing-input poses at the same time.
        #expect(try pixels(scalars, time: 30) == pixels(.init(), time: 30))
    }

    @Test func malformedAndExtremeInputsMatchTheirFiniteClampedPose() throws {
        let badSamples: [Float] = [.nan, .infinity, -.infinity, 4, -4, .greatestFiniteMagnitude, -.greatestFiniteMagnitude]
        let samples = (0..<1_024).map { badSamples[$0 % badSamples.count] }
        let clean = samples.map { $0.isFinite ? min(1, max(-1, $0)) : 0 }
        let badRhythm = OrbitRhythmFrame(energy: .init(.nan, .infinity, -1), pulse: .init(-1, .nan, -.infinity))
        #expect(try pixels(.init(), rhythm: badRhythm) == pixels(.init()))
        let overdriven = OrbitRhythmFrame(energy: .init(repeating: 4), pulse: .init(repeating: 4))
        let clipped = OrbitRhythmFrame(energy: .init(repeating: 1), pulse: .init(repeating: 1))
        for selected in 0..<3 {
            #expect(try pixels(bandSignal(selected, samples: samples)) == pixels(bandSignal(selected, samples: clean)))
            #expect(try pixels(bandSignal(selected, samples: samples), rhythm: overdriven)
                == pixels(bandSignal(selected, samples: clean), rhythm: clipped))
        }
    }

    @Test func bothDensitiesKeepThreeRecognizableRibbonsWithDifferentSampling() throws {
        let regular = try pixels(.init())
        let economical = try pixels(.init(), lowPower: true)
        let fullCounts = bandPixelCounts(regular), reducedCounts = bandPixelCounts(economical)
        #expect(fullCounts.allSatisfy { $0 > 100 })
        #expect(reducedCounts.allSatisfy { $0 > 100 })
        #expect(regular != economical)
        // Low-power points deliberately grow slightly to preserve legibility.
        // Their occupied screen area is therefore not a proxy for point count.
        print("Ribbon visible foreground pixels: regular=\(fullCounts), lowPower=\(reducedCounts)")
    }

    @Test func pausedAndReducedMotionFramesFreezeTheCompleteMeasuredRibbonPose() throws {
        var clock = ParticleFieldMotionClock()
        let quiet = bandSignal(0, samples: Array(repeating: 0, count: 1_024))
        let input = bandSignal(1, samples: wave(amplitude: 0.5))
        _ = clock.frame(at: 0, animated: true, levels: quiet)
        _ = clock.frame(at: 0.4, animated: true, levels: quiet)
        _ = clock.frame(at: 0.416, animated: true, levels: input)
        let active = clock.frame(at: 0.45, animated: true, levels: input)
        #expect(active.orbitRhythm.pulse.y > 0.1)
        let paused = clock.frame(at: 10, animated: false, levels: .init())
        let reduced = clock.frame(at: 20, animated: false, levels: bandSignal(2, samples: wave(amplitude: 1)), captureStaticSignal: true)
        let visible = try pixels(active.audio, rhythm: active.orbitRhythm, time: active.time)
        #expect(try pixels(paused.audio, rhythm: paused.orbitRhythm, time: paused.time) == visible)
        #expect(try pixels(reduced.audio, rhythm: reduced.orbitRhythm, time: reduced.time) == visible)
    }

    private func wave(amplitude: Float) -> [Float] {
        (0..<1_024).map { Float(sin(Double($0) * .pi * 2 / 48)) * amplitude }
    }

    private func bandSignal(_ band: Int, samples: [Float]) -> AudioLevels {
        var audio = AudioLevels(available: true)
        audio.bassWaveform = Array(repeating: 0, count: samples.count)
        audio.midWaveform = audio.bassWaveform; audio.trebleWaveform = audio.bassWaveform
        switch band {
        case 0: audio.bassWaveform = samples
        case 1: audio.midWaveform = samples
        default: audio.trebleWaveform = samples
        }
        audio.sampleRate = 44_100; audio.spectrumBinWidth = 44_100 / 2_048
        audio.waveformDuration = Double(samples.count - 1) / 44_100
        return audio
    }

    private func rms(_ samples: [Float]) -> Float {
        sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count))
    }

    private func pixels(_ audio: AudioLevels, rhythm: OrbitRhythmFrame = .zero,
                        lowPower: Bool = false, time: Float = 3) throws -> [UInt8] {
        try RibbonBackgroundReference.load(size: size)
        return try TemporalDesignExport.rgba(ParticleFieldOffscreen.image(mode: .ribbons, time: Double(time),
            audio: audio, orbitRhythm: rhythm, size: size, seed: 0xA17ACA, glow: true, lowPower: lowPower))
    }

    // Stable palette identities: warm peach = bass, violet = mid, teal = treble.
    // Render the exact production background pass separately, then subtract it
    // in linear light. Its blue gradient otherwise incorrectly classifies dim
    // teal grains and most empty pixels as the violet ribbon after sRGB encoding.
    // Ambiguous blended crossings remain excluded rather than being assigned to
    // one of the overlapping ribbons.
    private func colorBand(_ bytes: [UInt8], at offset: Int) -> Int? {
        let background = RibbonBackgroundReference.pixels
        let linear = RibbonBackgroundReference.linear
        let r = max(0, linear[Int(bytes[offset])] - linear[Int(background[offset])])
        let g = max(0, linear[Int(bytes[offset + 1])] - linear[Int(background[offset + 1])])
        let b = max(0, linear[Int(bytes[offset + 2])] - linear[Int(background[offset + 2])])
        guard max(r, max(g, b)) >= 0.004 else { return nil }
        if r > g * 1.15 && r > b * 1.25 { return 0 }
        if b > g * 1.15 && b > r * 1.08 { return 1 }
        if g > r * 1.15 && g > b * 1.02 { return 2 }
        return nil
    }

    private func changesByBand(_ first: [UInt8], _ last: [UInt8]) -> [Double] {
        var values = Array(repeating: 0.0, count: 3)
        for offset in stride(from: 0, to: first.count, by: 4) {
            let before = colorBand(first, at: offset), after = colorBand(last, at: offset)
            if let before, let after, before != after { continue }
            guard let band = before ?? after else { continue }
            let difference = (0..<3).reduce(0) { $0 + abs(Int(first[offset + $1]) - Int(last[offset + $1])) }
            if difference > 3 { values[band] += Double(difference) }
        }
        return values
    }

    private func expectOwnRibbonChanged(_ first: [UInt8], _ last: [UInt8], selected: Int,
                                       leakageFraction: Double = 0.16,
                                       sourceLocation: SourceLocation = #_sourceLocation) {
        let changes = changesByBand(first, last)
        print("Ribbon visible changes: selected=\(selected), changes=\(changes)")
        #expect(changes[selected] > 1_000, sourceLocation: sourceLocation)
        for other in 0..<3 where other != selected {
            #expect(changes[other] < max(400, changes[selected] * leakageFraction), sourceLocation: sourceLocation)
        }
    }

    private func bandLight(_ pixels: [UInt8]) -> [Double] {
        var light = Array(repeating: 0.0, count: 3)
        let background = RibbonBackgroundReference.pixels
        let linear = RibbonBackgroundReference.linear
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            guard let band = colorBand(pixels, at: offset) else { continue }
            for channel in 0..<3 {
                light[band] += max(0, linear[Int(pixels[offset + channel])] - linear[Int(background[offset + channel])])
            }
        }
        return light
    }

    private func bandPixelCounts(_ pixels: [UInt8]) -> [Int] {
        var counts = Array(repeating: 0, count: 3)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            if let band = colorBand(pixels, at: offset) { counts[band] += 1 }
        }
        return counts
    }
}
