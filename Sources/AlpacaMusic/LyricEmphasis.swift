import Foundation
import NaturalLanguage

enum LyricAccentKind: Int, CaseIterable, Equatable, Sendable { case ring, box, flash, weight, pulse, triangle }
enum LyricAccentReason: Equatable, Sendable { case typography, estimatedWord, wordOnset, sustain, pause }
/// Relative visual allocation derived from a closed, line-only lyric cue.
/// It never becomes provider word timing or changes the original lyric model.
struct LyricAccentWindow: Equatable, Sendable {
    var startOffset: Double
    var endOffset: Double
}
struct LyricAccentChoice: Equatable, Sendable {
    var kind: LyricAccentKind
    var reason: LyricAccentReason
    /// An editorial delay is visual choreography, never an inferred word time.
    var delay: Double = 0
    var direction: Double = 1
    var window: LyricAccentWindow? = nil
}
/// One complete visual event. Cue and word endings identify vocal timing;
/// they do not shorten a gesture that has already begun.
struct LyricAccentEventInterval: Equatable, Sendable {
    var start: Double
    var end: Double
    var singingEnd: Double
    var held: Bool
}
struct LyricAccentState: Equatable, Sendable {
    var kind: LyricAccentKind
    var intensity: Double
    var progress: Double
    var weightBoost: Double
    /// Local offsets are fractions of the fragment's font size.
    var offsetX: Double = 0
    var offsetY: Double = 0
    var scaleX: Double = 1
    var scaleY: Double = 1
    var rotation: Double = 0
    var trail: Double = 0
}

/// Sparse editorial accents. A supplied long duration or gap is useful visual
/// metadata, but neither is a claim that vocal stress has been recognized.
/// Every envelope is reconstructed from playback position, never frame history.
@MainActor enum LyricEmphasis {
    private static let joining = Set<Character>("-'’‐‑")
    private static let englishFunctionWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "nor", "so", "yet", "if", "then", "than", "that", "this", "these", "those",
        "i", "me", "my", "mine", "we", "us", "our", "ours", "you", "your", "yours", "he", "him", "his", "she", "her", "hers", "it", "its", "they", "them", "their", "theirs",
        "to", "of", "for", "at", "by", "in", "on", "from", "with", "as", "into", "onto", "beside", "near", "under", "over", "above", "below", "through", "between", "until", "after", "before", "is", "am", "are", "was", "were", "be", "been", "being",
        "do", "does", "did", "have", "has", "had", "can", "could", "will", "would", "shall", "should", "may", "might", "must", "not", "no", "also",
        "i'm", "i’ve", "i've", "i’ll", "i'll", "you're", "you’re", "we're", "we’re", "it's", "it’s", "don't", "don’t", "doesn't", "doesn’t", "isn't", "isn’t"
    ]
    private static let chineseFunctionWords: Set<String> = [
        "的", "地", "得", "了", "着", "著", "过", "過", "吗", "嗎", "呢", "吧", "啊", "呀", "哦", "喔", "啦",
        "我", "你", "您", "他", "她", "它", "我们", "我們", "你们", "你們", "他们", "他們", "自己",
        "这", "這", "那", "这些", "這些", "那些", "是", "有", "在", "把", "被", "对", "對", "向", "从", "從", "和", "与", "與", "或", "而", "但", "却", "卻", "及", "为", "為", "让", "讓", "将", "將",
        "都", "也", "就", "还", "還", "又", "才", "很", "更", "最", "不", "没", "沒", "没有", "沒有", "能", "会", "會", "可以", "应该", "應該", "已经", "已經", "正在", "因为", "因為", "所以", "如果", "然后", "然後"
    ]

    /// Word units and the intervening punctuation/whitespace are separate.
    /// The joined result is byte-for-byte the original text, including emoji
    /// graphemes, combining marks and provider-authored spacing.
    static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        guard text.utf8.count <= 16_384 else { return [text] }
        let characters = Array(text)
        guard characters.count <= 1_024 else { return [text] }
        let indices = Array(text.indices) + [text.endIndex]
        let offsets = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($0.element, $0.offset) })
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var ranges: [Range<Int>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            guard ranges.count < 256 else { return false }
            if let lower = offsets[range.lowerBound], let upper = offsets[range.upperBound], lower < upper {
                if let preceding = ranges.last,
                   isLatinWordEdge(characters[preceding.upperBound - 1]), isLatinWordEdge(characters[lower]),
                   lower >= preceding.upperBound,
                   characters[preceding.upperBound..<lower].allSatisfy({ joining.contains($0) }) {
                    ranges[ranges.count - 1] = preceding.lowerBound..<upper
                } else { ranges.append(lower..<upper) }
            }
            return true
        }
        guard ranges.count < 256 else { return [text] }
        var pieces: [String] = []
        func appendGap(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            var beginning = range.lowerBound
            for offset in range.dropFirst() {
                if gapClass(characters[offset]) != gapClass(characters[offset - 1]) {
                    pieces.append(String(text[indices[beginning]..<indices[offset]])); beginning = offset
                }
            }
            pieces.append(String(text[indices[beginning]..<indices[range.upperBound]]))
        }
        var cursor = 0
        for range in ranges {
            guard range.lowerBound >= cursor else { continue }
            appendGap(cursor..<range.lowerBound)
            pieces.append(String(text[indices[range.lowerBound]..<indices[range.upperBound]]))
            cursor = range.upperBound
        }
        appendGap(cursor..<characters.count)
        return pieces
    }

    /// The last cue may legitimately have no end. Its supplied word onsets
    /// remain usable, with a bounded window for conservative visual cleanup.
    static func hasUsableWordTiming(_ line: LyricLine) -> Bool {
        guard let start = line.start, start.isFinite, start >= 0,
              !line.words.isEmpty, line.words.count <= 48,
              removingWhitespace(line.words.map(\.text).joined()) == removingWhitespace(line.text) else { return false }
        let limit: Double
        if let end = line.end {
            guard end.isFinite, end > start else { return false }
            limit = end
        } else {
            limit = start + 120
            guard limit.isFinite, limit > start else { return false }
        }
        var preceding = -Double.infinity
        var hasPositiveInterval = false
        for index in line.words.indices {
            let word = line.words[index]
            guard !word.text.isEmpty, word.start.isFinite, word.start >= start,
                  word.start < limit, word.start >= preceding else { return false }
            let nextStart = line.words.indices.contains(index + 1) ? line.words[index + 1].start : limit
            if let end = word.end {
                guard end.isFinite, end >= word.start, end <= limit,
                      nextStart.isFinite, end <= nextStart + 0.000_001 else { return false }
            }
            if (word.end ?? nextStart) > word.start { hasPositiveInterval = true }
            preceding = word.start
        }
        return hasPositiveInterval
    }

    /// Cheap UI eligibility check. Pronunciation/token scheduling happens only
    /// when the cached stage plan is made, never during the animation loop.
    static func usesEstimatedTiming(_ line: LyricLine) -> Bool {
        guard !hasUsableWordTiming(line), closedCueWindow(line) != nil,
              !line.text.isEmpty, line.text.utf8.count <= 16_384,
              line.text.count <= 1_024 else { return false }
        return line.text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    /// Select at most two content units. The choice is stable across redraws,
    /// launches and backward seeks; audio cannot change the selected words.
    static func choices(texts: [String], line: LyricLine, suppliedWordTiming: Bool, seed: UInt64) -> [Int: LyricAccentChoice] {
        guard texts.count <= 256, !texts.isEmpty, line.text.utf8.count <= 16_384,
              removingWhitespace(texts.joined()) == removingWhitespace(line.text) else { return [:] }
        let timed = suppliedWordTiming && hasUsableWordTiming(line)
            && texts == line.words.map(\.text)
        let estimated = timed ? nil : estimatedWindows(texts: texts, line: line)
        guard timed || estimated != nil else { return [:] }
        let explicitDurations = timed ? line.words.compactMap { word in
            word.end.flatMap { $0 > word.start ? $0 - word.start : nil }
        }.sorted() : []
        let median = explicitDurations.isEmpty ? 0 : explicitDurations[explicitDurations.count / 2]
        struct Candidate { var index: Int; var score: Double; var hash: UInt64; var reason: LyricAccentReason }
        var candidates: [Candidate] = []
        for index in texts.indices where eligible(texts[index]) {
            let hash = stableHash(texts[index], index: index, seed: seed)
            if timed, let end = wordWindow(line: line, index: index)?.singingEnd,
               end <= line.words[index].start { continue }
            if timed, wordWindow(line: line, index: index) == nil { continue }
            if !timed, estimated?[index] == nil { continue }
            var reason: LyricAccentReason = timed ? .wordOnset : .estimatedWord
            var score = Double(hash % 1_000) / 1_000 + min(0.4, Double(texts[index].count) * 0.025)
            if timed, let end = line.words[index].end {
                let duration = end - line.words[index].start
                if duration >= max(0.55, median * 1.65) {
                    reason = .sustain; score += 4 + min(2, duration) * 0.15
                } else if line.words.indices.contains(index + 1), line.words[index + 1].start - end >= 0.24 {
                    reason = .pause; score += 3 + min(2, line.words[index + 1].start - end) * 0.15
                }
            }
            candidates.append(.init(index: index, score: score, hash: hash, reason: reason))
        }
        candidates.sort { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        let duration = cueWindow(line)?.duration ?? 0
        let count = duration < (timed ? 1.1 : 1.8) ? 1 : 2
        return Dictionary(uniqueKeysWithValues: candidates.prefix(count).map { candidate in
            let kind: LyricAccentKind
            switch candidate.reason {
            case .pause: kind = candidate.hash.isMultiple(of: 2) ? .ring : .box
            case .sustain: kind = candidate.hash.isMultiple(of: 2) ? .weight : .pulse
            case .wordOnset, .estimatedWord, .typography: kind = LyricAccentKind.allCases[Int(candidate.hash % UInt64(LyricAccentKind.allCases.count))]
            }
            let direction = candidate.hash.isMultiple(of: 2) ? 1.0 : -1.0
            return (candidate.index, .init(kind: kind, reason: candidate.reason, direction: direction,
                                          window: estimated?[candidate.index]))
        })
    }

    /// An onset always belongs to its original cue. Once triggered, the event
    /// receives its full natural duration even if another lyric cue begins.
    /// This upper bound lets the stage reconstruct live tails without history.
    static let maximumTailDuration = 1.28

    static func eventInterval(choice: LyricAccentChoice, line: LyricLine,
                              unitIndex: Int) -> LyricAccentEventInterval? {
        guard unitIndex >= 0, let cue = cueWindow(line) else { return nil }
        let naturalDuration = eventDuration(choice.kind)
        var start = cue.start + bounded(choice.delay, lower: 0, upper: 1.4)
        var singingEnd = cue.end
        var effectEnd = start + naturalDuration
        var held = false
        let estimated = choice.reason == .estimatedWord
        let timed = choice.reason != .typography && !estimated
        if estimated {
            guard usesEstimatedTiming(line), let window = choice.window,
                  window.startOffset.isFinite, window.endOffset.isFinite,
                  window.startOffset >= 0, window.endOffset > window.startOffset,
                  window.endOffset <= cue.duration else { return nil }
            start = cue.start + window.startOffset
            singingEnd = cue.start + window.endOffset
            effectEnd = start + naturalDuration
        }
        if timed {
            guard hasUsableWordTiming(line), line.words.indices.contains(unitIndex),
                  let window = wordWindow(line: line, index: unitIndex) else { return nil }
            let word = line.words[unitIndex]
            if choice.reason == .pause || choice.reason == .sustain {
                guard word.end != nil else { return nil }
            }
            start = window.start
            singingEnd = window.singingEnd
            if choice.reason == .sustain && (choice.kind == .weight || choice.kind == .pulse) {
                // A supplied hold can prolong presentation. A short word gets
                // the same complete cycle as an ordinary onset event.
                held = singingEnd - start >= naturalDuration
                effectEnd = max(start + naturalDuration, singingEnd + 0.34)
            } else {
                effectEnd = start + naturalDuration
            }
        }
        guard start.isFinite, start >= cue.start, start < cue.end,
              effectEnd.isFinite, effectEnd > start else { return nil }
        return .init(start: start, end: effectEnd, singingEnd: singingEnd, held: held)
    }

    static func state(choice: LyricAccentChoice, line: LyricLine, unitIndex: Int, position: Double,
                      audio: VisualizationAudio = .init(), reduceMotion: Bool = false) -> LyricAccentState? {
        guard !reduceMotion, position.isFinite,
              let interval = eventInterval(choice: choice, line: line, unitIndex: unitIndex),
              position >= interval.start, position < interval.end else { return nil }
        let start = interval.start, effectEnd = interval.end, singingEnd = interval.singingEnd
        let held = interval.held
        let naturalDuration = eventDuration(choice.kind)
        let estimated = choice.reason == .estimatedWord
        let timed = choice.reason != .typography && !estimated
        let synchronized = timed || estimated
        let age = position - start
        let duration = effectEnd - start
        let motionDuration = held ? min(naturalDuration, duration) : duration
        let u = clamp(age / max(0.001, motionDuration))
        let release = smooth((effectEnd - position) / min(0.34, max(0.025, duration * 0.28)))
        let preparation = synchronized ? 0 : -0.25 * bump(u, center: 0.045, width: 0.04)
        let strikeSeconds = choice.kind == .flash ? 0.045 : (choice.kind == .box ? 0.065 : (choice.kind == .triangle ? 0.060 : 0.055))
        let strikeAt = synchronized ? min(0.24, strikeSeconds / max(0.001, motionDuration))
            : (choice.kind == .flash ? 0.13 : (choice.kind == .box ? 0.20 : 0.17))
        let recovery = max(0, u - strikeAt) / (1 - strikeAt)
        // Two damped lobes after the strike produce recoil and settle. A
        // compact preparation moves the word against its coming gesture.
        let elastic = u < strikeAt ? smooth(u / strikeAt)
            : exp(-5.4 * recovery) * cos(3.8 * .pi * recovery)
        let tailGate = 1 - smooth((u - 0.76) / 0.24)
        let strikeWidth = synchronized ? min(0.2, 0.045 / max(0.001, motionDuration))
            : (choice.kind == .flash ? 0.11 : 0.16)
        let strike = bump(u, center: strikeAt, width: strikeWidth)
        let rebound = bump(u, center: strikeAt + 0.37, width: 0.18)
        let attackAt = synchronized ? min(0.08, 0.025 / max(0.001, motionDuration)) : 0.06
        let attack = smooth(u / attackAt)
        let holdProgress = clamp(age / max(0.001, singingEnd - start))
        let holdLift = held ? smooth(age / min(0.055, max(0.012, duration * 0.2)))
            * (0.58 + 0.20 * sin(.pi * holdProgress)) * release : 0
        let gesture = bounded((held ? elastic * tailGate * 0.55 + holdLift * 0.5
                              : (elastic + preparation) * tailGate) * release, lower: -0.45, upper: 1)
        // Ink has its own one-way lifecycle: draw completely, present the
        // complete shape, then erase/release once. Recoil never rewinds it.
        let drawAt = synchronized ? min(0.2, 0.075 / max(0.001, motionDuration)) : 0.19
        let finishAt = min(0.60, max(drawAt + 0.04, 0.32 / max(0.001, motionDuration)))
        let progress = clamp(0.82 * smooth(u / drawAt) + 0.18 * smooth((u - drawAt) / max(0.001, finishAt - drawAt)))
        let presentationEnd = held ? max(motionDuration * finishAt, singingEnd - start)
            : max(motionDuration * finishAt, motionDuration * 0.60)
        let trail = smooth((age - presentationEnd) / max(0.001, duration - presentationEnd))
        let trace = attack * (1 - trail) * release
        // Beat input is measured PCM energy only, and is gated to the actual
        // supplied word window. Untimed type never pretends to follow singing.
        let beat = timed && position < singingEnd && audio.available ? clamp(audio.beat) * 0.12 : 0
        // A quieter presentation keeps each finished mark legible after the
        // strike. Real sustained words continue to follow their supplied hold.
        let amplitude = choice.kind == .flash ? strike * 0.87 + rebound * 0.18 + trace * 0.14
            : ((choice.kind == .ring || choice.kind == .box || choice.kind == .triangle) ? trace * 0.62 + strike * 0.24
               : strike * 0.78 + rebound * 0.18 + holdLift * 0.54 + (held ? 0 : trace * 0.36))
        let intensity = clamp((amplitude + beat * (held ? holdLift : tailGate)) * attack * release)
        let boost = choice.kind == .weight ? intensity * 0.7 : intensity * (choice.kind == .pulse ? 0.22 : 0.28)
        let direction = choice.direction.isFinite && choice.direction < 0 ? -1.0 : 1.0
        var x = 0.0, y = 0.0, sx = 1.0, sy = 1.0, rotation = 0.0
        switch choice.kind {
        case .ring:
            x = direction * 0.018 * gesture; y = -0.075 * gesture
            sx += 0.04 * gesture; sy += 0.025 * gesture; rotation = direction * 2.1 * gesture
        case .box:
            x = direction * 0.025 * gesture; y = 0.014 * gesture
            sx += 0.065 * gesture; sy -= 0.06 * gesture; rotation = direction * 0.8 * gesture
        case .flash:
            x = direction * 0.05 * gesture; y = -0.02 * gesture
            sx += 0.025 * gesture; sy += 0.018 * gesture; rotation = direction * 1.4 * gesture
        case .weight:
            y = -0.09 * gesture; sx += 0.022 * gesture; sy += 0.04 * gesture
            rotation = direction * 1.1 * gesture
        case .pulse:
            y = -0.035 * gesture; sx += 0.075 * gesture; sy += 0.06 * gesture
            rotation = direction * 0.7 * gesture
        case .triangle:
            // An angular contour gets a stronger diagonal word nudge, with
            // the same bounded recovery and unchanged natural glyph size.
            x = direction * 0.04 * gesture; y = -0.055 * gesture
            sx += 0.06 * gesture; sy += 0.035 * gesture
            rotation = direction * 2.6 * gesture
        }
        return .init(kind: choice.kind, intensity: intensity, progress: progress, weightBoost: clamp(boost),
                     offsetX: bounded(x, lower: -0.06, upper: 0.06), offsetY: bounded(y, lower: -0.09, upper: 0.09),
                     scaleX: bounded(sx, lower: 0.92, upper: 1.08), scaleY: bounded(sy, lower: 0.92, upper: 1.08),
                     rotation: bounded(rotation, lower: -3, upper: 3), trail: trail)
    }

    private static func cueWindow(_ line: LyricLine) -> (start: Double, end: Double, duration: Double)? {
        guard let start = line.start, start.isFinite, start >= 0 else { return nil }
        let end: Double
        if let explicitEnd = line.end {
            guard explicitEnd.isFinite, explicitEnd > start else { return nil }
            end = explicitEnd
        } else {
            let lastStart = line.words.last.map(\.start).flatMap { $0.isFinite ? $0 : nil } ?? start
            let lastEnd = line.words.compactMap(\.end).filter(\.isFinite).max() ?? start
            end = min(start + 120, max(start + 6, lastStart + 1.2, lastEnd))
        }
        guard end.isFinite, end > start else { return nil }
        return (start, end, end - start)
    }

    private static func closedCueWindow(_ line: LyricLine) -> (start: Double, end: Double, duration: Double)? {
        guard let start = line.start, let end = line.end,
              start.isFinite, end.isFinite, start >= 0, end > start,
              end - start <= 120 else { return nil }
        return (start, end, end - start)
    }

    private static func wordWindow(line: LyricLine, index: Int) -> (start: Double, singingEnd: Double, next: Double)? {
        guard let cue = cueWindow(line), line.words.indices.contains(index) else { return nil }
        let word = line.words[index]
        let next = line.words.indices.contains(index + 1) ? line.words[index + 1].start : cue.end
        let end = word.end ?? next
        guard next.isFinite, end.isFinite, end > word.start, next > word.start else { return nil }
        return (word.start, end, next)
    }

    /// Pronunciation is estimated over the complete source text, before row
    /// wrapping. Function words consume time too. Source-character offsets keep
    /// repeated words and viewport-dependent fragment boundaries unambiguous.
    static func estimatedWindows(texts: [String], line: LyricLine) -> [Int: LyricAccentWindow]? {
        guard usesEstimatedTiming(line), let cue = closedCueWindow(line) else { return nil }
        let source = Array(line.text)
        guard !source.isEmpty, source.count <= 1_024 else { return nil }
        let sourcePositions = source.indices.filter { !source[$0].isWhitespace }
        guard let allocation = estimatedPronunciation(line.text) else { return nil }
        let speech = allocation.speech, pauses = allocation.pauses
        let spokenWeight = speech.reduce(0, +), pauseWeight = pauses.reduce(0, +)
        guard spokenWeight.isFinite, spokenWeight > 0 else { return nil }
        // A next line's onset does not reveal the preceding vocal offset. We
        // distribute the known cue only; punctuation receives at most 14% or
        // 0.9 seconds, without inventing a tempo or an acoustic pause detector.
        let pauseSeconds = pauseWeight > 0 ? min(0.9, cue.duration * 0.14,
                                               cue.duration * pauseWeight / (spokenWeight + pauseWeight)) : 0
        let speechScale = (cue.duration - pauseSeconds) / spokenWeight
        let pauseScale = pauseWeight > 0 ? pauseSeconds / pauseWeight : 0
        var offsets = [0.0]
        for index in source.indices {
            offsets.append(offsets[index] + speech[index] * speechScale + pauses[index] * pauseScale)
        }
        var result: [Int: LyricAccentWindow] = [:]
        var sourceOffset = 0
        for (index, text) in texts.enumerated() {
            let length = text.filter { !$0.isWhitespace }.count
            let ending = sourceOffset + length
            guard ending <= sourcePositions.count else { return nil }
            let spoken = sourcePositions[sourceOffset..<ending].filter { speech[$0] > 0 }
            if let first = spoken.first, let last = spoken.last {
                let onset = min(cue.duration, max(0, offsets[first]))
                let end = min(cue.duration, max(onset, offsets[last + 1]))
                if end > onset { result[index] = .init(startOffset: onset, endOffset: end) }
            }
            sourceOffset = ending
        }
        guard sourceOffset == sourcePositions.count else { return nil }
        return result
    }

    /// Shared visual estimate used by both emphasis and gradual glyph reveal.
    /// These weights describe text only; they are never provider/audio timing.
    static func estimatedPronunciation(_ text: String) -> (speech: [Double], pauses: [Double])? {
        guard text.utf8.count <= 16_384 else { return nil }
        let source = Array(text)
        guard !source.isEmpty, source.count <= 1_024 else { return nil }
        var speech = Array(repeating: 0.0, count: source.count)
        var pauses = Array(repeating: 0.0, count: source.count)
        var cursor = 0
        while cursor < source.count {
            let character = source[cursor]
            if character.isWhitespace { cursor += 1 }
            else if isCJK(character) {
                speech[cursor] = 1; cursor += 1
            } else if isLatinLetter(character) {
                let beginning = cursor
                cursor += 1
                while cursor < source.count {
                    if isLatinLetter(source[cursor]) { cursor += 1 }
                    else if joining.contains(source[cursor]), cursor + 1 < source.count,
                            isLatinLetter(source[cursor + 1]) { cursor += 1 }
                    else { break }
                }
                let word = String(source[beginning..<cursor])
                let letterCount = source[beginning..<cursor].filter(isLatinLetter).count
                let weight = pronunciationSyllables(word) / Double(max(1, letterCount))
                for index in beginning..<cursor where isLatinLetter(source[index]) { speech[index] = weight }
            } else if character.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
                // Digits may be sung as a number or read separately. A digit
                // unit is a bounded, language-neutral default for counters.
                speech[cursor] = 1; cursor += 1
            } else if character.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) {
                speech[cursor] = 1; cursor += 1
            } else {
                var pause = punctuationPause(character)
                let beginning = cursor
                cursor += 1
                while cursor < source.count, punctuationPause(source[cursor]) > 0 {
                    pause = max(pause, punctuationPause(source[cursor])); cursor += 1
                }
                // Repeated ellipses/exclamation marks form one modest pause.
                // Opening punctuation and emoji do not consume vocal time.
                if speech[..<beginning].contains(where: { $0 > 0 }) { pauses[cursor - 1] = pause }
            }
        }
        return (speech, pauses)
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
                || (0x20000...0x323AF).contains($0.value) || (0xF900...0xFAFF).contains($0.value)
                || (0x3040...0x30FF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value)
        }
    }
    private static func isLatinLetter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.value < 0x0250 && CharacterSet.letters.contains($0) }
            && character.unicodeScalars.allSatisfy {
                ($0.value < 0x0250 && CharacterSet.letters.contains($0)) || CharacterSet.nonBaseCharacters.contains($0)
            }
    }
    private static func pronunciationSyllables(_ text: String) -> Double {
        let letters = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter }
        guard !letters.isEmpty else { return 0 }
        let exceptions: [String: Double] = [
            "every": 2, "hour": 1, "our": 1, "quiet": 2, "beautiful": 3,
            "people": 2, "business": 2, "one": 1, "once": 1, "eyes": 1,
            "ocean": 2, "heaven": 2, "evening": 2
        ]
        if let count = exceptions[letters] { return count }
        let vowels = Set<Character>("aeiouy")
        let characters = Array(letters)
        if text == text.uppercased(), text != text.lowercased(), characters.count <= 6,
           !characters.contains(where: { vowels.contains($0) }) { return Double(characters.count) }
        var count = 0
        for index in characters.indices where vowels.contains(characters[index]) {
            if index == 0 || !vowels.contains(characters[index - 1]) { count += 1 }
        }
        if letters.hasSuffix("ed"), characters.count > 3,
           ![Character("t"), "d"].contains(characters[characters.count - 3]), count > 1 { count -= 1 }
        else if letters.hasSuffix("es"), characters.count > 3, count > 1,
                !letters.hasSuffix("ses"), !letters.hasSuffix("xes"), !letters.hasSuffix("zes"),
                !letters.hasSuffix("ches"), !letters.hasSuffix("shes") { count -= 1 }
        else if letters.hasSuffix("e"), count > 1 {
            let syllabicLE = letters.hasSuffix("le") && characters.count > 2 && !vowels.contains(characters[characters.count - 3])
            if !syllabicLE { count -= 1 }
        }
        return Double(min(12, max(1, count)))
    }
    private static func punctuationPause(_ character: Character) -> Double {
        if ",，、".contains(character) { return 0.35 }
        if ";；:：—–".contains(character) { return 0.45 }
        if ".。!?！？…".contains(character) { return 0.60 }
        return 0
    }

    private static func eligible(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 36,
              trimmed.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return false }
        let words = split(trimmed).filter { $0.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) }
        guard words.count <= 4 else { return false }
        return words.contains { word in
            let lexical = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            return !englishFunctionWords.contains(lexical) && !chineseFunctionWords.contains(lexical)
        }
    }
    private static func removingWhitespace(_ text: String) -> String { String(text.filter { !$0.isWhitespace }) }
    private static func isLatinWordEdge(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.value < 0x0250 && CharacterSet.alphanumerics.contains($0) }
            && character.unicodeScalars.allSatisfy {
                ($0.value < 0x0250 && CharacterSet.alphanumerics.contains($0)) || CharacterSet.nonBaseCharacters.contains($0)
            }
    }
    private static func gapClass(_ character: Character) -> Int {
        if character.isWhitespace { return 0 }
        if character.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) }) { return 1 }
        return 2
    }
    private static func stableHash(_ text: String, index: Int, seed: UInt64) -> UInt64 {
        var value = seed ^ 14_695_981_039_346_656_037
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
        value = (value ^ UInt64(index)) &* 1_099_511_628_211
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
    private static func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
    private static func bounded(_ value: Double, lower: Double, upper: Double) -> Double {
        value.isFinite ? min(upper, max(lower, value)) : min(upper, max(lower, 0))
    }
    private static func eventDuration(_ kind: LyricAccentKind) -> Double {
        switch kind { case .ring: 1.08; case .box: 1.16; case .flash: 0.84; case .weight: 1.20; case .pulse: 1.28; case .triangle: 1.14 }
    }
    private static func smooth(_ value: Double) -> Double { let x = clamp(value); return x * x * (3 - 2 * x) }
    private static func bump(_ value: Double, center: Double, width: Double) -> Double {
        let distance = abs(value - center) / width
        return distance < 1 ? (1 + cos(distance * .pi)) * 0.5 : 0
    }
}
