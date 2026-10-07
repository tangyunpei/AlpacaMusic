import SwiftUI

/// Keep the complete text in the layout while changing only its ink. Reading
/// rows can wrap naturally without jumping as the next character is sung.
struct LyricProgressText: View {
    @Environment(\.appPalette) private var palette
    enum Appearance { case highlight, reveal }
    var line: LyricLine
    var text: String
    var position: Double
    var appearance: Appearance = .highlight
    var reduceMotion = false
    var timingContext: LyricTimingContext = .init()

    var body: some View {
        Text(attributedText)
            .accessibilityLabel(line.text)
    }

    private var attributedText: AttributedString {
        let timeline = LyricReveal.timeline(for: line, context: timingContext)
        guard timeline.isTimed, position.isFinite,
              let units = timeline.fragments([text]).first,
              units.count == text.count else {
            var result = AttributedString(text)
            result.foregroundColor = palette.text
            return result
        }
        var result = AttributedString()
        for unit in units {
            let reveal = unit.opacity(at: position, reduceMotion: reduceMotion)
            var glyph = AttributedString(unit.text)
            switch appearance {
            case .highlight:
                // Unsung words remain available for reading; only the sung
                // word (or CJK character) lights up, following playback time.
                glyph.foregroundColor = palette.text.opacity(0.25 + reveal * 0.75)
            case .reveal:
                glyph.foregroundColor = palette.text.opacity(reveal)
            }
            result.append(glyph)
        }
        return result
    }
}

/// A short interpolation between authoritative player updates. It is bounded
/// by the current cue and resets immediately on seeks or source changes.
struct LyricPlaybackProjection {
    static func position(_ position: Double, anchoredAt date: Date, now: Date,
                         cueEnd: Double?) -> Double {
        guard position.isFinite else { return 0 }
        let elapsed = min(0.18, max(0, now.timeIntervalSince(date)))
        let projected = position + elapsed
        guard let cueEnd, cueEnd.isFinite else { return projected }
        return min(projected, max(position, cueEnd - 0.001))
    }
}
