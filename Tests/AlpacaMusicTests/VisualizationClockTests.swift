import Foundation
import Testing
@testable import AlpacaMusic

@Suite @MainActor struct VisualizationClockTests {
    @Test func pauseAndReducedMotionFreezeTheAudioShapeAndResumeWithoutJump() {
        let clock = VisualizationClock()
        let date = Date(timeIntervalSince1970: 0)
        let levels = AudioLevels(energy: 0.8, beat: 0.5, spectrum: [0.8, 0.2], available: true)
        _ = clock.frame(at: date, animated: true, levels: levels, playing: true)
        let moving = clock.frame(at: date.addingTimeInterval(0.04), animated: true, levels: levels, playing: true)
        #expect(moving.audio.energy > 0)
        for playing in [false, true] {
            let frozen = clock.frame(at: date.addingTimeInterval(100), animated: false, levels: AudioLevels(), playing: playing)
            #expect(frozen.time == moving.time)
            #expect(frozen.audio.energy == moving.audio.energy)
            #expect(frozen.audio.spectrum == moving.audio.spectrum)
        }
        let resumed = clock.frame(at: date.addingTimeInterval(200), animated: true, levels: levels, playing: true)
        #expect(resumed.time == moving.time)
        let next = clock.frame(at: date.addingTimeInterval(200.04), animated: true, levels: levels, playing: true)
        #expect(abs(next.time - moving.time - 0.04) < 0.00001)
    }

    @Test func unavailableAudioAdvancesAmbienceWithoutInventingEnergy() {
        let clock = VisualizationClock(), date = Date(timeIntervalSince1970: 0)
        _ = clock.frame(at: date, animated: true, levels: AudioLevels(), playing: true)
        let frame = clock.frame(at: date.addingTimeInterval(0.04), animated: true, levels: AudioLevels(), playing: true)
        #expect(frame.time > 0)
        #expect(!frame.audio.available && frame.audio.energy == 0 && frame.audio.beat == 0 && frame.audio.spectrum.isEmpty)
    }

    @Test func signedWaveformInterpolatesWithoutGainJumpAndFreezesWithTheFrame() {
        let clock = VisualizationClock(), date = Date(timeIntervalSince1970: 0)
        let input = AudioLevels(available: true, waveform: [-0.8, 0, 0.8, 0], amplitude: 0.6,
                                bass: 0.4, mid: 0.2, treble: 0.1, waveformDuration: 0.02)
        _ = clock.frame(at: date, animated: true, levels: input, playing: true)
        let moving = clock.frame(at: date.addingTimeInterval(1.0 / 60), animated: true, levels: input, playing: true)
        #expect(moving.audio.waveform.count == 4)
        #expect(moving.audio.waveform[0] < 0 && moving.audio.waveform[0] > -0.8)
        #expect(moving.audio.waveform[2] > 0 && moving.audio.waveform[2] < 0.8)
        #expect(moving.audio.amplitude > 0 && moving.audio.amplitude < 0.6)
        let frozen = clock.frame(at: date.addingTimeInterval(20), animated: false, levels: AudioLevels(), playing: false)
        #expect(frozen.audio.waveform == moving.audio.waveform)
        #expect(frozen.audio.waveformDuration == moving.audio.waveformDuration)
        let resumed = clock.frame(at: date.addingTimeInterval(40), animated: true, levels: input, playing: true)
        #expect(resumed.audio.waveform == frozen.audio.waveform)
        clock.resetSignal()
        let reset = clock.frame(at: date.addingTimeInterval(41), animated: false, levels: AudioLevels(), playing: false)
        #expect(reset.audio.waveform.isEmpty && !reset.audio.available)
    }

    @Test func unavailableAndNonfiniteWaveformsCannotBecomeFakeAudio() {
        let input = AudioLevels(available: true, waveform: [.nan, -.infinity, -3, 0.5, 4], amplitude: .nan,
                                bass: 2, mid: -1, treble: .infinity, waveformDuration: .nan)
        let clean = VisualizationAudio(input)
        #expect(clean.waveform == [0, 0, -1, 0.5, 1])
        #expect(clean.amplitude == 0 && clean.bass == 1 && clean.mid == 0 && clean.treble == 0)
        #expect(clean.waveformDuration == 0)
        let paused = VisualizationAudio(input, playing: false)
        #expect(!paused.available && paused.waveform.isEmpty)
        let clock = VisualizationClock(), date = Date(timeIntervalSince1970: 0)
        _ = clock.frame(at: date, animated: true, levels: input, playing: true)
        let absent = clock.frame(at: date.addingTimeInterval(0.02), animated: true, levels: AudioLevels(), playing: true)
        #expect(!absent.audio.available && absent.audio.waveform.isEmpty)
    }

    @Test func bandTracesFreezeResetAndRespectFormatChanges() {
        let clock = VisualizationClock(), date = Date(timeIntervalSince1970: 0)
        var levels = AudioLevels(available: true, waveformDuration: 0.02,
                                 bassWaveform: [-0.6, 0.6], midWaveform: [0.3, -0.3], trebleWaveform: [-0.1, 0.1],
                                 sampleRate: 44_100, spectrumBinWidth: 44_100.0 / 2_048)
        levels.spectrum = [0.8, 0.3]
        _ = clock.frame(at: date, animated: true, levels: levels, playing: true)
        let moving = clock.frame(at: date.addingTimeInterval(0.04), animated: true, levels: levels, playing: true)
        #expect(moving.audio.bassWaveform[0] < 0 && moving.audio.bassWaveform[1] > 0)
        #expect(moving.audio.midWaveform[0] > 0 && moving.audio.midWaveform[1] < 0)
        #expect(moving.audio.trebleWaveform[0] < 0 && moving.audio.trebleWaveform[1] > 0)
        let frozen = clock.frame(at: date.addingTimeInterval(10), animated: false, levels: AudioLevels(), playing: false)
        #expect(frozen.audio.bassWaveform == moving.audio.bassWaveform)
        #expect(frozen.audio.midWaveform == moving.audio.midWaveform)
        #expect(frozen.audio.trebleWaveform == moving.audio.trebleWaveform)
        #expect(frozen.audio.sampleRate == 44_100 && frozen.audio.spectrumBinWidth == levels.spectrumBinWidth)
        // Equal-sized new buffers at a different sample rate must not blend the
        // old time/frequency mapping into the new format on the first frame.
        levels.sampleRate = 48_000; levels.spectrumBinWidth = 48_000.0 / 2_048
        levels.spectrum = [0.1, 0.9]
        let changed = clock.frame(at: date.addingTimeInterval(11), animated: true, levels: levels, playing: true)
        #expect(changed.audio.bassWaveform == [0, 0])
        #expect(changed.audio.spectrum == [0.1, 0.9].map { Double(Float($0)) })
        #expect(changed.audio.sampleRate == 48_000)
        let absent = clock.frame(at: date.addingTimeInterval(11.04), animated: true, levels: AudioLevels(), playing: true)
        #expect(absent.audio.bassWaveform.isEmpty && absent.audio.midWaveform.isEmpty && absent.audio.trebleWaveform.isEmpty)
        #expect(absent.audio.sampleRate == 0 && absent.audio.spectrumBinWidth == 0)
        clock.resetSignal()
        #expect(clock.frame(at: date, animated: false, levels: AudioLevels(), playing: false).audio.bassWaveform.isEmpty)
    }

    @Test func malformedBandSamplesAndFrequencyMetadataAreSanitized() {
        let levels = AudioLevels(available: true, bassWaveform: [.nan, -3, 3],
                                 midWaveform: [.infinity, -.infinity], trebleWaveform: [-0.2, 0.2],
                                 sampleRate: .nan, spectrumBinWidth: -.infinity)
        let clean = VisualizationAudio(levels)
        #expect(clean.bassWaveform == [0, -1, 1] && clean.midWaveform == [0, 0])
        #expect(clean.trebleWaveform == [-0.2, 0.2].map { Double(Float($0)) })
        #expect(clean.sampleRate == 0 && clean.spectrumBinWidth == 0)
        let paused = VisualizationAudio(levels, playing: false)
        #expect(!paused.available && paused.bassWaveform.isEmpty && paused.midWaveform.isEmpty && paused.trebleWaveform.isEmpty)
    }


    @Test func savedOrbitalModeRetainsItsIdentityAfterScopeUpgrade() throws {
        let restored = try JSONDecoder().decode(VisualizationMode.self, from: Data("\"spectrumRing\"".utf8))
        #expect(restored == .spectrumRing)
        #expect(try JSONEncoder().encode(restored) == Data("\"spectrumRing\"".utf8))
    }


    @Test func openingAPlayingScopeWithReducedMotionShowsOneRealSnapshot() {
        let clock = VisualizationClock(), date = Date(timeIntervalSince1970: 0)
        let levels = AudioLevels(spectrum: [0.2, 0.8], available: true, waveform: [-0.2, 0.2],
                                 bassWaveform: [-0.3, 0.3], midWaveform: [-0.1, 0.1], trebleWaveform: [-0.05, 0.05],
                                 sampleRate: 44_100, spectrumBinWidth: 44_100.0 / 2_048)
        let initial = clock.frame(at: date, animated: false, levels: levels, playing: true, captureStaticSignal: true)
        #expect(initial.time == 0 && initial.audio.available)
        #expect(initial.audio.bassWaveform == [-0.3, 0.3].map { Double(Float($0)) })
        var changed = levels; changed.bassWaveform = [0.9, -0.9]
        let held = clock.frame(at: date.addingTimeInterval(30), animated: false, levels: changed, playing: true, captureStaticSignal: true)
        #expect(held.audio.bassWaveform == initial.audio.bassWaveform && held.time == initial.time)
        let unavailable = clock.frame(at: date.addingTimeInterval(31), animated: false, levels: AudioLevels(), playing: true, captureStaticSignal: true)
        #expect(!unavailable.audio.available && unavailable.audio.bassWaveform.isEmpty)
        let recovered = clock.frame(at: date.addingTimeInterval(32), animated: false, levels: changed, playing: true, captureStaticSignal: true)
        #expect(recovered.audio.bassWaveform == changed.bassWaveform.map(Double.init))
        changed.sampleRate = 48_000; changed.spectrumBinWidth = 48_000.0 / 2_048
        let reformatted = clock.frame(at: date.addingTimeInterval(33), animated: false, levels: changed, playing: true, captureStaticSignal: true)
        #expect(reformatted.audio.sampleRate == 48_000 && reformatted.audio.spectrumBinWidth == changed.spectrumBinWidth)
        let paused = clock.frame(at: date.addingTimeInterval(40), animated: false, levels: AudioLevels(), playing: false)
        #expect(paused.audio.bassWaveform == reformatted.audio.bassWaveform)
    }

}
