import Foundation

/// Platform milliseconds are preserved. Invalid word metadata never replaces
/// readable LRC text; providers fall back before constructing their payload.
enum PlatformWordLyrics {
    enum Format { case yrc, qrc }

    static func parse(_ input: String, format: Format, translation: String? = nil) -> LyricDocument? {
        guard input.utf8.count <= LyricsParser.maximumBytes else { return nil }
        guard let text = content(input, format: format) else { return nil }
        let rows = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        guard rows.count <= LyricsParser.maximumLines else { return nil }
        guard let sentence = try? NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#),
              let token = try? NSRegularExpression(pattern: format == .yrc ? #"\((\d+),(\d+),(\d+)\)"# : #"\((\d+),(\d+)\)"#) else { return nil }
        var lines: [LyricLine] = [], totalWords = 0
        for raw in rows {
            let row = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard row.utf8.count <= 32_768 else { return nil }
            if row.isEmpty || row.hasPrefix("{") { continue }
            guard let match = sentence.firstMatch(in: row, range: NSRange(row.startIndex..., in: row)) else {
                // Standard metadata tags may accompany either format.
                if row.hasPrefix("["), row.hasSuffix("]"), row.contains(":") { continue }
                return nil
            }
            guard let start = milliseconds(match, at: 1, in: row),
                  let duration = milliseconds(match, at: 2, in: row),
                  start + duration <= 86_400_000,
                  let heading = Range(match.range, in: row) else { return nil }
            let body = String(row[heading.upperBound...])
            let matches = token.matches(in: body, range: NSRange(body.startIndex..., in: body))
            guard !matches.isEmpty else {
                if body.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                return nil
            }
            var words: [LyricWord] = []
            for (index, item) in matches.enumerated() {
                guard let full = Range(item.range, in: body),
                      let onset = milliseconds(item, at: 1, in: body),
                      let length = milliseconds(item, at: 2, in: body),
                      length > 0, onset >= start, onset + length <= start + duration + 1,
                      words.last.map({ seconds(onset) >= $0.start }) ?? true else { return nil }
                let value: String
                switch format {
                case .yrc:
                    let end = index + 1 < matches.count ? Range(matches[index + 1].range, in: body)!.lowerBound : body.endIndex
                    value = String(body[full.upperBound..<end])
                    if index == 0, !body[..<full.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty { return nil }
                case .qrc:
                    let begin = index > 0 ? Range(matches[index - 1].range, in: body)!.upperBound : body.startIndex
                    value = String(body[begin..<full.lowerBound])
                    if index == matches.count - 1, !body[full.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty { return nil }
                }
                guard !value.isEmpty else { return nil }
                words.append(.init(id: index, text: value, start: seconds(onset), end: seconds(onset + length)))
            }
            totalWords += words.count
            guard totalWords <= 100_000, duration > 0,
                  lines.last.map({ seconds(start) >= ($0.start ?? 0) }) ?? true else { return nil }
            lines.append(.init(id: lines.count, text: words.map(\.text).joined(), start: seconds(start), end: seconds(start + duration), words: words))
        }
        guard !lines.isEmpty else { return nil }
        var document = LyricDocument(lines: lines, timing: .word, sourceDescription: "")
        if let translation, let translated = translatedDocument(translation, format: format) {
            var cursor = 0
            for index in document.lines.indices {
                guard let start = document.lines[index].start else { continue }
                while cursor < translated.lines.count, (translated.lines[cursor].start ?? -.infinity) < start - 0.05 { cursor += 1 }
                if cursor < translated.lines.count, let otherStart = translated.lines[cursor].start,
                   abs(otherStart - start) <= 0.05, translated.lines[cursor].text != document.lines[index].text {
                    document.lines[index].translation = translated.lines[cursor].text
                }
            }
        }
        guard (try? LyricsParser.parse(.init(text: "", document: document), sourceDescription: "")) != nil else { return nil }
        return document
    }

    private static func content(_ input: String, format: Format) -> String? {
        guard input.utf8.count <= LyricsParser.maximumBytes else { return nil }
        if format == .qrc, input.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
            guard !input.localizedCaseInsensitiveContains("<!DOCTYPE"),
                  let attribute = try? NSRegularExpression(pattern: #"LyricContent\s*=\s*(["'])([\s\S]*?)\1"#),
                  let match = attribute.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
                  let quoteRange = Range(match.range(at: 1), in: input),
                  let contentRange = Range(match.range(at: 2), in: input) else { return nil }
            // Literal newlines in XML attributes are normally normalized to
            // spaces. QRC uses them as sentence separators; preserve them as
            // numeric entities before the standard XML decoder handles escapes.
            let quote = String(input[quoteRange])
            let escaped = String(input[contentRange]).replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "&#10;")
            let delegate = QRCDocumentReader()
            let parser = XMLParser(data: Data("<Qrc LyricContent=\(quote)\(escaped)\(quote)/>".utf8))
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            guard !input.localizedCaseInsensitiveContains("<!DOCTYPE"),
                  parser.parse(), let content = delegate.content else { return nil }
            return content
        } else { return input }
    }

    private static func translatedDocument(_ input: String, format: Format) -> LyricDocument? {
        if let parsed = try? LyricsParser.parse(input), parsed.timing != .plain { return parsed }
        guard let text = content(input, format: format),
              let expression = try? NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#) else { return nil }
        let rows = text.components(separatedBy: "\n")
        guard rows.count <= LyricsParser.maximumLines else { return nil }
        var lines: [LyricLine] = []
        for row in rows {
            guard let match = expression.firstMatch(in: row, range: NSRange(row.startIndex..., in: row)),
                  let start = milliseconds(match, at: 1, in: row),
                  let duration = milliseconds(match, at: 2, in: row), duration > 0, start + duration <= 86_400_000,
                  let heading = Range(match.range, in: row) else { continue }
            lines.append(.init(id: lines.count, text: String(row[heading.upperBound...]), start: seconds(start), end: seconds(start + duration)))
        }
        guard !lines.isEmpty else { return nil }
        return .init(lines: lines, timing: .line, sourceDescription: "")
    }

    private static func milliseconds(_ match: NSTextCheckingResult, at index: Int, in text: String) -> Int? {
        guard let range = Range(match.range(at: index), in: text), text[range].count <= 9,
              let value = Int(text[range]), value >= 0, value <= 86_400_000 else { return nil }
        return value
    }

    private static func seconds(_ milliseconds: Int) -> Double { Double(milliseconds) / 1_000 }
}

private final class QRCDocumentReader: NSObject, XMLParserDelegate {
    var content: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if let value = attributeDict["LyricContent"] {
            guard content == nil else { parser.abortParsing(); return }
            content = value
        }
    }
}
