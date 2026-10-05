import CoreGraphics
import Testing
@testable import AlpacaMusic

@Suite struct OrbitRhythmRenderingTests {
    @Test @MainActor func onsetProducesVisibleIndependentAccentsInBothPointDensities() throws {
        for lowPower in [false, true] {
            let quiet = try pixels(.zero, lowPower: lowPower)
            var peaks: [[UInt8]] = []
            for band in 0..<3 {
                var response = OrbitRhythmFrame.zero
                response.energy[band] = 0.45
                response.pulse[band] = 0.85
                let peak = try pixels(response, lowPower: lowPower)
                #expect(peak != quiet)
                // An accent must be perceptible at scene scale, not just move a
                // handful of waveform samples by a subpixel amount.
                #expect(light(peak) > light(quiet) * 1.15)
                peaks.append(peak)
            }
            #expect(peaks[0] != peaks[1] && peaks[1] != peaks[2] && peaks[0] != peaks[2])
        }
    }

    @Test @MainActor func zeroRhythmRetainsAmbientSceneAndStarfieldIgnoresBandResponse() throws {
        let peak = OrbitRhythmFrame(energy: .init(repeating: 1), pulse: .init(repeating: 1))
        #expect(try pixels(.zero, mode: .starfield) == pixels(peak, mode: .starfield))
        let missing = try pixels(.zero)
        let bad = OrbitRhythmFrame(energy: .init(.nan, -.infinity, -1), pulse: .init(.infinity, -1, .nan))
        #expect(try pixels(bad) == missing)
    }

    @Test func pauseAndReducedMotionPreserveAnEntireRhythmicAccent() {
        var quiet = AudioLevels(available: true)
        quiet.bassWaveform = .init(repeating: 0, count: 1_024)
        quiet.midWaveform = quiet.bassWaveform; quiet.trebleWaveform = quiet.bassWaveform
        quiet.sampleRate = 44_100; quiet.waveformDuration = 1_023 / 44_100.0
        var drum = quiet
        drum.bassWaveform = (0..<1_024).map { Float(sin(Double($0) * .pi * 2 / 64)) * 0.5 }
        var clock = ParticleFieldMotionClock()
        _ = clock.frame(at: 0, animated: true, levels: quiet)
        _ = clock.frame(at: 0.4, animated: true, levels: quiet)
        var peak = clock.frame(at: 0.416, animated: true, levels: drum)
        for tick in 1...6 {
            peak = clock.frame(at: 0.416 + Double(tick) / 60, animated: true, levels: drum)
        }
        #expect(peak.orbitRhythm.pulse.x > 0.1)
        let paused = clock.frame(at: 10, animated: false, levels: .init())
        #expect(paused.orbitRhythm == peak.orbitRhythm && paused.time == peak.time)
        let reduced = clock.frame(at: 20, animated: false, levels: drum, captureStaticSignal: true)
        #expect(reduced.orbitRhythm == peak.orbitRhythm)
        let resumed = clock.frame(at: 30, animated: true, levels: drum)
        #expect(resumed.orbitRhythm == peak.orbitRhythm && resumed.time == peak.time)
        clock.reset()
        #expect(clock.frame(at: 40, animated: false, levels: drum).orbitRhythm == .zero)
    }

    @Test func briefSourceLossAndRecoveryKeepTheMeasuredRelease() {
        var quiet = AudioLevels(available: true)
        quiet.bassWaveform = .init(repeating: 0, count: 1_024)
        quiet.sampleRate = 44_100; quiet.waveformDuration = 1_023 / 44_100.0
        var drum = quiet
        drum.bassWaveform = (0..<1_024).map { Float(sin(Double($0) * .pi * 2 / 64)) * 0.5 }
        var clock = ParticleFieldMotionClock()
        _ = clock.frame(at: 0, animated: true, levels: quiet)
        _ = clock.frame(at: 0.016, animated: true, levels: drum)
        let peak = clock.frame(at: 0.050, animated: true, levels: drum)
        #expect(peak.orbitRhythm.pulse.x > 0.2)
        let lost = clock.frame(at: 0.066, animated: true, levels: .init())
        #expect(lost.audio.bassWaveform.isEmpty && lost.orbitRhythm.pulse.x > 0.2)
        let recovered = clock.frame(at: 0.082, animated: true, levels: drum)
        #expect(recovered.orbitRhythm.pulse.x > 0.2)
        #expect(recovered.orbitRhythm.pulse.x <= lost.orbitRhythm.pulse.x)
        #expect(recovered.audio.bassWaveform == drum.bassWaveform)
    }

    @MainActor private func pixels(_ rhythm: OrbitRhythmFrame, lowPower: Bool = false,
                                  mode: VisualizationMode = .spectrumRing) throws -> [UInt8] {
        let image = try ParticleFieldOffscreen.image(mode: mode, time: 3, audio: .init(),
            orbitRhythm: rhythm, size: .init(width: 960, height: 540), seed: 0xA17ACA,
            glow: true, lowPower: lowPower)
        return try TemporalDesignExport.rgba(image)
    }

    // Exclude the dim static background, whose pixels greatly outnumber the
    // particle cores. This measures visible luminous grain at scene scale.
    private func light(_ bytes: [UInt8]) -> Double {
        stride(from: 0, to: bytes.count, by: 4).reduce(0.0) { result, offset in
            result + max(0, Double(bytes[offset]) + Double(bytes[offset + 1]) + Double(bytes[offset + 2]) - 75)
        }
    }
}
