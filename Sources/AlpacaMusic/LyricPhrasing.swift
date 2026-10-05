import Foundation
import NaturalLanguage

/// A bounded, language-aware partition of the original text. The returned
/// strings contain every original character; this changes layout, never cues.
@MainActor enum LyricPhrasing {
    private struct CacheKey: Hashable {
        var text: String
        var count: Int
        var budget: Double?
    }
    private static var cache: [CacheKey: [String]] = [:]
    private static var order: [CacheKey] = []
    private static let closing = Set<Character>("，。！？；：、）》」』】〉〕］｝’”.,!?;:%％…")
    private static let opening = Set<Character>("（([｛［《〈「『【〔“‘")
    private static let naturalStops = Set<Character>("，。！？；：、.,!?;:…")
    private static let connecting = Set<Character>("的地得把被在向从從对對与與和及或而但让讓将將为為都")
    private static let adverbs: Set<String> = ["缓缓", "緩緩", "慢慢", "渐渐", "漸漸", "仍然", "忽然", "轻轻", "輕輕", "正在", "可以", "应该", "應該", "已经", "已經", "也许", "也許", "仿佛", "彷彿"]
    private static let weakStarters = Set<Character>("的地得")
    private static let joining = Set<Character>("-'’‐‑")
    private static let numerals = Set<Character>("一二三四五六七八九十百千万萬亿億两兩几幾半每这這那哪各某")
    private static let classifiers = Set<Character>("个個只首扇张張幅间間条條位件份段次点點句片页頁本册冊朵株滴杯碗瓶双雙对對支枝盏盞颗顆粒座栋棟架辆輛台匹头頭尾群部集场場封")

    /// CJK and full-width characters occupy one unit, Latin letters about half
    /// a unit. Emoji are measured as whole graphemes, including ZWJ sequences.
    static func widthUnits(_ text: String) -> Double {
        text.reduce(0) { $0 + width(of: $1) }
    }

    static func phrases(_ text: String, targetCount: Int, maximumUnits: Double? = nil) -> [String] {
        guard !text.isEmpty else { return [] }
        let count = min(6, max(1, targetCount))
        let suppliedBudget = maximumUnits.flatMap { $0.isFinite ? min(32, max(4, $0)) : nil }
        let key = CacheKey(text: text, count: count, budget: suppliedBudget)
        if let saved = cache[key] { return saved }
        let result = partition(text, count: count, maximumUnits: suppliedBudget)
        // Extremely large input stays available to the reading-layout fallback,
        // and does not evict normal cues or retain megabytes in this small cache.
        if text.utf8.count <= 16_384 {
            if order.count >= 32 { cache.removeValue(forKey: order.removeFirst()) }
            order.append(key); cache[key] = result
        }
        return result
    }

    private static func partition(_ text: String, count: Int, maximumUnits: Double?) -> [String] {
        let characters = Array(text)
        guard characters.count <= 2_048 else { return [text] }
        let indices = Array(text.indices) + [text.endIndex]
        let offsets = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($0.element, $0.offset) })
        var widths = [0.0]
        for character in characters { widths.append(widths.last! + width(of: character)) }
        let total = widths.last ?? 0
        let containsHan = characters.contains(where: isHan)
        guard total > 0 else { return [text] }
        let budget = maximumUnits ?? min(32, max(6, total / Double(count) * 1.25))
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var cuts: Set<Int> = [0, characters.count]
        var forced: Set<Int> = []

        func carriedBoundary(_ offset: Int) -> Int {
            var end = offset
            while end < characters.count, closing.contains(characters[end]) { end += 1 }
            while end < characters.count, characters[end].isWhitespace, !isNewline(characters[end]) { end += 1 }
            return end
        }
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if let raw = offsets[range.upperBound] {
                let end = carriedBoundary(raw)
                if isLexicalBoundary(end, in: characters) { cuts.insert(end) }
            }
            return true
        }
        for offset in characters.indices {
            let character = characters[offset]
            if isNewline(character) {
                cuts.insert(offset + 1); forced.insert(offset + 1)
            } else if character.isWhitespace || naturalStops.contains(character) || isEmoji(character) {
                let end = carriedBoundary(offset + 1)
                if isLexicalBoundary(end, in: characters) { cuts.insert(end) }
            }
        }
        let boundaries = cuts.sorted()
        // Limits apply to computational work, not to the user's text. The view
        // can render the untouched sentence in its existing scroll fallback.
        guard boundaries.count <= 512 else { return [text] }
        let required = max(1, Int(ceil(total / budget)))
        let desired = max(min(count, max(1, Int(total / 4))), required, forced.count + (forced.contains(characters.count) ? 0 : 1))
        let maximumRows = min(64, boundaries.count - 1, max(desired, count) + 5)
        guard maximumRows > 0, desired <= 64 else { return [text] }
        let ideal = max(1, total / Double(desired))
        let orphan = min(3.2, budget * 0.45)
        let n = boundaries.count
        let boundaryCosts = boundaries.map { boundaryCost(at: $0, characters: characters, preferentialWhitespace: containsHan) }
        var scores = Array(repeating: Array(repeating: Double.infinity, count: n), count: maximumRows + 1)
        var previous = Array(repeating: Array(repeating: -1, count: n), count: maximumRows + 1)
        scores[0][0] = 0
        var nearestForced = Array(repeating: characters.count, count: n)
        for start in 0..<n {
            nearestForced[start] = forced.filter { $0 > boundaries[start] }.min() ?? characters.count
        }

        // Each edge is a complete token span. All lines, including the last,
        // obey the same budget. Only a single indivisible long token may exceed
        // it, so the final row can never absorb a leftover paragraph.
        for rows in 1...maximumRows {
            for end in 1..<n {
                for start in stride(from: end - 1, through: 0, by: -1) {
                    guard scores[rows - 1][start].isFinite else { continue }
                    if boundaries[end] > nearestForced[start] { continue }
                    let span = widths[boundaries[end]] - widths[boundaries[start]]
                    let indivisible = end == start + 1
                    if span > budget + 0.000_001, !indivisible { continue }
                    let deviation = (min(span, max(budget, ideal)) - ideal) / ideal
                    var cost = deviation * deviation * 4
                    if span < orphan, total >= orphan * 2 {
                        cost += pow((orphan - span) / orphan, 2) * 38
                    }
                    cost += boundaryCosts[end]
                    // Original newlines are explicit choices and can contain a
                    // blank line; do not penalize preserving that input.
                    if forced.contains(boundaries[end]), span < 0.001 { cost = 0 }
                    let candidate = scores[rows - 1][start] + cost
                    if candidate < scores[rows][end] {
                        scores[rows][end] = candidate; previous[rows][end] = start
                    }
                }
            }
        }
        let last = n - 1
        let chosen = (1...maximumRows).filter { scores[$0][last].isFinite }.min { lhs, rhs in
            scores[lhs][last] + pow(Double(lhs - desired), 2) * 3.2 <
            scores[rhs][last] + pow(Double(rhs - desired), 2) * 3.2
        }
        guard var rows = chosen else { return [text] }
        var end = last, ranges: [Range<Int>] = []
        while rows > 0 {
            let start = previous[rows][end]
            guard start >= 0 else { return [text] }
            ranges.append(boundaries[start]..<boundaries[end]); end = start; rows -= 1
        }
        return ranges.reversed().map { String(text[indices[$0.lowerBound]..<indices[$0.upperBound]]) }
    }

    private static func boundaryCost(at offset: Int, characters: [Character], preferentialWhitespace: Bool) -> Double {
        guard offset < characters.count else { return 0 }
        var before = offset - 1
        while before >= 0, characters[before].isWhitespace { before -= 1 }
        guard before >= 0 else { return 0 }
        if isNewline(characters[offset - 1]) { return -2.5 }
        if naturalStops.contains(characters[before]) { return -3.5 }
        var penalty = 0.35
        if connecting.contains(characters[before]) { penalty += 18 }
        if before > 0, adverbs.contains(String(characters[(before - 1)...before])) { penalty += 6 }
        if closing.contains(characters[offset]) { penalty += 40 }
        if weakStarters.contains(characters[offset]) { penalty += 8 }
        // Spaces in Chinese lyrics commonly separate musical phrases. This is
        // a preference, not a forced cut: budget and orphan penalties still
        // govern the complete partition. Ordinary English retains balancing.
        if offset > 0, characters[offset - 1].isWhitespace { penalty -= preferentialWhitespace ? 3.5 : 0.3 }
        return penalty
    }

    private static func isLexicalBoundary(_ offset: Int, in characters: [Character]) -> Bool {
        guard offset > 0, offset < characters.count else { return true }
        let previous = characters[offset - 1], next = characters[offset]
        if closing.contains(next) { return false }
        var contentBefore = offset - 1
        while contentBefore > 0, characters[contentBefore].isWhitespace, !isNewline(characters[contentBefore]) { contentBefore -= 1 }
        if opening.contains(characters[contentBefore]) { return false }
        // Tokenizers can report a numeral and its classifier independently.
        // Keep these small grammatical atoms together without a general-purpose
        // verb/object dictionary or any invented lyric timing.
        if isNumeral(previous) {
            var after = offset
            while after < characters.count, isNumeral(characters[after]), after - offset < 6 { after += 1 }
            if after < characters.count, classifiers.contains(characters[after]) { return false }
        }
        if isLatin(previous), isLatin(next) { return false }
        if isLatin(previous), joining.contains(next), offset + 1 < characters.count, isLatin(characters[offset + 1]) { return false }
        if joining.contains(previous), isLatin(next), offset > 1, isLatin(characters[offset - 2]) { return false }
        return true
    }

    private static func isLatin(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isAlphabetic && (scalar.value <= 0x02af || (0x1e00...0x1eff).contains(scalar.value))
        }
    }
    private static func isNumeral(_ character: Character) -> Bool {
        numerals.contains(character) || character.isNumber
    }
    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x3400...0x9fff).contains(scalar.value) || (0xf900...0xfaff).contains(scalar.value) ||
            (0x20000...0x323af).contains(scalar.value)
        }
    }
    private static func isNewline(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.newlines.contains($0) }
    }
    private static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xfe0f || $0.value == 0x200d }
    }
    private static func width(of character: Character) -> Double {
        if isNewline(character) { return 0 }
        if character.isWhitespace { return 0.24 }
        if isEmoji(character) { return 1 }
        // Stops and closing marks have little ink compared with a CJK letter.
        // A comma plus its original following space should not force a lone
        // connector onto the preceding row merely to satisfy a width estimate.
        if naturalStops.contains(character) || closing.contains(character) { return 0.38 }
        if character.unicodeScalars.contains(where: { scalar in
            (0x1100...0x11ff).contains(scalar.value) || (0x2e80...0xa4cf).contains(scalar.value) ||
            (0xac00...0xd7af).contains(scalar.value) || (0xf900...0xfaff).contains(scalar.value) ||
            (0xff01...0xff60).contains(scalar.value) || (0x20000...0x323af).contains(scalar.value)
        }) { return 1 }
        return isLatin(character) || character.isNumber ? 0.5 : 0.75
    }
}
