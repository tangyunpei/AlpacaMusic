import Foundation

/// A measured recognizer run. Multi-character runs retain their real boundaries;
/// the display can estimate inside them without labeling interpolations as exact.
struct LyricAudioAnchor: Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
    var confidence: Double
}

/// Strict, monotone matching of recognized audio to the supplied lyric text.
/// This is ASR-anchored alignment, not a phoneme forced aligner. It refuses missing
/// or substituted words instead of turning percussion or ASR guesses into timing.
enum LyricAudioAnchorMatcher {
    private struct Unit {
        var value: String
        var range: Range<String.Index>
    }
    private struct RecognizedUnit {
        var value: String
        var anchorIndex: Int
    }

    static func align(document: LyricDocument, anchors: [LyricAudioAnchor],
                      vocalRegions: [LyricVocalRegion], audioRange: Range<Double>,
                      engineVersion: String, localeIdentifier: String) -> LyricAlignmentResult {
        guard audioRange.lowerBound.isFinite, audioRange.upperBound.isFinite,
              audioRange.lowerBound >= 0, audioRange.upperBound > audioRange.lowerBound,
              !document.isInstrumental, document.timing != .plain else {
            return .init(lines: [], vocalRegions: [], engineVersion: engineVersion,
                         localeIdentifier: localeIdentifier)
        }
        let validAnchors = anchors.filter {
            $0.start.isFinite && $0.end.isFinite && $0.confidence.isFinite &&
            $0.start >= audioRange.lowerBound && $0.end <= audioRange.upperBound + 0.05 &&
            $0.end > $0.start && (0...1).contains($0.confidence) &&
            !$0.text.isEmpty && $0.text.utf8.count <= 4_096
        }.sorted { $0.start < $1.start }
        let regions = mergedVocalRegions(vocalRegions, within: audioRange)
        var output: [LyricAlignedLine] = []
        for line in document.lines {
            guard line.words.isEmpty, let start = line.start else { continue }
            let end = line.end ?? audioRange.upperBound
            guard
                  start >= audioRange.lowerBound, end <= audioRange.upperBound + 0.05,
                  end > start, line.text.utf8.count <= 4_096 else { continue }
            let target = units(in: line.text)
            guard (2...256).contains(target.count) else { continue }
            let candidates = validAnchors.enumerated().filter {
                // Tiny recognizer boundary jitter is clamped, but a phrase from a
                // different cue is never pulled in to satisfy repeated text.
                $0.element.start >= start - 0.08 && $0.element.start < end &&
                $0.element.end <= end + 0.08
            }
            let recognized = candidates.flatMap { pair in
                units(in: pair.element.text).map { RecognizedUnit(value: $0.value, anchorIndex: pair.offset) }
            }
            guard !recognized.isEmpty, recognized.count <= 1_024,
                  let matched = completeMonotoneMatch(target.map(\.value), in: recognized) else { continue }
            var groups: [(first: Int, last: Int, anchor: Int)] = []
            for (targetIndex, recognizedIndex) in matched.enumerated() {
                let anchorIndex = recognized[recognizedIndex].anchorIndex
                if groups.last?.anchor == anchorIndex {
                    groups[groups.count - 1].last = targetIndex
                } else {
                    groups.append((targetIndex, targetIndex, anchorIndex))
                }
            }
            guard groups.allSatisfy({ group in
                units(in: validAnchors[group.anchor].text).map(\.value) ==
                    target[group.first...group.last].map(\.value)
            }) else { continue }
            var words: [LyricWord] = []
            var confidenceSum = 0.0, estimatedCount = 0
            for (index, group) in groups.enumerated() {
                let anchor = validAnchors[group.anchor]
                let lower = index == 0 ? line.text.startIndex : target[group.first].range.lowerBound
                let upper = index + 1 < groups.count ? target[groups[index + 1].first].range.lowerBound : line.text.endIndex
                let wordStart = max(start, anchor.start), wordEnd = min(end, anchor.end)
                guard wordEnd > wordStart else { words = []; break }
                if let previous = words.last, wordStart < (previous.end ?? previous.start) - 0.02 {
                    words = []; break
                }
                if !words.isEmpty, wordStart < (words[words.count - 1].end ?? wordStart) {
                    words[words.count - 1].end = wordStart
                }
                words.append(.init(id: index, text: String(line.text[lower..<upper]),
                                   start: wordStart, end: wordEnd))
                let count = group.last - group.first + 1
                confidenceSum += anchor.confidence * Double(count)
                estimatedCount += max(0, count - 1)
            }
            guard !words.isEmpty, words.map(\.text).joined() == line.text else { continue }
            let totalDuration = words.reduce(0.0) { $0 + (($1.end ?? $1.start) - $1.start) }
            let vocalDuration = words.reduce(0.0) { sum, word in
                sum + overlap(start: word.start, end: word.end ?? word.start, regions: regions)
            }
            let quality = LyricAlignmentQuality(coverage: 1,
                                                meanConfidence: confidenceSum / Double(target.count),
                                                maximumAnchorDrift: abs((words.first?.start ?? start) - start),
                                                vocalOverlap: totalDuration > 0 ? vocalDuration / totalDuration : 0,
                                                matchedUnitCount: target.count,
                                                estimatedUnitCount: estimatedCount)
            // VAD must independently support recognized words. Exact lyric
            // matching alone is insufficient because ASR can hallucinate music.
            guard quality.meanConfidence >= 0.5, quality.vocalOverlap >= 0.65,
                  quality.maximumAnchorDrift <= 1.5 else { continue }
            output.append(.init(lineID: line.id, words: words, quality: quality))
        }
        return .init(lines: output, vocalRegions: regions, engineVersion: engineVersion,
                     localeIdentifier: localeIdentifier)
    }

    /// A bounded subsequence search requires every lyric unit to have an observed
    /// text match. Unmatched recognizer words may be ignored, never substituted.
    private static func completeMonotoneMatch(_ target: [String], in recognized: [RecognizedUnit]) -> [Int]? {
        var choices = [Int](repeating: -1, count: target.count)
        var cursor = 0
        for index in target.indices {
            while cursor < recognized.count, recognized[cursor].value != target[index] { cursor += 1 }
            guard cursor < recognized.count else { return nil }
            choices[index] = cursor
            cursor += 1
        }
        return choices
    }

    static func mergedVocalRegions(_ regions: [LyricVocalRegion], within range: Range<Double>) -> [LyricVocalRegion] {
        let valid = regions.compactMap { region -> LyricVocalRegion? in
            guard region.start.isFinite, region.end.isFinite, region.end > region.start else { return nil }
            let start = max(range.lowerBound, region.start), end = min(range.upperBound, region.end)
            return end > start ? .init(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        var merged: [LyricVocalRegion] = []
        for region in valid {
            if let previous = merged.last, region.start <= previous.end + 0.025 {
                merged[merged.count - 1].end = max(previous.end, region.end)
            } else { merged.append(region) }
        }
        return merged
    }

    private static func overlap(start: Double, end: Double, regions: [LyricVocalRegion]) -> Double {
        regions.reduce(0) { $0 + max(0, min(end, $1.end) - max(start, $1.start)) }
    }

    static func lexicalUnitCount(in text: String) -> Int { units(in: text).count }

    private static func units(in text: String) -> [Unit] {
        var result: [Unit] = [], wordStart: String.Index?, cursor = text.startIndex
        func appendWord(through end: String.Index) {
            guard let start = wordStart else { return }
            let range = start..<end
            result.append(.init(value: normalized(String(text[range])), range: range))
            wordStart = nil
        }
        while cursor < text.endIndex {
            let next = text.index(after: cursor), character = text[cursor]
            let cjk = character.unicodeScalars.contains { scalar in
                (0x3400...0x9FFF).contains(scalar.value) || (0x20000...0x323AF).contains(scalar.value) ||
                (0x3040...0x30FF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value)
            }
            let letter = character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            if cjk {
                appendWord(through: cursor)
                result.append(.init(value: normalized(String(character)), range: cursor..<next))
            } else if letter {
                if wordStart == nil { wordStart = cursor }
            } else if (character == "'" || character == "’" || character == "-"), wordStart != nil,
                      next < text.endIndex, text[next].unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                // Preserve apostrophes and internal hyphens in Latin words.
            } else { appendWord(through: cursor) }
            cursor = next
        }
        appendWord(through: text.endIndex)
        return result
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "’", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
    }
}
