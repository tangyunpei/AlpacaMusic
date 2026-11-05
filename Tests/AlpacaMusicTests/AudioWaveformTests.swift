import Foundation
import Testing
@testable import AlpacaMusic

/// Each test drives the analyzer by hand: it runs only on `analyzeNow()`, on
/// a clock that moves only when the test advances it, so no result depends on
/// how soon the worker gets scheduled.
struct AudioWaveformTests {
    private let rate = 44100.0
    private let clock = ManualAnalyzerClock()

    private func makeAnalyzer() -> AudioAnalyzer { AudioAnalyzer.manual(clock) }

    private func tone(bin: Int = 8, amplitude: Double = 0.3, phase: Double = 0, count: Int = 4096) -> [Float] {
        (0..<count).map { Float(sin(2 * Double.pi * Double(bin) * Double($0) / 2048 + phase) * amplitude) }
    }

    /// Fewer samples than one analysis window: no pass can publish them, but
    /// they make the input fresh, so after a clear `levels()` shows what is
    /// actually published instead of stopping at its expiry check.
    private var partialWindow: [Float] { [Float](repeating: 0, count: 1024) }

    /// Runs one analysis pass and returns what it published.
    private func analyzed(_ analyzer: AudioAnalyzer) throws -> AudioLevels {
        analyzer.analyzeNow()
        let levels = analyzer.levels()
        try #require(levels.available, "The analyzer did not publish the supplied PCM.")
        return levels
    }

    private func expectCleared(_ levels: AudioLevels) {
        #expect(!levels.available)
        #expect(levels.waveform.isEmpty)
        #expect(levels.waveformDuration == 0)
        #expect(levels.bassWaveform.isEmpty && levels.midWaveform.isEmpty && levels.trebleWaveform.isEmpty)
        #expect(levels.sampleRate == 0 && levels.spectrumBinWidth == 0)
        #expect(levels.spectrum.isEmpty)
        #expect(levels.amplitude == 0 && levels.bass == 0 && levels.mid == 0 && levels.treble == 0)
        #expect(levels.energy == 0 && levels.beat == 0)
    }

    @Test func waveformContainsOriginalSignedPCMAtFixedScale() async throws {
        let analyzer = makeAnalyzer()
        let samples = tone()
        analyzer.ingest(samples: samples, sampleRate: rate)
        let levels = try analyzed(analyzer)
        #expect(levels.waveform.count == 1024)
        #expect(levels.bassWaveform.count == 1024 && levels.midWaveform.count == 1024 && levels.trebleWaveform.count == 1024)
        #expect(levels.sampleRate == rate && levels.spectrumBinWidth == rate / 2048)
        #expect(levels.waveform.contains { $0 > 0.25 })
        #expect(levels.waveform.contains { $0 < -0.25 })
        #expect(levels.waveform.allSatisfy { $0.isFinite && abs($0) <= 0.3 })
        #expect(abs(levels.waveformDuration - 1023 / rate) < 0.000001)
        let first = try #require(levels.waveform.first)
        #expect(first >= 0 && first < 0.01)
        // Every output is a consecutive original PCM value,
        // rather than a synthetic curve reconstructed from the FFT or its peak.
        let recent = Array(samples.suffix(2048))
        #expect((0...1024).contains { Array(recent[$0..<($0 + 1024)]) == levels.waveform })
    }

    @Test func risingTriggerStabilizesTheSameSignalAcrossCapturePhases() async throws {
        let first = makeAnalyzer(), second = makeAnalyzer()
        first.ingest(samples: tone(phase: 0), sampleRate: rate)
        second.ingest(samples: tone(phase: 0.9), sampleRate: rate)
        let left = try analyzed(first), right = try analyzed(second)
        let difference = zip(left.waveform, right.waveform).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / 1024
        #expect(difference < 0.01)
        #expect(abs(left.amplitude - right.amplitude) < 0.0001)
    }

    @Test func waveformPreservesHighFrequencySamplesAndSingleSamplePeaks() async throws {
        let highFrequency = makeAnalyzer(), pulse = makeAnalyzer()
        let samples = tone(bin: 700, amplitude: 0.2)
        highFrequency.ingest(samples: samples, sampleRate: rate)
        var impulse = [Float](repeating: 0, count: 2048)
        impulse[1101] = 0.6
        impulse[1102] = -0.4
        pulse.ingest(samples: impulse, sampleRate: rate)
        let high = try analyzed(highFrequency), narrow = try analyzed(pulse)
        let recent = Array(samples.suffix(2048))
        // A frequency above the old stride-four Nyquist limit is still represented
        // by all its original samples, not aliased into a lower-frequency curve.
        #expect((0...1024).contains { Array(recent[$0..<($0 + 1024)]) == high.waveform })
        try #require(narrow.waveform.count == 1024)
        #expect(narrow.waveform[77] == 0.6 && narrow.waveform[78] == -0.4)
        #expect(narrow.waveform.filter { $0 != 0 }.count == 2)
    }

    @Test(arguments: [4, 64, 320])
    func broadbandRMSAndBandsComeFromActualFrequencyEnergy(_ bin: Int) async throws {
        let analyzer = makeAnalyzer()
        analyzer.ingest(samples: tone(bin: bin, amplitude: 0.25), sampleRate: rate)
        let levels = try analyzed(analyzer)
        let expected = Float(0.25 / sqrt(2) * 1.7)
        #expect(abs(levels.amplitude - expected) < 0.001)
        let bands = [levels.bass, levels.mid, levels.treble]
        let selected = bin == 4 ? 0 : (bin == 64 ? 1 : 2)
        #expect(abs(bands[selected] - expected) < 0.002)
        #expect(bands.enumerated().filter { $0.offset != selected }.allSatisfy { $0.element < 0.002 })
    }

    @Test func silenceAndQuietInputAreNeverPeakNormalized() async throws {
        let silence = makeAnalyzer(), quiet = makeAnalyzer()
        silence.ingest(samples: [Float](repeating: 0, count: 4096), sampleRate: rate)
        quiet.ingest(samples: tone(amplitude: 0.00001), sampleRate: rate)
        let silent = try analyzed(silence), low = try analyzed(quiet)
        #expect(silent.waveform.count == 1024 && silent.waveform.allSatisfy { $0 == 0 })
        #expect([silent.bassWaveform, silent.midWaveform, silent.trebleWaveform].allSatisfy { $0.count == 1024 && $0.allSatisfy { $0 == 0 } })
        #expect(silent.amplitude == 0 && silent.bass == 0 && silent.mid == 0 && silent.treble == 0)
        #expect(low.waveform.count == 1024 && low.waveform.contains { $0 != 0 })
        #expect(low.waveform.allSatisfy { abs($0) <= 0.000011 })
        #expect(low.amplitude > 0 && low.amplitude < 0.00002)
    }

    @Test func invalidPCMIsFiniteAndBoundedAndInvalidRateClearsEverything() async throws {
        let analyzer = makeAnalyzer()
        let invalid: [Float] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude]
        analyzer.ingest(samples: (0..<4096).map { invalid[$0 % invalid.count] }, sampleRate: rate)
        let levels = try analyzed(analyzer)
        #expect(levels.waveform.count == 1024)
        #expect(levels.waveform.allSatisfy { $0.isFinite && (-1...1).contains($0) })
        #expect(levels.spectrum.allSatisfy { $0.isFinite && (0...1).contains($0) })
        #expect([levels.bassWaveform, levels.midWaveform, levels.trebleWaveform].allSatisfy { $0.count == 1024 && $0.allSatisfy { $0.isFinite && (-1...1).contains($0) } })
        #expect([levels.amplitude, levels.bass, levels.mid, levels.treble, levels.energy, levels.beat].allSatisfy { $0.isFinite && (0...1).contains($0) })
        for invalidRate in [Double.nan, .infinity, -.infinity, 0, -44100, .leastNonzeroMagnitude, 1e300, 768001] {
            analyzer.ingest(samples: tone(), sampleRate: rate)
            _ = try analyzed(analyzer)
            analyzer.ingest(samples: tone(), sampleRate: invalidRate)
            expectCleared(analyzer.levels())
            // The published levels were cleared too, not only hidden.
            analyzer.ingest(samples: partialWindow, sampleRate: rate)
            expectCleared(analyzer.levels())
        }
        analyzer.analyzeNow()
        expectCleared(analyzer.levels())
    }

    @Test func aResetClearsThePublishedLevels() async throws {
        let analyzer = makeAnalyzer()
        analyzer.ingest(samples: tone(), sampleRate: rate)
        _ = try analyzed(analyzer)
        analyzer.reset()
        analyzer.ingest(samples: partialWindow, sampleRate: rate)
        expectCleared(analyzer.levels())
    }

    /// The worker's own timer publishes, with no `analyzeNow()` call. The
    /// clock is frozen, so however late the timer runs, nothing expires.
    @Test func theWorkerTimerPublishesOnItsOwn() async throws {
        let analyzer = AudioAnalyzer(clock: clock.read)
        analyzer.ingest(samples: tone(), sampleRate: rate)
        var levels = analyzer.levels()
        for _ in 0..<500 where !levels.available {
            try await Task.sleep(for: .milliseconds(20))
            levels = analyzer.levels()
        }
        #expect(levels.available && levels.waveform.count == 1024)
    }

    /// Keeps the real worker timer, so passes already scheduled can run across
    /// the reset, on a frozen clock so nothing expires because a run is slow.
    @Test func resetDoesNotReuseEarlierSamplesOrPublishLateAudio() async throws {
        let analyzer = AudioAnalyzer(clock: clock.read)
        analyzer.ingest(samples: tone(), sampleRate: rate)
        _ = try analyzed(analyzer)
        analyzer.ingest(samples: tone(bin: 64), sampleRate: rate)
        analyzer.reset()
        expectCleared(analyzer.levels())
        analyzer.ingest(samples: partialWindow, sampleRate: rate)
        expectCleared(analyzer.levels())
        try await Task.sleep(for: .milliseconds(90))
        analyzer.analyzeNow()
        expectCleared(analyzer.levels())
        analyzer.ingest(samples: partialWindow, sampleRate: rate)
        let fresh = try analyzed(analyzer)
        #expect(fresh.waveform.count == 1024 && fresh.waveform.allSatisfy { $0 == 0 })
        #expect([fresh.bassWaveform, fresh.midWaveform, fresh.trebleWaveform].allSatisfy { $0.count == 1024 && $0.allSatisfy { $0 == 0 } })
        #expect(fresh.amplitude == 0 && fresh.energy == 0 && fresh.beat == 0)
    }

    @Test func expiryAndSampleRateChangeRequireAnEntireNewWindow() async throws {
        let analyzer = makeAnalyzer()
        analyzer.ingest(samples: tone(), sampleRate: rate)
        _ = try analyzed(analyzer)
        // Just before the expiry the levels still show. (Steps are exact in
        // binary, so the second one lands exactly on the expiry.)
        clock.advance(by: AudioAnalyzer.expiry - 0.125)
        #expect(analyzer.levels().available)
        // At the expiry they are gone at once, before any worker pass clears
        // them: a starved worker can no longer leave stale audio on screen.
        clock.advance(by: 0.125)
        expectCleared(analyzer.levels())
        // New input after the expiry with no worker pass in between, as with a
        // starved worker: the expired window and its levels are dropped, so
        // half a window shows nothing and publishes nothing.
        analyzer.ingest(samples: partialWindow, sampleRate: rate)
        expectCleared(analyzer.levels())
        analyzer.analyzeNow()
        expectCleared(analyzer.levels())
        // The same when a worker pass ran at the expiry first.
        analyzer.ingest(samples: tone(), sampleRate: rate)
        _ = try analyzed(analyzer)
        clock.advance(by: AudioAnalyzer.expiry)
        analyzer.analyzeNow()
        expectCleared(analyzer.levels())
        analyzer.ingest(samples: partialWindow, sampleRate: rate)
        expectCleared(analyzer.levels())
        analyzer.analyzeNow()
        expectCleared(analyzer.levels())
        // A sample-rate change also needs an entire new window.
        analyzer.ingest(samples: tone(), sampleRate: rate)
        _ = try analyzed(analyzer)
        analyzer.ingest(samples: partialWindow, sampleRate: 48000)
        expectCleared(analyzer.levels())
        analyzer.analyzeNow()
        expectCleared(analyzer.levels())
        analyzer.ingest(samples: partialWindow, sampleRate: 48000)
        let fresh = try analyzed(analyzer)
        #expect(fresh.waveform.allSatisfy { $0 == 0 })
        #expect([fresh.bassWaveform, fresh.midWaveform, fresh.trebleWaveform].allSatisfy { $0.count == 1024 && $0.allSatisfy { $0 == 0 } })
        #expect(fresh.sampleRate == 48000 && fresh.spectrumBinWidth == 48000.0 / 2048)
        #expect(fresh.amplitude == 0 && fresh.energy == 0 && fresh.beat == 0)
        #expect(abs(fresh.waveformDuration - 1023 / 48000) < 0.000001)
        analyzer.ingest(samples: [], sampleRate: 48000)
        expectCleared(analyzer.levels())
        analyzer.ingest(samples: partialWindow, sampleRate: 48000)
        expectCleared(analyzer.levels())
    }
}
