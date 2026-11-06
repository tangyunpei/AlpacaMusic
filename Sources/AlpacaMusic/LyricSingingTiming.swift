import Foundation

/// A local text cadence, measured in seconds per pronunciation unit. This is a
/// visual estimate from nearby lyric timestamps, never an acoustic word clock.
struct LyricTimingContext: Hashable, Sendable {
    private(set) var secondsPerSyllable: Double?

    init(secondsPerSyllable: Double? = nil) {
        if let value = secondsPerSyllable, value.isFinite, value >= 0.10, value <= 1.10 {
            self.secondsPerSyllable = value
        } else { self.secondsPerSyllable = nil }
    }
}

/// Line-only cues (LRC, LRCLIB) say when a line starts, and usually end where
/// the next one starts. Measured against word-timed lyrics, singers spread a
/// line's syllables evenly, and a cue holds its sung units plus about two more
/// for the held last vowel and the breath. So the cue's own length sets its
/// pace, capped near the song's pace so that an instrumental gap cannot slow
/// its words. The final sung grapheme keeps the rest of the cue. Exact
/// provider timestamps are never replaced by this estimate.
@MainActor enum LyricSingingTiming {
    struct Schedule: Equatable, Sendable {
        var characters: [LyricAccentWindow?]
        var articulationEnd: Double
    }

    /// The held last syllable plus the breath after a line, in sung units.
    static let holdUnits = 2.0
    /// A phrase break inside a line: a punctuation run, or a space between two
    /// Chinese or Japanese phrases.
    static let phraseBreakUnits = 2.0
    /// A line is sung at most this much slower than the song's pace.
    private static let cadenceCap = 1.2
    /// Each pace is pulled a tenth of the way (in log terms) toward a typical
    /// 0.30 s per unit, which steadies very short or very long lines.
    private static let typicalPace = 0.30, paceExponent = 0.9
    private static let paceShrink = pow(typicalPace, 1 - paceExponent)
    /// The cap when a document has no usable lines to learn a pace from.
    private static let defaultCap = 0.55

    private struct ContextCue: Equatable {
        var text: String
        var start: Double?
        var end: Double?
        var words: [LyricWord]
    }
    private struct ContextEntry {
        var neighbors: [ContextCue]
        var wordCadence: Double?
    }
    private static var contexts: [ContextEntry] = []
    private struct SongCadence {
        var lines: [LyricLine]
        var value: Double?
    }
    private static var song: SongCadence?
    private static let songSampleLimit = 256

    /// Provider word onsets in up to eight neighbouring cues give a measured
    /// pace and take precedence. Otherwise the pace comes from the whole song.
    static func context(for index: Int, in lines: [LyricLine]) -> LyricTimingContext {
        guard lines.indices.contains(index) else { return .init() }
        let lower = max(0, index - 4), upper = min(lines.count - 1, index + 4)
        let neighbors = (lower...upper).filter { $0 != index }.map { lines[$0] }
        guard neighbors.allSatisfy({
            $0.text.utf8.count <= 16_384 && $0.text.count <= 1_024 && $0.words.count <= 1_024
                && $0.words.reduce(0, { $0 + $1.text.utf8.count }) <= 32_768
        }) else { return .init() }
        if let wordCadence = wordCadence(neighbors) { return .init(secondsPerSyllable: wordCadence) }
        return .init(secondsPerSyllable: songCadence(lines))
    }

    /// The lower median pace of supplied word onsets in the neighbouring cues,
    /// when at least three intervals qualify. Cached by those cues' content.
    private static func wordCadence(_ neighbors: [LyricLine]) -> Double? {
        // Store only bounded timing inputs; translations and the surrounding
        // document are irrelevant to cadence and never retained in the cache.
        let key = neighbors.map { ContextCue(text: $0.text, start: $0.start, end: $0.end, words: $0.words) }
        if let cached = contexts.last, cached.neighbors == key { return cached.wordCadence }
        if let cachedIndex = contexts.lastIndex(where: { $0.neighbors == key }) {
            let cached = contexts.remove(at: cachedIndex); contexts.append(cached); return cached.wordCadence
        }
        var wordRates: [Double] = []
        for line in neighbors where LyricEmphasis.hasUsableWordTiming(line) {
            guard line.text.utf8.count <= 16_384,
                  let allocation = LyricEmphasis.estimatedPronunciation(line.text),
                  allocation.speech.reduce(0, +) >= 3 else { continue }
            for wordIndex in line.words.indices.dropLast() {
                let word = line.words[wordIndex]
                let next = line.words[wordIndex + 1]
                let tokenWeight = LyricEmphasis.estimatedPronunciation(word.text)?.speech.reduce(0, +) ?? 0
                // An explicit silence is not a pronunciation interval.
                let gap = word.end.map { next.start - $0 } ?? 0
                let duration = next.start - word.start
                guard tokenWeight > 0, gap <= 0.20, duration > 0,
                      duration <= max(1.4, tokenWeight * 1.25) else { continue }
                let rate = duration / tokenWeight
                if rate >= 0.10, rate <= 1.10 { wordRates.append(rate) }
            }
        }
        // The lower median resists a neighbouring sustain without selecting the
        // fastest isolated cue. Quantization gives stable bounded cache keys.
        let value = wordRates.count >= 3 ? quantized(lowerMedian(wordRates)) : nil
        if contexts.count >= 96 { contexts.removeFirst() }
        contexts.append(.init(neighbors: key, wordCadence: value))
        return value
    }

    /// The song's pace: the lower median, over every line of the document, of
    /// its cue length divided by its sung units plus the final hold. Lines that
    /// are very sparse (instrumental rests) or very dense are left out. One
    /// entry is cached; the same lines array is recognised without a scan, and
    /// an equal copy is adopted so later frames take that path too. Documents
    /// longer than a song (long subtitle files) are sampled evenly, so the first
    /// frame never analyses more than `songSampleLimit` lines.
    static func songCadence(_ lines: [LyricLine]) -> Double? {
        if let song, song.lines.count == lines.count,
           song.lines == lines
            || zip(song.lines, lines).allSatisfy({ $0.text == $1.text && $0.start == $1.start && $0.end == $1.end }) {
            self.song?.lines = lines
            return song.value
        }
        var paces: [Double] = []
        let stride = max(1, (lines.count + songSampleLimit - 1) / songSampleLimit)
        for line in Swift.stride(from: 0, to: lines.count, by: stride).map({ lines[$0] }) {
            guard line.text.utf8.count <= 16_384, line.text.count <= 1_024,
                  let allocation = LyricEmphasis.cadenceAllocation(line.text),
                  let start = line.start, let end = line.end, start.isFinite, end.isFinite,
                  start >= 0, end > start, end - start <= 30 else { continue }
            let weight = allocation.speech.reduce(0, +), duration = end - start
            guard weight >= 3, (0.12...1.25).contains(duration / weight) else { continue }
            paces.append(min(1.10, duration / (weight + holdUnits)))
        }
        let value = paces.isEmpty ? nil : quantized(lowerMedian(paces))
        song = .init(lines: lines, value: value)
        return value
    }

    private static func lowerMedian(_ values: [Double]) -> Double {
        let sorted = values.sorted(); return sorted[(sorted.count - 1) / 2]
    }
    private static func quantized(_ rate: Double) -> Double { (max(0.10, min(1.10, rate)) * 1_000).rounded() / 1_000 }

    /// Seconds per sung unit for a whole cue of `units` sung units and interior
    /// breaks. Its own length (plus the final hold) sets the pace, capped
    /// relative to the song, and the units always fit inside the cue.
    private static func pace(duration: Double, units: Double, context: LyricTimingContext) -> Double {
        let reference = LyricTimingContext(secondsPerSyllable: context.secondsPerSyllable).secondsPerSyllable
        let cap = reference.map { cadenceCap * $0 } ?? defaultCap
        let rate = paceShrink * pow(min(duration / (units + holdUnits), cap), paceExponent)
        return min(rate, duration / units)
    }

    /// A whole line-only cue: syllables evenly spaced at the cue's pace, with
    /// phrase breaks, and the last sung grapheme holding to the cue end.
    static func schedule(text: String, duration: Double,
                         context: LyricTimingContext = .init()) -> Schedule? {
        guard duration.isFinite, duration > 0, duration <= 120,
              let allocation = LyricEmphasis.cadenceAllocation(text) else { return nil }
        let speech = allocation.speech, breaks = allocation.breaks
        let weight = speech.reduce(0, +)
        guard weight.isFinite, weight > 0,
              let lastSpoken = speech.lastIndex(where: { $0 > 0 }) else { return nil }
        // Marks after the last syllable cost no time.
        let units = weight + breaks[..<lastSpoken].reduce(0, +)
        let rate = pace(duration: duration, units: units, context: context)
        let articulation = min(duration, units * rate)
        var elapsed = 0.0
        var windows = Array<LyricAccentWindow?>(repeating: nil, count: speech.count)
        var sung: LyricAccentWindow?
        for index in speech.indices {
            let end = min(articulation, elapsed + speech[index] * rate)
            if speech[index] > 0 {
                windows[index] = .init(startOffset: elapsed,
                                      endOffset: index == lastSpoken ? duration : end)
                sung = windows[index]
            } else if allocation.attached[index], let sung {
                // Sung together with the unit before it (きゃ): same window, no slot.
                windows[index] = sung
            }
            elapsed = min(articulation, end + breaks[index] * rate)
        }
        return .init(characters: windows, articulationEnd: articulation)
    }

    /// A cue without an end (the document's last line) lasts as long as its
    /// units and the final hold take at the song's pace, within 1.2–12 s.
    static func openCueDuration(_ text: String, context: LyricTimingContext) -> Double {
        guard let allocation = LyricEmphasis.cadenceAllocation(text),
              let lastSpoken = allocation.speech.lastIndex(where: { $0 > 0 }) else { return 1.2 }
        let units = allocation.speech.reduce(0, +) + allocation.breaks[..<lastSpoken].reduce(0, +) + holdUnits
        let pace = LyricTimingContext(secondsPerSyllable: context.secondsPerSyllable).secondsPerSyllable ?? typicalPace
        return min(12, max(1.2, units * pace))
    }

    /// Inside one provider-timed word: articulation runs at the context pace
    /// within the word's supplied window, and the last grapheme keeps the rest.
    static func wordSchedule(text: String, duration: Double,
                         context: LyricTimingContext = .init()) -> Schedule? {
        guard duration.isFinite, duration > 0, duration <= 120,
              let allocation = LyricEmphasis.estimatedPronunciation(text) else { return nil }
        let speech = allocation.speech, pauses = allocation.pauses
        let weight = speech.reduce(0, +), pauseWeight = pauses.reduce(0, +)
        guard weight.isFinite, weight > 0,
              let lastSpoken = speech.lastIndex(where: { $0 > 0 }) else { return nil }
        let rate = LyricTimingContext(secondsPerSyllable: context.secondsPerSyllable).secondsPerSyllable ?? 0.55
        let nominal = weight * rate
        let articulation = min(duration, nominal)
        // Punctuation inside the phrase has a small capped budget; a comma or
        // ellipsis cannot make every preceding character wait for a long tail.
        let pauseSeconds = pauseWeight > 0 ? min(0.65, articulation * 0.12,
                                                articulation * pauseWeight / (weight + pauseWeight)) : 0
        let speechScale = (articulation - pauseSeconds) / weight
        let pauseScale = pauseWeight > 0 ? pauseSeconds / pauseWeight : 0
        var elapsed = 0.0
        var windows = Array<LyricAccentWindow?>(repeating: nil, count: speech.count)
        var sung: LyricAccentWindow?
        for index in speech.indices {
            let end = min(articulation, elapsed + speech[index] * speechScale)
            if speech[index] > 0 {
                windows[index] = .init(startOffset: elapsed,
                                      endOffset: index == lastSpoken ? duration : end)
                sung = windows[index]
            } else if allocation.attached[index], let sung {
                // Sung together with the unit before it (きゃ): same window, no slot.
                windows[index] = sung
            }
            elapsed = min(articulation, end + pauses[index] * pauseScale)
        }
        return .init(characters: windows, articulationEnd: articulation)
    }

    /// Map by source character position rather than substring search, retaining
    /// repeated words and pronunciation windows after viewport wrapping.
    static func windows(texts: [String], line: LyricLine,
                        context: LyricTimingContext = .init()) -> [Int: LyricAccentWindow]? {
        guard let start = line.start, let end = line.end,
              start.isFinite, end.isFinite, start >= 0, end > start,
              let schedule = schedule(text: line.text, duration: end - start, context: context) else { return nil }
        let source = Array(line.text)
        let sourcePositions = source.indices.filter { !source[$0].isWhitespace }
        var cursor = 0, result: [Int: LyricAccentWindow] = [:]
        for (index, text) in texts.enumerated() {
            let characters = Array(text.filter { !$0.isWhitespace })
            let ending = cursor + characters.count
            guard ending <= sourcePositions.count,
                  zip(characters, sourcePositions[cursor..<ending]).allSatisfy({ $0 == source[$1] }) else { return nil }
            let spoken = sourcePositions[cursor..<ending].compactMap { schedule.characters[$0] }
            if let first = spoken.first, let last = spoken.last {
                result[index] = .init(startOffset: first.startOffset, endOffset: last.endOffset)
            }
            cursor = ending
        }
        return cursor == sourcePositions.count ? result : nil
    }
}
