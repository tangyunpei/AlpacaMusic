import Foundation

/// One shaped grapheme. Singing progress retains the source schedule; letters
/// belonging to the same word share a separate appearance window.
struct LyricRevealUnit: Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
    var revealStart: Double
    var revealEnd: Double
    private var untimed: Bool

    init(text: String, start: Double, end: Double, untimed: Bool = false) {
        self.text = text; self.start = start; self.end = end; self.untimed = untimed
        revealStart = start; revealEnd = end
    }

    func progress(at position: Double) -> Double {
        if untimed { return 1 }
        guard position.isFinite, start.isFinite, end.isFinite, end >= start else { return 0 }
        guard position >= start else { return 0 }
        guard end > start else { return 1 }
        return min(1, max(0, (position - start) / (end - start)))
    }

    /// Words fade in together, even when a provider times individual syllables.
    /// CJK graphemes retain their individual appearance windows.
    func opacity(at position: Double, reduceMotion: Bool = false) -> Double {
        if untimed { return 1 }
        guard position.isFinite, revealStart.isFinite, revealEnd.isFinite, revealEnd >= revealStart,
              position >= revealStart else { return 0 }
        if reduceMotion || revealEnd == revealStart { return 1 }
        let duration = min(0.12, (revealEnd - revealStart) * 0.75)
        guard duration > 0 else { return 1 }
        let x = min(1, max(0, (position - revealStart) / duration))
        return x * x * (3 - 2 * x)
    }
}

struct LyricRevealTimeline: Equatable, Sendable {
    var units: [LyricRevealUnit]
    var isTimed: Bool
    var isEstimated: Bool

    /// Layout may insert/remove spaces or newlines. Non-whitespace graphemes
    /// must still match in order, including repeated words and punctuation.
    /// A mismatch returns no mapping, letting the caller show readable text.
    func fragments(_ texts: [String]) -> [[LyricRevealUnit]] {
        guard texts.count <= 2_048,
              texts.reduce(0, { $0 + $1.utf8.count }) <= 32_768 else { return [] }
        let source = units.filter { !$0.text.allSatisfy(\.isWhitespace) }
        var cursor = 0, result: [[LyricRevealUnit]] = []
        var count = 0
        for text in texts {
            var fragment: [LyricRevealUnit] = []
            for character in text {
                count += 1
                guard count <= 2_048 else { return [] }
                if character.isWhitespace {
                    let previous = cursor > 0 ? source[cursor - 1].end : nil
                    let next = cursor < source.count ? source[cursor].start : nil
                    let time = previous.map { min($0, next ?? $0) } ?? next ?? units.first?.start ?? 0
                    fragment.append(.init(text: String(character), start: time, end: time, untimed: !isTimed))
                } else {
                    guard cursor < source.count, source[cursor].text == String(character) else { return [] }
                    fragment.append(source[cursor]); cursor += 1
                }
            }
            result.append(fragment)
        }
        return cursor == source.count ? result : []
    }
}

/// A bounded shared schedule, cached separately from the immutable lyric model.
/// Provider onsets remain authoritative. Only subdivisions/line-only schedules
/// are estimates; no audio beat or precise vocal recognition is fabricated.
@MainActor enum LyricReveal {
    private struct Entry {
        var line: LyricLine
        var context: LyricTimingContext
        var timeline: LyricRevealTimeline
    }
    private static var cache: [Entry] = []
    private static let maximumCharacters = 1_024

    static func timeline(for line: LyricLine, context: LyricTimingContext = .init()) -> LyricRevealTimeline {
        // Oversized input remains readable in the caller's normal Text view,
        // without copying it into thousands of animated or cached units.
        guard line.text.utf8.count <= 16_384, line.words.count <= maximumCharacters,
              line.text.count <= maximumCharacters else { return .init(units: [], isTimed: false, isEstimated: false) }
        if let entry = cache.last, entry.line == line && entry.context == context { return entry.timeline }
        if let index = cache.lastIndex(where: { $0.line == line && $0.context == context }) {
            let entry = cache.remove(at: index); cache.append(entry); return entry.timeline
        }
        let result = synchronizingWords(in: makeTimeline(line, context: context))
        if cache.count >= 96 { cache.removeFirst() }
        cache.append(.init(line: line, context: context, timeline: result))
        return result
    }

    /// Work on the complete cue before layout or provider-fragment mapping, so
    /// a word split into syllables (or letters) still appears as one word. The
    /// original timing remains available for progress and local emphasis.
    private static func synchronizingWords(in timeline: LyricRevealTimeline) -> LyricRevealTimeline {
        guard timeline.isTimed else { return timeline }
        var result = timeline
        let texts = timeline.units.map(\.text)
        // Cased alphabets cover Latin (including accented/combining letters),
        // Greek and Cyrillic without combining adjacent Han/Kana/Hangul text.
        let letters = texts.map { $0.lowercased() != $0.uppercased() }
        let wordCharacters = zip(texts, letters).map { text, letter in
            letter || text.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
        }
        let joiners: Set<String> = ["'", "’", "ʼ", "-", "‐", "‑"]
        var cursor = 0
        while cursor < texts.count {
            guard wordCharacters[cursor] else { cursor += 1; continue }
            let beginning = cursor
            cursor += 1
            while cursor < texts.count {
                if wordCharacters[cursor] { cursor += 1 }
                else if joiners.contains(texts[cursor]), cursor + 1 < texts.count,
                        wordCharacters[cursor - 1], wordCharacters[cursor + 1] { cursor += 1 }
                else { break }
            }
            let range = beginning..<cursor
            guard range.count > 1, range.contains(where: { letters[$0] }) else { continue }
            let start = range.map { timeline.units[$0].start }.min() ?? 0
            let end = range.map { timeline.units[$0].end }.max() ?? start
            for index in range {
                result.units[index].revealStart = start
                result.units[index].revealEnd = end
            }
        }
        return result
    }

    private static func makeTimeline(_ line: LyricLine, context: LyricTimingContext) -> LyricRevealTimeline {
        let source = Array(line.text)
        func readable() -> LyricRevealTimeline {
            .init(units: source.map { .init(text: String($0), start: 0, end: 0, untimed: true) },
                  isTimed: false, isEstimated: false)
        }
        guard !source.isEmpty, let start = line.start, validTime(start) else { return readable() }
        if let end = line.end, !validTime(end) || end <= start || end - start > 120 { return readable() }
        if let supplied = suppliedTimeline(line, context: context) { return supplied }
        let duration = line.end.map { $0 - start } ?? conservativeDuration(line.text, maximum: 12)
        let end = start + duration
        guard validTime(end), end > start else { return readable() }
        let units = subdivide(line.text, start: start, end: end, context: context)
        return .init(units: units, isTimed: true, isEstimated: true)
    }

    private static func suppliedTimeline(_ line: LyricLine, context: LyricTimingContext) -> LyricRevealTimeline? {
        guard let start = line.start, !line.words.isEmpty,
              line.words.reduce(0, { $0 + $1.text.utf8.count }) <= 32_768,
              compact(line.words.map(\.text).joined()) == compact(line.text) else { return nil }
        let limit = line.end ?? min(86_400, start + 120)
        var previous = start
        for word in line.words {
            guard !word.text.isEmpty, word.text.count <= maximumCharacters,
                  validTime(word.start), word.start >= previous, word.start < limit else { return nil }
            if let end = word.end, !validTime(end) || end < word.start || end > limit { return nil }
            previous = word.start
        }
        var estimated = line.wordTimingOrigin == .audioEstimate
        var units: [LyricRevealUnit] = []
        for index in line.words.indices {
            let word = line.words[index]
            let next = line.words.indices.contains(index + 1) ? line.words[index + 1].start : nil
            let inferredEnd = next ?? line.end ?? min(limit, word.start + conservativeDuration(word.text, maximum: 2.4))
            let end = word.end ?? inferredEnd
            // Simultaneous/zero-duration tokens appear together without NaNs or
            // losing their supplied onset. Explicit pauses stay unallocated.
            guard end >= word.start else { return nil }
            let spokenCharacters = word.text.filter { !$0.isWhitespace }.count
            if spokenCharacters > 1 || (word.end == nil && next == nil && line.end == nil) { estimated = true }
            units += subdivide(word.text, start: word.start, end: end, context: context)
        }
        let supplied = LyricRevealTimeline(units: units, isTimed: true, isEstimated: estimated)
        guard let mapped = supplied.fragments([line.text]).first else { return nil }
        return .init(units: mapped, isTimed: true, isEstimated: estimated)
    }

    private static func subdivide(_ text: String, start: Double, end: Double, context: LyricTimingContext) -> [LyricRevealUnit] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        if characters.count == 1 { return [.init(text: String(characters[0]), start: start, end: end)] }
        guard end > start else { return characters.map { .init(text: String($0), start: start, end: start) } }
        let texts = characters.map(String.init)
        let schedule = LyricSingingTiming.schedule(text: text, duration: end - start, context: context)
        let timings = schedule?.characters ?? Array(repeating: nil, count: characters.count)
        var precedingEnd = start
        return characters.indices.map { index in
            if let window = timings[index] {
                let onset = min(end, max(start, start + window.startOffset))
                let ending = min(end, max(onset, start + window.endOffset))
                precedingEnd = ending
                return .init(text: texts[index], start: onset, end: ending)
            }
            // A held final vowel keeps its singing progress, but closing
            // punctuation must not wait for the instrumental/cue tail.
            let displayAt = min(precedingEnd, start + (schedule?.articulationEnd ?? end - start))
            return .init(text: texts[index], start: displayAt, end: displayAt)
        }
    }

    private static func conservativeDuration(_ text: String, maximum: Double) -> Double {
        let weight = LyricEmphasis.estimatedPronunciation(text)?.speech.reduce(0, +) ?? 0
        return min(maximum, max(1.2, weight * 0.32))
    }
    private static func validTime(_ value: Double) -> Bool { value.isFinite && value >= 0 && value <= 86_400 }
    private static func compact(_ text: String) -> String { String(text.filter { !$0.isWhitespace }) }
}
