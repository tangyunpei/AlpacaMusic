import Accelerate
import Foundation

/// Analysis runs on the utility worker, never in the real-time audio callback.
/// All four traces use the same 1024 consecutive source sample positions.
struct AudioBandAnalysis {
    struct Snapshot {
        var levels: AudioLevels
        var amplitudes: [Float]
    }

    private let transform = try? vDSP.DiscreteFourierTransform(count: 2048, direction: .forward, transformType: .complexComplex, ofType: Float.self)
    private static let window = (0..<2048).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 2047)) }

    /// A deterministic entry point for imported PCM and production-renderer fixtures.
    /// Supply up to 8192 recent samples for filter pre-roll; at least 2048 are needed.
    static func analyze(samples: [Float], sampleRate: Double) -> AudioLevels {
        AudioBandAnalysis().analyzeSnapshot(samples: samples, sampleRate: sampleRate)?.levels ?? AudioLevels()
    }

    func analyzeSnapshot(samples source: [Float], sampleRate: Double) -> Snapshot? {
        guard Self.isValidSampleRate(sampleRate), source.count >= 2048, let transform else { return nil }
        let samples = source.suffix(8192).map(Self.finitePCM)
        let recent = Array(samples.suffix(2048))
        let input = zip(recent, Self.window).map(*)
        let result = transform.transform(real: input, imaginary: [Float](repeating: 0, count: 2048))
        let amplitudes = (0..<1024).map { index in
            sqrt(result.real[index] * result.real[index] + result.imaginary[index] * result.imaginary[index]) / 512
        }
        let spectrum = amplitudes.map { min(1, max(0, (20 * log10(max(0.0001, $0)) + 80) / 80)) }
        let rms = sqrt(recent.reduce(Float(0)) { $0 + $1 * $1 } / Float(recent.count))
        let first = samples.count - 2048 + Self.triggerStart(recent, rms: rms)
        let range = first..<(first + 1024)

        // The signed traces are actual filtered PCM. Fourth-order Butterworth
        // cutoffs are smooth crossovers, not ideal brick walls. Their phase response
        // is retained: every band uses the same source interval and fixed unity gain.
        // Replaying captured pre-roll avoids stale filter state after resets/seeks.
        let bass = Self.filtered(samples, sampleRate: sampleRate, lower: 20, upper: 250)
        let mid = Self.filtered(samples, sampleRate: sampleRate, lower: 250, upper: 4000)
        let treble = Self.filtered(samples, sampleRate: sampleRate, lower: 4000, upper: 20000)
        let powerCorrection: Float = 2 * 512 * 512 / (2048 * Self.window.reduce(Float(0)) { $0 + $1 * $1 })
        let band: (Double, Double) -> Float = { lower, upper in
            let first = max(1, min(1024, Int(ceil(lower * 2048 / sampleRate))))
            let pastEnd = max(first, min(1024, Int(ceil(upper * 2048 / sampleRate))))
            guard first < pastEnd else { return 0 }
            let power = amplitudes[first..<pastEnd].reduce(Float(0)) { $0 + $1 * $1 }
            return min(1, sqrt(power * powerCorrection) * 1.7)
        }
        let levels = AudioLevels(spectrum: spectrum, available: true,
                                 waveform: Array(samples[range]), amplitude: min(1, rms * 1.7),
                                 bass: band(20, 250), mid: band(250, 4000), treble: band(4000, 20000),
                                 waveformDuration: 1023 / sampleRate,
                                 bassWaveform: Array(bass[range]), midWaveform: Array(mid[range]), trebleWaveform: Array(treble[range]),
                                 sampleRate: sampleRate, spectrumBinWidth: sampleRate / 2048)
        return Snapshot(levels: levels, amplitudes: amplitudes)
    }

    // Bound the supported PCM rate so malformed values cannot overflow FFT-bin
    // integer conversions or produce numerically unusable filter coefficients.
    static func isValidSampleRate(_ rate: Double) -> Bool { rate.isFinite && (1...768000).contains(rate) }
    private static func finitePCM(_ value: Float) -> Float { value.isFinite ? min(1, max(-1, value)) : 0 }

    private static func triggerStart(_ samples: [Float], rms: Float) -> Int {
        guard rms >= 0.002 else { return 1024 }
        for index in stride(from: 1024, through: 1, by: -1) {
            if samples[index - 1] <= 0, samples[index] > 0 { return index }
        }
        return 1024
    }

    private static func filtered(_ samples: [Float], sampleRate: Double, lower: Double, upper: Double) -> [Float] {
        let nyquist = sampleRate / 2
        guard lower < min(upper, nyquist) else { return [Float](repeating: 0, count: samples.count) }
        var values = samples.map(Double.init)
        // The two pole-pair Q values realize a fourth-order Butterworth response.
        // Coefficients follow the W3C Audio EQ Cookbook high/low-pass equations:
        // https://www.w3.org/TR/audio-eq-cookbook/
        for cutoff in [(lower, true), (upper, false)] {
            guard cutoff.0 < nyquist else { continue } // A cutoff at Nyquist is the identity low-pass.
            for q in [0.541196100146197, 1.306562964876377] {
                var section = Biquad(cutoff: cutoff.0, sampleRate: sampleRate, q: q, highPass: cutoff.1)
                for index in values.indices { values[index] = section.process(values[index]) }
            }
        }
        // Full-scale clipping is fixed, never derived from an individual band's peak.
        return values.map { $0.isFinite ? Float(min(1, max(-1, $0))) : 0 }
    }

    private struct Biquad {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var z1 = 0.0, z2 = 0.0

        init(cutoff: Double, sampleRate: Double, q: Double, highPass: Bool) {
            let omega = 2 * Double.pi * cutoff / sampleRate
            let cosine = cos(omega), alpha = sin(omega) / (2 * q), inverseA0 = 1 / (1 + alpha)
            let base = highPass ? (1 + cosine) / 2 : (1 - cosine) / 2
            b0 = base * inverseA0; b2 = b0
            b1 = (highPass ? -2 : 2) * base * inverseA0
            a1 = -2 * cosine * inverseA0; a2 = (1 - alpha) * inverseA0
        }

        mutating func process(_ input: Double) -> Double {
            let output = b0 * input + z1
            z1 = b1 * input - a1 * output + z2
            z2 = b2 * input - a2 * output
            return output
        }
    }
}
