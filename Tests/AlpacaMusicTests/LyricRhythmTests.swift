import Foundation
import SwiftUI
import Testing
@testable import AlpacaMusic

@Suite @MainActor struct LyricRhythmTests {
    @Test func measuredBeatSettlesInsteadOfSnappingAndFreezesDuringPause() {
        let clock = LyricRhythmClock()
        let date = Date(timeIntervalSince1970: 100)
        _ = clock.sample(at: date, levels: AudioLevels(available: true), animated: true)
        let attack = clock.sample(at: date.addingTimeInterval(1.0 / 60), levels: AudioLevels(energy: 1, beat: 1, available: true), animated: true)
        #expect(attack.available && attack.beat > 0 && attack.beat < 1)
        let release = clock.sample(at: date.addingTimeInterval(2.0 / 60), levels: AudioLevels(available: true), animated: true)
        #expect(release.beat > 0 && release.beat < attack.beat)
        let paused = clock.sample(at: date.addingTimeInterval(10), levels: AudioLevels(), animated: false)
        #expect(paused.beat == release.beat && paused.energy == release.energy)
        let resumed = clock.sample(at: date.addingTimeInterval(100), levels: AudioLevels(available: true), animated: true)
        #expect(resumed.beat == paused.beat)
    }
    @Test func missingAndInvalidAudioNeverBecomeInventedRhythm() {
        let clock = LyricRhythmClock()
        let date = Date(timeIntervalSince1970: 10)
        _ = clock.sample(at: date, levels: AudioLevels(energy: 1, beat: 1, available: true), animated: true)
        let unavailable = clock.sample(at: date.addingTimeInterval(0.02), levels: AudioLevels(), animated: true)
        #expect(!unavailable.available && unavailable.beat == 0 && unavailable.energy == 0)
        let invalid = clock.sample(at: date.addingTimeInterval(0.04), levels: AudioLevels(energy: .nan, beat: .infinity, available: true, bass: -1, treble: 4), animated: true)
        #expect(invalid.energy == 0 && invalid.beat == 0 && invalid.bass == 0 && invalid.treble == 1)
        clock.reset()
        let reset = clock.sample(at: date.addingTimeInterval(0.06), levels: AudioLevels(), animated: false)
        #expect(!reset.available && reset.beat == 0)
    }
    @Test func glyphOutlinesScaleFromReusableGeometryForChineseAndLatin() throws {
        for text in ["留一点时间", "Quiet letters", "🌙 Night / 夜色"] {
            let small = try #require(LyricOutline.path(text: text, weight: .bold, tracking: -2.5, fontSize: 100))
            let big = try #require(LyricOutline.path(text: text, weight: .bold, tracking: -5, fontSize: 200))
            #expect(abs(big.boundingRect.width - small.boundingRect.width * 2) < 0.01)
            #expect(abs(big.boundingRect.midX) < 0.01 && abs(big.boundingRect.midY) < 0.01)
        }
    }
}
