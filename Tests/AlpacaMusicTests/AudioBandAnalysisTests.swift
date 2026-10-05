import Foundation
import Testing
@testable import AlpacaMusic

struct AudioBandAnalysisTests {
    private func tone(_ frequency: Double, rate: Double = 44100, amplitude: Double = 0.3, count: Int = 8192) -> [Float] {
        (0..<count).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    private func traces(_ levels: AudioLevels) -> [[Float]] { [levels.bassWaveform, levels.midWaveform, levels.trebleWaveform] }
    private func rms(_ samples: [Float]) -> Float { sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)) }

    @Test(arguments: [80.0, 1000, 8000])
    func realPCMSeparatesIntoTheExpectedBand(_ frequency: Double) {
        let levels = AudioBandAnalysis.analyze(samples: tone(frequency), sampleRate: 44100)
        let bands = traces(levels)
        let selected = frequency == 80 ? 0 : (frequency == 1000 ? 1 : 2)
        #expect(levels.available && bands.allSatisfy { $0.count == 1024 })
        #expect(bands[selected].contains { $0 > 0.25 } && bands[selected].contains { $0 < -0.25 })
        // The source window is not necessarily an integral number of low-frequency
        // periods; retain the filter's real phase rather than normalizing its RMS.
        #expect(abs(rms(bands[selected]) - Float(0.3 / sqrt(2))) < 0.012)
        #expect(bands.enumerated().filter { $0.offset != selected }.allSatisfy { rms($0.element) < 0.015 })
        let dominant = levels.spectrum.enumerated().dropFirst().max { $0.element < $1.element }?.offset ?? 0
        #expect(abs(Double(dominant) * levels.spectrumBinWidth - frequency) <= levels.spectrumBinWidth)
        #expect(levels.sampleRate == 44100 && levels.spectrumBinWidth == 44100.0 / 2048)
    }

    @Test(arguments: [250.0, 4000])
    func crossoverSharesEnergySmoothlyInsteadOfInventingAHardSwitch(_ frequency: Double) {
        let levels = AudioBandAnalysis.analyze(samples: tone(frequency), sampleRate: 44100)
        let bandRMS = traces(levels).map(rms)
        let selected = frequency == 250 ? [0, 1] : [1, 2]
        for index in selected { #expect(abs(bandRMS[index] - 0.15) < 0.012) }
        #expect(abs(bandRMS[selected[0]] - bandRMS[selected[1]]) < 0.005)
        #expect(bandRMS[frequency == 250 ? 2 : 0] < 0.002)
    }

    @Test func fixedScalePreservesQuietAudioAndMixedBands() {
        // Both inputs remain below the trigger threshold, so sample positions match.
        let loud = AudioBandAnalysis.analyze(samples: tone(1000, amplitude: 0.001), sampleRate: 44100)
        let quiet = AudioBandAnalysis.analyze(samples: tone(1000, amplitude: 0.00002), sampleRate: 44100)
        for pair in zip(loud.midWaveform, quiet.midWaveform) { #expect(abs(pair.0 * 0.02 - pair.1) < 0.000000001) }
        #expect(quiet.midWaveform.contains { $0 != 0 } && quiet.midWaveform.allSatisfy { abs($0) < 0.000022 })
        let components = [tone(80, amplitude: 0.12), tone(1000, amplitude: 0.08), tone(8000, amplitude: 0.04)]
        let mixed = (0..<8192).map { components[0][$0] + components[1][$0] + components[2][$0] }
        let levels = AudioBandAnalysis.analyze(samples: mixed, sampleRate: 44100)
        let measured = traces(levels).map(rms)
        for (actual, amplitude) in zip(measured, [0.12, 0.08, 0.04]) { #expect(abs(actual - Float(amplitude / sqrt(2))) < 0.012) }
        #expect(levels.bassWaveform != levels.midWaveform && levels.midWaveform != levels.trebleWaveform)
    }

    @Test func allTracesShareTheOriginalIntervalAndHaveCausalImpulseResponse() {
        var samples = [Float](repeating: 0, count: 8192)
        samples[8192 - 2048 + 1101] = 0.6
        samples[8192 - 2048 + 1102] = -0.4
        let levels = AudioBandAnalysis.analyze(samples: samples, sampleRate: 44100)
        #expect(levels.waveform[77] == 0.6 && levels.waveform[78] == -0.4)
        for waveform in traces(levels) {
            #expect(waveform.count == 1024 && waveform.prefix(77).allSatisfy { $0 == 0 })
            #expect(waveform.suffix(from: 77).contains { $0 != 0 })
        }
        #expect(levels.waveformDuration == 1023.0 / 44100)
    }

    @Test func lowSampleRatesRespectNyquistAndUseCurrentFrequencyMetadata() {
        let lowRate = AudioBandAnalysis.analyze(samples: tone(1000, rate: 8000), sampleRate: 8000)
        #expect(lowRate.available && lowRate.trebleWaveform.count == 1024)
        #expect(lowRate.trebleWaveform.allSatisfy { $0 == 0 } && lowRate.treble == 0)
        #expect(rms(lowRate.midWaveform) > 0.2)
        #expect(lowRate.sampleRate == 8000 && lowRate.spectrumBinWidth == 8000.0 / 2048)
        let subAudio = AudioBandAnalysis.analyze(samples: [Float](repeating: 0.1, count: 2048), sampleRate: 1)
        #expect(subAudio.available && traces(subAudio).allSatisfy { $0.count == 1024 && $0.allSatisfy { $0 == 0 } })
        let otherRate = AudioBandAnalysis.analyze(samples: tone(8000, rate: 48000), sampleRate: 48000)
        #expect(otherRate.sampleRate == 48000 && otherRate.spectrumBinWidth == 48000.0 / 2048)
        #expect(abs(otherRate.waveformDuration - 1023.0 / 48000) < 0.000001)
    }

    @Test func silenceInvalidInputAndRepeatedAnalysesCannotReusePreviousBandState() {
        let loud = AudioBandAnalysis.analyze(samples: tone(80), sampleRate: 44100)
        #expect(loud.bassWaveform.contains { $0 != 0 })
        let silence = AudioBandAnalysis.analyze(samples: [Float](repeating: 0, count: 8192), sampleRate: 44100)
        #expect(silence.available && traces(silence).allSatisfy { $0.count == 1024 && $0.allSatisfy { $0 == 0 } })
        #expect(silence.spectrum.allSatisfy { $0 == 0 })
        let values: [Float] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude]
        let malformed = AudioBandAnalysis.analyze(samples: (0..<8192).map { values[$0 % values.count] }, sampleRate: 44100)
        #expect(traces(malformed).allSatisfy { $0.count == 1024 && $0.allSatisfy { $0.isFinite && (-1...1).contains($0) } })
        for rate in [Double.nan, .infinity, -.infinity, 0, -44100, 1e300, 768001] {
            let invalid = AudioBandAnalysis.analyze(samples: tone(80), sampleRate: rate)
            #expect(!invalid.available && invalid.sampleRate == 0 && invalid.spectrumBinWidth == 0)
            #expect(traces(invalid).allSatisfy { $0.isEmpty })
        }
        let incomplete = AudioBandAnalysis.analyze(samples: tone(80, count: 2047), sampleRate: 44100)
        #expect(!incomplete.available && incomplete.waveform.isEmpty && traces(incomplete).allSatisfy { $0.isEmpty })
    }
}
