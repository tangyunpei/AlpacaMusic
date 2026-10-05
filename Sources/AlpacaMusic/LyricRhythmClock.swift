import Foundation

/// Smooth only measured audio envelopes. This is not a tempo generator: when
/// PCM is unavailable the lyric director continues from cue timing alone.
@MainActor final class LyricRhythmClock {
    private var previousDate: Date?
    private var audio = VisualizationAudio()

    func reset() { previousDate = nil; audio = VisualizationAudio() }
    func suspend() { previousDate = nil }

    func sample(at date: Date, levels: AudioLevels, animated: Bool) -> VisualizationAudio {
        guard animated else { previousDate = nil; return audio }
        guard levels.available else { reset(); return audio }
        func finite(_ value: Float) -> Double { value.isFinite ? min(1, max(0, Double(value))) : 0 }
        let incoming = (energy: finite(levels.energy), beat: finite(levels.beat), bass: finite(levels.bass), treble: finite(levels.treble))
        let elapsed = previousDate.map { date.timeIntervalSince($0) }
        previousDate = date
        let dt = elapsed.map { $0.isFinite ? min(0.08, max(0, $0)) : 0 } ?? 0
        if !audio.available {
            audio.energy = incoming.energy; audio.beat = incoming.beat
            audio.bass = incoming.bass; audio.treble = incoming.treble
        } else {
            func follow(_ old: Double, _ new: Double, attack: Double, release: Double) -> Double {
                old + (new - old) * (1 - exp(-dt * (new > old ? attack : release)))
            }
            audio.energy = follow(audio.energy, incoming.energy, attack: 10, release: 5)
            audio.beat = follow(audio.beat, incoming.beat, attack: 24, release: 8)
            audio.bass = follow(audio.bass, incoming.bass, attack: 12, release: 6)
            audio.treble = follow(audio.treble, incoming.treble, attack: 15, release: 7)
        }
        audio.available = true
        return audio
    }
}
