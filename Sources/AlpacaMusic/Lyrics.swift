import Foundation

enum LyricsFormat: String, Codable, Sendable { case lrc, srt, plain }
enum LyricTiming: String, Codable, Sendable { case plain, line, word }
enum LyricWordTimingOrigin: String, Codable, Sendable { case audioEstimate }
enum LyricsStatus: String, Sendable { case idle, loading, ready, unavailable, failed }

struct LyricWord: Identifiable, Codable, Equatable, Sendable {
    var id: Int
    var text: String
    var start: Double
    var end: Double? = nil
}
struct LyricLine: Identifiable, Codable, Equatable, Sendable {
    var id: Int
    var text: String
    var start: Double? = nil
    var end: Double? = nil
    var words: [LyricWord] = []
    var translation: String? = nil
    var wordTimingOrigin: LyricWordTimingOrigin? = nil
}
struct LyricDocument: Codable, Equatable, Sendable {
    var lines: [LyricLine]
    var timing: LyricTiming
    var sourceDescription: String
    var isInstrumental: Bool = false
    var title: String? = nil
    var artist: String? = nil

    /// Binary search follows seeks in either direction without retaining a
    /// stale current-line cursor. Explicit SRT gaps remain unhighlighted.
    func activeIndex(at seconds: Double) -> Int? {
        guard seconds.isFinite, seconds >= 0, timing != .plain else { return nil }
        var lower = 0, upper = lines.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if (lines[middle].start ?? -.infinity) <= seconds { lower = middle + 1 }
            else { upper = middle }
        }
        guard lower > 0 else { return nil }
        let index = lower - 1
        guard lines[index].start != nil, lines[index].end.map({ seconds < $0 }) ?? true else { return nil }
        return index
    }
    func activeWordIndex(in lineIndex: Int, at seconds: Double) -> Int? {
        guard lines.indices.contains(lineIndex), seconds.isFinite else { return nil }
        return lines[lineIndex].words.lastIndex { $0.start <= seconds && ($0.end.map { seconds < $0 } ?? true) }
    }
}

/// Authenticated platform text stays in memory; public LRCLIB results have a
/// separate bounded cache in LyricsStorage.
struct LyricsPayload: Sendable {
    var text: String
    var translation: String? = nil
    var format: LyricsFormat = .lrc
    var isInstrumental: Bool = false
    /// Platforms with explicit sentence and word ends can supply their measured
    /// timing without rounding through a textual LRC representation.
    var document: LyricDocument? = nil
}

enum LyricsParser {
    static let maximumBytes = 2 * 1024 * 1024
    static let maximumLines = 10_000

    static func parse(_ text: String, format: LyricsFormat? = nil, sourceDescription: String = L10n.string("歌词")) throws -> LyricDocument {
        guard text.utf8.count <= maximumBytes else { throw MusicError.message(L10n.string("歌词文件超过 2 MB，无法读取。")) }
        let normalized = text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let raw = normalized.components(separatedBy: "\n")
        guard raw.count <= maximumLines, raw.allSatisfy({ $0.utf8.count <= 32_768 }) else {
            throw MusicError.message(L10n.string("歌词行数或单行长度过大，无法读取。"))
        }
        let actual = format ?? (normalized.contains("-->") ? .srt : .lrc)
        let result: LyricDocument
        switch actual {
        case .plain:
            result = LyricDocument(lines: raw.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.enumerated().map { .init(id: $0.offset, text: $0.element) }, timing: .plain, sourceDescription: sourceDescription)
        case .srt: result = try parseSRT(raw, sourceDescription: sourceDescription)
        case .lrc: result = try parseLRC(raw, sourceDescription: sourceDescription)
        }
        guard !result.lines.isEmpty else { throw MusicError.message(L10n.string("没有找到可显示的歌词。")) }
        return result
    }

    static func parse(_ payload: LyricsPayload, sourceDescription: String) throws -> LyricDocument {
        if payload.isInstrumental {
            return .init(lines: [], timing: .plain, sourceDescription: sourceDescription, isInstrumental: true)
        }
        if var document = payload.document {
            try validate(document)
            document.sourceDescription = sourceDescription
            return document
        }
        var document = try parse(payload.text, format: payload.format, sourceDescription: sourceDescription)
        if let text = payload.translation, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let translated = try? parse(text, format: payload.format, sourceDescription: sourceDescription), translated.timing != .plain {
            // Match timestamped translations only. Similar titles or line counts
            // are never enough to attach unrelated text to the current line.
            var cursor = 0
            for index in document.lines.indices {
                guard let start = document.lines[index].start else { continue }
                while cursor < translated.lines.count, (translated.lines[cursor].start ?? -.infinity) < start - 0.05 { cursor += 1 }
                if cursor < translated.lines.count, let otherStart = translated.lines[cursor].start, abs(otherStart - start) <= 0.05 {
                    let other = translated.lines[cursor].text
                    if other != document.lines[index].text { document.lines[index].translation = other }
                }
            }
        }
        return document
    }

    private static func validate(_ document: LyricDocument) throws {
        guard document.lines.count <= maximumLines,
              document.isInstrumental || !document.lines.isEmpty else {
            throw MusicError.message(L10n.string("平台歌词为空或行数过多，无法读取。"))
        }
        var bytes = 0, words = 0, previousLine = -Double.infinity
        func valid(_ value: Double) -> Bool { value.isFinite && value >= 0 && value <= 86_400 }
        for line in document.lines {
            bytes += line.text.utf8.count + (line.translation?.utf8.count ?? 0)
            words += line.words.count
            guard line.text.utf8.count <= 32_768, bytes <= maximumBytes, words <= 100_000 else {
                throw MusicError.message(L10n.string("平台歌词内容过大，无法读取。"))
            }
            if let start = line.start {
                guard valid(start), start >= previousLine,
                      line.end.map({ valid($0) && $0 > start }) ?? true else {
                    throw MusicError.message(L10n.string("平台歌词句子时间无效，无法同步显示。"))
                }
                previousLine = start
            } else if document.timing != .plain {
                throw MusicError.message(L10n.string("平台歌词缺少句子时间。"))
            }
            var previousWord = line.start ?? 0
            for word in line.words {
                bytes += word.text.utf8.count
                guard bytes <= maximumBytes, word.text.utf8.count <= 32_768,
                      valid(word.start), word.start >= previousWord,
                      word.end.map({ valid($0) && $0 > word.start }) ?? true,
                      line.end.map({ (word.end ?? word.start) <= $0 }) ?? true else {
                    throw MusicError.message(L10n.string("平台逐字歌词时间无效，无法同步显示。"))
                }
                previousWord = word.start
            }
        }
    }

    private static func parseLRC(_ raw: [String], sourceDescription: String) throws -> LyricDocument {
        var offset = 0.0, title: String?, artist: String?
        for line in raw {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.lowercased().hasPrefix("[offset:"), value.hasSuffix("]"), let milliseconds = Double(value.dropFirst(8).dropLast()), milliseconds.isFinite {
                guard abs(milliseconds) <= 86_400_000 else { throw MusicError.message(L10n.string("歌词时间偏移超出有效范围。")) }
                // Positive LRC offset advances lyrics relative to the audio.
                offset = milliseconds / 1_000
            }
            if value.lowercased().hasPrefix("[ti:"), value.hasSuffix("]") { title = String(value.dropFirst(4).dropLast()) }
            if value.lowercased().hasPrefix("[ar:"), value.hasSuffix("]") { artist = String(value.dropFirst(4).dropLast()) }
        }
        var lines: [LyricLine] = [], expandedBytes = 0, expandedWords = 0
        for rawLine in raw {
            var remainder = rawLine.trimmingCharacters(in: .whitespaces)
            if remainder.isEmpty { continue }
            var timestamps: [Double] = []
            while remainder.first == "[", let closing = remainder.firstIndex(of: "]") {
                let token = String(remainder[remainder.index(after: remainder.startIndex)..<closing])
                guard let time = timestamp(token) else { break }
                timestamps.append(time)
                remainder = String(remainder[remainder.index(after: closing)...])
            }
            if timestamps.isEmpty {
                if remainder.hasPrefix("["), remainder.hasSuffix("]"), remainder.contains(":") { continue }
                lines.append(.init(id: lines.count, text: remainder))
                continue
            }
            for time in timestamps {
                let shift = time - (timestamps.first ?? time) - offset
                let words = try enhancedWords(remainder, shift: shift, lineStart: max(0, time - offset))
                let text = words.isEmpty ? remainder : words.map(\.text).joined()
                expandedBytes += text.utf8.count; expandedWords += words.count
                guard expandedBytes <= maximumBytes, expandedWords <= 100_000 else {
                    throw MusicError.message(L10n.string("重复时间标记展开后的歌词过大，无法读取。"))
                }
                lines.append(.init(id: lines.count, text: text.trimmingCharacters(in: .whitespaces), start: max(0, time - offset), words: words))
                guard lines.count <= maximumLines else { throw MusicError.message(L10n.string("歌词时间标记过多，无法读取。")) }
            }
        }
        return finalize(lines, sourceDescription: sourceDescription, title: title, artist: artist)
    }

    private static func enhancedWords(_ text: String, shift: Double, lineStart: Double) throws -> [LyricWord] {
        let pattern = #"<(\d{1,4}:\d{1,2}(?:[.:]\d{1,3})?)>"#
        let expression = try NSRegularExpression(pattern: pattern)
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return [] }
        var words: [LyricWord] = []
        if let range = Range(matches[0].range, in: text), range.lowerBound > text.startIndex {
            let prefix = String(text[..<range.lowerBound])
            if !prefix.isEmpty { words.append(.init(id: words.count, text: prefix, start: lineStart)) }
        }
        for (index, match) in matches.enumerated() {
            guard let tag = Range(match.range(at: 1), in: text), let time = timestamp(String(text[tag])),
                  let full = Range(match.range, in: text) else { continue }
            let end = index + 1 < matches.count ? Range(matches[index + 1].range, in: text)!.lowerBound : text.endIndex
            let start = max(0, time + shift)
            if let previous = words.last {
                guard start >= previous.start else { throw MusicError.message(L10n.string("逐字歌词时间顺序无效，无法同步显示。")) }
                words[words.count - 1].end = start
            }
            let value = String(text[full.upperBound..<end])
            if !value.isEmpty { words.append(.init(id: words.count, text: value, start: start)) }
        }
        return words
    }

    private static func parseSRT(_ raw: [String], sourceDescription: String) throws -> LyricDocument {
        var result: [LyricLine] = [], index = 0
        while index < raw.count {
            if raw[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1; continue }
            if Int(raw[index].trimmingCharacters(in: .whitespaces)) != nil { index += 1 }
            guard index < raw.count else { throw MusicError.message(L10n.string("SRT 歌词缺少时间范围。")) }
            let parts = raw[index].components(separatedBy: "-->")
            guard parts.count == 2, let start = srtTimestamp(parts[0]), let end = srtTimestamp(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0]), end > start else {
                throw MusicError.message(L10n.string("SRT 歌词时间格式无效。"))
            }
            index += 1
            var text: [String] = []
            while index < raw.count, !raw[index].trimmingCharacters(in: .whitespaces).isEmpty { text.append(raw[index]); index += 1 }
            result.append(.init(id: result.count, text: text.joined(separator: "\n"), start: start, end: end))
        }
        return finalize(result, sourceDescription: sourceDescription)
    }

    private static func timestamp(_ value: String) -> Double? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), let minutes = Double(parts[0]), minutes >= 0, minutes <= 1440 else { return nil }
        let seconds: Double?
        if parts.count == 3 { seconds = Double("\(parts[1]).\(parts[2])") } else { seconds = Double(parts[1]) }
        guard let seconds, seconds >= 0, seconds < 60, seconds.isFinite, minutes.rounded(.down) == minutes else { return nil }
        return minutes * 60 + seconds
    }
    private static func srtTimestamp(_ value: String) -> Double? {
        let parts = value.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let hours = Double(parts[0]), hours >= 0, hours <= 24,
              let minutes = Double(parts[1]), minutes >= 0, minutes < 60,
              let seconds = Double(parts[2].replacingOccurrences(of: ",", with: ".")), seconds >= 0, seconds < 60 else { return nil }
        let result = hours * 3600 + minutes * 60 + seconds
        return result.isFinite ? result : nil
    }
    private static func finalize(_ input: [LyricLine], sourceDescription: String, title: String? = nil, artist: String? = nil) -> LyricDocument {
        var lines = input.sorted { a, b in
            if a.start == b.start { return a.id < b.id }
            return (a.start ?? -.infinity) < (b.start ?? -.infinity)
        }
        var merged: [LyricLine] = []
        for line in lines {
            if let last = merged.last, line.start != nil, last.start == line.start {
                if last.text != line.text { merged[merged.count - 1].text += "\n" + line.text; merged[merged.count - 1].words = [] }
            } else { merged.append(line) }
        }
        lines = merged
        for index in lines.indices {
            lines[index].id = index
            if lines[index].start != nil, lines[index].end == nil, index + 1 < lines.count { lines[index].end = lines[index + 1].start }
            if !lines[index].words.isEmpty, lines[index].words.last?.end == nil { lines[index].words[lines[index].words.count - 1].end = lines[index].end }
        }
        let timing: LyricTiming = lines.contains(where: { !$0.words.isEmpty }) ? .word : (lines.contains(where: { $0.start != nil }) ? .line : .plain)
        return .init(lines: lines, timing: timing, sourceDescription: sourceDescription, title: title, artist: artist)
    }
}
