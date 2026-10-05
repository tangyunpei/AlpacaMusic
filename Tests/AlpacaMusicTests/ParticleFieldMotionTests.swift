import Foundation
import Testing
@testable import AlpacaMusic

@Suite struct ParticleFieldMotionTests {
    private var signal: AudioLevels {
        AudioLevels(energy: 0.8, beat: 0.7, available: true, amplitude: 0.6, bass: 0.9, mid: 0.4, treble: 0.3)
    }

    @Test func pauseAndBackgroundFreezePoseAndResumeWithoutCatchingUp() {
        var clock = ParticleFieldMotionClock()
        _ = clock.frame(at: 0, animated: true, levels: signal)
        let active = clock.frame(at: 0.1, animated: true, levels: signal)
        let paused = clock.frame(at: 100, animated: false, levels: AudioLevels())
        #expect(paused.time == active.time)
        #expect(paused.audio.bass == active.audio.bass && paused.audio.mid == active.audio.mid)
        #expect(paused.audio.beat == active.audio.beat && paused.audio.treble == active.audio.treble)
        let resumed = clock.frame(at: 200, animated: true, levels: signal)
        #expect(resumed.time == active.time)
        #expect(resumed.audio.bass == active.audio.bass)
        let next = clock.frame(at: 200.02, animated: true, levels: signal)
        #expect(abs(next.time - active.time - 0.02) < 0.0001)
    }

    @Test func constantSignalHasEquivalentMotionAcrossRefreshRates() {
        func run(_ fps: Int) -> ParticleFieldMotionFrame {
            var clock = ParticleFieldMotionClock()
            var frame = clock.frame(at: 0, animated: true, levels: signal)
            for tick in 1...fps { frame = clock.frame(at: Double(tick) / Double(fps), animated: true, levels: signal) }
            return frame
        }
        let thirty = run(30), sixty = run(60)
        #expect(abs(thirty.time - sixty.time) < 0.0001)
        #expect(abs(thirty.audio.bass - sixty.audio.bass) < 0.015)
        #expect(abs(thirty.audio.mid - sixty.audio.mid) < 0.015)
        #expect(abs(thirty.audio.treble - sixty.audio.treble) < 0.015)
        #expect(abs(thirty.audio.beat - sixty.audio.beat) < 0.015)
    }

    @Test func missingAudioAndSourceResetNeverInventBeatEvents() {
        var clock = ParticleFieldMotionClock()
        _ = clock.frame(at: 0, animated: true, levels: AudioLevels())
        let ambience = clock.frame(at: 1, animated: true, levels: AudioLevels())
        #expect(ambience.time > 0)
        #expect(!ambience.audio.available && ambience.audio.bass == 0 && ambience.audio.beat == 0)
        _ = clock.frame(at: 1.02, animated: true, levels: signal)
        clock.reset()
        let reset = clock.frame(at: 2, animated: false, levels: signal)
        #expect(reset.time == 0 && reset.audio.bass == 0 && reset.audio.beat == 0)
    }
}
