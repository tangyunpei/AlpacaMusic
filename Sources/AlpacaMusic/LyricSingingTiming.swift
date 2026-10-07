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

/// Separate articulation from the remaining cue. LRC usually closes a line at
/// the next line's onset: stretching every syllable over that interval delays
/// words before a held last vowel or an instrumental gap. The final spoken
/// grapheme retains the cue's tail, while preceding onsets use a bounded local
/// cadence. Exact provider timestamps are never replaced by this estimate.
@MainActor enum LyricSingingTiming {
    struct Schedule: Equatable, Sendable {
        var characters: [LyricAccentWindow?]
        var articulationEnd: Double
    }

    private struct ContextCue: Equatable {
        var text: String
        var start: Double?
        var end: Double?
        var words: [LyricWord]
    }
    private struct ContextEntry {
        var neighbors: [ContextCue]
        var context: LyricTimingContext
    }
    private static var contexts: [ContextEntry] = []

    /// Work is bounded to eight neighboring cues and cached by source content.
    /// The cue being displayed never teaches its own unusually long tail back
    /// into its cadence. Provider onsets take precedence over line densities.
    static func context(for index: Int, in lines: [LyricLine]) -> LyricTimingContext {
        guard lines.indices.contains(index) else { return .init() }
        let lower = max(0, index - 4), upper = min(lines.count - 1, index + 4)
        let neighbors = (lower...upper).filter { $0 != index }.map { lines[$0] }
        guard neighbors.allSatisfy({
            $0.text.utf8.count <= 16_384 && $0.text.count <= 1_024 && $0.words.count <= 1_024
                && $0.words.reduce(0, { $0 + $1.text.utf8.count }) <= 32_768
        }) else { return .init() }
        // Store only bounded timing inputs; translations and the surrounding
        // document are irrelevant to cadence and never retained in the cache.
        let key = neighbors.map { ContextCue(text: $0.text, start: $0.start, end: $0.end, words: $0.words) }
        if let cached = contexts.last, cached.neighbors == key { return cached.context }
        if let cachedIndex = contexts.lastIndex(where: { $0.neighbors == key }) {
            let cached = contexts.remove(at: cachedIndex); contexts.append(cached); return cached.context
        }
        var wordRates: [Double] = [], lineRates: [Double] = []
        for line in neighbors {
            guard line.text.utf8.count <= 16_384,
                  let allocation = LyricEmphasis.estimatedPronunciation(line.text) else { continue }
            let weight = allocation.speech.reduce(0, +)
            guard weight >= 3 else { continue }
            if LyricEmphasis.hasUsableWordTiming(line) {
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
            guard let start = line.start, let end = line.end, start.isFinite, end.isFinite,
                  start >= 0, end > start, end - start <= 30 else { continue }
            let rate = (end - start) / weight
            // Very sparse lines commonly include instrumental rests. They
            // remain displayed normally but cannot slow neighboring reveals.
            if rate >= 0.12, rate <= 1.25 {
                lineRates.append(min(1.10, rate * 0.86))
            }
        }
        let rates = wordRates.count >= 3 ? wordRates : lineRates
        let sorted = rates.sorted()
        // The lower median resists a neighboring sustain without selecting the
        // fastest isolated cue. Quantization gives stable bounded cache keys.
        let result: LyricTimingContext
        if sorted.isEmpty { result = .init() }
        else {
            let rate = sorted[(sorted.count - 1) / 2]
            result = .init(secondsPerSyllable: (max(0.10, min(1.10, rate)) * 1_000).rounded() / 1_000)
        }
        if contexts.count >= 96 { contexts.removeFirst() }
        contexts.append(.init(neighbors: key, context: result))
        return result
    }

    static func schedule(text: String, duration: Double,
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
        for index in speech.indices {
            let end = min(articulation, elapsed + speech[index] * speechScale)
            if speech[index] > 0 {
                windows[index] = .init(startOffset: elapsed,
                                      endOffset: index == lastSpoken ? duration : end)
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
